//go:build !windows

package libbox

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/netip"
	"reflect"
	"sync"
	"testing"

	"github.com/sagernet/sing-box/adapter"
	M "github.com/sagernet/sing/common/metadata"

	"github.com/kafeifei/xdial/core/engine"
)

type routingProbeTestOutbound struct {
	tag string
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
	}
	if got := tracker.snapshot(); !reflect.DeepEqual(got, want) {
		t.Fatalf("snapshot = %#v, want %#v", got, want)
	}
	const wantJSON = `{"direct_target_direct":1,"direct_target_vpn":1,"direct_target_other":1,"anyconnect_target_direct":1,"anyconnect_target_vpn":1,"anyconnect_target_other":1,"direct_target_tags":{"direct":1,"selector":1,"vpn":1},"anyconnect_target_tags":{"direct":1,"selector":1,"vpn":1}}`
	if got := tracker.snapshotJSON(); got != wantJSON {
		t.Fatalf("snapshot JSON = %s, want %s", got, wantJSON)
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
