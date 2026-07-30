//go:build !windows

package libbox

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"net/netip"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/sagernet/sing-box/adapter"
	C "github.com/sagernet/sing-box/constant"
	tun "github.com/sagernet/sing-tun"
	N "github.com/sagernet/sing/common/network"
)

const routingProbeZeroJSON = `{"direct_target_direct":0,"direct_target_vpn":0,"direct_target_other":0,"anyconnect_target_direct":0,"anyconnect_target_vpn":0,"anyconnect_target_other":0,"direct_target_tags":{},"anyconnect_target_tags":{},"probe_id":"","match_count":0,"outbound_tag_counts":{}}`

const (
	transparentProxyInboundTag = "transparent-proxy-in"
	maxRouteProbeHostnameBytes = 253
	maxRouteProbeTimeoutMS     = 15_000
)

var (
	directProbeTarget     = netip.MustParseAddr("1.0.0.1")
	anyConnectProbeTarget = netip.MustParseAddr("1.1.1.1")
)

type routingProbeTracker struct {
	directTargetDirect     atomic.Uint64
	directTargetVPN        atomic.Uint64
	directTargetOther      atomic.Uint64
	anyConnectTargetDirect atomic.Uint64
	anyConnectTargetVPN    atomic.Uint64
	anyConnectTargetOther  atomic.Uint64
	tagCountsMu            sync.Mutex
	directTargetTags       map[string]uint64
	anyConnectTargetTags   map[string]uint64
	experimentMu           sync.Mutex
	experiment             *routingProbeExperiment
}

type routingProbeSnapshot struct {
	DirectTargetDirect     uint64            `json:"direct_target_direct"`
	DirectTargetVPN        uint64            `json:"direct_target_vpn"`
	DirectTargetOther      uint64            `json:"direct_target_other"`
	AnyConnectTargetDirect uint64            `json:"anyconnect_target_direct"`
	AnyConnectTargetVPN    uint64            `json:"anyconnect_target_vpn"`
	AnyConnectTargetOther  uint64            `json:"anyconnect_target_other"`
	DirectTargetTags       map[string]uint64 `json:"direct_target_tags"`
	AnyConnectTargetTags   map[string]uint64 `json:"anyconnect_target_tags"`
	ProbeID                string            `json:"probe_id"`
	MatchCount             uint64            `json:"match_count"`
	OutboundTagCounts      map[string]uint64 `json:"outbound_tag_counts"`
	RuleSetTag             string            `json:"rule_set_tag,omitempty"`
}

type routingProbeExperiment struct {
	id                   string
	hostname             string
	matchCount           uint64
	outboundTagCounts    map[string]uint64
	ruleSetTag           string
	ruleSetTagConsistent bool
	timer                *time.Timer
}

func newRoutingProbeTracker() *routingProbeTracker {
	return &routingProbeTracker{
		directTargetTags:     make(map[string]uint64),
		anyConnectTargetTags: make(map[string]uint64),
	}
}

func (t *routingProbeTracker) RoutedConnection(
	_ context.Context,
	conn net.Conn,
	metadata adapter.InboundContext,
	matchedRule adapter.Rule,
	matchOutbound adapter.Outbound,
) net.Conn {
	t.record(metadata, matchedRule, matchOutbound)
	return conn
}

func (t *routingProbeTracker) RoutedPacketConnection(
	_ context.Context,
	conn N.PacketConn,
	metadata adapter.InboundContext,
	matchedRule adapter.Rule,
	matchOutbound adapter.Outbound,
) N.PacketConn {
	// URLSession may negotiate HTTP/3, so UDP/443 is equally valid route
	// evidence. This callback is separate from RoutedConnection and therefore
	// cannot double-count one transport.
	t.record(metadata, matchedRule, matchOutbound)
	return conn
}

func (t *routingProbeTracker) RoutedFlow(
	_ context.Context,
	metadata adapter.InboundContext,
	matchedRule adapter.Rule,
	matchOutbound adapter.Outbound,
) tun.FlowTracker {
	t.record(metadata, matchedRule, matchOutbound)
	return nil
}

