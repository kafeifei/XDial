//go:build !windows

package libbox

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"net"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/kafeifei/xdial/core/config"
	"github.com/kafeifei/xdial/core/engine"
	"github.com/sagernet/sing-box/adapter"
	"sslcon/session"
)

func networkReadinessTestContext(epoch string) string {
	data, _ := json.Marshal(lineNetworkContext{Epoch: epoch, Interfaces: json.RawMessage(switchNetworkInterfaces), DefaultName: "test0", DefaultIndex: 1, SystemDNS: []string{"192.0.2.53"}})
	return string(data)
}

func networkReadinessTestEnvelope(t *testing.T, configJSON string, lines map[string]string, vpn bool) string {
	t.Helper()
	envelope := transparentProxySession{ConfigJSON: configJSON, Plan: &config.ConnectionPlan{}, LineOutbounds: map[string]string{}, LineRuntimeIdentities: map[string]string{}}
	for id, kind := range lines {
		tag := id
		if kind == "vpn" {
			tag = "vpn"
		}
		envelope.Plan.Tasks = append(envelope.Plan.Tasks, config.ConnectionPlanTask{ID: "line:" + id, Kind: config.ConnectionTaskLine, ResourceID: id, ResourceType: kind})
		envelope.LineOutbounds[id] = tag
		envelope.LineRuntimeIdentities[id] = "line-runtime-v1:" + id
	}
	if vpn {
		envelope.AnyConnect = &transparentProxyAnyConnect{LineID: "company", Server: "vpn.example.com", Username: "test", Password: "private"}
	}
	data, err := json.Marshal(envelope)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func successfulNetworkProof(context.Context, adapter.Outbound) outboundTLSCapabilities {
	return outboundTLSCapabilities{IPv4: outboundTLSFamilyCapability{Available: true, TLSAuthenticated: 1}}
}

func terminalNetworkProof() outboundTLSCapabilities {
	return outboundTLSCapabilities{IPv4: outboundTLSFamilyCapability{
		FailureCodes: map[string]int{outboundTLSFailureAuthentication: 1},
		FailureClass: lineReadinessTerminal,
	}}
}

func readinessLine(t *testing.T, l *Libbox, id string) lineReadinessItem {
	t.Helper()
	var report lineReadinessReport
	if err := json.Unmarshal([]byte(l.LineReadiness()), &report); err != nil {
		t.Fatal(err)
	}
	for _, line := range report.Lines {
		if line.LineID == id {
			return line
		}
	}
	t.Fatalf("Line %q absent from readiness report: %+v", id, report)
	return lineReadinessItem{}
}

func TestNetworkReadinessDirectUsesCurrentUnderlayContextWithoutMandatoryTLS(t *testing.T) {
	const cfg = `{"log":{"disabled":true},"outbounds":[{"type":"direct","tag":"direct"},{"type":"direct","tag":"proxy"}],"route":{"final":"direct"}}`
	l := New(nil)
	defer l.Stop()
	var mu sync.Mutex
	counts := map[string]int{}
	l.probeOutboundTLSCapabilitiesFunc = func(ctx context.Context, outbound adapter.Outbound) outboundTLSCapabilities {
		mu.Lock()
		counts[outbound.Tag()]++
		mu.Unlock()
		if outbound.Tag() == "direct" {
			return terminalNetworkProof()
		}
		return successfulNetworkProof(ctx, outbound)
	}
	envelope := networkReadinessTestEnvelope(t, cfg, map[string]string{"direct": "direct", "proxy": "trojan"}, false)
	if err := l.StartForNetwork(envelope, networkReadinessTestContext("A"), ""); err != nil {
		t.Fatal(err)
	}
	if _, err := l.EnsureActiveLinesReady(1000); err != nil {
		t.Fatal(err)
	}
	if _, err := l.EnsureActiveLinesReady(1000); err != nil {
		t.Fatal(err)
	}
	if counts["direct"] != 0 || counts["proxy"] != 1 {
		t.Fatalf("duplicate initial probes: %v", counts)
	}
	direct := readinessLine(t, l, "direct")
	if direct.State != "ready" || direct.ProofKind != "underlay-context" || direct.IPv4Available != nil || direct.IPv6Available != nil {
		t.Fatalf("Direct readiness claimed an outbound TLS or address-family proof: %+v", direct)
	}
	proxy := readinessLine(t, l, "proxy")
	if proxy.ProofKind != "outbound-tls" || proxy.IPv4Available == nil || !*proxy.IPv4Available {
		t.Fatalf("proxy readiness lost its outbound TLS proof: %+v", proxy)
	}
	if err := l.PrepareSwitchForNetwork(envelope, networkReadinessTestContext("A"), ""); err != nil {
		t.Fatal(err)
	}
	if err := l.CommitPreparedSwitch(); err == nil {
		t.Fatal("candidate borrowed another Box's readiness")
	}
	diagnosticJSON, err := l.ProbePreparedSwitchOutboundTLSCapabilities("direct", 1000)
	if err != nil {
		t.Fatal(err)
	}
	var diagnostic outboundTLSCapabilities
	if err = json.Unmarshal([]byte(diagnosticJSON), &diagnostic); err != nil {
		t.Fatal(err)
	}
	if diagnostic.IPv4.Available || diagnostic.IPv6.Available || counts["direct"] != 1 {
		t.Fatalf("Direct diagnostic did not preserve its real TLS failure: json=%s counts=%v", diagnosticJSON, counts)
	}
	if err := l.CommitPreparedSwitch(); err == nil {
		t.Fatal("Direct diagnostic incorrectly satisfied the missing proxy proof")
	}
	if _, err := l.EnsurePreparedSwitchLinesReady(1000); err != nil {
		t.Fatal(err)
	}
	if counts["direct"] != 1 || counts["proxy"] != 2 {
		t.Fatalf("Ensure repeated existing proof or missed Line: %v", counts)
	}
	if err := l.CommitPreparedSwitch(); err != nil {
		t.Fatal(err)
	}
	if err := l.RetireCommittedSwitch(); err != nil {
		t.Fatal(err)
	}
	if err := l.PrepareSwitchForNetwork(envelope, networkReadinessTestContext("B"), ""); err != nil {
		t.Fatal(err)
	}
	if err := l.CommitPreparedSwitch(); err == nil {
		t.Fatal("old network proof accepted")
	}
	if _, err := l.EnsurePreparedSwitchLinesReady(1000); err != nil {
		t.Fatal(err)
	}
	if counts["direct"] != 1 || counts["proxy"] != 3 {
		t.Fatalf("new epoch did not verify each Line: %v", counts)
	}
}

func TestNetworkReadinessSameLineSuccessReplacesFailureAndKeepsOtherLineFailure(t *testing.T) {
	const cfg = `{"log":{"disabled":true},"outbounds":[{"type":"direct","tag":"a"},{"type":"direct","tag":"b"}],"route":{"final":"a"}}`
	l := New(nil)
	defer l.Stop()
	succeedA := false
	succeedB := false
	l.probeOutboundTLSCapabilitiesFunc = func(ctx context.Context, outbound adapter.Outbound) outboundTLSCapabilities {
		if (outbound.Tag() == "a" && succeedA) || (outbound.Tag() == "b" && succeedB) {
			return successfulNetworkProof(ctx, outbound)
		}
		return terminalNetworkProof()
	}
	if err := l.StartForNetwork(networkReadinessTestEnvelope(t, cfg, map[string]string{"a": "trojan", "b": "trojan"}, false), networkReadinessTestContext("A"), ""); err != nil {
		t.Fatal(err)
	}
	if _, err := l.EnsureActiveLinesReady(1000); err == nil || readinessErrorCode(err) != lineReadinessTerminal {
		t.Fatalf("two terminal Line failures were accepted: %v", err)
	}
	succeedA = true
	if _, err := l.ProbeOutboundTLSCapabilities("a", 1000); err != nil {
		t.Fatal(err)
	}
	var report lineReadinessReport
	if err := json.Unmarshal([]byte(l.LineReadiness()), &report); err != nil {
		t.Fatal(err)
	}
	if report.Code != lineReadinessTerminal || report.State != "failed" {
		t.Fatalf("aggregate terminal failure lost: %+v", report)
	}
	lineA, lineB := readinessLine(t, l, "a"), readinessLine(t, l, "b")
	if lineA.State != "ready" || lineA.Code != "" || lineB.State != "failed" || lineB.Code != lineReadinessTerminal {
		t.Fatalf("same-Line success did not replace only its old failure: a=%+v b=%+v", lineA, lineB)
	}
	succeedB = true
	if _, err := l.ProbeOutboundTLSCapabilities("b", 1000); err != nil {
		t.Fatal(err)
	}
	if got := l.LineReadiness(); !strings.Contains(got, `"state":"ready"`) || strings.Contains(got, lineReadinessTerminal) {
		t.Fatalf("old terminal failure remained after real recovery: %s", got)
	}
}

func TestNetworkReadinessDirectOnlyCancelledRuntimeFailsCurrentEnsure(t *testing.T) {
	l := New(nil)
	defer l.Stop()
	envelope := networkReadinessTestEnvelope(t, outboundProbeTestConfig, map[string]string{"direct": "direct"}, false)
	if err := l.StartForNetwork(envelope, networkReadinessTestContext("A"), ""); err != nil {
		t.Fatal(err)
	}
	l.runtimeCancel()
	if _, err := l.EnsureActiveLinesReady(1000); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled Direct-only runtime was accepted: %v", err)
	}
	var report lineReadinessReport
	if err := json.Unmarshal([]byte(l.LineReadiness()), &report); err != nil {
		t.Fatal(err)
	}
	if report.State != "failed" || report.Code != lineReadinessCancelled {
		t.Fatalf("cancelled Ensure lost its structured operation result: %+v", report)
	}
}

