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

func TestGenerateOmitsUnusedEnabledOutbounds(t *testing.T) {
	p := testProfile()
	p.ActiveModeID = "overseas"
	p.Lines = append(p.Lines, Line{
		ID: "unused-vmess", Name: "Unused", Type: LineTypeVMess, Enabled: true,
		VMessServer: "unused.example.com", VMessPort: 443, VMessUUID: "not-a-valid-uuid",
	})
	p.Subscriptions = append(p.Subscriptions, Subscription{
		ID: "unused-sub", Name: "Unused subscription", Enabled: true,
		Lines: []Line{{
			ID: "unused-node", Name: "Unused node", Type: LineTypeTrojan, Enabled: true,
			TrojanServer: "unused-sub.example.com", TrojanPort: 443,
		}},
	})

	data, err := GenerateSingBoxFor(p, 10800, "", PlatformNE, "/tmp")
	if err != nil {
		t.Fatal(err)
	}
	text := string(data)
	for _, forbidden := range []string{"unused-vmess", "unused.example.com", "unused-sub", "unused-sub.example.com"} {
		if strings.Contains(text, forbidden) {
			t.Fatalf("unused outbound %q leaked into active configuration", forbidden)
		}
	}
}

func TestGenerateUsesConfiguredConnectivityProbeRules(t *testing.T) {
	const (
		connectivityDirectID     = "xdial-connectivity-direct"
		connectivityAnyConnectID = "xdial-connectivity-anyconnect"
	)
	p := testProfile()
	p.ActiveModeID = "overseas"
	p.RuleSets = append(p.RuleSets,
		RuleSet{ID: connectivityDirectID, Name: "Direct probe", Type: RuleSetTypeManual, Enabled: true,
			CIDRs: []string{"1.0.0.1/32"}},
		RuleSet{ID: connectivityAnyConnectID, Name: "AnyConnect probe", Type: RuleSetTypeManual, Enabled: true,
			CIDRs: []string{"1.1.1.1/32"}},
	)
	p.Subscriptions = []Subscription{{
		ID: "probe-priority-sub", Name: "Probe priority", Enabled: true, Strategy: "selector",
		Lines: []Line{{
			ID: "probe-priority-node", Name: "Priority node", Type: LineTypeTrojan, Enabled: true,
			TrojanServer: "priority.example.com", TrojanPort: 443, TrojanPassword: "secret",
		}},
		Rules: []SubscriptionRule{{Type: "IP-CIDR", Value: "1.0.0.0/8", Group: "DIRECT"}},
	}}
	for index := range p.Modes {
		if p.Modes[index].ID == p.ActiveModeID {
			p.Modes[index].Bindings = append([]RuleBinding{
				{RuleSetID: connectivityDirectID, LineID: "direct"},
				{RuleSetID: connectivityAnyConnectID, LineID: "vpn"},
				{RuleSetID: "gfw", SubscriptionID: "probe-priority-sub"},
			}, p.Modes[index].Bindings...)
		}
	}

	data, err := GenerateSingBoxFor(p, 10800, "", PlatformNE, "/tmp")
	if err != nil {
		t.Fatal(err)
	}
	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}

	found := map[string]string{}
	positions := map[string]int{}
	for index, rawRule := range cfg.Route["rules"].([]interface{}) {
		rule := rawRule.(map[string]interface{})
		cidrs, ok := rule["ip_cidr"].([]interface{})
		if !ok || len(cidrs) != 1 {
			continue
		}
		if cidr, ok := cidrs[0].(string); ok {
			found[cidr], _ = rule["outbound"].(string)
			positions[cidr] = index
		}
	}
	if found["1.0.0.1/32"] != "direct" {
		t.Fatalf("configured Direct probe route uses %q", found["1.0.0.1/32"])
	}
	if found["1.1.1.1/32"] != "vpn" {
		t.Fatalf("configured AnyConnect probe route uses %q", found["1.1.1.1/32"])
	}
	for _, probeCIDR := range []string{"1.0.0.1/32", "1.1.1.1/32"} {
		if positions[probeCIDR] >= positions["1.0.0.0/8"] {
			t.Fatalf("visible connectivity rule %q must precede subscription catch-all: %v", probeCIDR, positions)
		}
	}
}

