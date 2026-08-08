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

func TestPrepareTailscaleDNSUnavailableWithoutMobileDataPlane(t *testing.T) {
	engine := New(nil)
	_, err := engine.PrepareTailscaleDNS("private-endpoint-name", "private-dns-server")
	if err == nil || !strings.Contains(err.Error(), "unavailable") {
		t.Fatalf("expected unavailable error, got %v", err)
	}
	if strings.Contains(err.Error(), "private-endpoint-name") || strings.Contains(err.Error(), "private-dns-server") {
		t.Fatalf("error leaked runtime tags: %v", err)
	}
}

func TestPreparedSwitchTailscaleUnavailableWithoutMobileDataPlane(t *testing.T) {
	engine := New(nil)
	privateEndpoint := "private-candidate-endpoint"
	privateDNS := "private-candidate-dns"
	errors := []error{}
	_, err := engine.PreparedSwitchTailscaleStatus(privateEndpoint)
	errors = append(errors, err)
	_, err = engine.PreparePreparedSwitchTailscaleDNS(
		privateEndpoint,
		privateDNS,
	)
	errors = append(errors, err)
	_, err = engine.ProbePreparedSwitchTailscalePeer(
		privateEndpoint,
		"100.64.0.1",
		1_000,
	)
	errors = append(errors, err)
	for _, candidateErr := range errors {
		if candidateErr == nil ||
			!strings.Contains(candidateErr.Error(), "unavailable") {
			t.Fatalf("expected unavailable error, got %v", candidateErr)
		}
		if strings.Contains(candidateErr.Error(), privateEndpoint) ||
			strings.Contains(candidateErr.Error(), privateDNS) {
			t.Fatalf("error leaked candidate runtime tag: %v", candidateErr)
		}
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

func TestTailscalePeerProbeUnavailableWithoutMobileDataPlane(t *testing.T) {
	engine := New(nil)
	_, err := engine.ProbeTailscalePeer("private-endpoint-name", "100.64.0.1", 1_000)
	if err == nil || !strings.Contains(err.Error(), "unavailable") {
		t.Fatalf("expected unavailable error, got %v", err)
	}
	if strings.Contains(err.Error(), "private-endpoint-name") {
		t.Fatalf("error leaked endpoint tag: %v", err)
	}
}

func TestTailscaleDERPHomeReselectionUnavailableWithoutMobileDataPlane(t *testing.T) {
	engine := New(nil)
	_, err := engine.ReselectTailscaleHomeDERP(
		"private-endpoint-name",
		5_000,
	)
	if err == nil || !strings.Contains(err.Error(), "unavailable") {
		t.Fatalf("expected unavailable error, got %v", err)
	}
	if strings.Contains(err.Error(), "private-endpoint-name") {
		t.Fatalf("error leaked endpoint tag: %v", err)
	}
}