func TestNetworkReadinessBudgetExpiryBeforeNextLineIsReplaceable(t *testing.T) {
	const cfg = `{"log":{"disabled":true},"outbounds":[{"type":"direct","tag":"a"},{"type":"direct","tag":"b"}],"route":{"final":"a"}}`
	l := New(nil)
	defer l.Stop()
	delayFirst := true
	l.probeOutboundTLSCapabilitiesFunc = func(ctx context.Context, outbound adapter.Outbound) outboundTLSCapabilities {
		if outbound.Tag() == "a" && delayFirst {
			time.Sleep(20 * time.Millisecond)
		}
		return successfulNetworkProof(ctx, outbound)
	}
	envelope := networkReadinessTestEnvelope(t, cfg, map[string]string{"a": "trojan", "b": "trojan"}, false)
	if err := l.StartForNetwork(envelope, networkReadinessTestContext("A"), ""); err != nil {
		t.Fatal(err)
	}
	if _, err := l.EnsureActiveLinesReady(1); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("expired total readiness budget was accepted: %v", err)
	}
	var report lineReadinessReport
	if err := json.Unmarshal([]byte(l.LineReadiness()), &report); err != nil {
		t.Fatal(err)
	}
	if report.State != "failed" || report.Code != lineReadinessTransient {
		t.Fatalf("budget expiry lost its structured operation result: %+v", report)
	}
	if lineA, lineB := readinessLine(t, l, "a"), readinessLine(t, l, "b"); lineA.State != "ready" || lineB.State != "waiting" {
		t.Fatalf("budget boundary did not preserve completed and pending Lines: a=%+v b=%+v", lineA, lineB)
	}
	delayFirst = false
	if _, err := l.EnsureActiveLinesReady(1000); err != nil {
		t.Fatalf("successful retry did not replace the operation failure: %v", err)
	}
	if got := l.LineReadiness(); !strings.Contains(got, `"state":"ready"`) || strings.Contains(got, lineReadinessTransient) {
		t.Fatalf("expired operation remained after success: %s", got)
	}
}

