//go:build !windows

package libbox

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/netip"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	M "github.com/sagernet/sing/common/metadata"

	"github.com/kafeifei/xdial/core/engine"
)

type routingProbeTestOutbound struct {
	tag string
}

type routingProbeTestRule struct {
	ruleType string
	text     string
}

func (r *routingProbeTestRule) Match(*adapter.InboundContext) bool {
	return true
}

func (r *routingProbeTestRule) String() string {
	return r.text
}

func (r *routingProbeTestRule) Start() error {
	return nil
}

func (r *routingProbeTestRule) Close() error {
	return nil
}

func (r *routingProbeTestRule) Type() string {
	return r.ruleType
}

func (r *routingProbeTestRule) Action() adapter.RuleAction {
	return nil
}

func (o *routingProbeTestOutbound) Type() string {
	return "test"
}

func (o *routingProbeTestOutbound) Tag() string {
	return o.tag
}

func (o *routingProbeTestOutbound) Network() []string {
	return []string{"tcp", "udp"}
}

func (o *routingProbeTestOutbound) Dependencies() []string {
	return nil
}

func (o *routingProbeTestOutbound) DialContext(context.Context, string, M.Socksaddr) (net.Conn, error) {
	return nil, errors.New("not implemented")
}

func (o *routingProbeTestOutbound) ListenPacket(context.Context, M.Socksaddr) (net.PacketConn, error) {
	return nil, errors.New("not implemented")
}

func routingProbeMetadata(address string) adapter.InboundContext {
	return adapter.InboundContext{
		Inbound:     "tun-in",
		InboundType: "tun",
		Destination: M.Socksaddr{
			Addr: netip.MustParseAddr(address),
			Port: 443,
		},
	}
}

func transparentProxyProbeMetadata(hostname string) adapter.InboundContext {
	return adapter.InboundContext{
		Inbound:     transparentProxyInboundTag,
		InboundType: "socks",
		Destination: M.Socksaddr{
			Fqdn: hostname,
			Port: 443,
		},
	}
}

func transparentProxyIPProbeMetadata(address string) adapter.InboundContext {
	return adapter.InboundContext{
		Inbound:     transparentProxyInboundTag,
		InboundType: "socks",
		Destination: M.Socksaddr{
			Addr: netip.MustParseAddr(address),
			Port: 443,
		},
	}
}

func decodeRoutingProbeSnapshot(t *testing.T, encoded string) routingProbeSnapshot {
	t.Helper()
	var snapshot routingProbeSnapshot
	if err := json.Unmarshal([]byte(encoded), &snapshot); err != nil {
		t.Fatalf("decode routing probe snapshot %q: %v", encoded, err)
	}
	return snapshot
}

func TestRoutingProbeTrackerClassifiesFixedTCPRoutes(t *testing.T) {
	tracker := newRoutingProbeTracker()
	left, right := net.Pipe()
	defer left.Close()
	defer right.Close()

	testCases := []struct {
		address string
		tag     string
	}{
		{address: "1.0.0.1", tag: "direct"},
		{address: "1.0.0.1", tag: "vpn"},
		{address: "1.0.0.1", tag: "selector"},
		{address: "1.1.1.1", tag: "direct"},
		{address: "1.1.1.1", tag: "vpn"},
		{address: "1.1.1.1", tag: "selector"},
	}
	for _, testCase := range testCases {
		got := tracker.RoutedConnection(
			context.Background(),
			left,
			routingProbeMetadata(testCase.address),
			nil,
			&routingProbeTestOutbound{tag: testCase.tag},
		)
		if got != left {
			t.Fatal("tracker replaced routed connection")
		}
	}

	want := routingProbeSnapshot{
		DirectTargetDirect:     1,
		DirectTargetVPN:        1,
		DirectTargetOther:      1,
		AnyConnectTargetDirect: 1,
		AnyConnectTargetVPN:    1,
		AnyConnectTargetOther:  1,
		DirectTargetTags: map[string]uint64{
			"direct":   1,
			"vpn":      1,
			"selector": 1,
		},
		AnyConnectTargetTags: map[string]uint64{
			"direct":   1,
			"vpn":      1,
			"selector": 1,
		},
		OutboundTagCounts: map[string]uint64{},
	}
	if got := tracker.snapshot(); !reflect.DeepEqual(got, want) {
		t.Fatalf("snapshot = %#v, want %#v", got, want)
	}
	const wantJSON = `{"direct_target_direct":1,"direct_target_vpn":1,"direct_target_other":1,"anyconnect_target_direct":1,"anyconnect_target_vpn":1,"anyconnect_target_other":1,"direct_target_tags":{"direct":1,"selector":1,"vpn":1},"anyconnect_target_tags":{"direct":1,"selector":1,"vpn":1},"probe_id":"","match_count":0,"outbound_tag_counts":{}}`
	if got := tracker.snapshotJSON(); got != wantJSON {
		t.Fatalf("snapshot JSON = %s, want %s", got, wantJSON)
	}
}

