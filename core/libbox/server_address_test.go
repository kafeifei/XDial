//go:build !windows

package libbox

import (
	"context"
	"errors"
	"net"
	"testing"
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