func (t *routingProbeTracker) record(
	metadata adapter.InboundContext,
	matchedRule adapter.Rule,
	matchOutbound adapter.Outbound,
) {
	tunIngress := metadata.Inbound == "tun-in" &&
		metadata.InboundType == C.TypeTun
	transparentProxyIngress :=
		metadata.Inbound == transparentProxyInboundTag &&
			metadata.InboundType == C.TypeSOCKS
	if !tunIngress && !transparentProxyIngress {
		return
	}

	outboundTag := ""
	if matchOutbound != nil {
		outboundTag = matchOutbound.Tag()
	}
	if transparentProxyIngress {
		t.recordExperiment(metadata, matchedRule, outboundTag)
	}
	if metadata.Destination.Port != 443 ||
		!metadata.Destination.Addr.IsValid() {
		return
	}

	target := metadata.Destination.Addr.Unmap()
	switch target {
	case directProbeTarget:
		t.incrementTag(t.directTargetTags, outboundTag)
		switch outboundTag {
		case "direct":
			t.directTargetDirect.Add(1)
		case "vpn":
			t.directTargetVPN.Add(1)
		default:
			t.directTargetOther.Add(1)
		}
	case anyConnectProbeTarget:
		t.incrementTag(t.anyConnectTargetTags, outboundTag)
		switch outboundTag {
		case "direct":
			t.anyConnectTargetDirect.Add(1)
		case "vpn":
			t.anyConnectTargetVPN.Add(1)
		default:
			t.anyConnectTargetOther.Add(1)
		}
	}
}

func (t *routingProbeTracker) recordExperiment(
	metadata adapter.InboundContext,
	matchedRule adapter.Rule,
	outboundTag string,
) {
	if metadata.Destination.Port != 443 ||
		!metadata.Destination.IsFqdn() {
		return
	}
	hostname := strings.ToLower(metadata.Destination.Fqdn)

	t.experimentMu.Lock()
	defer t.experimentMu.Unlock()
	experiment := t.experiment
	if experiment == nil ||
		experiment.hostname == "" ||
		experiment.hostname != hostname {
		return
	}
	experiment.matchCount++
	if outboundTag != "" {
		experiment.outboundTagCounts[outboundTag]++
	}
	ruleSetTag := extractRoutingProbeRuleSetTag(matchedRule)
	if ruleSetTag == "" {
		experiment.ruleSetTagConsistent = false
	} else if experiment.ruleSetTag == "" {
		experiment.ruleSetTag = ruleSetTag
	} else if experiment.ruleSetTag != ruleSetTag {
		experiment.ruleSetTagConsistent = false
	}
}

func extractRoutingProbeRuleSetTag(matchedRule adapter.Rule) string {
	if matchedRule == nil || matchedRule.Type() != C.RuleTypeDefault {
		return ""
	}
	const prefix = "rule_set="
	raw := matchedRule.String()
	if !strings.HasPrefix(raw, prefix) {
		return ""
	}
	tag := strings.TrimPrefix(raw, prefix)
	if tag == "" || len(tag) > 128 {
		return ""
	}
	for _, character := range tag {
		if (character >= 'a' && character <= 'z') ||
			(character >= 'A' && character <= 'Z') ||
			(character >= '0' && character <= '9') ||
			character == '-' || character == '_' ||
			character == '.' || character == ':' {
			continue
		}
		return ""
	}
	return tag
}

func (t *routingProbeTracker) incrementTag(target map[string]uint64, tag string) {
	t.tagCountsMu.Lock()
	target[tag]++
	t.tagCountsMu.Unlock()
}

func (t *routingProbeTracker) snapshot() routingProbeSnapshot {
	t.tagCountsMu.Lock()
	directTargetTags := make(map[string]uint64, len(t.directTargetTags))
	for tag, count := range t.directTargetTags {
		directTargetTags[tag] = count
	}
	anyConnectTargetTags := make(map[string]uint64, len(t.anyConnectTargetTags))
	for tag, count := range t.anyConnectTargetTags {
		anyConnectTargetTags[tag] = count
	}
	t.tagCountsMu.Unlock()
	t.experimentMu.Lock()
	probeID := ""
	matchCount := uint64(0)
	outboundTagCounts := make(map[string]uint64)
	ruleSetTag := ""
	if experiment := t.experiment; experiment != nil {
		probeID = experiment.id
		matchCount = experiment.matchCount
		outboundTagCounts = make(
			map[string]uint64,
			len(experiment.outboundTagCounts),
		)
		for tag, count := range experiment.outboundTagCounts {
			outboundTagCounts[tag] = count
		}
		if experiment.ruleSetTagConsistent {
			ruleSetTag = experiment.ruleSetTag
		}
	}
	t.experimentMu.Unlock()
	return routingProbeSnapshot{
		DirectTargetDirect:     t.directTargetDirect.Load(),
		DirectTargetVPN:        t.directTargetVPN.Load(),
		DirectTargetOther:      t.directTargetOther.Load(),
		AnyConnectTargetDirect: t.anyConnectTargetDirect.Load(),
		AnyConnectTargetVPN:    t.anyConnectTargetVPN.Load(),
		AnyConnectTargetOther:  t.anyConnectTargetOther.Load(),
		DirectTargetTags:       directTargetTags,
		AnyConnectTargetTags:   anyConnectTargetTags,
		ProbeID:                probeID,
		MatchCount:             matchCount,
		OutboundTagCounts:      outboundTagCounts,
		RuleSetTag:             ruleSetTag,
	}
}