func TestGenerateDoesNotHideConnectivityProbeRoutes(t *testing.T) {
	p := testProfile()
	data, err := GenerateSingBoxFor(p, 10800, "", PlatformNE, "/tmp")
	if err != nil {
		t.Fatal(err)
	}
	text := string(data)
	for _, cidr := range []string{"1.0.0.1/32", "1.1.1.1/32"} {
		if strings.Contains(text, cidr) {
			t.Fatalf("generator injected hidden connectivity route %q", cidr)
		}
	}
	for _, desktopDiagnostic := range append([]string{testSelectorTag}, testDomains...) {
		if strings.Contains(text, desktopDiagnostic) {
			t.Fatalf("network extension configuration contains hidden desktop diagnostic route %q", desktopDiagnostic)
		}
	}
}

func TestGenerateNECapturesIPv6AndHijacksDNSIntoMobileDispatcher(t *testing.T) {
	p := testProfile()
	p.ActiveModeID = "overseas"

	data, err := GenerateSingBoxFor(p, 10800, "", PlatformNE, "/tmp")
	if err != nil {
		t.Fatal(err)
	}
	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}
	addresses, _ := cfg.Inbounds[0]["address"].([]interface{})
	foundIPv6 := false
	for _, address := range addresses {
		if address == "fd00::1/126" {
			foundIPv6 = true
		}
	}
	if !foundIPv6 {
		t.Fatalf("NE TUN does not capture IPv6: %v", addresses)
	}

	foundDNS := false
	for _, rawRule := range cfg.Route["rules"].([]interface{}) {
		rule := rawRule.(map[string]interface{})
		if rule["protocol"] == "dns" {
			foundDNS = true
			if rule["action"] != "hijack-dns" {
				t.Fatalf("NE DNS does not enter the mobile dispatcher: %v", rule)
			}
			if _, exists := rule["outbound"]; exists {
				t.Fatalf("NE DNS still bypasses the mobile dispatcher: %v", rule)
			}
		}
	}
	if !foundDNS {
		t.Fatal("NE config is missing an explicit DNS route")
	}
}

func TestGenerateMacOSDoesNotInjectMobileOnlyNetworkSettings(t *testing.T) {
	p := testProfile()
	data, err := GenerateSingBox(p, 10800, "")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "fd00::1/126") {
		t.Fatal("desktop configuration contains mobile-only IPv6 TUN address")
	}
	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}
	for _, rawRule := range cfg.Route["rules"].([]interface{}) {
		rule := rawRule.(map[string]interface{})
		if rule["protocol"] == "dns" && rule["outbound"] != "direct" {
			t.Fatalf("desktop DNS route unexpectedly changed: %v", rule)
		}
	}
}

func TestSubscriptionGroupOmitsUnavailableNestedMember(t *testing.T) {
	p := &Profile{
		Lines: []Line{{ID: "direct", Name: "Direct", Type: LineTypeDirect, Enabled: true}},
		Subscriptions: []Subscription{{
			ID: "sub", Name: "Subscription", Enabled: true,
			Lines: []Line{{
				ID: "node", Name: "Good", Type: LineTypeShadowsocks, Enabled: true,
				SSServer: "good.example.com", SSPort: 8388, SSMethod: "aes-256-gcm", SSPass: "secret",
			}},
			ProxyGroups: []ProxyGroup{
				{Name: "Outer", Type: "select", Proxies: []string{"Good", "Empty"}},
				{Name: "Empty", Type: "select", Proxies: []string{"Missing"}},
			},
			Rules: []SubscriptionRule{{Type: "FINAL", Group: "Outer"}},
		}},
		Modes:        []Mode{{ID: "mode", Name: "Mode", DefaultSubscriptionID: "sub"}},
		ActiveModeID: "mode",
	}

	data, err := GenerateSingBoxFor(p, 0, "", PlatformNE, "/tmp")
	if err != nil {
		t.Fatal(err)
	}
	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}
	for _, outbound := range cfg.Outbounds {
		tag, _ := outbound["tag"].(string)
		if strings.Contains(tag, "empty") {
			t.Fatalf("unavailable nested group generated outbound %q", tag)
		}
		if tag == "sub-sub-outer" {
			members, _ := outbound["outbounds"].([]interface{})
			if len(members) != 1 || members[0] != "proxy-sub-node" {
				t.Fatalf("outer group kept unavailable member: %+v", members)
			}
		}
	}
}