func TestNetworkReadinessCurrentOperationFailureSurvivesReadyProofs(t *testing.T) {
	g := &lineNetworkGeneration{
		epoch:      "A",
		generation: 1,
		requirements: []lineNetworkRequirement{{
			id: "direct", kind: string(config.LineTypeDirect), tags: []string{"direct"},
		}},
	}
	operationID := g.beginReadinessOperation()
	g.recordOperationError(operationID, context.DeadlineExceeded)
	if report := g.report(); report.State != "failed" || report.Code != lineReadinessTransient {
		t.Fatalf("current operation failure was hidden by ready Lines: %+v", report)
	}
	g.beginReadinessOperation()
	if report := g.report(); report.State != "ready" || report.Code != "" {
		t.Fatalf("new readiness operation retained the old failure: %+v", report)
	}
}

func TestNetworkReadinessLateOperationCannotOverwriteNewAttempt(t *testing.T) {
	g := &lineNetworkGeneration{
		epoch:      "A",
		generation: 1,
		requirements: []lineNetworkRequirement{{
			id: "direct", kind: string(config.LineTypeDirect), tags: []string{"direct"},
		}},
	}
	oldOperationID := g.beginReadinessOperation()
	g.beginReadinessOperation()
	g.recordOperationError(oldOperationID, context.DeadlineExceeded)
	if report := g.report(); report.State != "ready" || report.Code != "" {
		t.Fatalf("late operation overwrote a newer successful attempt: %+v", report)
	}
}

