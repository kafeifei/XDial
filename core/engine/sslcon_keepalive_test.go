//go:build !windows

package engine

import (
	"encoding/json"
	"net/http"
	"testing"

	"sslcon/base"
	"sslcon/session"
)

func TestAnyConnectRuntimeSupportsForcedDPD(t *testing.T) {
	configurator, ok := any(base.Cfg).(anyConnectDPDConfigurator)
	if !ok {
		t.Skip("pristine sslcon source does not include the staged XDial patch")
	}
	configurator.SetXDialForceDPD(forcedAnyConnectDPDSeconds)
	if reader, ok := any(base.Cfg).(interface{ XDialForceDPD() int }); !ok ||
		reader.XDialForceDPD() != forcedAnyConnectDPDSeconds {
		t.Fatal("patched sslcon did not retain the forced DPD policy")
	}
}

func TestAnyConnectSessionDiagnosticsAreStructuredAndRedacted(t *testing.T) {
	configurator, ok := any(base.Cfg).(anyConnectDPDConfigurator)
	if !ok {
		t.Skip("pristine sslcon source does not include the staged XDial patch")
	}
	configurator.SetXDialForceDPD(forcedAnyConnectDPDSeconds)
	cSess := (&session.Session{}).NewConnSession(&http.Header{})
	raw := AnyConnectSessionDiagnostics(cSess)
	var snapshot map[string]any
	if err := json.Unmarshal([]byte(raw), &snapshot); err != nil {
		t.Fatalf("decode diagnostics: %v", err)
	}
	if snapshot["force_dpd_seconds"] != float64(forcedAnyConnectDPDSeconds) {
		t.Fatalf("unexpected diagnostics: %s", raw)
	}
}
