//go:build !windows

package libbox

import (
	"context"
	"net/netip"
	"strings"
	"testing"

	M "github.com/sagernet/sing/common/metadata"
)

func TestVPNOutboundRejectsIPv6WithoutBridgePanic(t *testing.T) {
	outbound := &vpnOutbound{line: &anyConnectLineRuntime{}}
	destination := M.SocksaddrFrom(netip.MustParseAddr("2001:db8::1"), 443)
	_, err := outbound.DialContext(context.Background(), "tcp", destination)
	if err == nil || !strings.Contains(err.Error(), "IPv6") {
		t.Fatalf("expected controlled IPv6 rejection, got %v", err)
	}
}

func TestVPNOutboundDoesNotFallBackWhenTunnelDNSUnavailable(t *testing.T) {
	outbound := &vpnOutbound{line: &anyConnectLineRuntime{}}
	_, err := outbound.resolve(context.Background(), "internal.example")
	if err == nil || !strings.Contains(err.Error(), "tunnel DNS") {
		t.Fatalf("expected fail-closed tunnel DNS error, got %v", err)
	}
}