func TestSubscriptionSelectorUsesPersistedSelection(t *testing.T) {
	p := &Profile{
		Lines: []Line{{ID: "direct", Name: "Direct", Type: LineTypeDirect, Enabled: true}},
		Subscriptions: []Subscription{{
			ID: "sub", Name: "Subscription", Enabled: true,
			Lines: []Line{
				{ID: "one", Name: "One", Type: LineTypeShadowsocks, Enabled: true,
					SSServer: "one.example.com", SSPort: 8388, SSMethod: "aes-256-gcm", SSPass: "secret"},
				{ID: "two", Name: "Two", Type: LineTypeShadowsocks, Enabled: true,
					SSServer: "two.example.com", SSPort: 8388, SSMethod: "aes-256-gcm", SSPass: "secret"},
			},
			ProxyGroups: []ProxyGroup{{
				Name: "Choice", Type: "select", Proxies: []string{"One", "Two"}, Selected: "Two",
			}},
		}},
		Modes:        []Mode{{ID: "mode", Name: "Mode", DefaultSubscriptionID: "sub"}},
		ActiveModeID: "mode",
	}

	data, err := GenerateSingBoxFor(p, 0, "", PlatformNE, "/tmp")
	if err != nil {
		t.Fatal(err)
	}
	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}
	for _, outbound := range cfg.Outbounds {
		if outbound["tag"] == "sub-sub-choice" {
			if outbound["default"] != "proxy-sub-two" {
				t.Fatalf("selector default = %v, want proxy-sub-two", outbound["default"])
			}
			return
		}
	}
	t.Fatal("subscription selector was not generated")
}

func TestDefaultSubscriptionSelectorUsesPersistedSelection(t *testing.T) {
	profile := &Profile{
		Lines: []Line{{ID: "direct", Name: "Direct", Type: LineTypeDirect, Enabled: true}},
		Subscriptions: []Subscription{{
			ID: "sub", Name: "Subscription", Enabled: true, Strategy: "selector", Selected: "Two",
			Lines: []Line{
				{ID: "one", Name: "One", Type: LineTypeShadowsocks, Enabled: true,
					SSServer: "one.example.com", SSPort: 8388, SSMethod: "aes-256-gcm", SSPass: "secret"},
				{ID: "two", Name: "Two", Type: LineTypeShadowsocks, Enabled: true,
					SSServer: "two.example.com", SSPort: 8388, SSMethod: "aes-256-gcm", SSPass: "secret"},
			},
		}},
		Modes:        []Mode{{ID: "mode", Name: "Mode", DefaultSubscriptionID: "sub"}},
		ActiveModeID: "mode",
	}

	data, err := GenerateSingBoxFor(profile, 0, "", PlatformNE, "/tmp")
	if err != nil {
		t.Fatal(err)
	}
	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}
	found := false
	for _, outbound := range cfg.Outbounds {
		if outbound["tag"] != "sub-sub" {
			continue
		}
		found = true
		if outbound["default"] != "proxy-sub-two" {
			t.Fatalf("default selector = %v, want proxy-sub-two", outbound["default"])
		}
	}
	if !found {
		t.Fatal("default subscription selector was not generated")
	}

	catalog := BuildSubscriptionRuntimeCatalog(profile, PlatformNE)
	if len(catalog.Subscriptions) != 1 || len(catalog.Subscriptions[0].Groups) != 1 {
		t.Fatalf("unexpected runtime catalog: %+v", catalog)
	}
	group := catalog.Subscriptions[0].Groups[0]
	if group.Name != "__default__" || group.Selected != "Two" || len(group.Members) != 2 {
		t.Fatalf("default runtime selector metadata is incomplete: %+v", group)
	}
}

