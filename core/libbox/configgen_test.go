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

func TestStartStandaloneRouteResolvePreferredByMemoryDNS(t *testing.T) {
	platform := &xdPlatformInterface{}
	platform.setDefaultInterface("test0", 1)
	instance := &Libbox{platform: platform}
	configJSON := `{
		"log":{"disabled":true},
		"dns":{
			"servers":[{
				"type":"hosts",
				"tag":"memory-dns",
				"memory_only":true,
				"predefined":{"member":["100.64.0.8"]}
			}],
			"final":"memory-dns"
		},
		"inbounds":[],
		"outbounds":[{"type":"direct","tag":"direct"}],
		"route":{
			"rules":[{
				"preferred_by":"memory-dns",
				"action":"resolve",
				"server":"memory-dns",
				"disable_cache":true
			}],
			"final":"direct"
		}
	}`
	if err := instance.StartStandalone(configJSON); err != nil {
		t.Fatalf("start route resolve with memory DNS ownership: %v", err)
	}
	if err := instance.Stop(); err != nil {
		t.Fatalf("stop route resolve with memory DNS ownership: %v", err)
	}
}

func TestGenerateNEConfigIncludesTailscaleEndpointWithMobileDNSDispatcher(t *testing.T) {
	basePath := t.TempDir()
	profile := config.Profile{
		Lines: []config.Line{
			{ID: "direct", Type: config.LineTypeDirect, Enabled: true},
			{
				ID: "tailnet", Type: config.LineTypeTailscale, Enabled: true,
				TailscaleMagicDNS: true,
			},
		},
		// MagicDNS 只对 active Scenario 引用且显式勾选的线路生成。
		Scenarios: []config.Scenario{{
			ID: "scenario", DefaultLineID: "tailnet",
		}},
		ActiveScenarioID: "scenario",
		Tailscale:        config.TailscaleIdentity{Hostname: "xdial-mobile"},
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
		servers[1].(map[string]interface{})["accept_search_domain"] != true ||
		servers[2].(map[string]interface{})["type"] != "xdial-mobile" {
		t.Fatalf("NetworkExtension mobile DNS chain is incomplete: %v", servers)
	}
	if dns["final"] != "xdial-mobile-dns" {
		t.Fatalf("NetworkExtension DNS final must use dispatcher: %v", dns)
	}
	rules, ok := dns["rules"].([]interface{})
	if !ok || len(rules) != 2 {
		t.Fatalf("NetworkExtension must expose dynamic and short-name MagicDNS rules: %v", dns)
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
		Scenarios:        []config.Scenario{{ID: "scenario", DefaultLineID: "vpn"}},
		ActiveScenarioID: "scenario",
		Tailscale:        config.TailscaleIdentity{Hostname: "xdial-mobile"},
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
		Scenarios: []config.Scenario{
			{ID: "scenario", Name: "Scenario", Bindings: []config.RuleBinding{{RuleSetID: "large", LineID: "ac"}}, DefaultLineID: "direct"},
		},
		ActiveScenarioID: "scenario",
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
		Scenarios: []config.Scenario{{
			ID: "scenario", Bindings: []config.RuleBinding{{RuleSetID: "remote", LineID: "direct"}},
			DefaultLineID: "direct",
		}},
		ActiveScenarioID: "scenario",
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
		Scenarios: []config.Scenario{{
			ID: "scenario",
			Bindings: []config.RuleBinding{{
				RuleSetID: "cnip",
				LineID:    "direct",
			}},
			DefaultLineID: "direct",
		}},
		ActiveScenarioID: "scenario",
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
			Scenarios: []config.Scenario{{
				ID: "scenario", Bindings: []config.RuleBinding{{RuleSetID: "cnip", LineID: "direct"}},
				DefaultLineID: "direct",
			}},
			ActiveScenarioID: "scenario",
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

func TestMaterializeNERuleSetsStartsImmediatelyFromStaleValidatedCache(t *testing.T) {
	basePath := t.TempDir()
	profile := &config.Profile{
		Lines: []config.Line{{ID: "direct", Type: config.LineTypeDirect, Enabled: true}},
		RuleSets: []config.RuleSet{{
			ID: "cnip", Type: config.RuleSetTypeURL, Enabled: true,
			URL: "https://rules.example.com/geoip-cn.json", Format: "json",
		}},
		Scenarios: []config.Scenario{{
			ID: "scenario", Bindings: []config.RuleBinding{{RuleSetID: "cnip", LineID: "direct"}},
			DefaultLineID: "direct",
		}},
		ActiveScenarioID: "scenario",
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
		Scenarios: []config.Scenario{{
			ID: "scenario", Bindings: []config.RuleBinding{{RuleSetID: "cnip", LineID: "direct"}},
			DefaultLineID: "direct",
		}},
		ActiveScenarioID: "scenario",
	}
	fetchCalls := 0
	pending, err := materializeNERuleSetsWithRefreshEvents(reconnect, basePath, func(string, int64) ([]byte, error) {
		fetchCalls++
		return nil, fmt.Errorf("network unavailable")
	}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if fetchCalls != 0 {
		t.Fatalf("stale cache must not block startup, fetch calls = %d", fetchCalls)
	}
	if reconnect.RuleSets[0].URL != "file://"+localPath {
		t.Fatalf("stale validated cache was not retained: %q", reconnect.RuleSets[0].URL)
	}
	if len(pending) != 1 || pending[0].RuleSetID != "cnip" ||
		pending[0].FetchLineID != "direct" || pending[0].LocalPath != localPath {
		t.Fatalf("background refresh was not scheduled: %+v", pending)
	}
}

func TestGenerateTransparentProxyRuleSetBootstrapSeparatesColdAndWarmRefresh(t *testing.T) {
	basePath := t.TempDir()
	newProfile := func(fetchLineID string) config.Profile {
		return config.Profile{
			Lines: []config.Line{
				{ID: "direct", Type: config.LineTypeDirect, Enabled: true},
				{
					ID: "source", Name: "Source", Type: config.LineTypeTrojan, Enabled: true,
					TrojanServer: "source.example.com", TrojanPort: 443,
					TrojanPassword: "secret", TrojanSNI: "source.example.com",
				},
			},
			RuleSets: []config.RuleSet{{
				ID: "remote", Type: config.RuleSetTypeURL, Enabled: true,
				URL: "https://rules.example.com/list.json", Format: "json",
				FetchLineID: fetchLineID,
			}},
			Scenarios: []config.Scenario{{
				ID:            "scenario",
				Bindings:      []config.RuleBinding{{RuleSetID: "remote", LineID: "direct"}},
				DefaultLineID: "direct",
			}},
			ActiveScenarioID: "scenario",
		}
	}
	generate := func(profile config.Profile) transparentProxyRuleSetBootstrap {
		t.Helper()
		profileJSON, err := json.Marshal(profile)
		if err != nil {
			t.Fatal(err)
		}
		raw, err := GenerateTransparentProxyRuleSetBootstrap(
			string(profileJSON), basePath, 29877, "user", "password",
			"utun-underlay", `["100.100.100.100"]`,
		)
		if err != nil {
			t.Fatal(err)
		}
		var bootstrap transparentProxyRuleSetBootstrap
		if err := json.Unmarshal([]byte(raw), &bootstrap); err != nil {
			t.Fatal(err)
		}
		return bootstrap
	}

	cold := generate(newProfile("source"))
	if len(cold.PreflightSessions) != 1 || len(cold.BackgroundSessions) != 0 {
		t.Fatalf("cold cache must create one preflight session: %+v", cold)
	}
	session := cold.PreflightSessions[0]
	if session.LineID != "source" || session.OutboundTag != "proxy-source" ||
		session.ReuseActive || len(session.Refreshes) != 1 {
		t.Fatalf("fetch-only Line leaked or was not isolated: %+v", session)
	}
	if session.Refreshes[0].ResolverTag != "proxy-dns-proxy-source" {
		t.Fatalf("fetch DNS did not follow the source Line: %+v", session.Refreshes[0])
	}
	if strings.Contains(session.ConfigJSON, `"ruleset-remote"`) {
		t.Fatalf("bootstrap config is not an isolated source session: %s", session.ConfigJSON)
	}
	var bootstrapConfig map[string]interface{}
	if err := json.Unmarshal([]byte(session.ConfigJSON), &bootstrapConfig); err != nil {
		t.Fatal(err)
	}
	if inbounds, ok := bootstrapConfig["inbounds"].([]interface{}); !ok || len(inbounds) != 0 {
		t.Fatalf("RuleSet acquisition session must not expose an ingress: %v", bootstrapConfig["inbounds"])
	}
	foundSource := false
	for _, rawOutbound := range bootstrapConfig["outbounds"].([]interface{}) {
		outbound := rawOutbound.(map[string]interface{})
		foundSource = foundSource || outbound["tag"] == "proxy-source"
	}
	if !foundSource {
		t.Fatalf("RuleSet acquisition session omitted its source Line: %v", bootstrapConfig["outbounds"])
	}

	ruleDir, err := prepareNERuleSetDirectory(basePath)
	if err != nil {
		t.Fatal(err)
	}
	localPath := neRuleSetCachePath(
		ruleDir, "profile", "remote",
		"https://rules.example.com/list.json", "source", "source",
	)
	content := []byte(`{"version":1,"rules":[{"domain_suffix":["example.com"]}]}`)
	if err := writeNERuleSetCache(localPath, content); err != nil {
		t.Fatal(err)
	}
	fresh := generate(newProfile("source"))
	if len(fresh.PreflightSessions) != 0 || len(fresh.BackgroundSessions) != 0 {
		t.Fatalf("fresh cache must not schedule network work: %+v", fresh)
	}
	staleTime := time.Now().Add(-neRuleSetCacheFreshFor - time.Hour)
	if err := os.Chtimes(localPath, staleTime, staleTime); err != nil {
		t.Fatal(err)
	}
	warm := generate(newProfile("source"))
	if len(warm.PreflightSessions) != 0 || len(warm.BackgroundSessions) != 1 {
		t.Fatalf("stale cache must refresh only after commit: %+v", warm)
	}
}

func TestGenerateTransparentProxyRuleSetBootstrapDefaultsToDirect(t *testing.T) {
	basePath := t.TempDir()
	profile := config.Profile{
		Lines: []config.Line{{ID: "proxy", Type: config.LineTypeTrojan, Enabled: true,
			TrojanServer: "proxy.example.com", TrojanPort: 443, TrojanPassword: "secret"}},
		RuleSets: []config.RuleSet{{
			ID: "remote", Type: config.RuleSetTypeURL, Enabled: true,
			URL: "https://rules.example.com/list.srs", Format: "srs",
		}},
		Scenarios: []config.Scenario{{
			ID:            "scenario",
			Bindings:      []config.RuleBinding{{RuleSetID: "remote", LineID: "proxy"}},
			DefaultLineID: "proxy",
		}},
		ActiveScenarioID: "scenario",
	}
	profileJSON, err := json.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := GenerateTransparentProxyRuleSetBootstrap(
		string(profileJSON), basePath, 29877, "user", "password",
		"utun-underlay", `["100.100.100.100"]`,
	)
	if err != nil {
		t.Fatal(err)
	}
	var bootstrap transparentProxyRuleSetBootstrap
	if err := json.Unmarshal([]byte(raw), &bootstrap); err != nil {
		t.Fatal(err)
	}
	if len(bootstrap.PreflightSessions) != 1 {
		t.Fatalf("missing Direct preflight session: %+v", bootstrap)
	}
	session := bootstrap.PreflightSessions[0]
	if session.LineID != "direct" || session.OutboundTag != "direct" ||
		session.Refreshes[0].ResolverTag != "xdial-system-dns" {
		t.Fatalf("unspecified fetch Line must be Direct: %+v", session)
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
			Scenarios: []config.Scenario{{
				ID: "scenario", Bindings: []config.RuleBinding{{RuleSetID: "cnip", LineID: "direct"}},
				DefaultLineID: "direct",
			}},
			ActiveScenarioID: "scenario",
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
		Scenarios: []config.Scenario{{
			ID: "scenario", Bindings: []config.RuleBinding{{RuleSetID: "plain", LineID: "direct"}},
			DefaultLineID: "direct",
		}},
		ActiveScenarioID: "scenario",
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
		Scenarios:        []config.Scenario{{ID: "scenario", DefaultLineID: "company"}},
		ActiveScenarioID: "scenario",
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
		session.AnyConnect.LineID != "company" ||
		session.AnyConnect.Server != "vpn.example.com:8443" ||
		session.AnyConnect.Username != "employee" ||
		session.AnyConnect.Password != "secret-password" ||
		!session.AnyConnect.AllowInsecure {
		t.Fatalf("active AnyConnect session is incomplete: %+v", session.AnyConnect)
	}
	if session.Plan == nil || session.Plan.Scenario.ID != "scenario" {
		t.Fatalf("dynamic connection plan is missing: %+v", session.Plan)
	}
	identity := session.LineRuntimeIdentities["company"]
	if !strings.HasPrefix(identity, lineRuntimeIdentityPrefix) {
		t.Fatalf("active AnyConnect runtime identity is missing: %q", identity)
	}
	planData, err := json.Marshal(session.Plan)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(planData), "line_runtime_identities") ||
		strings.Contains(string(planData), identity) {
		t.Fatal("private Line runtime identity leaked into ConnectionPlan")
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

func TestLineRuntimeIdentityUsesEffectiveCapabilityNotPresentation(
	t *testing.T,
) {
	profile := &config.Profile{}
	base := &config.Line{
		ID:            "company-a",
		Name:          "公司",
		Type:          config.LineTypeVPN,
		Enabled:       true,
		VPNServer:     "vpn.example.com:443",
		VPNUsername:   "employee",
		VPNPassword:   "secret",
		AllowInsecure: false,
	}
	want, err := lineRuntimeIdentity(profile, base)
	if err != nil {
		t.Fatal(err)
	}
	presentationOnly := *base
	presentationOnly.ID = "company-b"
	presentationOnly.Name = "Renamed"
	presentationOnly.Enabled = false
	got, err := lineRuntimeIdentity(profile, &presentationOnly)
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("presentation-only change altered runtime identity: %q != %q", got, want)
	}

	changedCredential := *base
	changedCredential.VPNPassword = "different"
	credentialIdentity, err := lineRuntimeIdentity(
		profile,
		&changedCredential,
	)
	if err != nil {
		t.Fatal(err)
	}
	if credentialIdentity == want {
		t.Fatal("changed AnyConnect credential reused the old runtime identity")
	}

	changedTLS := *base
	changedTLS.AllowInsecure = true
	tlsIdentity, err := lineRuntimeIdentity(profile, &changedTLS)
	if err != nil {
		t.Fatal(err)
	}
	if tlsIdentity == want {
		t.Fatal("changed AnyConnect TLS policy reused the old runtime identity")
	}
}

func TestActiveLineRuntimeIdentitiesExcludeUnreferencedLines(t *testing.T) {
	profile := &config.Profile{
		Lines: []config.Line{
			{ID: "direct", Type: config.LineTypeDirect, Enabled: true},
			{
				ID: "active", Type: config.LineTypeVPN, Enabled: true,
				VPNServer: "vpn.example.com", VPNUsername: "u", VPNPassword: "p",
			},
			{
				ID: "unused", Type: config.LineTypeVPN, Enabled: true,
				VPNServer: "unused.example.com", VPNUsername: "u", VPNPassword: "p",
			},
		},
		Scenarios: []config.Scenario{{
			ID: "scenario", DefaultLineID: "active",
		}},
		ActiveScenarioID: "scenario",
	}
	plan, err := config.BuildConnectionPlan(profile)
	if err != nil {
		t.Fatal(err)
	}
	identities, err := activeLineRuntimeIdentities(profile, plan)
	if err != nil {
		t.Fatal(err)
	}
	if len(identities) != 1 || identities["active"] == "" {
		t.Fatalf("active runtime identities = %#v", identities)
	}
	if _, exists := identities["unused"]; exists {
		t.Fatal("unreferenced Line received a live runtime capability identity")
	}
}

func TestGenerateTransparentProxySessionCarriesOnlyActiveApplicationCredentials(t *testing.T) {
	profile := config.Profile{
		Lines: []config.Line{
			{ID: "direct", Type: config.LineTypeDirect, Enabled: true},
			{
				ID: "us", Type: config.LineTypeTrojan, Enabled: true,
				TrojanServer: "us.example.com", TrojanPort: 443,
				TrojanPassword: "secret", TrojanSNI: "us.example.com",
			},
		},
		RuleSets: []config.RuleSet{
			{
				ID: "active-app", Type: config.RuleSetTypeApplication, Enabled: true,
				Applications: []config.ApplicationMatch{{
					Name: "Claude", Path: "/Applications/Claude.app",
					BundleIdentifier: "com.anthropic.claudefordesktop",
				}},
				Processes: []string{"claude"},
			},
			{
				ID: "unbound-app", Type: config.RuleSetTypeApplication, Enabled: true,
				Applications: []config.ApplicationMatch{{
					Path: "/Applications/Unbound.app",
				}},
			},
			{
				ID: "disabled-app", Type: config.RuleSetTypeApplication, Enabled: false,
				Applications: []config.ApplicationMatch{{
					Path: "/Applications/Disabled.app",
				}},
			},
		},
		Scenarios: []config.Scenario{{
			ID: "scenario",
			Bindings: []config.RuleBinding{
				{RuleSetID: "active-app", LineID: "us"},
				{RuleSetID: "disabled-app", LineID: "us"},
			},
			DefaultLineID: "direct",
		}},
		ActiveScenarioID: "scenario",
	}
	profileData, err := json.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}
	sessionJSON, err := GenerateTransparentProxySession(
		string(profileData), t.TempDir(), 29876, "session-user", "session-password",
		"utun-underlay", `["100.100.100.100"]`,
	)
	if err != nil {
		t.Fatal(err)
	}
	var session transparentProxySession
	if err := json.Unmarshal([]byte(sessionJSON), &session); err != nil {
		t.Fatal(err)
	}
	want := []config.ApplicationSOCKSCredential{
		{
			Kind:      config.ApplicationProcessSelectorBundleID,
			Value:     "com.anthropic.claudefordesktop",
			RuleSetID: "active-app",
			LineID:    "us",
			Username: config.ApplicationSOCKSUsername(
				"session-user", config.ApplicationProcessSelector{
					Kind: config.ApplicationProcessSelectorBundleID, Value: "com.anthropic.claudefordesktop",
				},
			),
		},
		{
			Kind:      config.ApplicationProcessSelectorBundlePath,
			Value:     "/Applications/Claude.app",
			RuleSetID: "active-app",
			LineID:    "us",
			Username: config.ApplicationSOCKSUsername(
				"session-user", config.ApplicationProcessSelector{
					Kind: config.ApplicationProcessSelectorBundlePath, Value: "/Applications/Claude.app",
				},
			),
		},
		{
			Kind:      config.ApplicationProcessSelectorName,
			Value:     "claude",
			RuleSetID: "active-app",
			LineID:    "us",
			Username: config.ApplicationSOCKSUsername(
				"session-user", config.ApplicationProcessSelector{
					Kind: config.ApplicationProcessSelectorName, Value: "claude",
				},
			),
		},
	}
	if !reflect.DeepEqual(session.ApplicationProcessCredentials, want) {
		t.Fatalf("application process credentials = %#v, want %#v", session.ApplicationProcessCredentials, want)
	}
	for _, credential := range session.ApplicationProcessCredentials {
		if credential.Value == "/Applications/Unbound.app" ||
			credential.Value == "/Applications/Disabled.app" {
			t.Fatalf("inactive application escaped into session credentials: %#v", session.ApplicationProcessCredentials)
		}
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
		Scenarios:        []config.Scenario{{ID: "scenario", Name: "Work", DefaultLineID: "company"}},
		ActiveScenarioID: "scenario",
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
	if plan.Scenario.ID != "scenario" || len(plan.Tasks) == 0 {
		t.Fatalf("invalid connection plan: %+v", plan)
	}
}

func TestGenerateConnectionPlanRejectsUnavailableActiveProxyLine(t *testing.T) {
	profile := config.Profile{
		Lines: []config.Line{{
			ID:             "anytls",
			Name:           "AnyTLS",
			Type:           config.LineTypeAnyTLS,
			Enabled:        true,
			AnyTLSServer:   "anytls.example.com",
			AnyTLSPort:     443,
			AnyTLSPassword: "secret",
			TFO:            true,
		}},
		Scenarios:        []config.Scenario{{ID: "scenario", DefaultLineID: "anytls"}},
		ActiveScenarioID: "scenario",
	}
	profileData, err := json.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}
	if planJSON, err := GenerateConnectionPlan(string(profileData)); err == nil {
		t.Fatalf("unavailable active proxy Line must fail before preparation, got %s", planJSON)
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
		Scenarios: []config.Scenario{{
			ID:            "scenario",
			DefaultLineID: "direct",
			Bindings: []config.RuleBinding{{
				RuleSetID: "active-rule",
				LineID:    "active-proxy",
			}},
		}},
		ActiveScenarioID: "scenario",
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

func TestActiveSubscriptionOutboundsUsesExactGeneratorCatalog(t *testing.T) {
	profile := transparentProxySubscriptionCapabilityProfile()
	plan, err := config.BuildConnectionPlan(&profile)
	if err != nil {
		t.Fatal(err)
	}

	got, err := activeSubscriptionOutbounds(&profile, plan)
	if err != nil {
		t.Fatal(err)
	}
	catalog := config.BuildSubscriptionRuntimeCatalog(
		&profile,
		config.PlatformTransparentProxy,
	)
	var readinessTags []string
	for _, subscription := range catalog.Subscriptions {
		if subscription.ID == "active-sub" {
			readinessTags = subscription.ReadinessTags
			break
		}
	}
	if len(readinessTags) == 0 {
		t.Fatalf("generator catalog omitted active subscription readiness tags: %+v", catalog)
	}
	if !reflect.DeepEqual(got, map[string][]string{"active-sub": readinessTags}) {
		t.Fatalf("active Subscription capabilities = %#v, want readiness tags %#v", got, readinessTags)
	}
	if _, loaded := got["unused-sub"]; loaded {
		t.Fatalf("unreferenced Subscription escaped into active capabilities: %#v", got)
	}
}

func TestActiveSubscriptionOutboundsFailsClosed(t *testing.T) {
	t.Run("missing active runtime outbound", func(t *testing.T) {
		profile := &config.Profile{}
		plan := &config.ConnectionPlan{Tasks: []config.ConnectionPlanTask{{
			ID:         "subscription:missing",
			Kind:       config.ConnectionTaskSubscription,
			ResourceID: "missing",
		}}}
		if _, err := activeSubscriptionOutbounds(profile, plan); err == nil ||
			!strings.Contains(err.Error(), "has no runtime outbound") {
			t.Fatalf("missing active Subscription runtime outbound must fail closed, got %v", err)
		}
	})

	t.Run("conflicting active runtime outbounds", func(t *testing.T) {
		profile := &config.Profile{Subscriptions: []config.Subscription{
			{
				ID:       "duplicate",
				Enabled:  true,
				Strategy: "selector",
				Lines: []config.Line{{
					ID: "one", Name: "One", Type: config.LineTypeTrojan, Enabled: true,
					TrojanServer: "one.example", TrojanPort: 443, TrojanPassword: "secret",
				}},
				ProxyGroups: []config.ProxyGroup{{
					Name: "First", Type: "select", Proxies: []string{"One"},
				}},
			},
			{
				ID:       "duplicate",
				Enabled:  true,
				Strategy: "selector",
				Lines: []config.Line{{
					ID: "two", Name: "Two", Type: config.LineTypeTrojan, Enabled: true,
					TrojanServer: "two.example", TrojanPort: 443, TrojanPassword: "secret",
				}},
				ProxyGroups: []config.ProxyGroup{{
					Name: "Second", Type: "select", Proxies: []string{"Two"},
				}},
			},
		}}
		plan := &config.ConnectionPlan{Tasks: []config.ConnectionPlanTask{{
			ID:         "subscription:duplicate",
			Kind:       config.ConnectionTaskSubscription,
			ResourceID: "duplicate",
		}}}
		if _, err := activeSubscriptionOutbounds(profile, plan); err == nil ||
			!strings.Contains(err.Error(), "conflicting runtime outbounds") {
			t.Fatalf("conflicting active Subscription runtime outbounds must fail closed, got %v", err)
		}
	})
}

func TestGenerateTransparentProxySessionCarriesActiveSubscriptionOutbound(t *testing.T) {
	profile := transparentProxySubscriptionCapabilityProfile()
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
	readinessTags := session.SubscriptionOutbounds["active-sub"]
	if len(readinessTags) == 0 {
		t.Fatalf("active Subscription capability is missing: %#v", session.SubscriptionOutbounds)
	}
	mainTag := readinessTags[0]
	if _, loaded := session.SubscriptionOutbounds["unused-sub"]; loaded {
		t.Fatalf(
			"unreferenced Subscription escaped into session capabilities: %#v",
			session.SubscriptionOutbounds,
		)
	}

	var generated config.SingBoxConfig
	if err := json.Unmarshal([]byte(session.ConfigJSON), &generated); err != nil {
		t.Fatal(err)
	}
	if final, _ := generated.Route["final"].(string); final != mainTag {
		t.Fatalf(
			"Subscription capability main tag %q does not match generated route.final %q",
			mainTag,
			final,
		)
	}
	foundMainOutbound := false
	foundAnyTLSNode := false
	for _, outbound := range generated.Outbounds {
		tag, _ := outbound["tag"].(string)
		switch tag {
		case mainTag:
			foundMainOutbound = true
		case "proxy-active-sub-anytls":
			foundAnyTLSNode = outbound["type"] == "anytls"
		}
	}
	if !foundMainOutbound || !foundAnyTLSNode {
		t.Fatalf(
			"generated data plane is missing main or AnyTLS outbound: main=%v anytls=%v",
			foundMainOutbound,
			foundAnyTLSNode,
		)
	}
}

func transparentProxySubscriptionCapabilityProfile() config.Profile {
	return config.Profile{
		Subscriptions: []config.Subscription{
			{
				ID:       "active-sub",
				Name:     "Active AnyTLS",
				Enabled:  true,
				Strategy: "selector",
				Lines: []config.Line{{
					ID:             "anytls",
					Name:           "AnyTLS",
					Type:           config.LineTypeAnyTLS,
					Enabled:        true,
					AnyTLSServer:   "anytls.example.com",
					AnyTLSPort:     443,
					AnyTLSPassword: "secret",
				}},
				ProxyGroups: []config.ProxyGroup{
					{
						Name: "Unavailable",
						Type: "select",
						Proxies: []string{
							"Missing",
						},
					},
					{
						Name:     "Primary",
						Type:     "select",
						Proxies:  []string{"AnyTLS"},
						Selected: "AnyTLS",
					},
				},
			},
			{
				ID:       "unused-sub",
				Name:     "Unused",
				Enabled:  true,
				Strategy: "selector",
				Lines: []config.Line{{
					ID: "unused", Name: "Unused", Type: config.LineTypeTrojan, Enabled: true,
					TrojanServer: "unused.example", TrojanPort: 443, TrojanPassword: "secret",
				}},
			},
		},
		Scenarios: []config.Scenario{{
			ID:                    "scenario",
			Name:                  "Subscription",
			DefaultSubscriptionID: "active-sub",
		}},
		ActiveScenarioID: "scenario",
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
				TailscaleMagicDNS: true,
			},
		},
		RuleSets: []config.RuleSet{{
			ID:      "cn",
			Type:    config.RuleSetTypeManual,
			Enabled: true,
			CIDRs:   []string{"203.0.113.0/24"},
		}},
		Scenarios: []config.Scenario{{
			ID:            "scenario",
			DefaultLineID: "direct",
			Bindings: []config.RuleBinding{{
				RuleSetID: "cn",
				LineID:    "japan",
			}},
		}},
		ActiveScenarioID: "scenario",
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
		session.Tailscale.ExitNode != "100.64.0.9" ||
		!session.Tailscale.MagicDNSEnabled ||
		session.Tailscale.DNSServerTag != config.TailscaleMagicDNSDNSServerTag("tailscale-japan") {
		t.Fatalf("Tailscale readiness target is incomplete: %+v", session.Tailscale)
	}
	if !reflect.DeepEqual(session.LineOutbounds, map[string]string{
		"direct": "direct",
		"japan":  "tailscale-japan",
	}) {
		t.Fatalf("active Line capabilities are incomplete: %#v", session.LineOutbounds)
	}
}

func TestGenerateTransparentProxySessionCarriesMagicDNSToggle(t *testing.T) {
	profile := config.Profile{
		Lines: []config.Line{
			{
				ID: "tailnet", Type: config.LineTypeTailscale, Enabled: true,
				TailscaleExitNode: "100.64.0.9", TailscaleMagicDNS: true,
			},
		},
		Scenarios: []config.Scenario{{
			ID: "scenario", DefaultLineID: "tailnet",
		}},
		ActiveScenarioID: "scenario",
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
		session.Tailscale.EndpointTag != "tailscale-tailnet" ||
		session.Tailscale.ExitNode != "100.64.0.9" ||
		!session.Tailscale.MagicDNSEnabled ||
		session.Tailscale.DNSServerTag != config.TailscaleMagicDNSDNSServerTag("tailscale-tailnet") {
		t.Fatalf("MagicDNS readiness target is incomplete: %+v", session.Tailscale)
	}
}

func TestGenerateTransparentProxySessionStillRequiresExitNodeWithMagicDNS(t *testing.T) {
	profile := config.Profile{
		Lines: []config.Line{{
			ID: "tailnet", Type: config.LineTypeTailscale, Enabled: true,
			TailscaleMagicDNS: true,
		}},
		Scenarios:        []config.Scenario{{ID: "scenario", DefaultLineID: "tailnet"}},
		ActiveScenarioID: "scenario",
	}
	profileData, err := json.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := GenerateTransparentProxySession(
		string(profileData),
		t.TempDir(),
		29876,
		"session-user",
		"session-password",
		"utun-underlay",
		`["100.100.100.100"]`,
	); err == nil || !strings.Contains(err.Error(), "exit node is missing") {
		t.Fatalf("Tailscale without an Exit Node was accepted: %v", err)
	}
}
