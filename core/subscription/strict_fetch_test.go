package subscription

import (
	"context"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"testing"
)

func TestStrictRedirectRejectsUnsafeTarget(t *testing.T) {
	for _, target := range []string{
		"http://127.0.0.1/private",
		"https://169.254.169.254/metadata",
		"https://[::1]/private",
	} {
		t.Run(target, func(t *testing.T) {
			req, err := http.NewRequest(http.MethodGet, target, nil)
			if err != nil {
				t.Fatal(err)
			}
			if err := strictRedirectPolicy(req, []*http.Request{{}}); err == nil {
				t.Fatalf("expected redirect to %s to be rejected", target)
			}
		})
	}
}

func TestStrictRedirectLimit(t *testing.T) {
	req, err := http.NewRequest(http.MethodGet, "https://example.com/list", nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := strictRedirectPolicy(req, make([]*http.Request, 10)); err == nil || !strings.Contains(err.Error(), "redirect") {
		t.Fatalf("expected redirect-limit error, got %v", err)
	}
}

func TestStrictDialRejectsUnsafeDNSResult(t *testing.T) {
	for _, unsafeAddress := range []string{"127.0.0.1", "100.64.0.1", "fd00::1"} {
		t.Run(unsafeAddress, func(t *testing.T) {
			dialCalls := 0
			dialContext := newStrictDialContext(
				func(context.Context, string, string) ([]netip.Addr, error) {
					return []netip.Addr{netip.MustParseAddr(unsafeAddress)}, nil
				},
				func(context.Context, string, string) (net.Conn, error) {
					dialCalls++
					return nil, nil
				},
			)

			if _, err := dialContext(context.Background(), "tcp", "public.example:443"); err == nil {
				t.Fatal("expected private DNS result to be rejected")
			}
			if dialCalls != 0 {
				t.Fatalf("dial called %d times for rejected address", dialCalls)
			}
		})
	}
}

func TestStrictDialPinsValidatedAddress(t *testing.T) {
	var dialedAddress string
	dialContext := newStrictDialContext(
		func(context.Context, string, string) ([]netip.Addr, error) {
			return []netip.Addr{netip.MustParseAddr("203.0.113.10")}, nil
		},
		func(_ context.Context, _ string, address string) (net.Conn, error) {
			dialedAddress = address
			client, server := net.Pipe()
			_ = server.Close()
			return client, nil
		},
	)

	connection, err := dialContext(context.Background(), "tcp", "public.example:443")
	if err != nil {
		t.Fatal(err)
	}
	_ = connection.Close()
	if dialedAddress != "203.0.113.10:443" {
		t.Fatalf("dialed %q, want validated numeric address", dialedAddress)
	}
}