func TestSubscriptionRuntimeCatalogMatchesGeneratedTags(t *testing.T) {
	profile := &Profile{Subscriptions: []Subscription{{
		ID: "catalog", Name: "Catalog", Enabled: true, Strategy: "selector",
		Lines: []Line{
			{ID: "one", Name: "Node One", Type: LineTypeShadowsocks, Enabled: true, SSServer: "one.example", SSPort: 443, SSMethod: "aes-256-gcm", SSPass: "secret"},
			{ID: "two", Name: "Node Two", Type: LineTypeShadowsocks, Enabled: true, SSServer: "two.example", SSPort: 443, SSMethod: "aes-256-gcm", SSPass: "secret"},
		},
		ProxyGroups: []ProxyGroup{
			{Name: "香港节点", Type: "select", Proxies: []string{"Node One"}, Selected: "Node One"},
			{Name: "台湾节点", Type: "select", Proxies: []string{"Node Two"}, Selected: "Node Two"},
		},
	}}}
	catalog := BuildSubscriptionRuntimeCatalog(profile, PlatformNE)
	if len(catalog.Subscriptions) != 1 {
		t.Fatalf("unexpected catalog: %+v", catalog)
	}
	entry := catalog.Subscriptions[0]
	if len(entry.Nodes) != 2 || len(entry.Groups) != 2 {
		t.Fatalf("runtime catalog omitted members: %+v", entry)
	}
	if entry.Groups[0].Tag == entry.Groups[1].Tag {
		t.Fatalf("colliding group names reused runtime tag: %+v", entry.Groups)
	}
	if entry.Groups[0].Selected != "Node One" || len(entry.Groups[0].Members) != 1 || entry.Groups[0].Members[0].Tag != entry.Nodes[0].Tag {
		t.Fatalf("runtime selection mapping does not match generated node: %+v", entry)
	}
}