func TestRoutingProbeTrackerAcceptsOnlyExactTransparentProxyIngress(t *testing.T) {
	tracker := newRoutingProbeTracker()
	outbound := &routingProbeTestOutbound{tag: "direct"}
	metadata := routingProbeMetadata("1.0.0.1")
	metadata.Inbound = transparentProxyInboundTag
	metadata.InboundType = "socks"
	tracker.RoutedConnection(context.Background(), nil, metadata, nil, outbound)

	genericSOCKS := metadata
	genericSOCKS.Inbound = "socks-in"
	tracker.RoutedConnection(context.Background(), nil, genericSOCKS, nil, outbound)
	wrongType := metadata
	wrongType.InboundType = "http"
	tracker.RoutedConnection(context.Background(), nil, wrongType, nil, outbound)

	got := tracker.snapshot()
	if got.DirectTargetDirect != 1 {
		t.Fatalf("Transparent Proxy ingress count = %d, want 1", got.DirectTargetDirect)
	}
}

func TestRoutingProbeExperimentObservesOnlyBoundedAuthenticatedFlow(t *testing.T) {
	tracker := newRoutingProbeTracker()
	probeID, err := tracker.begin("Probe.Example", 100)
	if err != nil {
		t.Fatal(err)
	}
	matchedRule := &routingProbeTestRule{
		ruleType: "default",
		text:     "rule_set=ruleset-cn",
	}
	outbound := &routingProbeTestOutbound{tag: "tailscale-japan"}
	tracker.RoutedConnection(
		context.Background(),
		nil,
		transparentProxyProbeMetadata("probe.example"),
		matchedRule,
		outbound,
	)

	wrongIngress := transparentProxyProbeMetadata("probe.example")
	wrongIngress.Inbound = "socks-in"
	tracker.RoutedConnection(
		context.Background(),
		nil,
		wrongIngress,
		matchedRule,
		outbound,
	)
	wrongPort := transparentProxyProbeMetadata("probe.example")
	wrongPort.Destination.Port = 80
	tracker.RoutedConnection(
		context.Background(),
		nil,
		wrongPort,
		matchedRule,
		outbound,
	)
	tracker.RoutedConnection(
		context.Background(),
		nil,
		transparentProxyProbeMetadata("other.example"),
		matchedRule,
		outbound,
	)

	got := tracker.snapshot()
	if got.ProbeID != probeID ||
		got.MatchCount != 1 ||
		got.OutboundTagCounts["tailscale-japan"] != 1 ||
		got.RuleSetTag != "ruleset-cn" {
		t.Fatalf("bounded route probe snapshot = %#v", got)
	}
	encoded := tracker.snapshotJSON()
	if strings.Contains(encoded, "probe.example") ||
		strings.Contains(encoded, "rule_set=") {
		t.Fatalf("route probe leaked target or raw rule: %s", encoded)
	}

	deadline := time.Now().Add(time.Second)
	for tracker.snapshot().ProbeID != "" && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	tracker.RoutedConnection(
		context.Background(),
		nil,
		transparentProxyProbeMetadata("probe.example"),
		matchedRule,
		outbound,
	)
	after := tracker.snapshot()
	if after.ProbeID != "" ||
		after.MatchCount != 0 ||
		len(after.OutboundTagCounts) != 0 ||
		after.RuleSetTag != "" {
		t.Fatalf("expired probe remained available: %#v", after)
	}
}

