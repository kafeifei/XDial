package config

import (
	"encoding/json"
	"testing"
)

func testProfile() *Profile {
	return &Profile{
		Exits: []Exit{
			{ID: "direct", Name: "直连", Type: ExitTypeDirect, Enabled: true},
			{ID: "vpn", Name: "VPN", Type: ExitTypeVPN, Enabled: true,
				VPNServer: "vpn.example.com:8443", VPNUsername: "user"},
			{ID: "ss", Name: "SS", Type: ExitTypeTrojan, Enabled: true,
				TrojanServer: "proxy.example.com", TrojanPort: 443,
				TrojanPassword: "pass", TrojanSNI: "proxy.example.com"},
		},
		Rules: []Rule{
			{ID: "internal", Name: "内部域名", Type: RuleTypeManual, Enabled: true,
				Domains: []string{"example.com", "internal.corp"}},
			{ID: "gfw", Name: "GFW", Type: RuleTypeURL, Enabled: true,
				URL: "https://example.com/geosite-gfw.srs"},
			{ID: "cnip", Name: "国内IP", Type: RuleTypeURL, Enabled: true,
				URL: "https://example.com/geoip-cn.json", Format: "json"},
		},
		Strategies: []Strategy{
			{
				ID: "overseas", Name: "海外",
				Bindings: []Binding{
					{RuleID: "internal", ExitID: "vpn"},
				},
				DefaultExitID: "direct",
			},
			{
				ID: "domestic", Name: "国内",
				Bindings: []Binding{
					{RuleID: "internal", ExitID: "vpn"},
					{RuleID: "gfw", ExitID: "vpn"},
				},
				DefaultExitID: "direct",
			},
			{
				ID: "domestic-ss", Name: "国内+SS",
				Bindings: []Binding{
					{RuleID: "internal", ExitID: "vpn"},
					{RuleID: "gfw", ExitID: "ss"},
				},
				DefaultExitID: "direct",
			},
		},
		ActiveStrategyID: "overseas",
	}
}

func TestProfileFinders(t *testing.T) {
	p := testProfile()
	if e := p.FindExit("vpn"); e == nil || e.Name != "VPN" {
		t.Fatal("FindExit(vpn) failed")
	}
	if r := p.FindRule("gfw"); r == nil || r.URL == "" {
		t.Fatal("FindRule(gfw) failed")
	}
	if s := p.ActiveStrategy(); s == nil || s.Name != "海外" {
		t.Fatal("ActiveStrategy failed")
	}
	if v := p.VPNExit(); v == nil || v.VPNServer == "" {
		t.Fatal("VPNExit failed")
	}
}

func TestGenerateWithManualRule(t *testing.T) {
	p := testProfile()
	p.ActiveStrategyID = "overseas"

	data, err := GenerateSingBox(p, 10800, "1.2.3.4")
	if err != nil {
		t.Fatal(err)
	}

	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}

	// 检查手动规则生成了 domain_suffix
	found := false
	for _, rule := range cfg.Route["rules"].([]interface{}) {
		r := rule.(map[string]interface{})
		if ds, ok := r["domain_suffix"]; ok {
			domains := ds.([]interface{})
			if len(domains) == 2 && domains[0] == "example.com" {
				found = true
				if r["outbound"] != "vpn" {
					t.Errorf("manual rule should route to vpn, got %v", r["outbound"])
				}
			}
		}
	}
	if !found {
		t.Fatal("manual domain rule not found in route rules")
	}

	// 海外策略不用 GFW rule-set，不应有 rule_set
	if rs, ok := cfg.Route["rule_set"]; ok {
		sets := rs.([]interface{})
		if len(sets) > 0 {
			t.Errorf("overseas strategy should not have rule_sets, got %d", len(sets))
		}
	}

	t.Log(string(data))
}

func TestGenerateWithURLRule_SRS(t *testing.T) {
	p := testProfile()
	p.ActiveStrategyID = "domestic"

	data, err := GenerateSingBox(p, 10800, "1.2.3.4")
	if err != nil {
		t.Fatal(err)
	}

	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}

	// 检查 rule_set 包含 GFW .srs
	rs, ok := cfg.Route["rule_set"].([]interface{})
	if !ok || len(rs) == 0 {
		t.Fatal("domestic strategy should have rule_sets")
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

func TestGenerateWithURLRule_JSON(t *testing.T) {
	p := testProfile()
	// 加一个使用 cnip (json format) 的策略
	p.Strategies = append(p.Strategies, Strategy{
		ID: "with-cnip", Name: "含国内IP",
		Bindings: []Binding{
			{RuleID: "cnip", ExitID: "direct"},
		},
		DefaultExitID: "vpn",
	})
	p.ActiveStrategyID = "with-cnip"

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

func TestGenerateMultipleRules(t *testing.T) {
	p := testProfile()
	p.ActiveStrategyID = "domestic-ss"

	data, err := GenerateSingBox(p, 10800, "1.2.3.4")
	if err != nil {
		t.Fatal(err)
	}

	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}

	// 应有 3 个 outbound：direct + vpn(socks) + ss(trojan)
	if len(cfg.Outbounds) < 3 {
		t.Fatalf("expected 3+ outbounds, got %d", len(cfg.Outbounds))
	}

	// GFW 规则应走 ss (proxy-ss)
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

func TestGenerateDefaultExit(t *testing.T) {
	p := testProfile()
	p.ActiveStrategyID = "overseas"

	data, err := GenerateSingBox(p, 10800, "")
	if err != nil {
		t.Fatal(err)
	}

	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}

	if cfg.Route["final"] != "direct" {
		t.Errorf("default exit should be direct, got %v", cfg.Route["final"])
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
