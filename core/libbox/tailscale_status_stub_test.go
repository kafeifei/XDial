//go:build !windows && (!with_gvisor || mobile_no_tailscale)

package libbox

import (
	"strings"
	"testing"
)

func TestTailscaleStatusUnavailableWithoutMobileDataPlane(t *testing.T) {
	engine := New(nil)
	_, err := engine.TailscaleStatus("private-endpoint-name")
	if err == nil || !strings.Contains(err.Error(), "unavailable") {
		t.Fatalf("expected unavailable error, got %v", err)
	}
	if strings.Contains(err.Error(), "private-endpoint-name") {
		t.Fatalf("error leaked endpoint tag: %v", err)
	}
}

func TestTailscaleLogoutUnavailableWithoutMobileDataPlane(t *testing.T) {
	engine := New(nil)
	err := engine.TailscaleLogout("private-endpoint-name")
	if err == nil || !strings.Contains(err.Error(), "unavailable") {
		t.Fatalf("expected unavailable error, got %v", err)
	}
	if strings.Contains(err.Error(), "private-endpoint-name") {
		t.Fatalf("error leaked endpoint tag: %v", err)
	}
}