func TestRoutingProbeExperimentCorrelatesSystemResolvedDNSSnapshotAddress(
	t *testing.T,
) {
	tracker := newRoutingProbeTracker()
	tracker.replaceDNSSnapshotAddresses(map[string][]netip.Addr{
		"probe": {
			netip.MustParseAddr("100.64.0.8"),
			netip.MustParseAddr("fd7a:115c:a1e0::8"),
		},
		"Probe.Example.": {
			netip.MustParseAddr("100.64.0.8"),
			netip.MustParseAddr("fd7a:115c:a1e0::8"),
		},
		"probe.other.example": {
			netip.MustParseAddr("100.64.0.9"),
		},
	})
	probeID, err := tracker.begin("probe", 1_000)
	if err != nil {
		t.Fatal(err)
	}
	outbound := &routingProbeTestOutbound{tag: "tailscale-japan"}
	tracker.RoutedConnection(
		context.Background(),
		nil,
		transparentProxyIPProbeMetadata("100.64.0.9"),
		nil,
		outbound,
	)
	tracker.RoutedConnection(
		context.Background(),
		nil,
		transparentProxyProbeMetadata("probe.other.example"),
		nil,
		outbound,
	)
	tracker.RoutedConnection(
		context.Background(),
		nil,
		transparentProxyProbeMetadata("probe.example"),
		nil,
		outbound,
	)
	tracker.RoutedConnection(
		context.Background(),
		nil,
		transparentProxyIPProbeMetadata("100.64.0.8"),
		nil,
		outbound,
	)

	got := tracker.snapshot()
	if got.ProbeID != probeID ||
		got.MatchCount != 2 ||
		got.OutboundTagCounts["tailscale-japan"] != 2 {
		t.Fatalf("resolved-address route probe snapshot = %#v", got)
	}
	encoded := tracker.snapshotJSON()
	if strings.Contains(encoded, "100.64.0.8") ||
		strings.Contains(encoded, "probe.example") {
		t.Fatalf("route probe leaked DNS snapshot input: %s", encoded)
	}
}

func TestRoutingProbeExperimentNeverReusesOldWindow(t *testing.T) {
	tracker := newRoutingProbeTracker()
	firstID, err := tracker.begin("first.example", 1_000)
	if err != nil {
		t.Fatal(err)
	}
	secondID, err := tracker.begin("second.example", 1_000)
	if err != nil {
		t.Fatal(err)
	}
	if firstID == secondID {
		t.Fatal("new route probe reused the prior probe ID")
	}

	tracker.RoutedConnection(
		context.Background(),
		nil,
		transparentProxyProbeMetadata("first.example"),
		&routingProbeTestRule{
			ruleType: "default",
			text:     "rule_set=ruleset-first",
		},
		&routingProbeTestOutbound{tag: "first-line"},
	)
	if got := tracker.snapshot(); got.ProbeID != secondID ||
		got.MatchCount != 0 {
		t.Fatalf("old target affected current window: %#v", got)
	}

	tracker.RoutedConnection(
		context.Background(),
		nil,
		transparentProxyProbeMetadata("second.example"),
		&routingProbeTestRule{
			ruleType: "default",
			text:     "rule_set=ruleset-second",
		},
		&routingProbeTestOutbound{tag: "second-line"},
	)
	if got := tracker.snapshot(); got.ProbeID != secondID ||
		got.MatchCount != 1 ||
		got.OutboundTagCounts["second-line"] != 1 {
		t.Fatalf("current window snapshot = %#v", got)
	}
}

func TestRoutingProbeExperimentStrictlyExtractsSingleRuleSetTag(t *testing.T) {
	testCases := []struct {
		name string
		rule adapter.Rule
		want string
	}{
		{
			name: "exact",
			rule: &routingProbeTestRule{
				ruleType: "default",
				text:     "rule_set=ruleset-company",
			},
			want: "ruleset-company",
		},
		{
			name: "extra condition",
			rule: &routingProbeTestRule{
				ruleType: "default",
				text:     "rule_set=ruleset-company port=443",
			},
		},
		{
			name: "multiple sets",
			rule: &routingProbeTestRule{
				ruleType: "default",
				text:     "rule_set=[ruleset-a ruleset-b]",
			},
		},
		{
			name: "logical rule",
			rule: &routingProbeTestRule{
				ruleType: "logical",
				text:     "rule_set=ruleset-company",
			},
		},
	}
	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			if got := extractRoutingProbeRuleSetTag(testCase.rule); got != testCase.want {
				t.Fatalf("extracted tag = %q, want %q", got, testCase.want)
			}
		})
	}
}

func TestRoutingProbeExperimentRejectsInvalidHostAndTimeout(t *testing.T) {
	tracker := newRoutingProbeTracker()
	for _, hostname := range []string{
		"",
		" target.example",
		"target.example.",
		"target_underscore.example",
		"192.0.2.1",
		"测试.example",
	} {
		if _, err := tracker.begin(hostname, 1_000); err == nil {
			t.Fatalf("accepted invalid hostname %q", hostname)
		}
	}
	if _, err := tracker.begin("target.example", 0); err == nil {
		t.Fatal("accepted zero timeout")
	}
	if _, err := tracker.begin(
		"target.example",
		maxRouteProbeTimeoutMS+1,
	); err == nil {
		t.Fatal("accepted timeout beyond 15 seconds")
	}
}

