//go:build mobile_no_tailscale

package engine

import (
	"errors"
	"testing"
)

func TestMobileBuildRejectsTailscaleSession(t *testing.T) {
	session, err := NewTailscaleSession("", nil, nil, nil)
	if err == nil {
		t.Fatal("expected mobile build to reject Tailscale session")
	}
	if !errors.Is(err, errTailscaleUnavailable) {
		t.Fatalf("unexpected error: %v", err)
	}
	if session != nil {
		t.Fatal("rejected Tailscale session must be nil")
	}
}
