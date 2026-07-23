//go:build !windows

package libbox

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/kafeifei/xdial/core/config"
)

func TestGenerateNEConfigIncludesTailscaleEndpointWithMobileDNSDispatcher(t *testing.T) {
	basePath := t.TempDir()
	profile := config.Profile{
		Lines: []config.Line{
			{ID: "direct", Type: config.LineTypeDirect, Enabled: true},
			{
				ID: "tailnet", Type: config.LineTypeTailscale, Enabled: true,
				TailscaleHostname: "xdial-mobile", TailscaleAcceptRoutes: true,
			},
		},
		Modes:        []config.Mode{{ID: "mode", DefaultLineID: "direct"}},
		ActiveModeID: "mode",
	}
	profileJSON, err := json.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}

	generated, err := GenerateNEConfig(string(profileJSON), "", basePath)
	if err != nil {
		t.Fatal(err)
	}
	var document map[string]interface{}
	if err := json.Unmarshal([]byte(generated), &document); err != nil {
		t.Fatal(err)
	}
	endpoints := document["endpoints"].([]interface{})
	if len(endpoints) != 1 {
		t.Fatalf("expected one Tailscale endpoint, got %v", endpoints)
	}
	endpoint := endpoints[0].(map[string]interface{})
	stateDirectory := endpoint["state_directory"].(string)
	if filepath.Dir(stateDirectory) != filepath.Join(basePath, "tailscale") {
		t.Fatalf("Tailscale state escaped writable base path: %q", stateDirectory)
	}
	dns := document["dns"].(map[string]interface{})
	servers := dns["servers"].([]interface{})
	if len(servers) != 3 ||
		servers[0].(map[string]interface{})["tag"] != "xdial-public-dns" ||
		servers[1].(map[string]interface{})["type"] != "tailscale" ||
		servers[1].(map[string]interface{})["accept_default_resolvers"] != false ||
		servers[2].(map[string]interface{})["type"] != "xdial-mobile" {
		t.Fatalf("NetworkExtension mobile DNS chain is incomplete: %v", servers)
	}
	if dns["final"] != "xdial-mobile-dns" {
		t.Fatalf("NetworkExtension DNS final must use dispatcher: %v", dns)
	}
	if _, exists := dns["rules"]; exists {
		t.Fatalf("NetworkExtension must not route all DNS directly through Tailscale: %v", dns)
	}
	route := document["route"].(map[string]interface{})
	if route["default_domain_resolver"] != "xdial-public-dns" {
		t.Fatalf("control-plane DNS must stay on public direct fallback: %v", route)
	}
}

func TestGenerateNEConfigRejectsOversizedOutput(t *testing.T) {
	domains := make([]string, 30_000)
	for index := range domains {
		domains[index] = strings.Repeat("a", 80) + "." + strings.Repeat("b", 40) + ".example"
	}
	profile := config.Profile{
		Lines: []config.Line{
			{ID: "direct", Name: "Direct", Type: config.LineTypeDirect, Enabled: true},
			{ID: "ac", Name: "AnyConnect", Type: config.LineTypeVPN, Enabled: true},
		},
		RuleSets: []config.RuleSet{
			{ID: "large", Name: "Large", Type: config.RuleSetTypeManual, Enabled: true, Domains: domains},
		},
		Modes: []config.Mode{
			{ID: "mode", Name: "Mode", Bindings: []config.RuleBinding{{RuleSetID: "large", LineID: "ac"}}, DefaultLineID: "direct"},
		},
		ActiveModeID: "mode",
	}
	data, err := json.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}

	_, err = GenerateNEConfig(string(data), "203.0.113.1", t.TempDir())
	if err == nil || !strings.Contains(err.Error(), "exceeds") {
		t.Fatalf("expected generated config size error, got %v", err)
	}
}

