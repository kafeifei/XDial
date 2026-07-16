package config

import (
	"encoding/json"
	"strings"
	"testing"
)

func testProfile() *Profile {
	return &Profile{
		Lines: []Line{
			{ID: "direct", Name: "直连", Type: LineTypeDirect, Enabled: true},
			{ID: "vpn", Name: "VPN", Type: LineTypeVPN, Enabled: true,
				VPNServer: "vpn.example.com:8443", VPNUsername: "user"},
			{ID: "ss", Name: "SS", Type: LineTypeTrojan, Enabled: true,
				TrojanServer: "proxy.example.com", TrojanPort: 443,
				TrojanPassword: "pass", TrojanSNI: "proxy.example.com"},
		},
		RuleSets: []RuleSet{
			{ID: "internal", Name: "内部域名", Type: RuleSetTypeManual, Enabled: true,
				Domains: []string{"example.com", "internal.corp"}},
			{ID: "gfw", Name: "GFW", Type: RuleSetTypeURL, Enabled: true,
				URL: "https://example.com/geosite-gfw.srs"},
			{ID: "cnip", Name: "国内IP", Type: RuleSetTypeURL, Enabled: true,
				URL: "https://example.com/geoip-cn.json", Format: "json"},
		},
		Modes: []Mode{
			{
				ID: "overseas", Name: "海外",
				Bindings: []RuleBinding{
					{RuleSetID: "internal", LineID: "vpn"},
				},
				DefaultLineID: "direct",
			},
			{
				ID: "domestic", Name: "国内",
				Bindings: []RuleBinding{
					{RuleSetID: "internal", LineID: "vpn"},
					{RuleSetID: "gfw", LineID: "vpn"},
				},
				DefaultLineID: "direct",
			},
			{
				ID: "domestic-ss", Name: "国内+SS",
				Bindings: []RuleBinding{
					{RuleSetID: "internal", LineID: "vpn"},
					{RuleSetID: "gfw", LineID: "ss"},
				},
				DefaultLineID: "direct",
			},
		},
		ActiveModeID: "overseas",
	}
}

func TestProfileFinders(t *testing.T) {
	p := testProfile()
	if e := p.FindLine("vpn"); e == nil || e.Name != "VPN" {
		t.Fatal("FindLine(vpn) failed")
	}
	if r := p.FindRuleSet("gfw"); r == nil || r.URL == "" {
		t.Fatal("FindRuleSet(gfw) failed")
	}
	if s := p.ActiveMode(); s == nil || s.Name != "海外" {
		t.Fatal("ActiveMode failed")
	}
	if v := p.VPNLine(); v == nil || v.VPNServer == "" {
		t.Fatal("VPNLine failed")
	}
}

func TestGenerateWithManualRuleSet(t *testing.T) {
	p := testProfile()
	p.ActiveModeID = "overseas"

	data, err := GenerateSingBox(p, 10800, "1.2.3.4")
	if err != nil {
		t.Fatal(err)
	}

	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}

	found := false
	for _, rule := range cfg.Route["rules"].([]interface{}) {
		r := rule.(map[string]interface{})
		if ds, ok := r["domain_suffix"]; ok {
			domains := ds.([]interface{})
			if len(domains) == 2 && domains[0] == "example.com" {
				found = true
				if r["outbound"] != "vpn" {
					t.Errorf("manual rule set should route to vpn, got %v", r["outbound"])
				}
			}
		}
	}
	if !found {
		t.Fatal("manual domain rule set not found in route rules")
	}

	if rs, ok := cfg.Route["rule_set"]; ok {
		sets := rs.([]interface{})
		if len(sets) > 0 {
			t.Errorf("overseas mode should not have rule_sets, got %d", len(sets))
		}
	}

	t.Log(string(data))
}

func TestGenerateWithURLRuleSet_SRS(t *testing.T) {
	p := testProfile()
	p.ActiveModeID = "domestic"

	data, err := GenerateSingBox(p, 10800, "1.2.3.4")
	if err != nil {
		t.Fatal(err)
	}

	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}

	rs, ok := cfg.Route["rule_set"].([]interface{})
	if !ok || len(rs) == 0 {
		t.Fatal("domestic mode should have rule_sets")
	}

	gfwSet := rs[0].(map[string]interface{})
	if gfwSet["format"] != "binary" {
		t.Errorf("srs format should be binary, got %v", gfwSet["format"])
	}
	if gfwSet["tag"] != "ruleset-gfw" {
		t.Errorf("tag should be ruleset-gfw, got %v", gfwSet["tag"])
	}

	t.Log(string(data))
}