func TestNetworkReadinessRejectsChangedFactsAndLateEpoch(t *testing.T) {
	l := New(nil)
	defer l.Stop()
	envelope := networkReadinessTestEnvelope(t, outboundProbeTestConfig, map[string]string{"direct": "direct"}, false)
	if err := l.StartForNetwork(envelope, networkReadinessTestContext("A"), ""); err != nil {
		t.Fatal(err)
	}
	_, network, g, err := l.decodeNetworkSession(envelope, networkReadinessTestContext("A"))
	if err != nil {
		t.Fatal(err)
	}
	network.SystemDNS = []string{"192.0.2.54"}
	if err = l.observeNetworkGeneration(network, g); err == nil || readinessErrorCode(err) != lineReadinessTerminal {
		t.Fatalf("same-epoch DNS mutation accepted: %v", err)
	}
	_, next, ng, err := l.decodeNetworkSession(envelope, networkReadinessTestContext("B"))
	if err != nil {
		t.Fatal(err)
	}
	if err = l.observeNetworkGeneration(next, ng); err != nil {
		t.Fatal(err)
	}
	_, old, og, _ := l.decodeNetworkSession(envelope, networkReadinessTestContext("A"))
	if err = l.observeNetworkGeneration(old, og); err == nil || readinessErrorCode(err) != lineReadinessSuperseded {
		t.Fatalf("late epoch accepted: %v", err)
	}
}

func TestNetworkReadinessAcceptsPureSubscriptionClosure(t *testing.T) {
	profile := transparentProxySubscriptionCapabilityProfile()
	profileData, err := json.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}
	// Use the production generator rather than manufacturing a Line for the
	// subscription: active subscription nodes are their own task closure.
	var envelope transparentProxySession
	encoded, err := GenerateTransparentProxySession(string(profileData), t.TempDir(), 18081, "user", "pass", "test0", `["192.0.2.53"]`)
	if err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal([]byte(encoded), &envelope); err != nil {
		t.Fatal(err)
	}
	_, _, g, err := New(nil).decodeNetworkSession(encoded, networkReadinessTestContext("A"))
	if err != nil {
		t.Fatal(err)
	}
	if len(g.requirements) != len(envelope.SubscriptionOutbounds) {
		t.Fatalf("subscription closure lost: %+v", g.requirements)
	}
	for _, requirement := range g.requirements {
		if requirement.kind != "subscription" || len(requirement.tags) == 0 || requirement.identity == "" {
			t.Fatalf("subscription requirement incomplete: %+v", requirement)
		}
	}
}

func TestNetworkReadinessTypedDialClassification(t *testing.T) {
	for name, test := range map[string]struct {
		err  error
		code string
	}{
		"certificate":  {&tls.CertificateVerificationError{Err: x509.UnknownAuthorityError{}}, lineReadinessTerminal},
		"untyped-auth": {errors.New("proxy authentication rejected"), lineReadinessTerminal},
		"reset":        {&net.OpError{Op: "dial", Net: "tcp", Err: syscall.ECONNRESET}, lineReadinessTransient},
	} {
		t.Run(name, func(t *testing.T) {
			class := outboundTLSReadinessErrorClass(context.Background(), test.err)
			if class != test.code {
				t.Fatalf("class=%s want %s", class, test.code)
			}
			family := outboundTLSFamilyCapability{FailureCodes: map[string]int{outboundTLSFailureTCPConnect: 1}, FailureClass: class}
			if got := tlsReadinessFailureCode(outboundTLSCapabilities{IPv4: family}); got != test.code {
				t.Fatalf("proof class=%s", got)
			}
		})
	}
}

