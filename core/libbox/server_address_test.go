//go:build !windows

package libbox

import (
	"context"
	"errors"
	"fmt"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/kafeifei/xdial/core/engine"
)

type stubServerIPResolver struct {
	addresses []net.IP
	err       error
	host      string
	network   string
}

func (r *stubServerIPResolver) LookupIP(_ context.Context, network, host string) ([]net.IP, error) {
	r.network = network
	r.host = host
	return r.addresses, r.err
}

func TestResolveServerIPv4AcceptsLiteral(t *testing.T) {
	resolver := &stubServerIPResolver{err: errors.New("must not resolve a literal")}
	got, err := resolveServerIPv4(context.Background(), resolver, "198.51.100.7:8443")
	if err != nil {
		t.Fatalf("resolve literal: %v", err)
	}
	if got != "198.51.100.7" {
		t.Fatalf("address = %q, want 198.51.100.7", got)
	}
}

func TestResolveServerIPv4ResolvesURLHostname(t *testing.T) {
	resolver := &stubServerIPResolver{addresses: []net.IP{
		net.ParseIP("2001:db8::1"),
		net.ParseIP("203.0.113.9"),
	}}
	got, err := resolveServerIPv4(context.Background(), resolver, "https://gateway.example.com:9443/path")
	if err != nil {
		t.Fatalf("resolve hostname: %v", err)
	}
	if got != "203.0.113.9" {
		t.Fatalf("address = %q, want 203.0.113.9", got)
	}
	if resolver.network != "ip4" || resolver.host != "gateway.example.com" {
		t.Fatalf("lookup = %q %q, want ip4 gateway.example.com", resolver.network, resolver.host)
	}
}

func TestResolveServerIPv4RejectsLookupFailureWithoutLeakingHost(t *testing.T) {
	resolver := &stubServerIPResolver{err: errors.New("lookup gateway.secret.example: no such host")}
	_, err := resolveServerIPv4(context.Background(), resolver, "gateway.secret.example")
	if err == nil {
		t.Fatal("expected lookup error")
	}
	if got := err.Error(); got != "server IPv4 lookup failed" {
		t.Fatalf("error = %q, want redacted lookup failure", got)
	}
}

func TestServerHostnameRejectsIPv6BecauseControlPathIsTCP4(t *testing.T) {
	resolver := &stubServerIPResolver{}
	_, err := resolveServerIPv4(context.Background(), resolver, "[2001:db8::2]:443")
	if err == nil || err.Error() != "server endpoint is not IPv4" {
		t.Fatalf("error = %v, want IPv4-only error", err)
	}
}

func TestServerAddressFallbackUsesVerifiedTunnelAfterDNSFailure(t *testing.T) {
	var cache serverAddressCache
	now := time.Unix(100, 0)
	config := engine.VPNConfig{Server: "gateway.example:8443"}
	cache.remember(config, &engine.VPNInfo{ServerAddr: "203.0.113.8"}, now)
	resolver := &stubServerIPResolver{err: context.DeadlineExceeded}
	got, err := resolveServerIPv4WithFallback(context.Background(), resolver, config.Server, &cache, func() time.Time { return now })
	if err != nil || got != "203.0.113.8" {
		t.Fatalf("DNS outage recovery = %q, %v", got, err)
	}
	if resolver.host != "gateway.example" || config.Server != "gateway.example:8443" {
		t.Fatal("fallback changed the hostname/certificate identity")
	}
}

func TestServerAddressFallbackNeverSeedsFromAnInsecureOrInvalidTunnel(t *testing.T) {
	for _, test := range []struct {
		name     string
		insecure bool
		address  string
	}{
		{"insecure", true, "203.0.113.8"},
		{"empty", false, ""},
		{"ipv6", false, "2001:db8::1"},
		{"invalid", false, "not an address"},
	} {
		t.Run(test.name, func(t *testing.T) {
			var cache serverAddressCache
			now := time.Unix(100, 0)
			config := engine.VPNConfig{Server: "gateway.example:8443", AllowInsecure: test.insecure}
			cache.remember(config, &engine.VPNInfo{ServerAddr: test.address}, now)
			_, err := resolveServerIPv4WithFallback(context.Background(), &stubServerIPResolver{err: errors.New("DNS unavailable")}, config.Server, &cache, func() time.Time { return now })
			if !errors.Is(err, errServerIPv4Lookup) {
				t.Fatalf("unverified cache entry used: %v", err)
			}
		})
	}
}