func TestSubscriptionGeoIPLANUsesPrivateMatcherWithoutRemoteResource(t *testing.T) {
	sub := Subscription{
		ID: "sub", Rules: []SubscriptionRule{{Type: "GEOIP", Value: "LAN", Group: "DIRECT"}},
	}
	rules, sets := buildSubscriptionRules(&sub, map[string]string{})
	if len(sets) != 0 {
		t.Fatalf("GEOIP,LAN unexpectedly created remote resources: %v", sets)
	}
	if len(rules) != 1 || rules[0]["ip_is_private"] != true || rules[0]["outbound"] != "direct" {
		t.Fatalf("GEOIP,LAN was not translated to ip_is_private: %v", rules)
	}
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

	// tun inbound 保留最小字段并明确使用 gVisor，不含桌面专属的路由字段。
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
	for _, k := range []string{"auto_route", "strict_route", "route_exclude_address"} {
		if _, ok := tun[k]; ok {
			t.Errorf("NE tun should not have %q, got %v", k, tun[k])
		}
	}
	if tun["stack"] != "gvisor" {
		t.Errorf("NE tun stack = %v, want gvisor", tun["stack"])
	}

	if cfg.Route["auto_detect_interface"] != true {
		t.Error("NE route should auto-detect the physical interface")
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
	preferredFound := false
	for _, rawRule := range cfg.Route["rules"].([]interface{}) {
		rule := rawRule.(map[string]interface{})
		if rule["preferred_by"] == "tailscale-../../work" && rule["outbound"] == "tailscale-../../work" {
			preferredFound = true
			break
		}
	}
	if !preferredFound {
		t.Fatal("tailscale preferred route missing")
	}
	servers := cfg.DNS["servers"].([]interface{})
	if len(servers) != 2 || servers[1].(map[string]interface{})["type"] != "tailscale" {
		t.Fatalf("tailscale DNS missing: %v", servers)
	}
}

func TestGenerateNETailscaleEndpoint(t *testing.T) {
	basePath := t.TempDir()
	p := &Profile{
		Lines: []Line{
			{ID: "direct", Name: "直连", Type: LineTypeDirect, Enabled: true},
			{
				ID: "mobile-tailnet", Name: "Tailnet", Type: LineTypeTailscale, Enabled: true,
				TailscaleHostname: "xdial-mobile", TailscaleAcceptRoutes: true,
				TailscaleExitNode: "exit-node",
			},
		},
		Modes:        []Mode{{ID: "tailnet", Name: "Tailnet", DefaultLineID: "direct"}},
		ActiveModeID: "tailnet",
	}

	data, err := GenerateSingBoxFor(p, 0, "", PlatformNE, basePath)
	if err != nil {
		t.Fatal(err)
	}
	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}
	if len(cfg.Endpoints) != 1 {
		t.Fatalf("expected one mobile tailscale endpoint, got %d", len(cfg.Endpoints))
	}
	endpoint := cfg.Endpoints[0]
	if endpoint["type"] != "tailscale" || endpoint["tag"] != "tailscale-mobile-tailnet" {
		t.Fatalf("unexpected endpoint: %v", endpoint)
	}
	if endpoint["state_directory"] != TailscaleStateDirectory(basePath, "mobile-tailnet") {
		t.Fatalf("state directory must remain inside the writable base path: %v", endpoint["state_directory"])
	}
	if endpoint["hostname"] != "xdial-mobile" || endpoint["accept_routes"] != true || endpoint["exit_node"] != "exit-node" {
		t.Fatalf("mobile tailscale options differ from desktop: %v", endpoint)
	}

	preferredFound := false
	for _, rawRule := range cfg.Route["rules"].([]interface{}) {
		rule := rawRule.(map[string]interface{})
		if rule["preferred_by"] == "tailscale-mobile-tailnet" && rule["outbound"] == "tailscale-mobile-tailnet" {
			preferredFound = true
			break
		}
	}
	if !preferredFound {
		t.Fatal("mobile tailscale preferred route missing")
	}
	servers := cfg.DNS["servers"].([]interface{})
	if len(servers) != 3 {
		t.Fatalf("expected public, Tailscale, and dispatcher DNS servers, got %v", servers)
	}
	publicDNS := servers[0].(map[string]interface{})
	if publicDNS["type"] != "udp" || publicDNS["tag"] != mobilePublicDNSTag ||
		publicDNS["server"] != "1.1.1.1" {
		t.Fatalf("unexpected public DNS fallback: %v", publicDNS)
	}
	if _, exists := publicDNS["detour"]; exists {
		t.Fatalf("public DNS must use the transport direct dialer: %v", publicDNS)
	}
	tailscaleDNS := servers[1].(map[string]interface{})
	if tailscaleDNS["type"] != "tailscale" ||
		tailscaleDNS["endpoint"] != "tailscale-mobile-tailnet" ||
		tailscaleDNS["accept_default_resolvers"] != false {
		t.Fatalf("unexpected Tailscale DNS transport: %v", tailscaleDNS)
	}
	dispatcher := servers[2].(map[string]interface{})
	if dispatcher["type"] != "xdial-mobile" ||
		dispatcher["tag"] != mobileDispatcherDNSTag ||
		dispatcher["public_fallback"] != mobilePublicDNSTag {
		t.Fatalf("unexpected mobile DNS dispatcher: %v", dispatcher)
	}
	bindings := dispatcher["tailscale"].([]interface{})
	if len(bindings) != 1 ||
		bindings[0].(map[string]interface{})["endpoint"] != "tailscale-mobile-tailnet" ||
		bindings[0].(map[string]interface{})["server"] != mobileTailscaleDNSTag("tailscale-mobile-tailnet") {
		t.Fatalf("unexpected dispatcher bindings: %v", bindings)
	}
	if cfg.DNS["final"] != mobileDispatcherDNSTag {
		t.Fatalf("mobile DNS final must use dispatcher: %v", cfg.DNS)
	}
	routeRules := cfg.Route["rules"].([]interface{})
	if len(routeRules) < 2 ||
		routeRules[0].(map[string]interface{})["action"] != "sniff" ||
		routeRules[1].(map[string]interface{})["action"] != "hijack-dns" {
		t.Fatalf("NE system DNS packets must be hijacked: %v", routeRules)
	}
	if cfg.Route["default_domain_resolver"] != mobilePublicDNSTag {
		t.Fatalf("NE control-plane resolver must stay public/direct: %v", cfg.Route)
	}
}