type networkReadinessVPNClient struct {
	mu              sync.Mutex
	current         *session.ConnSession
	connects        int
	fail            error
	blockAfterFirst bool
	entered         chan struct{}
	release         chan struct{}
	once            sync.Once
}

func (c *networkReadinessVPNClient) Connect(engine.VPNConfig) (*engine.VPNInfo, error) {
	c.mu.Lock()
	c.connects++
	count, fail := c.connects, c.fail
	c.mu.Unlock()
	if c.blockAfterFirst && count > 1 {
		c.once.Do(func() { close(c.entered) })
		<-c.release
	}
	if fail != nil {
		return nil, fail
	}
	c.mu.Lock()
	c.current = newStartTestSession()
	c.mu.Unlock()
	return &engine.VPNInfo{VPNAddress: "10.0.0.2", DNS: []string{"10.0.0.53"}, MTU: 1400}, nil
}
func (c *networkReadinessVPNClient) Session() *session.ConnSession {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.current
}
func (c *networkReadinessVPNClient) Disconnect() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.current != nil {
		select {
		case <-c.current.CloseChan:
		default:
			close(c.current.CloseChan)
		}
		c.current = nil
	}
}
func (c *networkReadinessVPNClient) count() int { c.mu.Lock(); defer c.mu.Unlock(); return c.connects }