func TestRoutingProbeTrackerRejectsNonSystemProbeTraffic(t *testing.T) {
	tracker := newRoutingProbeTracker()
	outbound := &routingProbeTestOutbound{tag: "direct"}

	wrongInbound := routingProbeMetadata("1.0.0.1")
	wrongInbound.Inbound = "socks-in"
	tracker.RoutedConnection(context.Background(), nil, wrongInbound, nil, outbound)

	wrongInboundType := routingProbeMetadata("1.0.0.1")
	wrongInboundType.InboundType = "socks"
	tracker.RoutedConnection(context.Background(), nil, wrongInboundType, nil, outbound)

	wrongPort := routingProbeMetadata("1.0.0.1")
	wrongPort.Destination.Port = 80
	tracker.RoutedConnection(context.Background(), nil, wrongPort, nil, outbound)

	tracker.RoutedConnection(context.Background(), nil, routingProbeMetadata("8.8.8.8"), nil, outbound)
	tracker.RoutedConnection(context.Background(), nil, adapter.InboundContext{
		Inbound:     "tun-in",
		InboundType: "tun",
		Destination: M.Socksaddr{Fqdn: "1.0.0.1", Port: 443},
	}, nil, outbound)
	wrongPacketPort := routingProbeMetadata("1.0.0.1")
	wrongPacketPort.Destination.Port = 53
	tracker.RoutedPacketConnection(
		context.Background(),
		nil,
		wrongPacketPort,
		nil,
		outbound,
	)

	if got := tracker.snapshotJSON(); got != routingProbeZeroJSON {
		t.Fatalf("non-probe traffic changed snapshot: %s", got)
	}
}

func TestRoutingProbeTrackerClassifiesHTTP3PacketRoutes(t *testing.T) {
	tracker := newRoutingProbeTracker()

	tracker.RoutedPacketConnection(
		context.Background(),
		nil,
		routingProbeMetadata("1.0.0.1"),
		nil,
		&routingProbeTestOutbound{tag: "direct"},
	)
	tracker.RoutedPacketConnection(
		context.Background(),
		nil,
		routingProbeMetadata("1.1.1.1"),
		nil,
		&routingProbeTestOutbound{tag: "vpn"},
	)

	got := tracker.snapshot()
	if got.DirectTargetDirect != 1 || got.AnyConnectTargetVPN != 1 {
		t.Fatalf("HTTP/3 route snapshot = %#v", got)
	}
}

func TestRoutingProbeTrackerIsThreadSafe(t *testing.T) {
	const (
		writerCount = 32
		routesEach  = 500
		readerCount = 4
	)
	tracker := newRoutingProbeTracker()
	metadata := routingProbeMetadata("1.0.0.1")
	outbound := &routingProbeTestOutbound{tag: "direct"}

	stopReaders := make(chan struct{})
	var readerWG sync.WaitGroup
	for range readerCount {
		readerWG.Add(1)
		go func() {
			defer readerWG.Done()
			for {
				select {
				case <-stopReaders:
					return
				default:
					var snapshot routingProbeSnapshot
					if err := json.Unmarshal([]byte(tracker.snapshotJSON()), &snapshot); err != nil {
						t.Errorf("concurrent snapshot is invalid JSON: %v", err)
						return
					}
				}
			}
		}()
	}

	var writerWG sync.WaitGroup
	for range writerCount {
		writerWG.Add(1)
		go func() {
			defer writerWG.Done()
			for range routesEach {
				tracker.RoutedConnection(context.Background(), nil, metadata, nil, outbound)
			}
		}()
	}
	writerWG.Wait()
	close(stopReaders)
	readerWG.Wait()

	want := uint64(writerCount * routesEach)
	if got := tracker.snapshot().DirectTargetDirect; got != want {
		t.Fatalf("direct route count = %d, want %d", got, want)
	}
}