func TestGenerateWithURLRuleSet_JSON(t *testing.T) {
	p := testProfile()
	p.Modes = append(p.Modes, Mode{
		ID: "with-cnip", Name: "含国内IP",
		Bindings: []RuleBinding{
			{RuleSetID: "cnip", LineID: "direct"},
		},
		DefaultLineID: "vpn",
	})
	p.ActiveModeID = "with-cnip"

	data, err := GenerateSingBox(p, 10800, "1.2.3.4")
	if err != nil {
		t.Fatal(err)
	}

	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}

	rs := cfg.Route["rule_set"].([]interface{})
	cnipSet := rs[0].(map[string]interface{})
	if cnipSet["format"] != "source" {
		t.Errorf("json format should be source, got %v", cnipSet["format"])
	}
}

func TestGenerateMultipleRuleSets(t *testing.T) {
	p := testProfile()
	p.ActiveModeID = "domestic-ss"

	data, err := GenerateSingBox(p, 10800, "1.2.3.4")
	if err != nil {
		t.Fatal(err)
	}

	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}

	if len(cfg.Outbounds) < 4 { // direct + vpn + ss + selector
		t.Fatalf("expected 4+ outbounds, got %d", len(cfg.Outbounds))
	}

	rules := cfg.Route["rules"].([]interface{})
	for _, rule := range rules {
		r := rule.(map[string]interface{})
		if rs, ok := r["rule_set"]; ok && rs == "ruleset-gfw" {
			if r["outbound"] != "proxy-ss" {
				t.Errorf("GFW in domestic-ss should route to proxy-ss, got %v", r["outbound"])
			}
		}
	}

	t.Log(string(data))
}

func TestGenerateDefaultLine(t *testing.T) {
	p := testProfile()
	p.ActiveModeID = "overseas"

	data, err := GenerateSingBox(p, 10800, "")
	if err != nil {
		t.Fatal(err)
	}

	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}

	if cfg.Route["final"] != "direct" {
		t.Errorf("default line should be direct, got %v", cfg.Route["final"])
	}
}

func TestVPNServerExcluded(t *testing.T) {
	p := testProfile()
	data, err := GenerateSingBox(p, 10800, "1.2.3.4")
	if err != nil {
		t.Fatal(err)
	}

	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}

	tun := cfg.Inbounds[0]
	addrs := tun["route_exclude_address"].([]interface{})
	if len(addrs) == 0 || addrs[0] != "1.2.3.4/32" {
		t.Errorf("VPN server IP should be excluded, got %v", addrs)
	}
}

func TestGenerateNEMode(t *testing.T) {
	p := testProfile()
	p.ActiveModeID = "overseas"

	data, err := GenerateSingBoxFor(p, 10800, "1.2.3.4", PlatformNE, "/var/mobile/Containers/Data/sandbox")
	if err != nil {
		t.Fatal(err)
	}

	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}

	// tun inbound 只保留最小字段,不含桌面专属的路由字段。
	tun := cfg.Inbounds[0]
	if tun["type"] != "tun" {
		t.Errorf("expected tun inbound, got %v", tun["type"])
	}
	if _, ok := tun["address"]; !ok {
		t.Error("NE tun should keep address")
	}
	if _, ok := tun["mtu"]; !ok {
		t.Error("NE tun should keep mtu")
	}
	for _, k := range []string{"auto_route", "strict_route", "stack", "route_exclude_address"} {
		if _, ok := tun[k]; ok {
			t.Errorf("NE tun should not have %q, got %v", k, tun[k])
		}
	}

	// route 不含 auto_detect_interface。
	if _, ok := cfg.Route["auto_detect_interface"]; ok {
		t.Error("NE route should not have auto_detect_interface")
	}

	// experimental 不含 clash_api;cache_file 用绝对路径。
	if _, ok := cfg.Experimental["clash_api"]; ok {
		t.Error("NE experimental should not have clash_api")
	}
	cache, ok := cfg.Experimental["cache_file"].(map[string]interface{})
	if !ok {
		t.Fatal("NE experimental should keep cache_file")
	}
	if cache["path"] != "/var/mobile/Containers/Data/sandbox/cache.db" {
		t.Errorf("NE cache_file path should be absolute under basePath, got %v", cache["path"])
	}
}

