package engine

import "testing"

func TestParseTailscaleAuthURL(t *testing.T) {
	line := "INFO[0001] endpoint/tailscale[tail]: Waiting for authentication: https://login.tailscale.com/a/abc123\x1b[0m"
	if got := parseTailscaleAuthURL(line); got != "https://login.tailscale.com/a/abc123" {
		t.Fatalf("unexpected auth URL: %q", got)
	}
}

func TestParseTailscaleAuthURLRejectsNonHTTP(t *testing.T) {
	line := "Waiting for authentication: file:///tmp/not-safe"
	if got := parseTailscaleAuthURL(line); got != "" {
		t.Fatalf("expected unsafe URL to be rejected, got %q", got)
	}
}
