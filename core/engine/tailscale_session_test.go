package engine

import (
	"net/netip"
	"testing"

	"github.com/sagernet/tailscale/ipn/ipnstate"
	"github.com/sagernet/tailscale/types/key"
)

func TestTailscaleExitNodes(t *testing.T) {
	status := &ipnstate.Status{
		CurrentTailnet: &ipnstate.TailnetStatus{MagicDNSSuffix: "example.ts.net"},
		Peer: map[key.NodePublic]*ipnstate.PeerStatus{
			{}: {
				ID:             "node-1",
				DNSName:        "home-mac.example.ts.net.",
				OS:             "macOS",
				TailscaleIPs:   []netip.Addr{netip.MustParseAddr("fd7a:115c:a1e0::1"), netip.MustParseAddr("100.64.0.8")},
				Online:         true,
				ExitNodeOption: true,
			},
		},
	}

	nodes := tailscaleExitNodes(status)
	if len(nodes) != 1 {
		t.Fatalf("expected one exit node, got %d", len(nodes))
	}
	if nodes[0].Name != "home-mac" || nodes[0].IP != "100.64.0.8" || !nodes[0].Online {
		t.Fatalf("unexpected exit node: %+v", nodes[0])
	}
}