func TestGenerateNEMultipleTailscaleDNSBindingsRemainIsolated(t *testing.T) {
	basePath := t.TempDir()
	p := &Profile{
		Lines: []Line{
			{ID: "direct", Type: LineTypeDirect, Enabled: true},
			{ID: "tail-a", Type: LineTypeTailscale, Enabled: true},
			{ID: "tail-b", Type: LineTypeTailscale, Enabled: true},
			{ID: "disabled", Type: LineTypeTailscale, Enabled: false},
		},
		Modes:        []Mode{{ID: "mode", DefaultLineID: "direct"}},
		ActiveModeID: "mode",
	}

	data, err := GenerateSingBoxFor(p, 0, "", PlatformNE, basePath)
	if err != nil {
		t.Fatal(err)
	}
	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}
	servers := cfg.DNS["servers"].([]interface{})
	if len(servers) != 4 {
		t.Fatalf("expected public + two Tailscale + dispatcher servers, got %v", servers)
	}
	dispatcher := servers[len(servers)-1].(map[string]interface{})
	bindings := dispatcher["tailscale"].([]interface{})
	if len(bindings) != 2 {
		t.Fatalf("only enabled Tailscale endpoints should be bound: %v", bindings)
	}
	seen := make(map[string]string)
	for _, rawBinding := range bindings {
		binding := rawBinding.(map[string]interface{})
		seen[binding["endpoint"].(string)] = binding["server"].(string)
	}
	if seen["tailscale-tail-a"] != mobileTailscaleDNSTag("tailscale-tail-a") ||
		seen["tailscale-tail-b"] != mobileTailscaleDNSTag("tailscale-tail-b") {
		t.Fatalf("Tailscale DNS bindings crossed endpoints: %v", seen)
	}
}

func TestGenerateNEWithoutTailscaleStillUsesMobileDNSDispatcher(t *testing.T) {
	p := &Profile{
		Lines:        []Line{{ID: "direct", Type: LineTypeDirect, Enabled: true}},
		Modes:        []Mode{{ID: "mode", DefaultLineID: "direct"}},
		ActiveModeID: "mode",
	}
	data, err := GenerateSingBoxFor(p, 0, "", PlatformNE, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}
	servers := cfg.DNS["servers"].([]interface{})
	if len(servers) != 2 ||
		servers[0].(map[string]interface{})["tag"] != mobilePublicDNSTag ||
		servers[1].(map[string]interface{})["type"] != "xdial-mobile" {
		t.Fatalf("standalone NE DNS dispatcher is incomplete: %v", servers)
	}
	if bindings := servers[1].(map[string]interface{})["tailscale"].([]interface{}); len(bindings) != 0 {
		t.Fatalf("standalone dispatcher unexpectedly contains Tailscale: %v", bindings)
	}
}

