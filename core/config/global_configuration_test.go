package config

import (
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
)

func TestResourceOnlyDocumentRoundTripDoesNotInventRouting(t *testing.T) {
	source := &Profile{ID: "source", Lines: []Line{{ID: "direct", Name: "Direct", Type: LineTypeDirect, Enabled: true}}, RuleSets: []RuleSet{{ID: "rule", Name: "Domains", Type: RuleSetTypeManual, Enabled: true, Domains: []string{"example.test"}}}}
	encoded, err := ExportProfileDocument(source)
	if err != nil {
		t.Fatal(err)
	}
	var metadata ProfileDocument
	if err := json.Unmarshal(encoded, &metadata); err != nil {
		t.Fatal(err)
	}
	if metadata.XDial.SchemaVersion != 2 || !metadata.XDial.ResourcesOnly {
		t.Fatalf("missing resources-only version: %s", encoded)
	}
	restored, err := ImportProfileDocument(encoded, "new-source")
	if err != nil {
		t.Fatal(err)
	}
	if len(restored.Scenarios) != 0 || restored.ActiveScenarioID != "" || len(restored.RuleSets) != 1 {
		t.Fatalf("changed source scope: %+v", restored)
	}
	clone := CloneProfile(restored, "copy")
	if len(clone.Scenarios) != 0 {
		t.Fatal("copy introduced routing")
	}
	if err := ValidateDocumentProfile(clone); err != nil {
		t.Fatal(err)
	}
	var invalid ProfileDocument = metadata
	invalid.Route.Final = "direct"
	encoded, _ = json.Marshal(invalid)
	if _, err := ImportProfileDocument(encoded, "invalid"); err == nil {
		t.Fatal("resource document hid routing policy")
	}
}

func TestGlobalRuntimeKeepsSourceTailscaleIdentity(t *testing.T) {
	p := &Profile{ID: "global-configuration", Lines: []Line{
		{ID: "a", Name: "A", Type: LineTypeTailscale, Enabled: true, IdentityProfileID: "source-a", IdentityHostname: "xdial-source-a"},
		{ID: "b", Name: "B", Type: LineTypeTailscale, Enabled: true, IdentityProfileID: "source-b", IdentityHostname: "xdial-source-b"},
	}, Scenarios: []Scenario{{ID: "work", DefaultLineID: "a"}, {ID: "home", DefaultLineID: "b"}}, ActiveScenarioID: "work"}
	base := t.TempDir()
	work, err := ProfileDataPath(p, base)
	if err != nil {
		t.Fatal(err)
	}
	if work != filepath.Join(base, "profiles", "source-a") {
		t.Fatalf("identity moved: %s", work)
	}
	endpoint, err := buildTailscaleEndpoint(&p.Lines[0], TailscaleIdentity{Hostname: "unused"}, work, "")
	if err != nil {
		t.Fatal(err)
	}
	if endpoint["hostname"] != "xdial-source-a" || endpoint["state_directory"] != filepath.Join(work, "tailscale") {
		t.Fatalf("source identity lost: %+v", endpoint)
	}
	p.ActiveScenarioID = "home"
	home, err := ProfileDataPath(p, base)
	if err != nil {
		t.Fatal(err)
	}
	if home != filepath.Join(base, "profiles", "source-b") {
		t.Fatalf("source identities merged: %s", home)
	}
	clone := CloneProfile(p, "copied")
	if clone.Lines[0].IdentityProfileID != "" || clone.Lines[0].IdentityHostname != "" {
		t.Fatal("clone retained source identity")
	}
	p.Lines[1].IdentityProfileID = "../escape"
	if _, err := ProfileDataPath(p, base); err == nil {
		t.Fatal("unsafe source identity accepted")
	}
}

func TestExportNeverCarriesSourceRuntimeIdentity(t *testing.T) {
	p := &Profile{Lines: []Line{{ID: "tailscale", Name: "Tailscale", Type: LineTypeTailscale, Enabled: true, IdentityProfileID: "private-origin", IdentityHostname: "private-host"}}}
	data, err := ExportProfileDocument(p)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "private-origin") || strings.Contains(string(data), "private-host") {
		t.Fatal("runtime identity exported")
	}
}

func TestGlobalTailscaleFingerprintIncludesOnlyActiveSourceIdentity(t *testing.T) {
	p := &Profile{ID: "global-configuration", Lines: []Line{
		{ID: "a", Type: LineTypeTailscale, Enabled: true, IdentityProfileID: "source-a", IdentityHostname: "xdial-a"},
		{ID: "b", Type: LineTypeTailscale, Enabled: true, IdentityProfileID: "source-b", IdentityHostname: "xdial-b"},
	}, Scenarios: []Scenario{{ID: "work", DefaultLineID: "a"}}, ActiveScenarioID: "work"}
	before := runtimeFingerprintForTest(t, p)
	p.Lines[1].IdentityHostname = "unreferenced-edit"
	if before != runtimeFingerprintForTest(t, p) {
		t.Fatal("unused source identity changed active fingerprint")
	}
	p.Lines[0].IdentityHostname = "active-edit"
	if before == runtimeFingerprintForTest(t, p) {
		t.Fatal("active hostname missing from fingerprint")
	}
	p.Lines[0].IdentityHostname = "xdial-a"
	p.Lines[0].IdentityProfileID = "other-source"
	if before == runtimeFingerprintForTest(t, p) {
		t.Fatal("active identity path missing from fingerprint")
	}
}
