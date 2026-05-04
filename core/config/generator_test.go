package config

import (
	"encoding/json"
	"testing"
)

func testProfile() *Profile {
	return &Profile{
		Ports: []Port{
			{ID: "direct", Name: "直连", Type: PortTypeDirect, Enabled: true},
			{ID: "vpn", Name: "VPN", Type: PortTypeVPN, Enabled: true,
				VPNServer: "vpn.example.com:8443", VPNUsername: "user"},
			{ID: "ss", Name: "SS", Type: PortTypeTrojan, Enabled: true,
				TrojanServer: "proxy.example.com", TrojanPort: 443,
				TrojanPassword: "pass", TrojanSNI: "proxy.example.com"},
		},
		Cargoes: []Cargo{
			{ID: "internal", Name: "内部域名", Type: CargoTypeManual, Enabled: true,
				Domains: []string{"example.com", "internal.corp"}},
			{ID: "gfw", Name: "GFW", Type: CargoTypeURL, Enabled: true,
				URL: "https://example.com/geosite-gfw.srs"},
			{ID: "cnip", Name: "国内IP", Type: CargoTypeURL, Enabled: true,
				URL: "https://example.com/geoip-cn.json", Format: "json"},
		},
		Cruises: []Cruise{
			{
				ID: "overseas", Name: "海外",
				Bindings: []Binding{
					{CargoID: "internal", PortID: "vpn"},
				},
				DefaultPortID: "direct",
			},
			{
				ID: "domestic", Name: "国内",
				Bindings: []Binding{
					{CargoID: "internal", PortID: "vpn"},
					{CargoID: "gfw", PortID: "vpn"},
				},
				DefaultPortID: "direct",
			},
			{
				ID: "domestic-ss", Name: "国内+SS",
				Bindings: []Binding{
					{CargoID: "internal", PortID: "vpn"},
					{CargoID: "gfw", PortID: "ss"},
				},
				DefaultPortID: "direct",
			},
		},
		ActiveCruiseID: "overseas",
	}
}

func TestProfileFinders(t *testing.T) {
	p := testProfile()
	if e := p.FindPort("vpn"); e == nil || e.Name != "VPN" {
		t.Fatal("FindPort(vpn) failed")
	}
	if r := p.FindCargo("gfw"); r == nil || r.URL == "" {
		t.Fatal("FindCargo(gfw) failed")
	}
	if s := p.ActiveCruise(); s == nil || s.Name != "海外" {
		t.Fatal("ActiveCruise failed")
	}
	if v := p.VPNPort(); v == nil || v.VPNServer == "" {
		t.Fatal("VPNPort failed")
	}
}

func TestGenerateWithManualCargo(t *testing.T) {
	p := testProfile()
	p.ActiveCruiseID = "overseas"

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
					t.Errorf("manual cargo should route to vpn, got %v", r["outbound"])
				}
			}
		}
	}
	if !found {
		t.Fatal("manual domain cargo not found in route rules")
	}

	if rs, ok := cfg.Route["rule_set"]; ok {
		sets := rs.([]interface{})
		if len(sets) > 0 {
			t.Errorf("overseas cruise should not have rule_sets, got %d", len(sets))
		}
	}

	t.Log(string(data))
}

func TestGenerateWithURLCargo_SRS(t *testing.T) {
	p := testProfile()
	p.ActiveCruiseID = "domestic"

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
		t.Fatal("domestic cruise should have rule_sets")
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

func TestGenerateWithURLCargo_JSON(t *testing.T) {
	p := testProfile()
	p.Cruises = append(p.Cruises, Cruise{
		ID: "with-cnip", Name: "含国内IP",
		Bindings: []Binding{
			{CargoID: "cnip", PortID: "direct"},
		},
		DefaultPortID: "vpn",
	})
	p.ActiveCruiseID = "with-cnip"

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

func TestGenerateMultipleCargoes(t *testing.T) {
	p := testProfile()
	p.ActiveCruiseID = "domestic-ss"

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

func TestGenerateDefaultPort(t *testing.T) {
	p := testProfile()
	p.ActiveCruiseID = "overseas"

	data, err := GenerateSingBox(p, 10800, "")
	if err != nil {
		t.Fatal(err)
	}

	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}

	if cfg.Route["final"] != "direct" {
		t.Errorf("default port should be direct, got %v", cfg.Route["final"])
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