func TestGenerateNETailscaleRejectsRelativeStatePath(t *testing.T) {
	p := &Profile{
		Lines: []Line{
			{ID: "direct", Type: LineTypeDirect, Enabled: true},
			{ID: "ts", Type: LineTypeTailscale, Enabled: true},
		},
		Modes:        []Mode{{ID: "mode", DefaultLineID: "direct"}},
		ActiveModeID: "mode",
	}

	_, err := GenerateSingBoxFor(p, 0, "", PlatformNE, "relative")
	if err == nil || !strings.Contains(err.Error(), "state directory") {
		t.Fatalf("expected unavailable state directory error, got %v", err)
	}
}

func TestGenerateExplicitModeRuleBeforeTailscalePreferredRoute(t *testing.T) {
	p := &Profile{
		Lines: []Line{
			{ID: "direct", Name: "直连", Type: LineTypeDirect, Enabled: true},
			{ID: "vpn", Name: "VPN", Type: LineTypeVPN, Enabled: true, VPNServer: "vpn.example.com:8443"},
			{ID: "ts", Name: "Tailnet", Type: LineTypeTailscale, Enabled: true, TailscaleExitNode: "exit-node"},
		},
		RuleSets: []RuleSet{
			{ID: "internal", Name: "内部域名", Type: RuleSetTypeManual, Enabled: true, Domains: []string{"corp.example.com"}},
		},
		Modes: []Mode{{
			ID: "split", Name: "分流",
			Bindings:      []RuleBinding{{RuleSetID: "internal", LineID: "vpn"}},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "split",
	}

	data, err := GenerateSingBoxFor(p, 10800, "", PlatformMacOS, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}

	explicitIndex, preferredIndex := -1, -1
	for i, rawRule := range cfg.Route["rules"].([]interface{}) {
		rule := rawRule.(map[string]interface{})
		if rule["outbound"] == "vpn" {
			if domains, ok := rule["domain_suffix"].([]interface{}); ok && len(domains) == 1 && domains[0] == "corp.example.com" {
				explicitIndex = i
			}
		}
		if rule["preferred_by"] == "tailscale-ts" {
			preferredIndex = i
		}
	}
	if explicitIndex < 0 || preferredIndex < 0 {
		t.Fatalf("expected explicit VPN and Tailscale preferred rules, got %v", cfg.Route["rules"])
	}
	if explicitIndex >= preferredIndex {
		t.Fatalf("explicit VPN rule at %d must precede Tailscale preferred route at %d", explicitIndex, preferredIndex)
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

func TestGenerateNERejectsMultipleActiveAnyConnectLines(t *testing.T) {
	profile := &Profile{
		Lines: []Line{
			{ID: "direct", Type: LineTypeDirect, Enabled: true},
			{ID: "vpn-a", Type: LineTypeVPN, Enabled: true},
			{ID: "vpn-b", Type: LineTypeVPN, Enabled: true},
		},
		RuleSets: []RuleSet{
			{ID: "internal", Type: RuleSetTypeManual, Enabled: true, Domains: []string{"corp.example.com"}},
		},
		Modes: []Mode{{
			ID: "mode", DefaultLineID: "vpn-a",
			Bindings: []RuleBinding{{RuleSetID: "internal", LineID: "vpn-b"}},
		}},
		ActiveModeID: "mode",
	}

	if _, err := GenerateSingBoxFor(profile, 0, "", PlatformNE, t.TempDir()); err == nil || !strings.Contains(err.Error(), "only one") {
		t.Fatalf("expected multiple-AnyConnect error, got %v", err)
	}

	profile.Modes[0].Bindings[0].LineID = "vpn-a"
	if _, err := GenerateSingBoxFor(profile, 0, "", PlatformNE, t.TempDir()); err != nil {
		t.Fatalf("same AnyConnect line referenced twice should be allowed: %v", err)
	}

	profile.Modes[0].Bindings[0].LineID = "vpn-b"
	profile.RuleSets[0].Enabled = false
	if _, err := GenerateSingBoxFor(profile, 0, "", PlatformNE, t.TempDir()); err != nil {
		t.Fatalf("disabled rule must not create an AnyConnect conflict: %v", err)
	}
}