func TestGenerateMacOSModeUnchanged(t *testing.T) {
	p := testProfile()
	p.ActiveModeID = "overseas"

	// 旧签名(macOS 模式包装)与显式 PlatformMacOS 应产出完全一致的配置,
	// 且 basePath 在 macOS 模式下必须被忽略。
	viaWrapper, err := GenerateSingBox(p, 10800, "1.2.3.4")
	if err != nil {
		t.Fatal(err)
	}
	viaExplicit, err := GenerateSingBoxFor(p, 10800, "1.2.3.4", PlatformMacOS, "/should/be/ignored")
	if err != nil {
		t.Fatal(err)
	}
	if string(viaWrapper) != string(viaExplicit) {
		t.Error("macOS wrapper and explicit PlatformMacOS should be identical; basePath must be ignored")
	}

	var cfg SingBoxConfig
	if err := json.Unmarshal(viaWrapper, &cfg); err != nil {
		t.Fatal(err)
	}
	if cfg.Route["auto_detect_interface"] != true {
		t.Error("macOS route should keep auto_detect_interface")
	}
	if _, ok := cfg.Experimental["clash_api"]; !ok {
		t.Error("macOS experimental should keep clash_api")
	}
	cache := cfg.Experimental["cache_file"].(map[string]interface{})
	if cache["path"] != "cache.db" {
		t.Errorf("macOS cache_file path should stay relative, got %v", cache["path"])
	}
	tun := cfg.Inbounds[0]
	if tun["auto_route"] != true || tun["stack"] != "system" {
		t.Error("macOS tun should keep auto_route/stack")
	}
}

func TestGenerateTailscaleEndpoint(t *testing.T) {
	p := &Profile{
		Lines: []Line{
			{ID: "direct", Name: "直连", Type: LineTypeDirect, Enabled: true},
			{
				ID: "../../work", Name: "Tailnet", Type: LineTypeTailscale, Enabled: true,
				TailscaleHostname: "xdial-mac", TailscaleAcceptRoutes: true,
			},
		},
		Modes:        []Mode{{ID: "tailnet", Name: "Tailnet", DefaultLineID: "direct"}},
		ActiveModeID: "tailnet",
	}

	data, err := GenerateSingBoxFor(p, 0, "", PlatformMacOS, "/Library/Application Support/XDial")
	if err != nil {
		t.Fatal(err)
	}
	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}
	if len(cfg.Endpoints) != 1 {
		t.Fatalf("expected one tailscale endpoint, got %d", len(cfg.Endpoints))
	}
	endpoint := cfg.Endpoints[0]
	if endpoint["type"] != "tailscale" || endpoint["tag"] != "tailscale-../../work" {
		t.Fatalf("unexpected endpoint: %v", endpoint)
	}
	if endpoint["hostname"] != "xdial-mac" || endpoint["accept_routes"] != true {
		t.Fatalf("tailscale options missing: %v", endpoint)
	}
	stateDirectory, _ := endpoint["state_directory"].(string)
	if !strings.HasPrefix(stateDirectory, "/Library/Application Support/XDial/tailscale/") || strings.Contains(stateDirectory, "..") {
		t.Fatalf("unsafe tailscale state directory: %q", stateDirectory)
	}

	for _, outbound := range cfg.Outbounds {
		if outbound["tag"] == "vpn" {
			t.Fatal("tailscale-only profile must not generate VPN outbound")
		}
	}
	rules := cfg.Route["rules"].([]interface{})
	preferred := rules[1].(map[string]interface{})
	if preferred["preferred_by"] != "tailscale-../../work" || preferred["outbound"] != "tailscale-../../work" {
		t.Fatalf("tailscale preferred route missing: %v", preferred)
	}
	servers := cfg.DNS["servers"].([]interface{})
	if len(servers) != 2 || servers[1].(map[string]interface{})["type"] != "tailscale" {
		t.Fatalf("tailscale DNS missing: %v", servers)
	}
}

func TestGenerateTailscaleExitNodeAsDefault(t *testing.T) {
	p := &Profile{
		Lines: []Line{
			{ID: "direct", Name: "直连", Type: LineTypeDirect, Enabled: true},
			{ID: "ts", Name: "Tailnet", Type: LineTypeTailscale, Enabled: true, TailscaleExitNode: "exit-node"},
		},
		Modes:        []Mode{{ID: "exit", Name: "Exit", DefaultLineID: "ts"}},
		ActiveModeID: "exit",
	}

	data, err := GenerateSingBoxFor(p, 0, "", PlatformMacOS, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}
	if cfg.Route["final"] != "tailscale-ts" {
		t.Fatalf("tailscale should be final outbound, got %v", cfg.Route["final"])
	}
	if cfg.Endpoints[0]["exit_node"] != "exit-node" {
		t.Fatalf("exit node missing: %v", cfg.Endpoints[0])
	}
}
