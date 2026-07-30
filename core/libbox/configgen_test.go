//go:build !windows

package libbox

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/kafeifei/xdial/core/config"
)

func TestGenerateNEConfigIncludesTailscaleEndpointWithMobileDNSDispatcher(t *testing.T) {
	basePath := t.TempDir()
	profile := config.Profile{
		Lines: []config.Line{
			{ID: "direct", Type: config.LineTypeDirect, Enabled: true},
			{ID: "tailnet", Type: config.LineTypeTailscale, Enabled: true},
		},
		RuleSets: []config.RuleSet{
			{ID: "ts-hosts", Type: config.RuleSetTypeManual, Enabled: true, Domains: []string{"ts.example"}},
		},
		// tailscale DNS 分支只对被 active Mode 引用的线路生成（INV1c 声明≠生效），
		// 本用例验证的是"用上 Tailscale 时 dispatcher 链完整"，故显式绑定。
		Modes: []config.Mode{{
			ID:            "mode",
			Bindings:      []config.RuleBinding{{RuleSetID: "ts-hosts", LineID: "tailnet"}},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "mode",
		Tailscale:    config.TailscaleIdentity{Hostname: "xdial-mobile"},
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
	if stateDirectory != filepath.Join(basePath, "tailscale") {
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

func TestGenerateTailscaleSetupConfigIsIsolated(t *testing.T) {
	basePath := t.TempDir()
	profile := config.Profile{
		Lines: []config.Line{
			{ID: "direct", Type: config.LineTypeDirect, Enabled: true},
			{ID: "vpn", Type: config.LineTypeVPN, Enabled: true, VPNServer: "private-vpn.example", VPNPassword: "must-not-leak"},
			{ID: "tailnet", Type: config.LineTypeTailscale, Enabled: false, TailscaleExitNode: "must-not-activate"},
			{ID: "other-tailnet", Type: config.LineTypeTailscale, Enabled: true},
		},
		Modes:        []config.Mode{{ID: "mode", DefaultLineID: "vpn"}},
		ActiveModeID: "mode",
		Tailscale:    config.TailscaleIdentity{Hostname: "xdial-mobile"},
	}
	profileJSON, err := json.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}

	generated, err := GenerateTailscaleSetupConfig(string(profileJSON), "tailnet", basePath)
	if err != nil {
		t.Fatal(err)
	}
	var document map[string]interface{}
	if err := json.Unmarshal([]byte(generated), &document); err != nil {
		t.Fatal(err)
	}
	inbounds, ok := document["inbounds"].([]interface{})
	if !ok || len(inbounds) != 0 {
		t.Fatalf("setup config must not contain an inbound: %v", document["inbounds"])
	}
	outbounds, ok := document["outbounds"].([]interface{})
	if !ok || len(outbounds) != 1 {
		t.Fatalf("setup config must contain only Direct: %v", document["outbounds"])
	}
	direct := outbounds[0].(map[string]interface{})
	if direct["type"] != "direct" || direct["tag"] != "direct" {
		t.Fatalf("unexpected setup outbound: %v", direct)
	}
	dns := document["dns"].(map[string]interface{})
	dnsServers := dns["servers"].([]interface{})
	if len(dnsServers) != 1 ||
		dnsServers[0].(map[string]interface{})["type"] != "local" ||
		dnsServers[0].(map[string]interface{})["tag"] != "xdial-setup-system-dns" {
		t.Fatalf("setup must read the existing Underlay resolver without replacing it: %v", dns)
	}
	endpoints, ok := document["endpoints"].([]interface{})
	if !ok || len(endpoints) != 1 {
		t.Fatalf("setup config must contain one endpoint: %v", document["endpoints"])
	}
	endpoint := endpoints[0].(map[string]interface{})
	if endpoint["type"] != "tailscale" ||
		endpoint["tag"] != "tailscale-tailnet" ||
		endpoint["hostname"] != "xdial-mobile" ||
		endpoint["state_directory"] != config.TailscaleStateDirectory(basePath) {
		t.Fatalf("unexpected setup endpoint: %v", endpoint)
	}
	if endpoint["system_interface"] != false || endpoint["accept_routes"] != false {
		t.Fatalf("setup endpoint must stay inside the setup runtime: %v", endpoint)
	}
	for _, forbidden := range []string{"advertise_routes", "advertise_exit_node", "auth_key"} {
		if _, exists := endpoint[forbidden]; exists {
			t.Fatalf("setup endpoint must not contain %s: %v", forbidden, endpoint)
		}
	}
	if _, exists := endpoint["ephemeral"]; exists {
		t.Fatalf("setup endpoint must be a persistent node: %v", endpoint)
	}
	if _, exists := endpoint["exit_node"]; exists {
		t.Fatalf("setup endpoint must not activate an exit node: %v", endpoint)
	}
	for _, forbidden := range []string{"private-vpn.example", "must-not-leak", "must-not-activate", "other-tailnet", `"type":"tun"`, `"type":"vpn"`} {
		if strings.Contains(generated, forbidden) {
			t.Fatalf("setup config leaked unrelated profile value %q: %s", forbidden, generated)
		}
	}
}

func TestGenerateTailscaleSetupConfigUsesOnlyTransientAuthKey(t *testing.T) {
	basePath := t.TempDir()
	profile := config.Profile{
		Lines: []config.Line{{
			ID: "tailnet", Type: config.LineTypeTailscale, Enabled: true,
			TailscaleAuthKey: "persisted-key-must-not-win",
		}},
		Tailscale: config.TailscaleIdentity{Hostname: "xdial-desktop"},
	}
	profileJSON, err := json.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}

	generated, err := GenerateTailscaleSetupConfigWithAuthKey(
		string(profileJSON),
		"tailnet",
		basePath,
		"  transient-auth-key  ",
	)
	if err != nil {
		t.Fatal(err)
	}
	var document map[string]interface{}
	if err := json.Unmarshal([]byte(generated), &document); err != nil {
		t.Fatal(err)
	}
	endpoint := document["endpoints"].([]interface{})[0].(map[string]interface{})
	if endpoint["auth_key"] != "transient-auth-key" {
		t.Fatalf("setup config did not use the explicit transient key: %v", endpoint)
	}
	if strings.Contains(generated, "persisted-key-must-not-win") {
		t.Fatalf("setup config leaked the persisted legacy key: %s", generated)
	}
}

func TestGenerateTailscaleSetupConfigRejectsInvalidSelection(t *testing.T) {
	basePath := t.TempDir()
	profile := config.Profile{
		Lines: []config.Line{
			{ID: "direct", Type: config.LineTypeDirect, Enabled: true},
			{ID: "tailnet", Type: config.LineTypeTailscale, Enabled: true},
		},
	}
	profileJSON, err := json.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name     string
		lineID   string
		basePath string
	}{
		{name: "missing ID", lineID: "", basePath: basePath},
		{name: "unknown line", lineID: "missing", basePath: basePath},
		{name: "non-Tailscale line", lineID: "direct", basePath: basePath},
		{name: "relative base path", lineID: "tailnet", basePath: "relative"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if _, err := GenerateTailscaleSetupConfig(string(profileJSON), test.lineID, test.basePath); err == nil {
				t.Fatal("expected validation error")
			}
		})
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

func TestMaterializeNERuleSetsReportsExactStructuredFailure(t *testing.T) {
	profile := &config.Profile{
		Lines: []config.Line{{
			ID: "direct", Type: config.LineTypeDirect, Enabled: true,
		}},
		RuleSets: []config.RuleSet{{
			ID: "cnip", Name: "CN IP", Type: config.RuleSetTypeURL,
			Enabled: true, URL: "https://rules.example/cnip.srs",
			Format: "binary",
		}},
		Modes: []config.Mode{{
			ID: "mode",
			Bindings: []config.RuleBinding{{
				RuleSetID: "cnip",
				LineID:    "direct",
			}},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "mode",
	}
	var events []connectionPreparationEvent
	err := materializeNERuleSetsWithEvents(
		profile,
		t.TempDir(),
		func(string, int64) ([]byte, error) {
			return nil, fmt.Errorf("offline")
		},
		func(event connectionPreparationEvent) {
			events = append(events, event)
		},
	)
	if err == nil {
		t.Fatal("expected preparation failure")
	}
	if len(events) != 2 ||
		events[0].TaskID != "rule-set:cnip" ||
		events[0].State != "running" ||
		events[1].TaskID != "rule-set:cnip" ||
		events[1].State != "failed" ||
		events[1].Code != "rule-set-unavailable" {
		t.Fatalf("events = %#v", events)
	}
	if strings.Contains(events[1].Message, "rules.example") {
		t.Fatalf("structured event leaked URL: %#v", events[1])
	}
}

func TestMaterializeNERuleSetsReusesValidatedCacheAcrossStarts(t *testing.T) {
	basePath := t.TempDir()
	newProfile := func(rawURL string) *config.Profile {
		return &config.Profile{
			Lines: []config.Line{{ID: "direct", Type: config.LineTypeDirect, Enabled: true}},
			RuleSets: []config.RuleSet{{
				ID: "cnip", Type: config.RuleSetTypeURL, Enabled: true,
				URL: rawURL, Format: "json",
			}},
			Modes: []config.Mode{{
				ID: "mode", Bindings: []config.RuleBinding{{RuleSetID: "cnip", LineID: "direct"}},
				DefaultLineID: "direct",
			}},
			ActiveModeID: "mode",
		}
	}
	content := []byte(`{"version":1,"rules":[{"ip_cidr":["192.0.2.0/24"]}]}`)
	first := newProfile("https://rules.example.com/geoip-cn.json")
	if err := materializeNERuleSets(first, basePath, func(string, int64) ([]byte, error) {
		return content, nil
	}); err != nil {
		t.Fatal(err)
	}
	firstPath := strings.TrimPrefix(first.RuleSets[0].URL, "file://")

	// GenerateTransparentProxySession calls this before every start. Preparing the
	// directory again must preserve the validated last-known-good copy.
	if _, err := prepareNERuleSetDirectory(basePath); err != nil {
		t.Fatal(err)
	}
	fetchCalls := 0
	second := newProfile("https://rules.example.com/geoip-cn.json")
	if err := materializeNERuleSets(second, basePath, func(string, int64) ([]byte, error) {
		fetchCalls++
		return nil, fmt.Errorf("underlay cannot reach rule host")
	}); err != nil {
		t.Fatal(err)
	}
	if fetchCalls != 0 {
		t.Fatalf("fresh cache should make reconnect network-independent, fetch calls = %d", fetchCalls)
	}
	if second.RuleSets[0].URL != "file://"+firstPath {
		t.Fatalf("reconnect did not reuse the exact cached copy: %q", second.RuleSets[0].URL)
	}
}

func TestMaterializeNERuleSetsFallsBackToStaleValidatedCache(t *testing.T) {
	basePath := t.TempDir()
	profile := &config.Profile{
		Lines: []config.Line{{ID: "direct", Type: config.LineTypeDirect, Enabled: true}},
		RuleSets: []config.RuleSet{{
			ID: "cnip", Type: config.RuleSetTypeURL, Enabled: true,
			URL: "https://rules.example.com/geoip-cn.json", Format: "json",
		}},
		Modes: []config.Mode{{
			ID: "mode", Bindings: []config.RuleBinding{{RuleSetID: "cnip", LineID: "direct"}},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "mode",
	}
	content := []byte(`{"version":1,"rules":[{"ip_cidr":["192.0.2.0/24"]}]}`)
	if err := materializeNERuleSets(profile, basePath, func(string, int64) ([]byte, error) {
		return content, nil
	}); err != nil {
		t.Fatal(err)
	}
	localPath := strings.TrimPrefix(profile.RuleSets[0].URL, "file://")
	staleTime := time.Now().Add(-neRuleSetCacheFreshFor - time.Hour)
	if err := os.Chtimes(localPath, staleTime, staleTime); err != nil {
		t.Fatal(err)
	}

	reconnect := &config.Profile{
		Lines: []config.Line{{ID: "direct", Type: config.LineTypeDirect, Enabled: true}},
		RuleSets: []config.RuleSet{{
			ID: "cnip", Type: config.RuleSetTypeURL, Enabled: true,
			URL: "https://rules.example.com/geoip-cn.json", Format: "json",
		}},
		Modes: []config.Mode{{
			ID: "mode", Bindings: []config.RuleBinding{{RuleSetID: "cnip", LineID: "direct"}},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "mode",
	}
	fetchCalls := 0
	if err := materializeNERuleSets(reconnect, basePath, func(string, int64) ([]byte, error) {
		fetchCalls++
		return nil, fmt.Errorf("network unavailable")
	}); err != nil {
		t.Fatal(err)
	}
	if fetchCalls != 1 {
		t.Fatalf("stale cache should attempt one refresh, fetch calls = %d", fetchCalls)
	}
	if reconnect.RuleSets[0].URL != "file://"+localPath {
		t.Fatalf("stale validated cache was not retained: %q", reconnect.RuleSets[0].URL)
	}
}

func TestMaterializeNERuleSetsDoesNotReuseCacheForChangedURL(t *testing.T) {
	basePath := t.TempDir()
	newProfile := func(rawURL string) *config.Profile {
		return &config.Profile{
			Lines: []config.Line{{ID: "direct", Type: config.LineTypeDirect, Enabled: true}},
			RuleSets: []config.RuleSet{{
				ID: "cnip", Type: config.RuleSetTypeURL, Enabled: true,
				URL: rawURL, Format: "json",
			}},
			Modes: []config.Mode{{
				ID: "mode", Bindings: []config.RuleBinding{{RuleSetID: "cnip", LineID: "direct"}},
				DefaultLineID: "direct",
			}},
			ActiveModeID: "mode",
		}
	}
	content := []byte(`{"version":1,"rules":[{"ip_cidr":["192.0.2.0/24"]}]}`)
	if err := materializeNERuleSets(
		newProfile("https://rules.example.com/old.json"),
		basePath,
		func(string, int64) ([]byte, error) { return content, nil },
	); err != nil {
		t.Fatal(err)
	}
	err := materializeNERuleSets(
		newProfile("https://rules.example.com/new.json"),
		basePath,
		func(string, int64) ([]byte, error) { return nil, fmt.Errorf("network unavailable") },
	)
	if err == nil || !strings.Contains(err.Error(), `"cnip"`) {
		t.Fatalf("changed URL must not inherit another resource's cache: %v", err)
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
	want := []byte(`{"version":1,"rules":[{"ip_cidr":["192.0.2.0/24"]}]}`)
	var fetched string
	input = []byte(`{
        "route": {
          "rule_set": [{
            "type": "remote",
            "tag": "sub-geoip-example-cn",
            "format": "source",
            "url": "https://rules.example.com/geoip-cn.json?token=secret",
            "download_detour": "direct"
          }]
        }
      }`)
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

func TestGenerateTransparentProxySessionCarriesActiveAnyConnectOnlyInEnvelope(t *testing.T) {
	profile := config.Profile{
		Lines: []config.Line{{
			ID:            "company",
			Type:          config.LineTypeVPN,
			Enabled:       true,
			VPNServer:     "vpn.example.com:8443",
			VPNUsername:   "employee",
			VPNPassword:   "secret-password",
			AllowInsecure: true,
		}},
		Modes:        []config.Mode{{ID: "mode", DefaultLineID: "company"}},
		ActiveModeID: "mode",
	}
	profileData, err := json.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}
	sessionJSON, err := GenerateTransparentProxySession(
		string(profileData),
		t.TempDir(),
		29876,
		"session-user",
		"session-password",
		"utun-underlay",
		`["100.100.100.100"]`,
	)
	if err != nil {
		t.Fatal(err)
	}
	var session transparentProxySession
	if err := json.Unmarshal([]byte(sessionJSON), &session); err != nil {
		t.Fatal(err)
	}
	if session.AnyConnect == nil ||
		session.AnyConnect.Server != "vpn.example.com:8443" ||
		session.AnyConnect.Username != "employee" ||
		session.AnyConnect.Password != "secret-password" ||
		!session.AnyConnect.AllowInsecure {
		t.Fatalf("active AnyConnect session is incomplete: %+v", session.AnyConnect)
	}
	if session.Plan == nil || session.Plan.Mode.ID != "mode" {
		t.Fatalf("dynamic connection plan is missing: %+v", session.Plan)
	}
	if strings.Contains(session.ConfigJSON, "secret-password") ||
		strings.Contains(session.ConfigJSON, "employee") {
		t.Fatal("AnyConnect credentials leaked into sing-box configuration")
	}

	var document map[string]interface{}
	if err := json.Unmarshal([]byte(session.ConfigJSON), &document); err != nil {
		t.Fatal(err)
	}
	inbound := document["inbounds"].([]interface{})[0].(map[string]interface{})
	if inbound["type"] != "socks" || inbound["listen"] != "127.0.0.1" {
		t.Fatalf("unexpected Transparent Proxy config: %v", inbound)
	}
	outbounds := document["outbounds"].([]interface{})
	foundVPN := false
	for _, raw := range outbounds {
		outbound := raw.(map[string]interface{})
		if outbound["tag"] == "vpn" {
			foundVPN = outbound["type"] == "vpn"
		}
	}
	if !foundVPN {
		t.Fatalf("in-process AnyConnect outbound is missing: %v", outbounds)
	}
}

func TestGenerateConnectionPlanIsSideEffectFreeAndCredentialFree(t *testing.T) {
	profile := config.Profile{
		Lines: []config.Line{{
			ID:          "company",
			Name:        "Company",
			Type:        config.LineTypeVPN,
			Enabled:     true,
			VPNServer:   "vpn.example.com:8443",
			VPNUsername: "employee",
			VPNPassword: "secret-password",
		}},
		Modes:        []config.Mode{{ID: "mode", Name: "Work", DefaultLineID: "company"}},
		ActiveModeID: "mode",
	}
	profileData, err := json.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}
	planJSON, err := GenerateConnectionPlan(string(profileData))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(planJSON, "secret-password") ||
		strings.Contains(planJSON, "employee") ||
		strings.Contains(planJSON, "vpn.example.com") {
		t.Fatalf("connection plan leaked credentials or endpoint details: %s", planJSON)
	}
	var plan config.ConnectionPlan
	if err := json.Unmarshal([]byte(planJSON), &plan); err != nil {
		t.Fatal(err)
	}
	if plan.Mode.ID != "mode" || len(plan.Tasks) == 0 {
		t.Fatalf("invalid connection plan: %+v", plan)
	}
}

func TestActiveLineOutboundsUsesExactConnectionPlan(t *testing.T) {
	profile := &config.Profile{
		Lines: []config.Line{
			{
				ID:             "active-proxy",
				Type:           config.LineTypeTrojan,
				Enabled:        true,
				TrojanServer:   "active.example",
				TrojanPort:     443,
				TrojanPassword: "secret",
			},
			{
				ID:             "unused-proxy",
				Type:           config.LineTypeTrojan,
				Enabled:        true,
				TrojanServer:   "unused.example",
				TrojanPort:     443,
				TrojanPassword: "secret",
			},
		},
		RuleSets: []config.RuleSet{{
			ID:      "active-rule",
			Type:    config.RuleSetTypeManual,
			Enabled: true,
			Domains: []string{"active.example"},
		}},
		Modes: []config.Mode{{
			ID:            "mode",
			DefaultLineID: "direct",
			Bindings: []config.RuleBinding{{
				RuleSetID: "active-rule",
				LineID:    "active-proxy",
			}},
		}},
		ActiveModeID: "mode",
	}
	plan, err := config.BuildConnectionPlan(profile)
	if err != nil {
		t.Fatal(err)
	}
	got, err := activeLineOutbounds(profile, plan)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		"active-proxy": "proxy-active-proxy",
		"direct":       "direct",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("active Line capabilities = %#v, want %#v", got, want)
	}
	if _, loaded := got["unused-proxy"]; loaded {
		t.Fatalf("unreferenced Line escaped into active capabilities: %#v", got)
	}
}

func TestActiveRouteRuleSetTagsComeFromGeneratedDataPlane(t *testing.T) {
	got, err := activeRouteRuleSetTags([]byte(`{
		"route": {
			"rule_set": [
				{"tag": "ruleset-active", "type": "local", "path": "/secret/path"},
				{"tag": "ruleset-active", "type": "local"},
				{"tag": ""}
			]
		}
	}`))
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, []string{"ruleset-active"}) {
		t.Fatalf("active rule-set capabilities = %#v", got)
	}
}

func TestGenerateTransparentProxySessionCarriesActiveTailscaleReadinessTarget(t *testing.T) {
	profile := config.Profile{
		Lines: []config.Line{
			{ID: "direct", Type: config.LineTypeDirect, Enabled: true},
			{
				ID:                "japan",
				Type:              config.LineTypeTailscale,
				Enabled:           true,
				TailscaleExitNode: "100.64.0.9",
			},
		},
		RuleSets: []config.RuleSet{{
			ID:      "cn",
			Type:    config.RuleSetTypeManual,
			Enabled: true,
			CIDRs:   []string{"203.0.113.0/24"},
		}},
		Modes: []config.Mode{{
			ID:            "mode",
			DefaultLineID: "direct",
			Bindings: []config.RuleBinding{{
				RuleSetID: "cn",
				LineID:    "japan",
			}},
		}},
		ActiveModeID: "mode",
	}
	profileData, err := json.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}
	sessionJSON, err := GenerateTransparentProxySession(
		string(profileData),
		t.TempDir(),
		29876,
		"session-user",
		"session-password",
		"utun-underlay",
		`["100.100.100.100"]`,
	)
	if err != nil {
		t.Fatal(err)
	}
	var session transparentProxySession
	if err := json.Unmarshal([]byte(sessionJSON), &session); err != nil {
		t.Fatal(err)
	}
	if session.Tailscale == nil ||
		session.Tailscale.EndpointTag != "tailscale-japan" ||
		session.Tailscale.ExitNode != "100.64.0.9" {
		t.Fatalf("Tailscale readiness target is incomplete: %+v", session.Tailscale)
	}
	if !reflect.DeepEqual(session.LineOutbounds, map[string]string{
		"direct": "direct",
		"japan":  "tailscale-japan",
	}) {
		t.Fatalf("active Line capabilities are incomplete: %#v", session.LineOutbounds)
	}
}