func TestNetworkReadinessCandidateCancelPreservesOwnerRecovery(t *testing.T) {
	vpn := &networkReadinessVPNClient{blockAfterFirst: true, entered: make(chan struct{}), release: make(chan struct{})}
	l := New(nil)
	l.vpn = vpn
	l.anyConnectRetryDelays = []time.Duration{0, 0, 0}
	defer l.Stop()
	envelope := networkReadinessTestEnvelope(t, switchAnyConnectConfig, map[string]string{"company": "vpn"}, true)
	if err := l.StartForNetwork(envelope, networkReadinessTestContext("A"), "192.0.2.1"); err != nil {
		t.Fatal(err)
	}
	capability := l.activeAnyConnectCapability
	original := capability.snapshot().session
	l.probeOutboundTLSCapabilitiesFunc = func(ctx context.Context, outbound adapter.Outbound) outboundTLSCapabilities {
		if capability.snapshot().session == original {
			return outboundTLSCapabilities{IPv4: outboundTLSFamilyCapability{FailureClass: lineReadinessTransient}}
		}
		return successfulNetworkProof(ctx, outbound)
	}
	if err := l.PrepareSwitchForNetwork(envelope, networkReadinessTestContext("B"), "192.0.2.1"); err != nil {
		t.Fatal(err)
	}
	probeDone := make(chan error, 1)
	go func() { _, err := l.ProbePreparedSwitchOutboundTLSCapabilities("vpn", 1000); probeDone <- err }()
	select {
	case <-vpn.entered:
	case <-time.After(time.Second):
		t.Fatal("owner recovery did not start")
	}
	if err := l.AbortPreparedSwitch(); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-probeDone:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("candidate waiter=%v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("candidate cancellation waited on owner")
	}
	if capability.ownerCtx.Err() != nil {
		t.Fatal("candidate cancellation canceled committed owner")
	}
	close(vpn.release)
	if err := capability.ensureTransport(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	if vpn.count() != 2 {
		t.Fatalf("parallel waiters redialed: %d", vpn.count())
	}
	if !capability.available() || l.activeAnyConnectCapability != capability {
		t.Fatal("committed owner was not recovered")
	}
}

func TestNetworkReadinessOwnerFailureBudgetSurvivesSceneWaiters(t *testing.T) {
	vpn := &networkReadinessVPNClient{fail: syscall.ECONNRESET}
	l := New(nil)
	l.vpn = vpn
	l.anyConnectRetryDelays = []time.Duration{0, 0, 0}
	c := &anyConnectRuntimeCapability{vpn: vpn, line: newAnyConnectLineRuntime(nil, nil)}
	c.attachOwner(l, true)
	c.observeNetwork("A", nil)
	defer c.stop()
	for i := 0; i < 3; i++ {
		if err := c.ensureTransport(context.Background(), false); !errors.Is(err, syscall.ECONNRESET) {
			t.Fatalf("owner failure=%v", err)
		}
	}
	if vpn.count() != 3 {
		t.Fatalf("Scene waiters reset owner budget: %d", vpn.count())
	}
	c.observeNetwork("B", nil)
	if err := c.ensureTransport(context.Background(), false); !errors.Is(err, syscall.ECONNRESET) {
		t.Fatal(err)
	}
	if vpn.count() != 6 {
		t.Fatalf("new real network did not receive its own budget: %d", vpn.count())
	}
}

func TestNetworkReadinessLateProbeCannotVerifyNewEpoch(t *testing.T) {
	const cfg = `{"log":{"disabled":true},"outbounds":[{"type":"direct","tag":"proxy"}],"route":{"final":"proxy"}}`
	l := New(nil)
	defer l.Stop()
	envelope := networkReadinessTestEnvelope(t, cfg, map[string]string{"proxy": "trojan"}, false)
	if err := l.StartForNetwork(envelope, networkReadinessTestContext("A"), ""); err != nil {
		t.Fatal(err)
	}
	if err := l.PrepareSwitchForNetwork(envelope, networkReadinessTestContext("B"), ""); err != nil {
		t.Fatal(err)
	}
	entered, release := make(chan struct{}), make(chan struct{})
	l.probeOutboundTLSCapabilitiesFunc = func(ctx context.Context, outbound adapter.Outbound) outboundTLSCapabilities {
		close(entered)
		<-release
		return successfulNetworkProof(ctx, outbound)
	}
	done := make(chan error, 1)
	go func() { _, err := l.ProbePreparedSwitchOutboundTLSCapabilities("proxy", 1000); done <- err }()
	<-entered
	_, network, g, err := l.decodeNetworkSession(envelope, networkReadinessTestContext("C"))
	if err != nil {
		t.Fatal(err)
	}
	if err = l.observeNetworkGeneration(network, g); err != nil {
		t.Fatal(err)
	}
	close(release)
	if err = <-done; err == nil || readinessErrorCode(err) != lineReadinessSuperseded {
		t.Fatalf("late proof accepted: %v", err)
	}
	if err = l.CommitPreparedSwitch(); err == nil || readinessErrorCode(err) != lineReadinessSuperseded {
		t.Fatalf("old epoch committed: %v", err)
	}
}

type networkRevisionTailscaleCapability struct {
	*tailscaleRuntimeTestCapability
	revision uint64
}

func (c *networkRevisionTailscaleCapability) readinessRevision() uint64 { return c.revision }

func TestNetworkReadinessProtocolRevisionInvalidatesSameEpochProof(t *testing.T) {
	l := New(nil)
	c := &networkRevisionTailscaleCapability{tailscaleRuntimeTestCapability: &tailscaleRuntimeTestCapability{line: &tailscaleLineRuntime{}, platform: &xdPlatformInterface{}}, revision: 17}
	g := &lineNetworkGeneration{libbox: l, epoch: "A", generation: 1, tailscale: c, requirements: []lineNetworkRequirement{{id: "ts", kind: "tailscale", identity: "private", tags: []string{"ts"}}}, proofs: map[string]lineNetworkProof{"ts": {capabilities: successfulNetworkProof(nil, nil), revision: 17}}}
	if err := g.validate("A"); err != nil {
		t.Fatal(err)
	}
	c.revision = 18 // Same Underlay, a new protocol/control generation.
	if err := g.validate("A"); err == nil {
		t.Fatal("same-epoch protocol replacement preserved the old proof")
	}
}

func TestNetworkReadinessFinalLeaseCancelsRecoveryOwner(t *testing.T) {
	vpn := &networkReadinessVPNClient{blockAfterFirst: true, entered: make(chan struct{}), release: make(chan struct{})}
	l := New(nil)
	l.vpn = vpn
	l.anyConnectRetryDelays = []time.Duration{0, 0, 0}
	c, err := l.createAnyConnectRuntimeCapability(engine.VPNConfig{Server: "vpn.example.com"})
	if err != nil {
		t.Fatal(err)
	}
	c.attachOwner(l, true)
	c.observeNetwork("A", nil)
	var pool lineRuntimePool
	if err = pool.beginCandidate(1); err != nil {
		t.Fatal(err)
	}
	if _, _, err = pool.acquireCandidate(1, "identity", lineRuntimeCapabilityAnyConnect, true, func() (lineRuntimeCapability, error) { return c, nil }); err != nil {
		t.Fatal(err)
	}
	if err = pool.promoteCandidate(1); err != nil {
		t.Fatal(err)
	}
	if err = pool.beginCandidate(2); err != nil {
		t.Fatal(err)
	}
	if _, _, err = pool.acquireCandidate(2, "identity", lineRuntimeCapabilityAnyConnect, true, nil); err != nil {
		t.Fatal(err)
	}
	workDone := make(chan error, 1)
	go func() { workDone <- c.ensureTransport(context.Background(), true) }()
	<-vpn.entered
	pool.releaseCandidate(2)
	if c.ownerCtx.Err() != nil {
		t.Fatal("a candidate lease cancelled the shared owner")
	}
	stopDone := make(chan struct{})
	go func() { pool.releaseCommitted(1); close(stopDone) }()
	select {
	case <-c.ownerCtx.Done():
	case <-time.After(time.Second):
		t.Fatal("last lease did not cancel owner")
	}
	close(vpn.release)
	if err = <-workDone; !errors.Is(err, context.Canceled) {
		t.Fatalf("stopped recovery returned %v", err)
	}
	select {
	case <-stopDone:
	case <-time.After(time.Second):
		t.Fatal("last lease did not finish recovery teardown")
	}
	if !pool.empty() || c.available() {
		t.Fatal("last lease left a live capability")
	}
}

func readyNetworkAnyConnectCandidate(t *testing.T) (*Libbox, *anyConnectRuntimeCapability) {
	t.Helper()
	l := New(nil)
	l.vpn = &networkReadinessVPNClient{}
	l.probeOutboundTLSCapabilitiesFunc = successfulNetworkProof
	envelope := networkReadinessTestEnvelope(t, switchAnyConnectConfig, map[string]string{"company": "vpn"}, true)
	if err := l.StartForNetwork(envelope, networkReadinessTestContext("A"), "192.0.2.1"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = l.Stop() })
	if err := l.PrepareSwitchForNetwork(envelope, networkReadinessTestContext("A"), "192.0.2.1"); err != nil {
		t.Fatal(err)
	}
	return l, l.activeAnyConnectCapability
}