func TestMaterializeNERuleSetsUsesStrictLocalFile(t *testing.T) {
	profile := &config.Profile{
		Lines: []config.Line{{ID: "direct", Type: config.LineTypeDirect, Enabled: true}},
		RuleSets: []config.RuleSet{{
			ID: "remote", Type: config.RuleSetTypeURL, Enabled: true,
			URL: "https://rules.example.com/path-token/list.json?token=must-not-remain", Format: "json",
		}},
		Modes: []config.Mode{{
			ID: "mode", Bindings: []config.RuleBinding{{RuleSetID: "remote", LineID: "direct"}},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "mode",
	}
	want := []byte(`{"version":1,"rules":[]}`)
	var fetchedURL string
	err := materializeNERuleSets(profile, t.TempDir(), func(rawURL string, limit int64) ([]byte, error) {
		fetchedURL = rawURL
		if limit != maxNERuleSetBytes {
			t.Fatalf("unexpected fetch budget: %d", limit)
		}
		return want, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(fetchedURL, "must-not-remain") {
		t.Fatal("fetcher did not receive original address")
	}
	localURL := profile.RuleSets[0].URL
	if !strings.HasPrefix(localURL, "file://") || strings.Contains(localURL, "must-not-remain") {
		t.Fatalf("rule was not replaced by sanitized local path: %q", localURL)
	}
	got, err := os.ReadFile(strings.TrimPrefix(localURL, "file://"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("local rule content mismatch: %q", got)
	}

	generated, err := config.GenerateSingBoxFor(profile, 0, "", config.PlatformNE, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(generated), "rules.example.com") || strings.Contains(string(generated), "must-not-remain") {
		t.Fatal("generated extension config retained remote address")
	}
	if !strings.Contains(string(generated), `"type": "local"`) {
		t.Fatal("generated extension config did not use local rule set")
	}
}

func TestMaterializeNERuleSetsConvertsPlainText(t *testing.T) {
	profile := &config.Profile{
		Lines: []config.Line{{ID: "direct", Type: config.LineTypeDirect, Enabled: true}},
		RuleSets: []config.RuleSet{{
			ID: "plain", Type: config.RuleSetTypeURL, Enabled: true,
			URL: "https://rules.example.com/list.txt", Format: "text",
		}},
		Modes: []config.Mode{{
			ID: "mode", Bindings: []config.RuleBinding{{RuleSetID: "plain", LineID: "direct"}},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "mode",
	}
	input := []byte("# comment\nexample.com\n||blocked.example^\nDOMAIN,exact.example\nIP-CIDR,192.0.2.9/24\n0.0.0.0 hosts.example\n")
	err := materializeNERuleSets(profile, t.TempDir(), func(string, int64) ([]byte, error) {
		return input, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if profile.RuleSets[0].Format != "source" {
		t.Fatalf("text rule was not converted to source: %q", profile.RuleSets[0].Format)
	}
	stored, err := os.ReadFile(strings.TrimPrefix(profile.RuleSets[0].URL, "file://"))
	if err != nil {
		t.Fatal(err)
	}
	var document struct {
		Version int `json:"version"`
		Rules   []struct {
			Domain       []string `json:"domain"`
			DomainSuffix []string `json:"domain_suffix"`
			IPCIDR       []string `json:"ip_cidr"`
		} `json:"rules"`
	}
	if err := json.Unmarshal(stored, &document); err != nil {
		t.Fatal(err)
	}
	if document.Version != 3 || len(document.Rules) != 1 {
		t.Fatalf("unexpected source rule set: %s", stored)
	}
	wantExact := []string{"exact.example", "hosts.example"}
	wantSuffix := []string{"example.com", "blocked.example"}
	wantCIDR := []string{"192.0.2.0/24"}
	if !equalStrings(document.Rules[0].Domain, wantExact) ||
		!equalStrings(document.Rules[0].DomainSuffix, wantSuffix) ||
		!equalStrings(document.Rules[0].IPCIDR, wantCIDR) {
		t.Fatalf("unexpected converted rules: %+v", document.Rules[0])
	}
}

func TestConvertTextRuleSetRejectsUnsupportedSemantics(t *testing.T) {
	for _, input := range []string{
		"@@||allowed.example^",
		"PROCESS-NAME,secret-app",
		"not a domain",
	} {
		if _, err := convertTextRuleSet([]byte(input)); err == nil {
			t.Fatalf("expected %q to be rejected", input)
		}
	}
}

func equalStrings(got, want []string) bool {
	if len(got) != len(want) {
		return false
	}
	for index := range got {
		if got[index] != want[index] {
			return false
		}
	}
	return true
}

func TestMaterializeGeneratedNERuleSetsRemovesRemoteURL(t *testing.T) {
	basePath := t.TempDir()
	ruleDir, err := prepareNERuleSetDirectory(basePath)
	if err != nil {
		t.Fatal(err)
	}
	input := []byte(`{
        "route": {
          "rule_set": [{
            "type": "remote",
            "tag": "sub-geoip-example-cn",
            "format": "binary",
            "url": "https://rules.example.com/geoip-cn.srs?token=secret",
            "download_detour": "direct"
          }]
        }
      }`)
	want := []byte("binary-rule-set")
	var fetched string
	output, err := materializeGeneratedNERuleSets(input, ruleDir, func(rawURL string, limit int64) ([]byte, error) {
		fetched = rawURL
		if limit != maxNERuleSetBytes {
			t.Fatalf("unexpected fetch budget: %d", limit)
		}
		return want, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(fetched, "token=secret") {
		t.Fatal("strict fetcher did not receive original generated URL")
	}
	text := string(output)
	if strings.Contains(text, "rules.example.com") || strings.Contains(text, "token=secret") || strings.Contains(text, "download_detour") {
		t.Fatalf("extension config retained remote metadata: %s", text)
	}
	if !strings.Contains(text, `"type": "local"`) {
		t.Fatalf("generated rule set was not made local: %s", text)
	}

	var document map[string]interface{}
	if err := json.Unmarshal(output, &document); err != nil {
		t.Fatal(err)
	}
	route := document["route"].(map[string]interface{})
	set := route["rule_set"].([]interface{})[0].(map[string]interface{})
	localPath := set["path"].(string)
	stored, err := os.ReadFile(localPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(stored, want) {
		t.Fatalf("stored generated rule set mismatch: %q", stored)
	}
}

func TestStartVPNConfigCarriesAllowInsecure(t *testing.T) {
	cfg := startVPNConfig("example.com", "203.0.113.1", "user", "secret", true)
	if !cfg.AllowInsecure {
		t.Fatal("selected line certificate policy was not carried into engine config")
	}
	if cfg.Server != "example.com" || cfg.DialAddress != "203.0.113.1" {
		t.Fatalf("unexpected connection identity: %+v", cfg)
	}

	secureDefault := startVPNConfig("example.com", "", "user", "secret", false)
	if secureDefault.AllowInsecure {
		t.Fatal("legacy entry points must keep certificate verification enabled")
	}
}
