//go:build !windows

package libbox

import (
	"context"
	stdjson "encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/kafeifei/xdial/core/config"
	"github.com/kafeifei/xdial/core/engine"
	"github.com/sagernet/sing-box/adapter"
)

const (
	lineReadinessTransient  = "line-readiness-transient"
	lineReadinessTerminal   = "line-readiness-terminal"
	lineReadinessCancelled  = "line-readiness-cancelled"
	lineReadinessSuperseded = "network-superseded"
)

type lineNetworkContext struct {
	Epoch        string             `json:"epoch"`
	Interfaces   stdjson.RawMessage `json:"network_interfaces"`
	DefaultName  string             `json:"default_interface_name"`
	DefaultIndex int                `json:"default_interface_index"`
	SystemDNS    []string           `json:"system_dns,omitempty"`
}

type lineNetworkProof struct {
	capabilities outboundTLSCapabilities
	revision     uint64
	code         string
}

type lineNetworkRequirement struct {
	id, identity, kind string
	tags               []string
}

type lineNetworkProbe struct {
	done  chan struct{}
	proof lineNetworkProof
	err   error
}

// The requirement closure comes from the same Go-generated session as the
// immutable Box. Proofs belong to this exact Box generation, while protocol
// recovery belongs to the capability shared by committed/candidate leases.
type lineNetworkGeneration struct {
	mu             sync.Mutex
	libbox         *Libbox
	epoch          string
	generation     uint64
	requirements   []lineNetworkRequirement
	proofs         map[string]lineNetworkProof
	probes         map[string]*lineNetworkProbe
	anyConnect     *anyConnectRuntimeCapability
	tailscale      pooledTailscaleRuntime
	structuralCode string
	operationCode  string
	operationID    uint64
}

type lineReadinessItem struct {
	LineID          string `json:"line_id"`
	State           string `json:"state"`
	NetworkEpoch    string `json:"network_epoch"`
	RuntimeRevision uint64 `json:"runtime_revision"`
	ProofKind       string `json:"proof_kind"`
	IPv4Available   *bool  `json:"ipv4_available,omitempty"`
	IPv6Available   *bool  `json:"ipv6_available,omitempty"`
	Code            string `json:"code,omitempty"`
}

type lineReadinessReport struct {
	Epoch string              `json:"epoch"`
	State string              `json:"state"`
	Code  string              `json:"code,omitempty"`
	Lines []lineReadinessItem `json:"lines"`
}

type lineReadinessError struct {
	code  string
	cause error
}

func (e *lineReadinessError) Error() string { return e.code + ": " + e.cause.Error() }
func (e *lineReadinessError) Unwrap() error { return e.cause }

func readinessErrorCode(err error) string {
	var typed *lineReadinessError
	if errors.As(err, &typed) {
		return typed.code
	}
	if errors.Is(err, context.Canceled) {
		return lineReadinessCancelled
	}
	if transientLineReadinessError(err) {
		return lineReadinessTransient
	}
	return lineReadinessTerminal
}

func firstLineNetworkGeneration(values []*lineNetworkGeneration) *lineNetworkGeneration {
	if len(values) == 0 {
		return nil
	}
	return values[0]
}

func (g *lineNetworkGeneration) install(generation uint64, vpn *anyConnectRuntimeCapability, tailscale pooledTailscaleRuntime) {
	g.mu.Lock()
	g.generation, g.anyConnect, g.tailscale = generation, vpn, tailscale
	g.mu.Unlock()
	if vpn != nil {
		vpn.attachOwner(g.libbox, true)
		vpn.observeNetwork(g.epoch, nil)
	}
	if tailscale != nil {
		if platform := tailscale.platformInterface(); platform != nil {
			// A newly started endpoint already consumed this snapshot. Register its
			// initial epoch without sending a synthetic network-change notification
			// when another Scene first borrows it on the same network.
			platform.mu.Lock()
			if platform.lineEpoch == "" {
				platform.lineEpoch = g.epoch
			}
			platform.mu.Unlock()
		}
	}
}

