//go:build !windows

package libbox

import (
	"context"
	"encoding/json"
	"net"
	"net/netip"
	"sync"
	"sync/atomic"

	"github.com/sagernet/sing-box/adapter"
	C "github.com/sagernet/sing-box/constant"
	N "github.com/sagernet/sing/common/network"
)

const routingProbeZeroJSON = `{"direct_target_direct":0,"direct_target_vpn":0,"direct_target_other":0,"anyconnect_target_direct":0,"anyconnect_target_vpn":0,"anyconnect_target_other":0,"direct_target_tags":{},"anyconnect_target_tags":{}}`

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
	_ adapter.Rule,
	matchOutbound adapter.Outbound,
) net.Conn {
	t.record(metadata, matchOutbound)
	return conn
}

func (t *routingProbeTracker) RoutedPacketConnection(
	_ context.Context,
	conn N.PacketConn,
	metadata adapter.InboundContext,
	_ adapter.Rule,
	matchOutbound adapter.Outbound,
) N.PacketConn {
	// URLSession may negotiate HTTP/3, so UDP/443 is equally valid route
	// evidence. This callback is separate from RoutedConnection and therefore
	// cannot double-count one transport.
	t.record(metadata, matchOutbound)
	return conn
}

func (t *routingProbeTracker) record(metadata adapter.InboundContext, matchOutbound adapter.Outbound) {
	if metadata.Inbound != "tun-in" ||
		metadata.InboundType != C.TypeTun ||
		metadata.Destination.Port != 443 ||
		!metadata.Destination.Addr.IsValid() {
		return
	}

	target := metadata.Destination.Addr.Unmap()
	outboundTag := ""
	if matchOutbound != nil {
		outboundTag = matchOutbound.Tag()
	}
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
	return routingProbeSnapshot{
		DirectTargetDirect:     t.directTargetDirect.Load(),
		DirectTargetVPN:        t.directTargetVPN.Load(),
		DirectTargetOther:      t.directTargetOther.Load(),
		AnyConnectTargetDirect: t.anyConnectTargetDirect.Load(),
		AnyConnectTargetVPN:    t.anyConnectTargetVPN.Load(),
		AnyConnectTargetOther:  t.anyConnectTargetOther.Load(),
		DirectTargetTags:       directTargetTags,
		AnyConnectTargetTags:   anyConnectTargetTags,
	}
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