func assertReadinessFailureClass(t *testing.T, l *Libbox, err error, code string) {
	t.Helper()
	if err == nil || readinessErrorCode(err) != code {
		t.Fatalf("Go failure=%v want %s", err, code)
	}
	var report lineReadinessReport
	if decodeErr := json.Unmarshal([]byte(l.LineReadiness()), &report); decodeErr != nil {
		t.Fatal(decodeErr)
	}
	if report.State != "failed" || report.Code != code {
		t.Fatalf("Swift-visible failure lost: %+v", report)
	}
}

func TestNetworkReadinessCommitRevisionFailureHasStructuredCode(t *testing.T) {
	l, c := readyNetworkAnyConnectCandidate(t)
	if _, err := l.EnsurePreparedSwitchLinesReady(1000); err != nil {
		t.Fatal(err)
	}
	c.mu.Lock()
	c.revision++
	c.mu.Unlock()
	assertReadinessFailureClass(t, l, l.CommitPreparedSwitch(), lineReadinessTransient)
	if _, err := l.EnsurePreparedSwitchLinesReady(1000); err != nil {
		t.Fatalf("fresh proofs did not clear transient failure: %v", err)
	}
	if err := l.CommitPreparedSwitch(); err != nil {
		t.Fatal(err)
	}
}

func TestNetworkReadinessProbeRevisionFailureHasStructuredCode(t *testing.T) {
	l, c := readyNetworkAnyConnectCandidate(t)
	l.probeOutboundTLSCapabilitiesFunc = func(ctx context.Context, outbound adapter.Outbound) outboundTLSCapabilities {
		c.mu.Lock()
		c.revision++
		c.mu.Unlock()
		return successfulNetworkProof(ctx, outbound)
	}
	_, err := l.ProbePreparedSwitchOutboundTLSCapabilities("vpn", 1000)
	assertReadinessFailureClass(t, l, err, lineReadinessTransient)
	l.probeOutboundTLSCapabilitiesFunc = successfulNetworkProof
	if _, err = l.EnsurePreparedSwitchLinesReady(1000); err != nil {
		t.Fatalf("replacement proof did not clear transient failure: %v", err)
	}
	if err = l.CommitPreparedSwitch(); err != nil {
		t.Fatal(err)
	}
}

