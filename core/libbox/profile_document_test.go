//go:build !windows

package libbox

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/kafeifei/xdial/core/config"
)

func TestProfileImportExportRedactedDraft(t *testing.T) {
	input := `{"outbounds":[{"type":"trojan","tag":"node","server":"192.0.2.1","server_port":443,"password":"example-private-password","tls":{"enabled":true},"transport":{"type":"ws","path":"/proxy","headers":{"Authorization":"example-private-header"}}}],"route":{"final":"node"}}`
	imported, err := ImportProfile(input, "auto", "first", false)
	if err != nil {
		t.Fatal(err)
	}
	exported, err := ExportProfile(imported)
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{"example-private-password", "example-private-header"} {
		if strings.Contains(exported, secret) {
			t.Fatal("export leaked a credential")
		}
	}
	draft, err := ImportProfile(exported, "auto", "second", false)
	if err != nil {
		t.Fatalf("redacted document cannot be edited after import: %v", err)
	}
	profile, err := config.ParseProfile([]byte(draft))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := config.BuildConnectionPlan(profile); err == nil {
		t.Fatal("incomplete credentials became a connectable configuration")
	}
}

func TestProfileImportNativeUnknownOptionsAndExplicitLinesOnly(t *testing.T) {
	input := `{"outbounds":[{"type":"trojan","tag":"node","server":"192.0.2.1","server_port":443,"password":"test-only","tls":{"enabled":true}}],"dns":{"final":"external"},"route":{"final":"node"}}`
	if _, err := ImportProfile(input, "auto", "first", false); err == nil {
		t.Fatal("custom DNS silently lost")
	}
	text, err := ImportProfile(input, "auto", "first", true)
	if err != nil {
		t.Fatal(err)
	}
	var profile config.Profile
	if err := json.Unmarshal([]byte(text), &profile); err != nil {
		t.Fatal(err)
	}
	if len(profile.Subscriptions) != 0 || len(profile.Scenarios) != 1 || !profile.FindLine(profile.Scenarios[0].DefaultLineID).IsGroup() {
		t.Fatal("lines-only import did not create a self-contained default Scenario")
	}
	invalid := strings.Replace(strings.Replace(input, `,"dns":{"final":"external"}`, "", 1), `"enabled":true`, `"enabled":true,"unknown_tls_option":true`, 1)
	if _, err := ImportProfile(invalid, "auto", "first", false); err == nil {
		t.Fatal("unsupported TLS option silently lost")
	}
}

func TestProfileImportClashPromotesSharedResources(t *testing.T) {
	input := `proxies:
  - {name: Edge, type: trojan, server: 192.0.2.1, port: 443, password: test-only}
proxy-groups:
  - {name: Proxy, type: select, proxies: [Edge, DIRECT]}
rules:
  - DOMAIN-SUFFIX,example.com,Proxy
  - MATCH,DIRECT
`
	text, err := ImportProfile(input, "auto", "airport", false)
	if err != nil {
		t.Fatal(err)
	}
	profile, err := config.ParseProfile([]byte(text))
	if err != nil {
		t.Fatal(err)
	}
	if len(profile.Subscriptions) != 0 || len(profile.RuleSets) != 1 || len(profile.Scenarios[0].Bindings) != 1 {
		t.Fatal("Clash resources were not promoted into the Profile")
	}
	if _, err := config.BuildConnectionPlan(profile); err != nil {
		t.Fatal(err)
	}
}

