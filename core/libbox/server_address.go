//go:build !windows

package libbox

import (
	"context"
	"fmt"
	"net"
	"net/url"
	"strings"
	"time"
)

const serverAddressResolutionTimeout = 6 * time.Second

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
	return resolveServerIPv4(ctx, net.DefaultResolver, server)
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
		return "", fmt.Errorf("server IPv4 lookup failed")
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