func TestRoutingProbeSnapshotResetsAcrossStartGenerations(t *testing.T) {
	platform := &xdPlatformInterface{}
	platform.setDefaultInterface("test0", 1)
	newVPN := func() *startTestVPNClient {
		return &startTestVPNClient{
			session: newStartTestSession(),
			info: &engine.VPNInfo{
				VPNAddress: "10.0.0.2",
				DNS:        []string{"10.0.0.53"},
				MTU:        1400,
			},
		}
	}
	configJSON := `{
		"log":{"disabled":true},
		"outbounds":[{"type":"direct","tag":"direct"}],
		"route":{"final":"direct"}
	}`
	l := &Libbox{vpn: newVPN(), platform: platform}
	l.SetDebugRoutingProbeEnabled(true)

	if got := l.RoutingProbeSnapshot(); got != routingProbeZeroJSON {
		t.Fatalf("stopped snapshot = %s", got)
	}
	if err := l.Start("https://connect.example.com", "user", "password", configJSON); err != nil {
		t.Fatalf("first Start: %v", err)
	}
	firstTracker := l.routingProbe
	if firstTracker == nil {
		t.Fatal("first Start did not install routing tracker")
	}
	firstTracker.RoutedConnection(
		context.Background(),
		nil,
		routingProbeMetadata("1.0.0.1"),
		nil,
		&routingProbeTestOutbound{tag: "direct"},
	)
	if got := decodeRoutingProbeSnapshot(t, l.RoutingProbeSnapshot()).DirectTargetDirect; got != 1 {
		t.Fatalf("running route count = %d, want 1", got)
	}
	if err := l.Stop(); err != nil {
		t.Fatalf("first Stop: %v", err)
	}
	if got := l.RoutingProbeSnapshot(); got != routingProbeZeroJSON {
		t.Fatalf("stopped snapshot retained prior generation: %s", got)
	}

	l.vpn = newVPN()
	if err := l.Start("https://connect.example.com", "user", "password", configJSON); err != nil {
		t.Fatalf("second Start: %v", err)
	}
	if l.routingProbe == firstTracker {
		t.Fatal("second Start reused the prior generation tracker")
	}
	if got := l.RoutingProbeSnapshot(); got != routingProbeZeroJSON {
		t.Fatalf("second generation did not start empty: %s", got)
	}
	if err := l.Stop(); err != nil {
		t.Fatalf("second Stop: %v", err)
	}
}

func TestRoutingProbeDisabledByDefaultNeverInstallsFlowTracker(
	t *testing.T,
) {
	platform := &xdPlatformInterface{}
	platform.setDefaultInterface("test0", 1)
	configJSON := `{
		"log":{"disabled":true},
		"outbounds":[{"type":"direct","tag":"direct"}],
		"route":{"final":"direct"}
	}`
	l := &Libbox{platform: platform}
	if err := l.StartStandalone(configJSON); err != nil {
		t.Fatal(err)
	}
	defer l.Stop()

	if l.routingProbe != nil {
		t.Fatal("default runtime installed a routing flow tracker")
	}
	if got := l.RoutingProbeSnapshot(); got != routingProbeZeroJSON {
		t.Fatalf("disabled routing probe returned evidence: %s", got)
	}
	if _, err := l.BeginRoutingProbe("probe.example", 1_000); err == nil {
		t.Fatal("disabled runtime accepted a route probe window")
	}

	// The flag is a next-generation option; changing it must not splice a
	// tracker into a running box.
	l.SetDebugRoutingProbeEnabled(true)
	if l.routingProbe != nil {
		t.Fatal("running generation was mutated by the debug option")
	}
}

func TestRoutingProbeDisabledByDefaultOnAnyConnectStart(t *testing.T) {
	platform := &xdPlatformInterface{}
	platform.setDefaultInterface("test0", 1)
	vpn := &startTestVPNClient{
		session: newStartTestSession(),
		info: &engine.VPNInfo{
			VPNAddress: "10.0.0.2",
			DNS:        []string{"10.0.0.53"},
			MTU:        1400,
		},
	}
	l := &Libbox{vpn: vpn, platform: platform}
	configJSON := `{
		"log":{"disabled":true},
		"outbounds":[{"type":"direct","tag":"direct"}],
		"route":{"final":"direct"}
	}`
	if err := l.Start(
		"https://connect.example.com",
		"user",
		"password",
		configJSON,
	); err != nil {
		t.Fatal(err)
	}
	defer l.Stop()

	if l.routingProbe != nil {
		t.Fatal("default AnyConnect runtime installed a routing flow tracker")
	}
	if got := l.RoutingProbeSnapshot(); got != routingProbeZeroJSON {
		t.Fatalf("disabled AnyConnect route probe returned evidence: %s", got)
	}
}