func TestGroupedProfileCompactionAndRemoteBootstrap(t *testing.T) {
	profile := config.Profile{
		ID: "grouped", Lines: []config.Line{{ID: "direct", Name: "Direct", Type: config.LineTypeDirect, Enabled: true}},
		RuleSets: []config.RuleSet{
			{ID: "domain", Name: "Domain", Type: config.RuleSetTypeNative, Enabled: true, NativeRule: json.RawMessage(`{"domain":["example.test"]}`)},
			{ID: "remote", Name: "Remote", Type: config.RuleSetTypeURL, Enabled: true, URL: "https://rules.example/list.srs", Format: "srs", NoResolve: true},
			{ID: "app", Name: "Application", Type: config.RuleSetTypeApplication, Enabled: true, Processes: []string{"Example*"}},
		},
		Scenarios: []config.Scenario{{ID: "scene", Name: "Default", DefaultLineID: "direct", Bindings: []config.RuleBinding{{RuleSetID: "domain", LineID: "direct"}, {RuleSetID: "remote", LineID: "direct"}, {RuleSetID: "app", LineID: "direct"}}}}, ActiveScenarioID: "scene",
	}
	raw, _ := json.Marshal(profile)
	compacted, err := CompactProfileRuleSets(string(raw))
	if err != nil {
		t.Fatal(err)
	}
	grouped, err := config.ParseProfile([]byte(compacted))
	if err != nil {
		t.Fatal(err)
	}
	if len(grouped.RuleSets) != 1 || len(grouped.RuleSets[0].Conditions) != 3 {
		t.Fatal("compaction lost conditions")
	}
	again, err := CompactProfileRuleSets(compacted)
	if err != nil || again != compacted {
		t.Fatal("compaction is not idempotent")
	}
	bootstrapRaw, err := GenerateTransparentProxyRuleSetBootstrap(compacted, t.TempDir(), 29877, "user", "password", "utun-underlay", `["192.0.2.53"]`)
	if err != nil {
		t.Fatal(err)
	}
	var bootstrap transparentProxyRuleSetBootstrap
	if err := json.Unmarshal([]byte(bootstrapRaw), &bootstrap); err != nil {
		t.Fatal(err)
	}
	if len(bootstrap.PreflightSessions) != 1 || len(bootstrap.PreflightSessions[0].Refreshes) != 1 {
		t.Fatal("grouped remote resource skipped acquisition")
	}
	runtime, err := config.ParseRuntimeProfile([]byte(compacted))
	if err != nil {
		t.Fatal(err)
	}
	if err := materializeNERuleSets(runtime, t.TempDir(), func(string, int64) ([]byte, error) { return nil, fmt.Errorf("unavailable") }); err == nil {
		t.Fatal("remote acquisition failure silently ignored")
	}
	if grouped.RuleSets[0].Conditions[1].URL != "https://rules.example/list.srs" {
		t.Fatal("resource preparation mutated source group")
	}
	exported, err := ExportProfile(compacted)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(exported, "https://rules.example/list.srs") {
		t.Fatal("nested source URL leaked in redacted export")
	}
	if _, err := ImportProfile(exported, "auto", "copy", false); err != nil {
		t.Fatal(err)
	}
}

func TestSubscriptionImportNormalizesAnyTLSTFOAcrossFormats(t *testing.T) {
	cases := map[string]string{
		"surge": "[Proxy]\nDirect = direct\nEdge = anytls, edge.example, 443, password=fixture, skip-cert-verify=true, tfo=true, tls=true\n[Proxy Group]\nProxy = select, Edge\n[Rule]\nDOMAIN-SUFFIX,example.org,Proxy\nFINAL,Proxy",
		"clash": "proxies:\n  - {name: Edge, type: anytls, server: edge.example, port: 443, password: fixture, tfo: true}\nproxy-groups:\n  - {name: Proxy, type: select, proxies: [Edge]}\nrules:\n  - DOMAIN-SUFFIX,example.org,Proxy\n  - MATCH,Proxy",
		"uri":   "anytls://fixture@edge.example:443?tfo=true#Edge",
	}
	for name, content := range cases {
		t.Run(name, func(t *testing.T) {
			encoded, err := ImportProfile(content, "auto", name, false)
			if err != nil {
				t.Fatal(err)
			}
			profile, err := config.ParseProfile([]byte(encoded))
			if err != nil {
				t.Fatal(err)
			}
			if len(profile.ImportAdjustments) != 1 || profile.ImportAdjustments[0].Code != "anytls-tfo-disabled" || profile.ImportAdjustments[0].Count != 1 {
				t.Fatal("adjustment not exposed to the import preview")
			}
			if name != "uri" && len(profile.RuleSets) != 1 {
				t.Fatal("adaptation dropped routing rules")
			}
			if err := ValidateProfileDocument(encoded); err != nil {
				t.Fatal(err)
			}
		})
	}
}
