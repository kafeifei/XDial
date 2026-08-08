//go:build !windows

package libbox

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"sync"

	"github.com/kafeifei/xdial/core/engine"

	mDNS "github.com/miekg/dns"
)

var errAnyConnectLineUnavailable = errors.New("AnyConnect line is reconnecting")

// anyConnectLineRuntime is the stable data-plane handle owned by one sing-box
// generation. The concrete AnyConnect bridge behind it may be replaced after a
// line-only reconnect without rebuilding unrelated endpoints such as
// Tailscale.
//
// An empty slot is deliberate fail-closed state: new TCP/UDP dials fail
// immediately and the DNS transport returns an error, which sing-box exposes
// to the client as SERVFAIL. It never falls back to direct or another resolver.
type anyConnectLineRuntime struct {
	mu        sync.RWMutex
	bridge    *engine.VPNBridge
	dnsServer []netip.Addr
}

func newAnyConnectLineRuntime(
	bridge *engine.VPNBridge,
	dnsServer []netip.Addr,
) *anyConnectLineRuntime {
	line := &anyConnectLineRuntime{}
	line.activate(bridge, dnsServer)
	return line
}

func anyConnectDNSServers(raw []string) []netip.Addr {
	servers := make([]netip.Addr, 0, len(raw))
	for _, value := range raw {
		addr, err := netip.ParseAddr(value)
		if err == nil && addr.Is4() {
			servers = append(servers, addr)
		}
	}
	return servers
}

func (l *anyConnectLineRuntime) activate(
	bridge *engine.VPNBridge,
	dnsServer []netip.Addr,
) {
	l.mu.Lock()
	l.bridge = bridge
	l.dnsServer = append([]netip.Addr(nil), dnsServer...)
	l.mu.Unlock()
}

func (l *anyConnectLineRuntime) deactivate(
	expected *engine.VPNBridge,
) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.bridge != expected {
		return false
	}
	l.bridge = nil
	l.dnsServer = nil
	return true
}

func (l *anyConnectLineRuntime) snapshot() (
	*engine.VPNBridge,
	[]netip.Addr,
) {
	l.mu.RLock()
	bridge := l.bridge
	servers := append([]netip.Addr(nil), l.dnsServer...)
	l.mu.RUnlock()
	return bridge, servers
}

func (l *anyConnectLineRuntime) available() bool {
	bridge, _ := l.snapshot()
	return bridge != nil
}

func (l *anyConnectLineRuntime) DialTCP(
	ctx context.Context,
	address string,
) (net.Conn, error) {
	bridge, _ := l.snapshot()
	if bridge == nil {
		return nil, errAnyConnectLineUnavailable
	}
	return bridge.DialTCP(ctx, address)
}

func (l *anyConnectLineRuntime) DialUDP(
	local,
	remote *net.UDPAddr,
) (net.Conn, error) {
	bridge, _ := l.snapshot()
	if bridge == nil {
		return nil, errAnyConnectLineUnavailable
	}
	return bridge.DialUDP(local, remote)
}

func (l *anyConnectLineRuntime) Exchange(
	ctx context.Context,
	message *mDNS.Msg,
) (*mDNS.Msg, error) {
	bridge, servers := l.snapshot()
	if bridge == nil || len(servers) == 0 {
		return nil, errMobileDNSFailed
	}
	return newBridgeDNSExchanger(bridge, servers).Exchange(ctx, message)
}