func (l *Libbox) decodeNetworkSession(sessionJSON, contextJSON string) (*transparentProxySession, *lineNetworkContext, *lineNetworkGeneration, error) {
	var envelope transparentProxySession
	var network lineNetworkContext
	g := &lineNetworkGeneration{libbox: l, proofs: make(map[string]lineNetworkProof), probes: make(map[string]*lineNetworkProbe)}
	if err := stdjson.Unmarshal([]byte(contextJSON), &network); err != nil {
		return nil, nil, g, err
	}
	network.Epoch = strings.TrimSpace(network.Epoch)
	g.epoch = network.Epoch
	if network.Epoch == "" || network.DefaultName == "" || network.DefaultIndex <= 0 || len(network.Interfaces) == 0 {
		return nil, nil, g, fmt.Errorf("network context is incomplete")
	}
	if err := stdjson.Unmarshal([]byte(sessionJSON), &envelope); err != nil {
		return nil, nil, g, err
	}
	if envelope.Plan == nil || envelope.ConfigJSON == "" {
		return nil, nil, g, fmt.Errorf("session envelope is incomplete")
	}
	seen := make(map[string]bool)
	for _, task := range envelope.Plan.Tasks {
		if task.Kind != config.ConnectionTaskLine {
			continue
		}
		id := task.ResourceID
		identity, tag := envelope.LineRuntimeIdentities[id], envelope.LineOutbounds[id]
		if id == "" || identity == "" || tag == "" || seen[id] {
			return nil, nil, g, fmt.Errorf("session Line requirement is incomplete or duplicated")
		}
		seen[id] = true
		requirement := lineNetworkRequirement{id: id, identity: identity, kind: task.ResourceType, tags: []string{tag}}
		g.requirements = append(g.requirements, requirement)
	}
	if len(seen) != len(envelope.LineOutbounds) || len(seen) != len(envelope.LineRuntimeIdentities) {
		return nil, nil, g, fmt.Errorf("session Line requirement closure does not match the plan")
	}
	subscriptions := make(map[string]bool)
	for _, task := range envelope.Plan.Tasks {
		if task.Kind != config.ConnectionTaskSubscription {
			continue
		}
		id := task.ResourceID
		tags := envelope.SubscriptionOutbounds[id]
		if id == "" || len(tags) == 0 || subscriptions[id] {
			return nil, nil, g, fmt.Errorf("subscription readiness closure is incomplete")
		}
		subscriptions[id] = true
		identity, err := subscriptionNetworkIdentity(envelope.ConfigJSON, tags)
		if err != nil {
			return nil, nil, g, err
		}
		g.requirements = append(g.requirements, lineNetworkRequirement{id: id, identity: identity, kind: "subscription", tags: append([]string(nil), tags...)})
	}
	if len(subscriptions) != len(envelope.SubscriptionOutbounds) || len(g.requirements) == 0 {
		return nil, nil, g, fmt.Errorf("session readiness closure does not match the plan")
	}
	sort.Slice(g.requirements, func(i, j int) bool { return g.requirements[i].id < g.requirements[j].id })
	return &envelope, &network, g, nil
}

func containsLineTag(tags []string, tag string) bool {
	for _, candidate := range tags {
		if candidate == tag {
			return true
		}
	}
	return false
}

func subscriptionNetworkIdentity(configJSON string, tags []string) (string, error) {
	var document struct {
		Outbounds []map[string]interface{} `json:"outbounds"`
	}
	if err := stdjson.Unmarshal([]byte(configJSON), &document); err != nil {
		return "", err
	}
	var material []map[string]interface{}
	seen := make(map[string]bool)
	for _, tag := range tags {
		if tag == "" || seen[tag] {
			return "", fmt.Errorf("subscription readiness tag is empty or duplicated")
		}
		seen[tag] = true
		found := false
		for _, outbound := range document.Outbounds {
			if outbound["tag"] == tag {
				copy := make(map[string]interface{}, len(outbound))
				for key, value := range outbound {
					if key != "tag" {
						copy[key] = value
					}
				}
				material = append(material, copy)
				found = true
				break
			}
		}
		if !found {
			return "", fmt.Errorf("subscription readiness outbound is absent from the generated Box")
		}
	}
	return opaqueLineRuntimeIdentity(struct {
		Kind      string
		Outbounds []map[string]interface{}
	}{"subscription", material})
}