func TestNetworkReadinessForcedRecoveryExhaustionEscalatesActiveLine(t *testing.T) {
	vpn := &networkReadinessVPNClient{}
	l := New(nil)
	l.vpn = vpn
	l.anyConnectRetryDelays = []time.Duration{0, 0, 0}
	defer l.Stop()
	envelope := networkReadinessTestEnvelope(t, switchAnyConnectConfig, map[string]string{"company": "vpn"}, true)
	if err := l.StartForNetwork(envelope, networkReadinessTestContext("A"), "192.0.2.1"); err != nil {
		t.Fatal(err)
	}
	c := l.activeAnyConnectCapability
	vpn.mu.Lock()
	vpn.fail = syscall.ECONNRESET
	vpn.mu.Unlock()
	if err := c.ensureTransport(context.Background(), true); !errors.Is(err, syscall.ECONNRESET) {
		t.Fatalf("forced recovery result=%v", err)
	}
	deadline := time.After(time.Second)
	for l.IsRunning() {
		select {
		case <-deadline:
			t.Fatal("owner exhaustion left active Line permanently unavailable")
		default:
			time.Sleep(time.Millisecond)
		}
	}
	if !l.lineRuntimes.empty() {
		t.Fatal("exhausted owner retained active leases")
	}
}

func TestNetworkReadinessUnknownAuthenticationFailureDoesNotRetry(t *testing.T) {
	vpn := &networkReadinessVPNClient{fail: errors.New("authentication rejected")}
	l := New(nil)
	l.vpn = vpn
	l.anyConnectRetryDelays = []time.Duration{0, 0, 0}
	c := &anyConnectRuntimeCapability{vpn: vpn, line: newAnyConnectLineRuntime(nil, nil)}
	c.attachOwner(l, true)
	c.observeNetwork("A", nil)
	defer c.stop()
	for i := 0; i < 3; i++ {
		err := c.ensureTransport(context.Background(), false)
		if err == nil || readinessErrorCode(err) != lineReadinessTerminal {
			t.Fatalf("unknown auth failure=%v", err)
		}
	}
	if vpn.count() != 1 {
		t.Fatalf("untyped authentication error was retried: %d", vpn.count())
	}
}

func TestNetworkReadinessBuiltinDirectDisabledRowRoundTrip(t *testing.T) {
	profile := config.Profile{Lines: []config.Line{{ID: "direct", Type: config.LineTypeDirect, Enabled: false}}, Scenarios: []config.Scenario{{ID: "home", DefaultLineID: "direct"}}, ActiveScenarioID: "home"}
	encodedProfile, err := json.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}
	envelope, err := GenerateTransparentProxySession(string(encodedProfile), t.TempDir(), 18082, "user", "pass", "test0", `["192.0.2.53"]`)
	if err != nil {
		t.Fatal(err)
	}
	_, _, generation, err := New(nil).decodeNetworkSession(envelope, networkReadinessTestContext("A"))
	if err != nil {
		t.Fatal(err)
	}
	if len(generation.requirements) != 1 || generation.requirements[0].id != "direct" || generation.requirements[0].identity == "" {
		t.Fatalf("Direct readiness requirement missing: %+v", generation.requirements)
	}
}

func TestNetworkReadinessInitialTailscaleEpochDoesNotRefreshSameNetwork(t *testing.T) {
	platform := &xdPlatformInterface{}
	c := &tailscaleRuntimeTestCapability{line: &tailscaleLineRuntime{}, platform: platform}
	g := &lineNetworkGeneration{libbox: New(nil), epoch: "A"}
	g.install(1, nil, c)
	platform.observeLineNetwork(&xdPlatformInterface{}, "A")
	if revision := platform.lineNetworkRevision(); revision != 0 {
		t.Fatalf("same network was refreshed after initial install: %d", revision)
	}
	platform.observeLineNetwork(&xdPlatformInterface{}, "B")
	if revision := platform.lineNetworkRevision(); revision != 1 {
		t.Fatalf("new network did not refresh owner exactly once: %d", revision)
	}
	platform.observeLineNetwork(&xdPlatformInterface{}, "B")
	if revision := platform.lineNetworkRevision(); revision != 1 {
		t.Fatalf("same new epoch refreshed owner twice: %d", revision)
	}
}