func TestServerAddressFallbackExpiresWithoutExtendingItsLifetime(t *testing.T) {
	var cache serverAddressCache
	start := time.Unix(100, 0)
	cache.remember(engine.VPNConfig{Server: "gateway.example"}, &engine.VPNInfo{ServerAddr: "203.0.113.8"}, start)
	if _, ok := cache.lookup("gateway.example", start.Add(rememberedServerAddressLifetime-time.Second)); !ok {
		t.Fatal("entry expired too early")
	}
	if _, ok := cache.lookup("gateway.example", start.Add(rememberedServerAddressLifetime)); ok {
		t.Fatal("fallback read extended the expiry")
	}
}

func TestServerAddressFallbackIsScopedToHostnameAndPort(t *testing.T) {
	var cache serverAddressCache
	now := time.Unix(100, 0)
	cache.remember(engine.VPNConfig{Server: "https://Gateway.example:8443/path"}, &engine.VPNInfo{ServerAddr: "203.0.113.8"}, now)
	if _, ok := cache.lookup("gateway.example:8443", now); !ok {
		t.Fatal("equivalent endpoint did not match")
	}
	for _, server := range []string{"other.example:8443", "gateway.example:443", "gateway.example"} {
		if _, ok := cache.lookup(server, now); ok {
			t.Fatalf("reused another endpoint's address: %s", server)
		}
	}
}

func TestFreshDNSWinsButCannotPoisonVerifiedFallback(t *testing.T) {
	var cache serverAddressCache
	now := time.Unix(100, 0)
	server := "gateway.example"
	cache.remember(engine.VPNConfig{Server: server}, &engine.VPNInfo{ServerAddr: "203.0.113.8"}, now)
	clock := func() time.Time { return now }
	fresh := &stubServerIPResolver{addresses: []net.IP{net.ParseIP("203.0.113.9")}}
	if got, err := resolveServerIPv4WithFallback(context.Background(), fresh, server, &cache, clock); got != "203.0.113.9" || err != nil {
		t.Fatalf("fresh DNS ignored: %q, %v", got, err)
	}
	failed := &stubServerIPResolver{err: errors.New("DNS unavailable")}
	if got, err := resolveServerIPv4WithFallback(context.Background(), failed, server, &cache, clock); got != "203.0.113.8" || err != nil {
		t.Fatalf("unverified DNS result replaced tunnel evidence: %q, %v", got, err)
	}
}

func TestServerAddressFallbackRespectsCancellationAndIPv4Policy(t *testing.T) {
	var cache serverAddressCache
	now := time.Unix(100, 0)
	server := "gateway.example"
	cache.remember(engine.VPNConfig{Server: server}, &engine.VPNInfo{ServerAddr: "203.0.113.8"}, now)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := resolveServerIPv4WithFallback(ctx, &stubServerIPResolver{err: context.Canceled}, server, &cache, func() time.Time { return now }); err == nil {
		t.Fatal("canceled operation resumed through fallback")
	}
	if _, err := resolveServerIPv4WithFallback(context.Background(), &stubServerIPResolver{}, server, &cache, func() time.Time { return now }); err == nil {
		t.Fatal("successful DNS with no IPv4 silently used a stale address")
	}
}

func TestServerAddressCacheIsBoundedAndConcurrent(t *testing.T) {
	var cache serverAddressCache
	now := time.Unix(100, 0)
	for i := 0; i < rememberedServerAddressLimit+1; i++ {
		cache.remember(engine.VPNConfig{Server: fmt.Sprintf("gateway-%d.example", i)}, &engine.VPNInfo{ServerAddr: "203.0.113.8"}, now.Add(time.Duration(i)*time.Second))
	}
	if len(cache.entries) != rememberedServerAddressLimit {
		t.Fatalf("cache size = %d", len(cache.entries))
	}
	if _, ok := cache.lookup("gateway-0.example", now); ok {
		t.Fatal("oldest entry was not evicted")
	}
	var group sync.WaitGroup
	for i := 0; i < 32; i++ {
		group.Add(1)
		go func() {
			defer group.Done()
			cache.remember(engine.VPNConfig{Server: "gateway.example"}, &engine.VPNInfo{ServerAddr: "203.0.113.8"}, now)
			cache.lookup("gateway.example", now)
		}()
	}
	group.Wait()
}