func (l *Libbox) observeNetworkGeneration(network *lineNetworkContext, g *lineNetworkGeneration) error {
	canonical, err := stdjson.Marshal(network)
	if err != nil {
		return err
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	l.lastNetworkReadiness = g
	if l.networkEpochs == nil {
		l.networkEpochs = make(map[string]bool)
	}
	if network.Epoch == l.networkEpoch {
		if string(canonical) != l.networkContextJSON {
			return &lineReadinessError{lineReadinessTerminal, fmt.Errorf("the same network epoch has different Underlay facts")}
		}
	} else {
		if l.networkEpochs[network.Epoch] {
			return &lineReadinessError{lineReadinessSuperseded, fmt.Errorf("network epoch has already been superseded")}
		}
		l.networkEpochs[network.Epoch] = true
		l.networkEpoch, l.networkContextJSON = network.Epoch, string(canonical)
	}
	return nil
}

func (l *Libbox) publishNetworkFailure(g *lineNetworkGeneration, err error) error {
	if err == nil {
		return nil
	}
	g.recordStructuralError(err)
	l.mu.Lock()
	if l.lastNetworkReadiness == nil || l.lastNetworkReadiness == g || l.networkEpoch == g.epoch {
		l.lastNetworkReadiness = g
	}
	l.mu.Unlock()
	return err
}

func (g *lineNetworkGeneration) recordError(err error) {
	// validatePreparedSwitchCommitLocked calls this for both structural epoch
	// failures and the current per-Line report. Only the former is generation
	// state; a later current proof must be able to replace a Line failure.
	if readinessErrorCode(err) == lineReadinessSuperseded {
		g.recordStructuralError(err)
	}
}

func (g *lineNetworkGeneration) recordStructuralError(err error) {
	if err == nil {
		return
	}
	code := readinessErrorCode(err)
	g.mu.Lock()
	if readinessPriority(code) > readinessPriority(g.structuralCode) {
		g.structuralCode = code
	}
	g.mu.Unlock()
}

func (g *lineNetworkGeneration) beginReadinessOperation() uint64 {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.operationID++
	g.operationCode = ""
	return g.operationID
}

func (g *lineNetworkGeneration) recordOperationError(operationID uint64, err error) {
	if err == nil {
		return
	}
	code := readinessErrorCode(err)
	g.mu.Lock()
	if operationID == g.operationID && readinessPriority(code) > readinessPriority(g.operationCode) {
		g.operationCode = code
	}
	g.mu.Unlock()
}

func (g *lineNetworkGeneration) hasCurrentFailureProof(requirement lineNetworkRequirement, tag string) bool {
	revision := g.revisionFor(requirement)
	g.mu.Lock()
	defer g.mu.Unlock()
	proof, exists := g.proofs[tag]
	return exists && proof.revision == revision && proof.code != ""
}

func networkSessionRuntimeInputs(envelope *transparentProxySession, dialAddress string) (*engine.VPNConfig, string, string, string) {
	var vpnConfig *engine.VPNConfig
	var vpnIdentity, tailscaleID, tailscaleIdentity string
	if vpn := envelope.AnyConnect; vpn != nil {
		value := startVPNConfig(vpn.Server, dialAddress, vpn.Username, vpn.Password, vpn.AllowInsecure)
		vpnConfig, vpnIdentity = &value, envelope.LineRuntimeIdentities[vpn.LineID]
	}
	for _, task := range envelope.Plan.Tasks {
		if task.Kind == config.ConnectionTaskLine && task.ResourceType == string(config.LineTypeTailscale) {
			tailscaleID = task.ResourceID
			tailscaleIdentity = envelope.LineRuntimeIdentities[tailscaleID]
		}
	}
	return vpnConfig, vpnIdentity, tailscaleID, tailscaleIdentity
}

// StartForNetwork keeps the established startup implementation, adding an
// epoch-scoped requirement closure. It does not claim readiness until the same
// exact-outbound probes used by the Provider have produced current proofs.
func (l *Libbox) StartForNetwork(sessionJSON, networkContextJSON, anyConnectDialAddress string) error {
	envelope, network, g, err := l.decodeNetworkSession(sessionJSON, networkContextJSON)
	if err != nil {
		return l.publishNetworkFailure(g, err)
	}
	if err = l.observeNetworkGeneration(network, g); err != nil {
		return l.publishNetworkFailure(g, err)
	}
	l.mu.Lock()
	platform := l.platform
	busy := l.running || l.cleaning || l.startPreparing || l.switchPreparing
	l.mu.Unlock()
	if busy {
		return l.publishNetworkFailure(g, fmt.Errorf("connection cannot start in the current state"))
	}
	candidatePlatform, err := platform.switchCandidate(string(network.Interfaces), network.DefaultName, network.DefaultIndex)
	if err != nil {
		return l.publishNetworkFailure(g, err)
	}
	l.mu.Lock()
	l.platform = candidatePlatform
	l.mu.Unlock()
	vpnConfig, vpnIdentity, tailscaleID, tailscaleIdentity := networkSessionRuntimeInputs(envelope, anyConnectDialAddress)
	err = l.coldStart(envelope.ConfigJSON, vpnConfig, vpnIdentity, tailscaleID, tailscaleIdentity, g)
	return l.publishNetworkFailure(g, err)
}

// PrepareSwitchForNetwork borrows recoverable stable handles. Recovery itself
// stays with the Line owner and is awaited by the exact-outbound probe, so an
// unavailable transport cannot abort construction before readiness can run.
func (l *Libbox) PrepareSwitchForNetwork(sessionJSON, networkContextJSON, anyConnectDialAddress string) error {
	envelope, network, g, err := l.decodeNetworkSession(sessionJSON, networkContextJSON)
	if err != nil {
		return l.publishNetworkFailure(g, err)
	}
	if err = l.observeNetworkGeneration(network, g); err != nil {
		return l.publishNetworkFailure(g, err)
	}
	vpnConfig, vpnIdentity, tailscaleID, tailscaleIdentity := networkSessionRuntimeInputs(envelope, anyConnectDialAddress)
	vpnID := ""
	if envelope.AnyConnect != nil {
		vpnID = envelope.AnyConnect.LineID
	}
	err = l.prepareSwitch(envelope.ConfigJSON, vpnID, vpnIdentity, vpnConfig, tailscaleID, tailscaleIdentity, string(network.Interfaces), network.DefaultName, network.DefaultIndex, g)
	return l.publishNetworkFailure(g, err)
}

func (g *lineNetworkGeneration) revisionFor(requirement lineNetworkRequirement) uint64 {
	if requirement.kind == string(config.LineTypeVPN) && g.anyConnect != nil {
		return g.anyConnect.snapshot().revision
	}
	if requirement.kind == string(config.LineTypeTailscale) && g.tailscale != nil {
		if runtime, ok := g.tailscale.(interface{ readinessRevision() uint64 }); ok {
			return runtime.readinessRevision()
		}
		if platform := g.tailscale.platformInterface(); platform != nil {
			return platform.lineNetworkRevision()
		}
	}
	return g.generation
}

func (g *lineNetworkGeneration) requirementForTag(tag string) (lineNetworkRequirement, bool) {
	for _, requirement := range g.requirements {
		if containsLineTag(requirement.tags, tag) {
			return requirement, true
		}
	}
	return lineNetworkRequirement{}, false
}

func tlsReadinessFailureCode(value outboundTLSCapabilities) string {
	if value.IPv4.Available || value.IPv6.Available {
		return ""
	}
	result := ""
	for _, family := range []outboundTLSFamilyCapability{value.IPv4, value.IPv6} {
		if readinessPriority(family.FailureClass) > readinessPriority(result) {
			result = family.FailureClass
		}
	}
	if result != "" {
		return result
	}
	return lineReadinessTerminal
}

func lineTLSReadinessFailureCode(requirement lineNetworkRequirement, value outboundTLSCapabilities) string {
	// The AnyConnect bridge explicitly supports IPv4 only. Its expected IPv6
	// unsupported result is not a failed authentication or a reason to suppress
	// recovery of the independently verified IPv4 transport.
	if requirement.kind == string(config.LineTypeVPN) {
		value.IPv6 = outboundTLSFamilyCapability{}
	}
	return tlsReadinessFailureCode(value)
}

func requiresOutboundTLSProof(requirement lineNetworkRequirement) bool {
	return requirement.kind != string(config.LineTypeDirect)
}

func (l *Libbox) probeNetworkOutbound(ctx context.Context, g *lineNetworkGeneration, tag string, outbound adapter.Outbound, probe func(context.Context, adapter.Outbound) outboundTLSCapabilities) (outboundTLSCapabilities, error) {
	if g == nil {
		return probe(ctx, outbound), nil
	}
	requirement, ok := g.requirementForTag(tag)
	if !ok {
		return probe(ctx, outbound), nil
	} // A diagnostic-only tag cannot satisfy a Line requirement.
	if !requiresOutboundTLSProof(requirement) {
		// Direct readiness comes from the current Box generation and its captured
		// Underlay context. An explicit TLS probe remains a real diagnostic, but
		// neither its success nor failure changes the commit gate.
		return probe(ctx, outbound), nil
	}
	if err := g.checkEpoch(); err != nil {
		g.recordError(err)
		return outboundTLSCapabilities{}, err
	}
	revision := g.revisionFor(requirement)
	g.mu.Lock()
	if proof, exists := g.proofs[tag]; exists && proof.code == "" && proof.revision == revision {
		g.mu.Unlock()
		return proof.capabilities, nil
	}
	if running := g.probes[tag]; running != nil {
		g.mu.Unlock()
		select {
		case <-ctx.Done():
			return outboundTLSCapabilities{}, ctx.Err()
		case <-running.done:
			return running.proof.capabilities, running.err
		}
	}
	work := &lineNetworkProbe{done: make(chan struct{})}
	g.probes[tag] = work
	g.mu.Unlock()
	var value outboundTLSCapabilities
	var err error
	if requirement.kind == string(config.LineTypeVPN) && g.anyConnect != nil {
		g.anyConnect.attachOwner(l, true)
		err = g.anyConnect.ensureTransport(ctx, false)
	}
	if err == nil {
		revision = g.revisionFor(requirement)
		probeCtx := ctx
		probeCancel := func() {}
		if requirement.kind == string(config.LineTypeVPN) && g.anyConnect != nil {
			budget := 2 * time.Second
			if deadline, ok := ctx.Deadline(); ok && time.Until(deadline)/3 < budget {
				budget = time.Until(deadline) / 3
			}
			if budget > 0 {
				probeCtx, probeCancel = context.WithTimeout(ctx, budget)
			}
		}
		value = probe(probeCtx, outbound)
		probeCancel()
		if lineTLSReadinessFailureCode(requirement, value) == lineReadinessTransient && requirement.kind == string(config.LineTypeVPN) && g.anyConnect != nil && ctx.Err() == nil {
			err = g.anyConnect.ensureTransport(ctx, true, revision)
			if err == nil {
				revision = g.revisionFor(requirement)
				value = probe(ctx, outbound)
			}
		}
	}
	code := lineTLSReadinessFailureCode(requirement, value)
	if err == nil && ctx.Err() != nil {
		err = ctx.Err()
	}
	if err == nil {
		err = g.checkEpoch()
	}
	if err == nil && revision != g.revisionFor(requirement) {
		err = &lineReadinessError{lineReadinessTransient, fmt.Errorf("Line runtime changed during readiness proof")}
	}
	if err != nil {
		code = readinessErrorCode(err)
		g.recordError(err)
	}
	proof := lineNetworkProof{value, revision, code}
	g.mu.Lock()
	g.proofs[tag] = proof
	work.proof, work.err = proof, err
	delete(g.probes, tag)
	close(work.done)
	g.mu.Unlock()
	return value, err
}

func (g *lineNetworkGeneration) checkEpoch() error {
	g.libbox.mu.Lock()
	current := g.libbox.networkEpoch
	g.libbox.mu.Unlock()
	if current != g.epoch {
		return &lineReadinessError{lineReadinessSuperseded, fmt.Errorf("readiness belongs to an older network epoch")}
	}
	return nil
}

func readinessPriority(code string) int {
	switch code {
	case lineReadinessTerminal:
		return 5
	case lineReadinessSuperseded:
		return 4
	case lineReadinessCancelled:
		return 3
	case lineReadinessTransient:
		return 2
	default:
		return 0
	}
}

func (g *lineNetworkGeneration) report() lineReadinessReport {
	g.mu.Lock()
	defer g.mu.Unlock()
	code := g.structuralCode
	if readinessPriority(g.operationCode) > readinessPriority(code) {
		code = g.operationCode
	}
	report := lineReadinessReport{Epoch: g.epoch, State: "ready", Code: code, Lines: make([]lineReadinessItem, 0, len(g.requirements))}
	for _, requirement := range g.requirements {
		revision := g.revisionFor(requirement)
		item := lineReadinessItem{LineID: requirement.id, State: "ready", NetworkEpoch: g.epoch, RuntimeRevision: revision}
		if !requiresOutboundTLSProof(requirement) {
			item.ProofKind = "underlay-context"
			if revision == 0 {
				item.State = "waiting"
			}
			if item.State != "ready" && report.State == "ready" {
				report.State = item.State
			}
			report.Lines = append(report.Lines, item)
			continue
		}
		ipv4Available, ipv6Available := true, true
		item.ProofKind = "outbound-tls"
		item.IPv4Available = &ipv4Available
		item.IPv6Available = &ipv6Available
		for _, tag := range requirement.tags {
			proof, exists := g.proofs[tag]
			if !exists || proof.revision != revision {
				item.State = "waiting"
				*item.IPv4Available = false
				*item.IPv6Available = false
				if g.probes[tag] != nil {
					item.State = "verifying"
				}
				if exists {
					item.State = "failed"
					item.Code = proof.code
					if item.Code == "" {
						item.Code = lineReadinessTransient
					}
				}
				continue
			}
			*item.IPv4Available = *item.IPv4Available && proof.capabilities.IPv4.Available
			*item.IPv6Available = *item.IPv6Available && proof.capabilities.IPv6.Available
			if proof.code != "" {
				item.State = "failed"
				if readinessPriority(proof.code) > readinessPriority(item.Code) {
					item.Code = proof.code
				}
			}
		}
		if requirement.kind == string(config.LineTypeVPN) && g.anyConnect != nil && !g.anyConnect.available() && item.State == "ready" {
			item.State = "failed"
			item.Code = lineReadinessTransient
			*item.IPv4Available = false
			*item.IPv6Available = false
		}
		if requirement.kind == string(config.LineTypeTailscale) && g.tailscale != nil && (!g.tailscale.available() || revision == 0) && item.State == "ready" {
			item.State = "failed"
			item.Code = lineReadinessTransient
			*item.IPv4Available = false
			*item.IPv6Available = false
		}
		if item.State != "ready" && report.State == "ready" {
			report.State = item.State
		}
		if readinessPriority(item.Code) > readinessPriority(report.Code) {
			report.Code = item.Code
		}
		report.Lines = append(report.Lines, item)
	}
	if report.Code != "" {
		report.State = "failed"
	}
	return report
}

func (g *lineNetworkGeneration) validate(epoch string) error {
	if epoch != g.epoch {
		return &lineReadinessError{lineReadinessSuperseded, fmt.Errorf("candidate network epoch is no longer current")}
	}
	report := g.report()
	if report.State != "ready" {
		code := report.Code
		if code == "" {
			code = lineReadinessTransient
		}
		return &lineReadinessError{code, fmt.Errorf("not every required Line has a current network proof")}
	}
	return nil
}

// LineReadiness remains readable after Abort so the Provider can classify a
// failed candidate without parsing an NSError message. Failures aggregate over
// all parallel Line probes; a later success on another Line cannot erase them.
func (l *Libbox) LineReadiness() string {
	l.mu.Lock()
	g := l.lastNetworkReadiness
	epoch := l.networkEpoch
	l.mu.Unlock()
	if g == nil {
		return `{"state":"waiting","lines":[]}`
	}
	report := g.report()
	if epoch != g.epoch && report.Code == "" {
		report.State = "failed"
		report.Code = lineReadinessSuperseded
	}
	encoded, _ := stdjson.Marshal(report)
	return string(encoded)
}

func (l *Libbox) EnsureActiveLinesReady(timeoutMS int) (string, error) {
	return l.ensureNetworkLinesReady(false, timeoutMS)
}
func (l *Libbox) EnsurePreparedSwitchLinesReady(timeoutMS int) (string, error) {
	return l.ensureNetworkLinesReady(true, timeoutMS)
}

func (l *Libbox) ensureNetworkLinesReady(prepared bool, timeoutMS int) (string, error) {
	l.mu.Lock()
	g := l.activeNetworkReadiness
	runtimeCtx := l.runtimeCtx
	if prepared {
		if l.preparedSwitch == nil {
			l.mu.Unlock()
			return l.LineReadiness(), fmt.Errorf("switch candidate is not prepared")
		}
		g = l.preparedSwitch.networkReadiness
		runtimeCtx = l.preparedSwitch.runtimeCtx
	}
	l.mu.Unlock()
	if g == nil || runtimeCtx == nil {
		return l.LineReadiness(), fmt.Errorf("network Line requirements are unavailable")
	}
	operationID := g.beginReadinessOperation()
	if timeoutMS <= 0 {
		timeoutMS = 10000
	}
	if timeoutMS > 120000 {
		timeoutMS = 120000
	}
	ctx, cancel := context.WithTimeout(runtimeCtx, time.Duration(timeoutMS)*time.Millisecond)
	defer cancel()
	if err := ctx.Err(); err != nil {
		g.recordOperationError(operationID, err)
		return l.LineReadiness(), err
	}
	for _, requirement := range g.requirements {
		if !requiresOutboundTLSProof(requirement) {
			continue
		}
		for _, tag := range requirement.tags {
			if err := ctx.Err(); err != nil {
				g.recordOperationError(operationID, err)
				return l.LineReadiness(), err
			}
			remaining := timeoutMS
			if deadline, ok := ctx.Deadline(); ok {
				remaining = int(time.Until(deadline).Milliseconds())
				if remaining < 1 {
					remaining = 1
				}
			}
			var err error
			if prepared {
				_, err = l.ProbePreparedSwitchOutboundTLSCapabilities(tag, remaining)
			} else {
				_, err = l.ProbeOutboundTLSCapabilities(tag, remaining)
			}
			if err != nil {
				if !g.hasCurrentFailureProof(requirement, tag) {
					g.recordOperationError(operationID, err)
				}
				return l.LineReadiness(), err
			}
		}
	}
	l.mu.Lock()
	epoch := l.networkEpoch
	l.mu.Unlock()
	err := g.validate(epoch)
	if err != nil {
		g.recordError(err)
		if report := g.report(); report.Code == "" {
			g.recordOperationError(operationID, err)
		}
	}
	return l.LineReadiness(), err
}
