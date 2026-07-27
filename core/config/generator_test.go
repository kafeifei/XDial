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

// isTailnetRouteRule 判断一条 route 规则是不是「tailnet 内部网段 → 该 endpoint」。
// IPv4 CGNAT 与 IPv6 ULA 缺一不可：双栈客户端优先取 AAAA，只写 IPv4 会走 direct 黑洞。
func isTailnetRouteRule(rule map[string]interface{}, endpointTag string) bool {
	cidrs, ok := rule["ip_cidr"].([]interface{})
	if !ok || len(cidrs) != 2 {
		return false
	}
	return cidrs[0] == "100.64.0.0/10" && cidrs[1] == "fd7a:115c:a1e0::/48" &&
		rule["outbound"] == endpointTag
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
	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}
	if _, exists := cfg.Inbounds[0]["route_exclude_address"]; exists {
		t.Fatal("desktop TUN excludes a VPN server address that was not requested")
	}
	if cfg.Inbounds[0]["stack"] != "system" || cfg.Inbounds[0]["auto_route"] != true {
		t.Fatalf("desktop TUN must keep the auto_route/system stack: %v", cfg.Inbounds[0])
	}
	// 桌面 DNS 必须 hijack 后由 sing-box 应答，绝不原样转发：系统 DNS 可能
	// 指向官方 Tailscale 的 100.100.100.100，转发到物理口 = 整机断网。
	hijackFound := false
	for _, rawRule := range cfg.Route["rules"].([]interface{}) {
		rule := rawRule.(map[string]interface{})
		if rule["protocol"] == "dns" {
			if rule["action"] != "hijack-dns" {
				t.Fatalf("desktop DNS packets must be hijacked, got %v", rule)
			}
			hijackFound = true
		}
	}
	if !hijackFound {
		t.Fatal("desktop DNS hijack rule is missing")
	}
	if cfg.DNS["final"] != "public-dns" {
		t.Fatalf("desktop DNS final must be the direct-IP DoH resolver: %v", cfg.DNS["final"])
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
			{ID: "../../work", Name: "Tailnet", Type: LineTypeTailscale, Enabled: true},
		},
		Modes:        []Mode{{ID: "tailnet", Name: "Tailnet", DefaultLineID: "direct"}},
		ActiveModeID: "tailnet",
		Tailscale:    TailscaleIdentity{Hostname: "xdial-mac"},
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
	if endpoint["hostname"] != "xdial-mac" {
		t.Fatalf("tailscale hostname missing: %v", endpoint)
	}
	// 身份是全局的：设备名来自 Profile.Tailscale，不再是 Line 的字段。
	if _, exists := endpoint["ephemeral"]; exists {
		t.Fatalf("tailscale endpoint must be a persistent node (ephemeral loses identity between sessions): %v", endpoint)
	}
	// accept_routes 会把 peer 广播的子网路由拉进来，与「Tailscale 只是一条出口线路」
	// 的定位冲突（还可能和本地网段撞上），必须不出现。
	if _, exists := endpoint["accept_routes"]; exists {
		t.Fatalf("tailscale endpoint must not accept peer routes: %v", endpoint)
	}
	// XDial 是工具，不提供网络出口，任何 advertise 都不能出现。
	for _, key := range []string{"advertise_routes", "advertise_exit_node", "advertise_tags"} {
		if _, exists := endpoint[key]; exists {
			t.Fatalf("tailscale endpoint must not advertise anything, got %s: %v", key, endpoint)
		}
	}
	stateDirectory, _ := endpoint["state_directory"].(string)
	if stateDirectory != "/Library/Application Support/XDial/tailscale" {
		t.Fatalf("tailscale state must live in one global directory, got %q", stateDirectory)
	}

	for _, outbound := range cfg.Outbounds {
		if outbound["tag"] == "vpn" {
			t.Fatal("tailscale-only profile must not generate VPN outbound")
		}
	}
	// Tailscale 只自动接管 tailnet 内部网段；exit node 广播的
	// 0.0.0.0/0 绝不隐式全捞（会让模式默认出口失效）。想默认走 exit node，
	// 把模式默认线路设为 Tailscale 线路即可（见 TestGenerateTailscaleExitNodeAsDefault）。
	tailnetRouteFound := false
	for _, rawRule := range cfg.Route["rules"].([]interface{}) {
		rule := rawRule.(map[string]interface{})
		if _, exists := rule["preferred_by"]; exists {
			t.Fatalf("exit-node routes must not be implicitly grabbed: %v", rule)
		}
		if isTailnetRouteRule(rule, "tailscale-../../work") {
			tailnetRouteFound = true
		}
	}
	if !tailnetRouteFound {
		t.Fatal("tailnet internal CGNAT route is missing")
	}
	servers := cfg.DNS["servers"].([]interface{})
	if len(servers) != 3 || servers[2].(map[string]interface{})["type"] != "tailscale" {
		t.Fatalf("tailscale DNS missing: %v", servers)
	}
	if servers[2].(map[string]interface{})["accept_default_resolvers"] != false {
		t.Fatalf("tailscale DNS must explicitly disable default resolvers: %v", servers[2])
	}
	// tailnet 名字之外的解析回落 IP 直连 DoH，绝不依赖系统 DNS（黑洞风险）。
	if cfg.DNS["final"] != "public-dns" {
		t.Fatalf("desktop DNS final must be the direct-IP DoH resolver: %v", cfg.DNS["final"])
	}
}