func (t *routingProbeTracker) begin(
	rawHostname string,
	timeoutMS int,
) (string, error) {
	hostname, err := normalizeRoutingProbeHostname(rawHostname)
	if err != nil {
		return "", err
	}
	if timeoutMS <= 0 || timeoutMS > maxRouteProbeTimeoutMS {
		return "", fmt.Errorf("route probe timeout is invalid")
	}
	var randomID [16]byte
	if _, err := rand.Read(randomID[:]); err != nil {
		return "", fmt.Errorf("create route probe ID: %w", err)
	}
	probeID := hex.EncodeToString(randomID[:])
	experiment := &routingProbeExperiment{
		id:                   probeID,
		hostname:             hostname,
		outboundTagCounts:    make(map[string]uint64),
		ruleSetTagConsistent: true,
	}

	t.experimentMu.Lock()
	if t.experiment != nil && t.experiment.timer != nil {
		t.experiment.timer.Stop()
	}
	t.experiment = experiment
	experiment.timer = time.AfterFunc(
		time.Duration(timeoutMS)*time.Millisecond,
		func() {
			t.experimentMu.Lock()
			defer t.experimentMu.Unlock()
			if t.experiment != experiment {
				return
			}
			// The probe ID is the capability for this one observation window.
			// Discard the whole experiment at the deadline so a later request
			// cannot mistake an expired aggregate for current evidence.
			t.experiment = nil
		},
	)
	t.experimentMu.Unlock()
	return probeID, nil
}

func normalizeRoutingProbeHostname(rawHostname string) (string, error) {
	if rawHostname == "" ||
		len(rawHostname) > maxRouteProbeHostnameBytes ||
		rawHostname != strings.TrimSpace(rawHostname) {
		return "", fmt.Errorf("route probe hostname is invalid")
	}
	for index := range len(rawHostname) {
		if rawHostname[index] > 0x7f {
			return "", fmt.Errorf("route probe hostname is invalid")
		}
	}
	hostname := strings.ToLower(rawHostname)
	if _, err := netip.ParseAddr(hostname); err == nil {
		return "", fmt.Errorf("route probe hostname is invalid")
	}
	for _, label := range strings.Split(hostname, ".") {
		if label == "" || len(label) > 63 ||
			label[0] == '-' || label[len(label)-1] == '-' {
			return "", fmt.Errorf("route probe hostname is invalid")
		}
		for index := range len(label) {
			character := label[index]
			if (character >= 'a' && character <= 'z') ||
				(character >= '0' && character <= '9') ||
				character == '-' {
				continue
			}
			return "", fmt.Errorf("route probe hostname is invalid")
		}
	}
	return hostname, nil
}

func (t *routingProbeTracker) snapshotJSON() string {
	encoded, err := json.Marshal(t.snapshot())
	if err != nil {
		return routingProbeZeroJSON
	}
	return string(encoded)
}

// RoutingProbeSnapshot returns route evidence collected from system packetFlow
// traffic only. Each successful Start creates a fresh generation; stopped
// engines expose an all-zero snapshot.
func (l *Libbox) RoutingProbeSnapshot() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	if !l.running || l.routingProbe == nil {
		return routingProbeZeroJSON
	}
	return l.routingProbe.snapshotJSON()
}

// BeginRoutingProbe opens one bounded, in-memory observation window for a
// caller-selected ASCII hostname on TCP/UDP 443. It never initiates traffic;
// only the authenticated macOS Transparent Proxy ingress can satisfy it.
func (l *Libbox) BeginRoutingProbe(
	hostname string,
	timeoutMS int,
) (string, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if !l.running || l.routingProbe == nil {
		return "", fmt.Errorf("connection is not running")
	}
	return l.routingProbe.begin(hostname, timeoutMS)
}
