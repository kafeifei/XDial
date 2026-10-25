//go:build !windows

package libbox

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/kafeifei/xdial/core/engine"
)

const serverAddressResolutionTimeout = 6 * time.Second

const rememberedServerAddressLifetime = 15 * time.Minute
const rememberedServerAddressLimit = 64

var errServerIPv4Lookup = errors.New("server IPv4 lookup failed")
var rememberedServerAddresses serverAddressCache

type rememberedServerAddress struct {
	address string
	expires time.Time
}

// Reconnection hints are process-memory only, bounded, and seeded only after a
// certificate-verified AnyConnect tunnel succeeds. A DNS answer alone must not
// replace a previously working address (for example on a captive network).
type serverAddressCache struct {
	mu      sync.Mutex
	entries map[string]rememberedServerAddress
}

func serverAddressKey(server string) (string, error) {
	host, err := serverHostname(server)
	if err != nil {
		return "", err
	}
	port := "443"
	if strings.Contains(server, "://") {
		parsed, _ := url.Parse(strings.TrimSpace(server))
		if parsed.Port() != "" {
			port = parsed.Port()
		}
	} else if _, parsedPort, err := net.SplitHostPort(strings.TrimSpace(server)); err == nil {
		port = parsedPort
	}
	return net.JoinHostPort(strings.ToLower(host), port), nil
}

func (c *serverAddressCache) remember(config engine.VPNConfig, info *engine.VPNInfo, now time.Time) {
	if config.AllowInsecure || info == nil {
		return
	}
	address := net.ParseIP(info.ServerAddr)
	if address == nil || address.To4() == nil {
		return
	}
	key, err := serverAddressKey(config.Server)
	if err != nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.entries == nil {
		c.entries = make(map[string]rememberedServerAddress)
	}
	for key, entry := range c.entries {
		if !now.Before(entry.expires) {
			delete(c.entries, key)
		}
	}
	if _, exists := c.entries[key]; !exists && len(c.entries) >= rememberedServerAddressLimit {
		var oldestKey string
		var oldest time.Time
		for key, entry := range c.entries {
			if oldest.IsZero() || entry.expires.Before(oldest) {
				oldestKey, oldest = key, entry.expires
			}
		}
		delete(c.entries, oldestKey)
	}
	c.entries[key] = rememberedServerAddress{address.To4().String(), now.Add(rememberedServerAddressLifetime)}
}

func (c *serverAddressCache) lookup(server string, now time.Time) (string, bool) {
	key, err := serverAddressKey(server)
	if err != nil {
		return "", false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	entry, ok := c.entries[key]
	if ok && !now.Before(entry.expires) {
		delete(c.entries, key)
		return "", false
	}
	return entry.address, ok
}

func rememberAnyConnectServerAddress(config engine.VPNConfig, info *engine.VPNInfo) {
	rememberedServerAddresses.remember(config, info, time.Now())
}

func resolveServerIPv4WithFallback(ctx context.Context, resolver serverIPResolver, server string, cache *serverAddressCache, now func() time.Time) (string, error) {
	address, err := resolveServerIPv4(ctx, resolver, server)
	if err == nil || !errors.Is(err, errServerIPv4Lookup) || errors.Is(ctx.Err(), context.Canceled) {
		return address, err
	}
	if address, ok := cache.lookup(server, now()); ok {
		// Only the numeric socket target changes. The caller retains the
		// configured hostname for both certificate verification and HTTP Host.
		return address, nil
	}
	return "", err
}

type serverIPResolver interface {
	LookupIP(ctx context.Context, network, host string) ([]net.IP, error)
}

// ResolveServerIPv4 resolves the configured AnyConnect endpoint before iOS
// installs the packet-tunnel default route. The returned numeric address is
// used both by NETunnelNetworkSettings and by sslcon's socket dial path, while
// the original hostname remains the TLS SNI and HTTP Host identity.
//
// sslcon currently dials tcp4, so returning IPv6 here would create a mismatch
// between the route exclusion and the actual control connection.
func ResolveServerIPv4(server string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), serverAddressResolutionTimeout)
	defer cancel()
	return resolveServerIPv4WithFallback(ctx, net.DefaultResolver, server, &rememberedServerAddresses, time.Now)
}

func resolveServerIPv4(ctx context.Context, resolver serverIPResolver, server string) (string, error) {
	host, err := serverHostname(server)
	if err != nil {
		return "", err
	}

	if ip := net.ParseIP(host); ip != nil {
		if ipv4 := ip.To4(); ipv4 != nil {
			return ipv4.String(), nil
		}
		return "", fmt.Errorf("server endpoint is not IPv4")
	}

	addresses, err := resolver.LookupIP(ctx, "ip4", host)
	if err != nil {
		return "", errServerIPv4Lookup
	}
	for _, address := range addresses {
		if ipv4 := address.To4(); ipv4 != nil {
			return ipv4.String(), nil
		}
	}
	return "", fmt.Errorf("server endpoint has no IPv4 address")
}

func serverHostname(server string) (string, error) {
	raw := strings.TrimSpace(server)
	if raw == "" {
		return "", fmt.Errorf("server endpoint is empty")
	}

	if strings.Contains(raw, "://") {
		parsed, err := url.Parse(raw)
		if err != nil || parsed.Hostname() == "" {
			return "", fmt.Errorf("server endpoint is invalid")
		}
		return parsed.Hostname(), nil
	}

	if host, _, err := net.SplitHostPort(raw); err == nil {
		if host == "" {
			return "", fmt.Errorf("server endpoint is invalid")
		}
		return strings.Trim(host, "[]"), nil
	}

	trimmed := strings.Trim(raw, "[]")
	if net.ParseIP(trimmed) != nil {
		return trimmed, nil
	}
	if strings.ContainsAny(raw, "/?#") || strings.Contains(raw, ":") {
		return "", fmt.Errorf("server endpoint is invalid")
	}
	return raw, nil
}