func TestGenerateNETailscaleEndpoint(t *testing.T) {
	basePath := t.TempDir()
	p := &Profile{
		Lines: []Line{
			{ID: "direct", Name: "直连", Type: LineTypeDirect, Enabled: true},
			{
				ID: "mobile-tailnet", Name: "Tailnet", Type: LineTypeTailscale, Enabled: true,
				TailscaleExitNode: "exit-node",
			},
		},
		Modes:        []Mode{{ID: "tailnet", Name: "Tailnet", DefaultLineID: "direct"}},
		ActiveModeID: "tailnet",
		Tailscale:    TailscaleIdentity{Hostname: "xdial-mobile"},
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
	if endpoint["state_directory"] != TailscaleStateDirectory(basePath) {
		t.Fatalf("state directory must remain inside the writable base path: %v", endpoint["state_directory"])
	}
	if endpoint["hostname"] != "xdial-mobile" || endpoint["exit_node"] != "exit-node" {
		t.Fatalf("mobile tailscale options differ from desktop: %v", endpoint)
	}
	if _, exists := endpoint["ephemeral"]; exists {
		t.Fatalf("mobile tailscale endpoint must also be a persistent node: %v", endpoint)
	}
	if _, exists := endpoint["accept_routes"]; exists {
		t.Fatalf("mobile tailscale endpoint must not accept peer routes: %v", endpoint)
	}

	// 移动端与桌面端保持相同语义：只接管 tailnet 内部网段。
	tailnetRouteFound := false
	for _, rawRule := range cfg.Route["rules"].([]interface{}) {
		rule := rawRule.(map[string]interface{})
		if _, exists := rule["preferred_by"]; exists {
			t.Fatalf("exit-node routes must not be implicitly grabbed: %v", rule)
		}
		if isTailnetRouteRule(rule, "tailscale-mobile-tailnet") {
			tailnetRouteFound = true
		}
	}
	if !tailnetRouteFound {
		t.Fatal("mobile tailnet internal CGNAT route is missing")
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

// 多 endpoint 的 DNS 绑定不能串台。生成器层面现在只会给出一个 endpoint
// （见 TestGenerateRejectsMultipleEnabledTailscaleLines），所以直接测 buildNEDNS。
func TestBuildNEDNSKeepsTailscaleBindingsIsolated(t *testing.T) {
	dns := buildNEDNS([]string{"tailscale-tail-a", "tailscale-tail-b"})
	servers := dns["servers"].([]map[string]interface{})
	if len(servers) != 4 {
		t.Fatalf("expected public + two Tailscale + dispatcher servers, got %v", servers)
	}
	dispatcher := servers[len(servers)-1]
	bindings := dispatcher["tailscale"].([]map[string]interface{})
	if len(bindings) != 2 {
		t.Fatalf("每个 endpoint 都要有自己的 DNS transport: %v", bindings)
	}
	seen := make(map[string]string)
	for _, binding := range bindings {
		seen[binding["endpoint"].(string)] = binding["server"].(string)
	}
	if seen["tailscale-tail-a"] != mobileTailscaleDNSTag("tailscale-tail-a") ||
		seen["tailscale-tail-b"] != mobileTailscaleDNSTag("tailscale-tail-b") {
		t.Fatalf("Tailscale DNS bindings crossed endpoints: %v", seen)
	}
}

// Tailscale 身份（state_directory / node key）全 Profile 一份，两条 enabled 线路
// 会生成两个抢同一目录的 endpoint —— 生成阶段就必须拒绝，而不是让它"起来但连不通"。
func TestGenerateRejectsMultipleEnabledTailscaleLines(t *testing.T) {
	p := &Profile{
		Lines: []Line{
			{ID: "direct", Type: LineTypeDirect, Enabled: true},
			{ID: "tail-a", Type: LineTypeTailscale, Enabled: true},
			{ID: "tail-b", Type: LineTypeTailscale, Enabled: true},
		},
		Modes:        []Mode{{ID: "mode", DefaultLineID: "direct"}},
		ActiveModeID: "mode",
	}

	for _, platform := range []Platform{PlatformMacOS, PlatformNE} {
		if _, err := GenerateSingBoxFor(p, 0, "", platform, t.TempDir()); err == nil ||
			!strings.Contains(err.Error(), "only one enabled Tailscale line") {
			t.Fatalf("platform %v: expected multiple-Tailscale error, got %v", platform, err)
		}
	}

	// 停用其中一条即可恢复：未启用的线路不生成 endpoint，也就不抢目录。
	p.Lines[2].Enabled = false
	for _, platform := range []Platform{PlatformMacOS, PlatformNE} {
		if _, err := GenerateSingBoxFor(p, 0, "", platform, t.TempDir()); err != nil {
			t.Fatalf("platform %v: single enabled Tailscale line must be accepted: %v", platform, err)
		}
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

// Tailscale 的自动接管范围只有 tailnet 内部网段（100.64/10）。设计定案
// （2026-07-26，来回三次的最终结论）：
//   - exit node 广播的 0.0.0.0/0 绝不隐式全捞（preferred_by）——那会让
//     「模式默认出口」永远失效，用户配的"默认直连"被整个抢走；
//   - 想让默认流量走 exit node，把模式默认线路设为 Tailscale 线路（final
//     即 endpoint tag，见 TestGenerateTailscaleExitNodeAsDefault）；
//   - 100.64/10 必须接管，否则按 MagicDNS 名字访问 tailnet 设备会走 direct 黑洞。
func TestTailscaleRoutesOnlyTailnetCIDR(t *testing.T) {
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

	explicitFound, tailnetFound := false, false
	for _, rawRule := range cfg.Route["rules"].([]interface{}) {
		rule := rawRule.(map[string]interface{})
		if _, exists := rule["preferred_by"]; exists {
			t.Fatalf("exit-node routes must not be implicitly grabbed: %v", rule)
		}
		if rule["outbound"] == "vpn" {
			if domains, ok := rule["domain_suffix"].([]interface{}); ok && len(domains) == 1 && domains[0] == "corp.example.com" {
				explicitFound = true
			}
		}
		if isTailnetRouteRule(rule, "tailscale-ts") {
			tailnetFound = true
		}
	}
	if !explicitFound {
		t.Fatalf("expected the explicit VPN rule to survive, got %v", cfg.Route["rules"])
	}
	if !tailnetFound {
		t.Fatalf("tailnet internal CGNAT route is missing: %v", cfg.Route["rules"])
	}
	// final 归模式所有：默认直连不被 exit node 抢走。
	if cfg.Route["final"] != "direct" {
		t.Fatalf("mode default outbound must remain direct, got %v", cfg.Route["final"])
	}
}

// 企业内网域名（绑定到 AnyConnect 线路的手动规则集）的解析必须交给服务端
// 下发的企业 DNS、且查询经隧道出去：真内网名（如 oa.corp.example）在公共 DNS 上是
// NXDOMAIN（2026-07-26 实测），解析不出来内网就"不通"。
func TestGenerateDesktopRoutesEnterpriseDomainsToVPNDNS(t *testing.T) {
	p := testProfile()
	p.ActiveModeID = "overseas" // internal → vpn

	data, err := GenerateSingBoxDesktop(p, 10800, "1.2.3.4", t.TempDir(), []string{"10.8.0.10", "10.8.0.11"})
	if err != nil {
		t.Fatal(err)
	}
	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}

	var enterprise map[string]interface{}
	for _, rawServer := range cfg.DNS["servers"].([]interface{}) {
		server := rawServer.(map[string]interface{})
		if server["tag"] == "enterprise-dns" {
			enterprise = server
		}
	}
	if enterprise == nil {
		t.Fatalf("enterprise DNS server missing: %v", cfg.DNS["servers"])
	}
	if enterprise["server"] != "10.8.0.10" || enterprise["detour"] != "vpn" {
		t.Fatalf("enterprise DNS must query the pushed resolver through the tunnel: %v", enterprise)
	}
	// 桌面的 vpn outbound 是只支持 CONNECT 的本地 SOCKS 桥：UDP 会假成功后丢包，
	// 而带 server 的 DNS 规则命中后不回落 final，内网域名会卡满超时再 SERVFAIL。
	if enterprise["type"] != "tcp" {
		t.Fatalf("enterprise DNS must go over TCP through the SOCKS bridge: %v", enterprise)
	}
	// public-dns 对内网名的 NXDOMAIN 不能被 enterprise-dns / tailscale-dns 共用。
	if cfg.DNS["independent_cache"] != true {
		t.Fatalf("desktop DNS cache must be per-server: %v", cfg.DNS)
	}

	rules, _ := cfg.DNS["rules"].([]interface{})
	ruleFound := false
	for _, rawRule := range rules {
		rule := rawRule.(map[string]interface{})
		if rule["server"] == "enterprise-dns" {
			domains, _ := rule["domain_suffix"].([]interface{})
			if len(domains) == 2 && domains[0] == "example.com" && domains[1] == "internal.corp" {
				ruleFound = true
			}
		}
	}
	if !ruleFound {
		t.Fatalf("VPN-bound domains must resolve via enterprise DNS: %v", rules)
	}

	// 没有企业 DNS 时（未连 AnyConnect / 服务端没下发）不得生成半残配置。
	data, err = GenerateSingBoxDesktop(p, 10800, "1.2.3.4", t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "enterprise-dns") {
		t.Fatal("enterprise DNS must be omitted when the tunnel pushed none")
	}
}

// splitProfileWithTailscale 是用户的真实组合：内网手动规则→AnyConnect，
// gfwlist（URL 规则集）→Tailscale 出口，其余直连。
func splitProfileWithTailscale() *Profile {
	return &Profile{
		Lines: []Line{
			{ID: "direct", Name: "直连", Type: LineTypeDirect, Enabled: true},
			{ID: "vpn", Name: "Corp VPN", Type: LineTypeVPN, Enabled: true, VPNServer: "vpn.example.com:8443"},
			{ID: "ts", Name: "Tailnet", Type: LineTypeTailscale, Enabled: true, TailscaleExitNode: "irvine"},
		},
		RuleSets: []RuleSet{
			{ID: "internal", Name: "内网", Type: RuleSetTypeManual, Enabled: true,
				Domains: []string{"corp.example"}},
			{ID: "gfw", Name: "GFW", Type: RuleSetTypeURL, Enabled: true,
				URL: "https://example.com/geosite-gfw.srs"},
			{ID: "oversea", Name: "手动出海", Type: RuleSetTypeManual, Enabled: true,
				Domains: []string{"example.org"}},
		},
		Modes: []Mode{{
			ID: "split", Name: "分流",
			Bindings: []RuleBinding{
				{RuleSetID: "internal", LineID: "vpn"},
				{RuleSetID: "gfw", LineID: "ts"},
				{RuleSetID: "oversea", LineID: "ts"},
			},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "split",
		Tailscale:    TailscaleIdentity{Hostname: "xdial-mac"},
	}
}

// 绑到代理型线路的域名，解析也必须经该线路出去。在本地问境内公共 DNS 拿到的是
// 污染结果，再从境外出口连过去 —— 分流白做，还会连到墙给的假地址。
func TestGenerateDesktopResolvesProxyBoundDomainsThroughTheLine(t *testing.T) {
	data, err := GenerateSingBoxDesktop(splitProfileWithTailscale(), 10800, "1.2.3.4", t.TempDir(), []string{"10.8.0.10"})
	if err != nil {
		t.Fatal(err)
	}
	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}

	// 同一条线路只生成一个 DoH server，两个规则集共用。
	var proxyServers []map[string]interface{}
	for _, rawServer := range cfg.DNS["servers"].([]interface{}) {
		server := rawServer.(map[string]interface{})
		if tag, _ := server["tag"].(string); strings.HasPrefix(tag, "proxy-dns-") {
			proxyServers = append(proxyServers, server)
		}
	}
	if len(proxyServers) != 1 {
		t.Fatalf("expected exactly one per-line resolver, got %v", proxyServers)
	}
	proxy := proxyServers[0]
	if proxy["tag"] != "proxy-dns-tailscale-ts" || proxy["type"] != "https" ||
		proxy["server"] != "1.1.1.1" || proxy["detour"] != "tailscale-ts" {
		t.Fatalf("per-line resolver must be a DoH query sent through the line: %v", proxy)
	}

	rules := cfg.DNS["rules"].([]interface{})
	if len(rules) != 4 {
		t.Fatalf("expected enterprise + two proxy + tailnet rules, got %v", rules)
	}
	// 顺序是语义的一部分：内网名先归企业 DNS，代理域名次之，tailnet 兜底最后。
	if rules[0].(map[string]interface{})["server"] != "enterprise-dns" {
		t.Fatalf("enterprise rule must come first: %v", rules)
	}
	urlRule := rules[1].(map[string]interface{})
	if urlRule["server"] != "proxy-dns-tailscale-ts" || urlRule["rule_set"] != "ruleset-gfw" {
		t.Fatalf("URL rule set must reuse the downloaded rule_set resource: %v", urlRule)
	}
	manualRule := rules[2].(map[string]interface{})
	domains, _ := manualRule["domain_suffix"].([]interface{})
	if manualRule["server"] != "proxy-dns-tailscale-ts" ||
		len(domains) != 1 || domains[0] != "example.org" {
		t.Fatalf("manual rule set must be inlined as domain suffixes: %v", manualRule)
	}
	tailnetRule := rules[3].(map[string]interface{})
	if tailnetRule["ip_accept_any"] != true || tailnetRule["server"] != "tailscale-dns" {
		t.Fatalf("tailnet fallback must stay last: %v", tailnetRule)
	}
}

// direct 不算承载线路：它本就要本地视角。绑到 vpn 的手动规则集归 enterprise-dns。
func TestGenerateDesktopKeepsDirectBoundRuleSetsOnPublicDNS(t *testing.T) {
	p := splitProfileWithTailscale()
	p.Modes[0].Bindings = []RuleBinding{
		{RuleSetID: "internal", LineID: "vpn"},
		{RuleSetID: "gfw", LineID: "direct"},
		{RuleSetID: "oversea", LineID: "direct"},
	}

	data, err := GenerateSingBoxDesktop(p, 10800, "1.2.3.4", t.TempDir(), []string{"10.8.0.10"})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "proxy-dns-") {
		t.Fatalf("direct-bound rule sets must not get a tunneled resolver:\n%s", data)
	}
}

// 预设模式"国内"就是这个组合：gfwlist（URL 规则集）绑 AnyConnect 线路。
// 它既不是内网名（enterprise-dns 只收手动规则集），又曾被当作"vpn 不是代理线路"
// 跳过，于是落到 final 的境内解析器上被污染 —— 分流白做。
func TestGenerateDesktopResolvesVPNBoundURLRuleSetThroughTheTunnel(t *testing.T) {
	p := splitProfileWithTailscale()
	p.Modes[0].Bindings = []RuleBinding{
		{RuleSetID: "internal", LineID: "vpn"},
		{RuleSetID: "gfw", LineID: "vpn"},
	}

	data, err := GenerateSingBoxDesktop(p, 10800, "1.2.3.4", t.TempDir(), []string{"10.8.0.10"})
	if err != nil {
		t.Fatal(err)
	}
	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}

	var vpnResolver map[string]interface{}
	for _, rawServer := range cfg.DNS["servers"].([]interface{}) {
		server := rawServer.(map[string]interface{})
		if server["tag"] == "proxy-dns-vpn" {
			vpnResolver = server
		}
	}
	if vpnResolver == nil {
		t.Fatalf("URL rule set bound to the AnyConnect line has no resolver:\n%s", data)
	}
	// DoH 而非 UDP：桌面的 vpn outbound 是只实现了 CONNECT 的本地 go-socks5 桥。
	if vpnResolver["type"] != "https" || vpnResolver["server"] != "1.1.1.1" ||
		vpnResolver["detour"] != "vpn" {
		t.Fatalf("VPN-bound resolver must be DoH through the tunnel: %v", vpnResolver)
	}

	rules := cfg.DNS["rules"].([]interface{})
	if len(rules) != 3 {
		t.Fatalf("expected enterprise + vpn-url + tailnet rules, got %v", rules)
	}
	enterpriseRule := rules[0].(map[string]interface{})
	if enterpriseRule["server"] != "enterprise-dns" {
		t.Fatalf("enterprise rule must come first: %v", rules)
	}
	// 手动规则集仍然只归企业 DNS：内网名只有它有记录。
	domains, _ := enterpriseRule["domain_suffix"].([]interface{})
	if len(domains) != 1 || domains[0] != "corp.example" {
		t.Fatalf("manual rule set bound to vpn must stay on enterprise-dns: %v", enterpriseRule)
	}
	urlRule := rules[1].(map[string]interface{})
	if urlRule["server"] != "proxy-dns-vpn" || urlRule["rule_set"] != "ruleset-gfw" {
		t.Fatalf("URL rule set must resolve through the VPN resolver: %v", urlRule)
	}
}

// 桌面 tun 必须双栈：sing-tun 的 auto_route 没有 IPv6 地址就一条 IPv6 路由都不装，
// IPv6 流量整体绕过 XDial —— tailnet 的 fd7a:115c:a1e0::/48 规则永不求值，
// 经隧道解出的未污染 AAAA 反而被系统拿去直连。
func TestGenerateDesktopTUNCapturesIPv6(t *testing.T) {
	data, err := GenerateSingBox(testProfile(), 10800, "1.2.3.4")
	if err != nil {
		t.Fatal(err)
	}
	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}
	addresses, _ := cfg.Inbounds[0]["address"].([]interface{})
	if len(addresses) != 2 || addresses[0] != "198.18.0.1/15" || addresses[1] != "fd00::1/126" {
		t.Fatalf("desktop TUN must be dual-stack: %v", addresses)
	}
}

// 规则集要从它自己所描述的路径上下载，硬编码 direct 就是从被墙链路取 gfwlist；
// 首次下载失败是硬失败（sing-box router 启动即 FATAL），不是降级。
func TestGenerateRuleSetDownloadDetourFollowsBinding(t *testing.T) {
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
	sets := cfg.Route["rule_set"].([]interface{})
	if len(sets) != 1 {
		t.Fatalf("expected the gfw rule set only, got %v", sets)
	}
	set := sets[0].(map[string]interface{})
	if set["tag"] != "ruleset-gfw" || set["download_detour"] != "proxy-ss" {
		t.Fatalf("rule set must download through its bound line: %v", set)
	}
}

// Tailscale endpoint 不能当 download_detour：tsnet server 在 StartStatePostStart
// 才启动，而 rule_set 首次下载在更早的 StartStateStart，那时 dial 必然失败。
// direct / vpn 绑定同样退回 direct。
func TestGenerateRuleSetDownloadDetourFallsBackToDirect(t *testing.T) {
	for _, tc := range []struct {
		name   string
		lineID string
	}{
		{"tailscale", "ts"},
		{"vpn", "vpn"},
		{"direct", "direct"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			p := splitProfileWithTailscale()
			p.Modes[0].Bindings = []RuleBinding{{RuleSetID: "gfw", LineID: tc.lineID}}

			data, err := GenerateSingBox(p, 10800, "1.2.3.4")
			if err != nil {
				t.Fatal(err)
			}
			var cfg SingBoxConfig
			if err := json.Unmarshal(data, &cfg); err != nil {
				t.Fatal(err)
			}
			set := cfg.Route["rule_set"].([]interface{})[0].(map[string]interface{})
			if set["download_detour"] != "direct" {
				t.Fatalf("expected direct download detour, got %v", set)
			}
		})
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
