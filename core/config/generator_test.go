package config

import (
	"encoding/json"
	"fmt"
	"reflect"
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
		Scenarios: []Scenario{
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
		ActiveScenarioID: "overseas",
	}
}

func isMagicDNSRouteRule(rule map[string]interface{}, endpointTag string) bool {
	return rule["preferred_by"] == endpointTag && rule["outbound"] == endpointTag
}

func sliceContainsString(values []interface{}, expected string) bool {
	for _, value := range values {
		if value == expected {
			return true
		}
	}
	return false
}

func TestProfileFinders(t *testing.T) {
	p := testProfile()
	if e := p.FindLine("vpn"); e == nil || e.Name != "VPN" {
		t.Fatal("FindLine(vpn) failed")
	}
	if r := p.FindRuleSet("gfw"); r == nil || r.URL == "" {
		t.Fatal("FindRuleSet(gfw) failed")
	}
	if s := p.ActiveScenario(); s == nil || s.Name != "海外" {
		t.Fatal("ActiveScenario failed")
	}
	if v := p.VPNLine(); v == nil || v.VPNServer == "" {
		t.Fatal("VPNLine failed")
	}
}

func TestBuildAnyTLSOutbound(t *testing.T) {
	line := &Line{
		ID:                             "anytls",
		Type:                           LineTypeAnyTLS,
		Enabled:                        true,
		AnyTLSServer:                   "anytls.example.com",
		AnyTLSPort:                     443,
		AnyTLSPassword:                 "secret",
		AnyTLSSNI:                      "edge.example.com",
		AllowInsecure:                  true,
		UDP:                            true,
		AnyTLSClientFingerprint:        "chrome",
		AnyTLSALPN:                     []string{"h2"},
		AnyTLSIdleSessionCheckInterval: 30,
		AnyTLSIdleSessionTimeout:       30,
	}

	outbound := buildProxyOutbound(line)
	if outbound == nil {
		t.Fatal("expected AnyTLS outbound")
	}
	if outbound["type"] != "anytls" ||
		outbound["tag"] != "proxy-anytls" ||
		outbound["server"] != "anytls.example.com" ||
		outbound["server_port"] != 443 ||
		outbound["password"] != "secret" {
		t.Fatalf("unexpected AnyTLS outbound: %+v", outbound)
	}
	tls, ok := outbound["tls"].(map[string]interface{})
	if !ok || tls["enabled"] != true ||
		tls["server_name"] != "edge.example.com" ||
		tls["insecure"] != true {
		t.Fatalf("unexpected AnyTLS TLS options: %+v", outbound["tls"])
	}
	alpn, ok := tls["alpn"].([]string)
	if !ok || len(alpn) != 1 || alpn[0] != "h2" {
		t.Fatalf("unexpected AnyTLS ALPN: %+v", tls["alpn"])
	}
	utls, ok := tls["utls"].(map[string]interface{})
	if !ok || utls["enabled"] != true || utls["fingerprint"] != "chrome" {
		t.Fatalf("unexpected AnyTLS uTLS options: %+v", tls["utls"])
	}
	if outbound["idle_session_check_interval"] != "30s" ||
		outbound["idle_session_timeout"] != "30s" {
		t.Fatalf("unexpected AnyTLS idle session options: %+v", outbound)
	}
	if _, exists := outbound["min_idle_session"]; exists {
		t.Fatal("AnyTLS min_idle_session=0 must keep the upstream default")
	}
	if _, exists := outbound["tcp_fast_open"]; exists {
		t.Fatal("AnyTLS outbound must not enable TCP Fast Open")
	}
	if _, exists := outbound["udp_over_tcp"]; exists {
		t.Fatal("AnyTLS uses native UoT and must not emit generic udp_over_tcp")
	}
}

func TestBuildAnyTLSOutboundDefaultsSNIAndRejectsTFO(t *testing.T) {
	line := &Line{
		ID:             "anytls",
		Type:           LineTypeAnyTLS,
		Enabled:        true,
		AnyTLSServer:   "anytls.example.com",
		AnyTLSPort:     443,
		AnyTLSPassword: "secret",
	}
	outbound := buildProxyOutbound(line)
	tls, ok := outbound["tls"].(map[string]interface{})
	if !ok || tls["server_name"] != "anytls.example.com" {
		t.Fatalf("AnyTLS SNI should default to server: %+v", outbound)
	}
	if _, exists := tls["utls"]; exists {
		t.Fatal("legacy AnyTLS line must not enable uTLS implicitly")
	}
	if _, exists := tls["alpn"]; exists {
		t.Fatal("legacy AnyTLS line must not gain an implicit ALPN")
	}
	if _, exists := outbound["idle_session_check_interval"]; exists {
		t.Fatal("legacy AnyTLS line must keep the upstream idle check default")
	}
	if _, exists := outbound["idle_session_timeout"]; exists {
		t.Fatal("legacy AnyTLS line must keep the upstream idle timeout default")
	}

	line.TFO = true
	if outbound := buildProxyOutbound(line); outbound != nil {
		t.Fatalf("AnyTLS with TFO must be unavailable: %+v", outbound)
	}
}

func TestBuildAnyTLSOutboundValidatesBoundaries(t *testing.T) {
	base := Line{
		ID:             "anytls",
		Type:           LineTypeAnyTLS,
		Enabled:        true,
		AnyTLSServer:   "anytls.example.com",
		AnyTLSPort:     443,
		AnyTLSPassword: "secret",
	}
	tests := []struct {
		name   string
		mutate func(*Line)
	}{
		{
			name: "unknown fingerprint",
			mutate: func(line *Line) {
				line.AnyTLSClientFingerprint = "chrome-unknown"
			},
		},
		{
			name: "empty ALPN",
			mutate: func(line *Line) {
				line.AnyTLSALPN = []string{""}
			},
		},
		{
			name: "control character in ALPN",
			mutate: func(line *Line) {
				line.AnyTLSALPN = []string{"h2\n"}
			},
		},
		{
			name: "invalid UTF-8 in ALPN",
			mutate: func(line *Line) {
				line.AnyTLSALPN = []string{string([]byte{0xff})}
			},
		},
		{
			name: "overlong ALPN",
			mutate: func(line *Line) {
				line.AnyTLSALPN = []string{strings.Repeat("a", maxAnyTLSALPNProtocolBytes+1)}
			},
		},
		{
			name: "too many ALPN protocols",
			mutate: func(line *Line) {
				line.AnyTLSALPN = []string{
					"h2", "http/1.1", "h3", "mqtt", "acme-tls/1",
					"dot", "custom-1", "custom-2", "custom-3",
				}
			},
		},
		{
			name: "duplicate ALPN",
			mutate: func(line *Line) {
				line.AnyTLSALPN = []string{"h2", "h2"}
			},
		},
		{
			name: "idle check interval below runtime minimum",
			mutate: func(line *Line) {
				line.AnyTLSIdleSessionCheckInterval = minAnyTLSDurationSeconds - 1
			},
		},
		{
			name: "idle check interval overflow",
			mutate: func(line *Line) {
				line.AnyTLSIdleSessionCheckInterval = int(maxAnyTLSDurationSeconds + 1)
			},
		},
		{
			name: "idle timeout below runtime minimum",
			mutate: func(line *Line) {
				line.AnyTLSIdleSessionTimeout = minAnyTLSDurationSeconds - 1
			},
		},
		{
			name: "idle timeout overflow",
			mutate: func(line *Line) {
				line.AnyTLSIdleSessionTimeout = int(maxAnyTLSDurationSeconds + 1)
			},
		},
		{
			name: "negative minimum idle sessions",
			mutate: func(line *Line) {
				line.AnyTLSMinIdleSession = -1
			},
		},
		{
			name: "too many minimum idle sessions",
			mutate: func(line *Line) {
				line.AnyTLSMinIdleSession = maxAnyTLSMinIdleSession + 1
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			line := base
			test.mutate(&line)
			if outbound := buildProxyOutbound(&line); outbound != nil {
				t.Fatalf("invalid AnyTLS options must be unavailable: %+v", outbound)
			}
		})
	}
}

func TestBuildAnyTLSOutboundAllowsSupportedFingerprintALPNAndIdlePool(t *testing.T) {
	line := &Line{
		ID:                             "anytls",
		Type:                           LineTypeAnyTLS,
		Enabled:                        true,
		AnyTLSServer:                   "anytls.example.com",
		AnyTLSPort:                     443,
		AnyTLSPassword:                 "secret",
		AnyTLSClientFingerprint:        "safari",
		AnyTLSALPN:                     []string{"http/1.1", "h2", "custom-protocol"},
		AnyTLSIdleSessionCheckInterval: minAnyTLSDurationSeconds,
		AnyTLSIdleSessionTimeout:       maxAnyTLSDurationSeconds,
		AnyTLSMinIdleSession:           2,
	}
	outbound := buildProxyOutbound(line)
	if outbound == nil {
		t.Fatal("supported AnyTLS boundary values must compile")
	}
	if outbound["idle_session_check_interval"] !=
		fmt.Sprintf("%ds", minAnyTLSDurationSeconds) ||
		outbound["idle_session_timeout"] !=
			fmt.Sprintf("%ds", maxAnyTLSDurationSeconds) ||
		outbound["min_idle_session"] != 2 {
		t.Fatalf("unexpected AnyTLS boundary output: %+v", outbound)
	}
}

func TestGenerateAnyTLSOnlyWhenReferencedByActiveScenario(t *testing.T) {
	profile := &Profile{
		Lines: []Line{
			{ID: "direct", Name: "Direct", Type: LineTypeDirect, Enabled: true},
			{
				ID:             "active-anytls",
				Name:           "Active AnyTLS",
				Type:           LineTypeAnyTLS,
				Enabled:        true,
				AnyTLSServer:   "active.example.com",
				AnyTLSPort:     443,
				AnyTLSPassword: "active-secret",
			},
			{
				ID:             "idle-anytls",
				Name:           "Idle AnyTLS",
				Type:           LineTypeAnyTLS,
				Enabled:        true,
				AnyTLSServer:   "idle.example.com",
				AnyTLSPort:     443,
				AnyTLSPassword: "idle-secret",
			},
		},
		Scenarios: []Scenario{{
			ID:            "scenario",
			Name:          "Scenario",
			DefaultLineID: "active-anytls",
		}},
		ActiveScenarioID: "scenario",
	}

	data, err := GenerateSingBox(profile, 0, "")
	if err != nil {
		t.Fatal(err)
	}
	text := string(data)
	if !strings.Contains(text, `"tag": "proxy-active-anytls"`) ||
		!strings.Contains(text, `"password": "active-secret"`) {
		t.Fatalf("active AnyTLS outbound is missing: %s", text)
	}
	if strings.Contains(text, "proxy-idle-anytls") ||
		strings.Contains(text, "idle.example.com") ||
		strings.Contains(text, "idle-secret") {
		t.Fatalf("unreferenced AnyTLS line leaked into generated config: %s", text)
	}
}

func TestBuildLineRuntimeCatalogIncludesTailscaleEndpointTag(t *testing.T) {
	profile := &Profile{Lines: []Line{
		{ID: "direct", Name: "Direct", Type: LineTypeDirect, Enabled: true},
		{ID: "tailnet", Name: "Tailnet", Type: LineTypeTailscale, Enabled: true},
		{ID: "disabled", Name: "Disabled", Type: LineTypeTrojan, Enabled: false},
	}}
	catalog := BuildLineRuntimeCatalog(profile)
	if len(catalog.Lines) != 2 {
		t.Fatalf("unexpected runtime line catalog: %+v", catalog)
	}
	if catalog.Lines[0].Tag != "direct" || catalog.Lines[1].Tag != "tailscale-tailnet" {
		t.Fatalf("runtime catalog drifted from generated tags: %+v", catalog)
	}
}

func TestGenerateWithManualRuleSet(t *testing.T) {
	p := testProfile()
	p.ActiveScenarioID = "overseas"

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
			t.Errorf("overseas scenario should not have rule_sets, got %d", len(sets))
		}
	}

	t.Log(string(data))
}

func TestGenerateWithURLRuleSet_SRS(t *testing.T) {
	p := testProfile()
	p.ActiveScenarioID = "domestic"

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
		t.Fatal("domestic scenario should have rule_sets")
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
	p.Scenarios = append(p.Scenarios, Scenario{
		ID: "with-cnip", Name: "含国内IP",
		Bindings: []RuleBinding{
			{RuleSetID: "cnip", LineID: "direct"},
		},
		DefaultLineID: "vpn",
	})
	p.ActiveScenarioID = "with-cnip"

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
	p.ActiveScenarioID = "domestic-ss"

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
	p.ActiveScenarioID = "overseas"
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
	p.ActiveScenarioID = "overseas"
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
	for index := range p.Scenarios {
		if p.Scenarios[index].ID == p.ActiveScenarioID {
			p.Scenarios[index].Bindings = append([]RuleBinding{
				{RuleSetID: connectivityDirectID, LineID: "direct"},
				{RuleSetID: connectivityAnyConnectID, LineID: "vpn"},
				{RuleSetID: "gfw", SubscriptionID: "probe-priority-sub"},
			}, p.Scenarios[index].Bindings...)
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
	p.ActiveScenarioID = "overseas"

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
	// 桌面 DNS 必须 hijack 后由 sing-box 应答，绝不原样转发：启动前 Underlay
	// 使用的 resolver 可能只在下层虚拟网络中可达，强制直出会形成解析黑洞。
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
		Scenarios:        []Scenario{{ID: "scenario", Name: "Scenario", DefaultSubscriptionID: "sub"}},
		ActiveScenarioID: "scenario",
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
		Scenarios:        []Scenario{{ID: "scenario", Name: "Scenario", DefaultSubscriptionID: "sub"}},
		ActiveScenarioID: "scenario",
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
		Scenarios:        []Scenario{{ID: "scenario", Name: "Scenario", DefaultSubscriptionID: "sub"}},
		ActiveScenarioID: "scenario",
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
	if catalog.Subscriptions[0].MainTag != group.Tag {
		t.Fatalf(
			"runtime catalog main tag = %q, want generated default group %q",
			catalog.Subscriptions[0].MainTag,
			group.Tag,
		)
	}
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
		Rules: []SubscriptionRule{
			{Type: "DOMAIN-SUFFIX", Value: "primary.example", Group: "香港节点"},
			{Type: "DOMAIN-SUFFIX", Value: "secondary.example", Group: "台湾节点"},
			{Type: "DOMAIN-SUFFIX", Value: "direct.example", Group: "DIRECT"},
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
	if entry.MainTag != entry.Groups[0].Tag {
		t.Fatalf("runtime catalog main tag = %q, want %q", entry.MainTag, entry.Groups[0].Tag)
	}
	if !reflect.DeepEqual(
		entry.ReadinessTags,
		[]string{entry.Groups[0].Tag, entry.Groups[1].Tag},
	) {
		t.Fatalf(
			"runtime readiness tags = %#v, want both route-visible groups",
			entry.ReadinessTags,
		)
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
	p.ActiveScenarioID = "overseas"

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
	p.ActiveScenarioID = "overseas"

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
	p.ActiveScenarioID = "overseas"

	// 旧签名(macOS 模式包装)与显式 PlatformMacOS 应产出完全一致的配置；
	// 显式路径传入同一份系统 Underlay 快照，且 basePath 在 macOS 模式下被忽略。
	viaWrapper, err := GenerateSingBox(p, 10800, "1.2.3.4")
	if err != nil {
		t.Fatal(err)
	}
	viaExplicit, err := GenerateSingBoxFor(p, 10800, "1.2.3.4", PlatformMacOS, "/should/be/ignored", "en0")
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
	if got := cfg.Route["default_interface"]; got != "en0" {
		t.Errorf("macOS route should forward the system Underlay snapshot, got %v", got)
	}
	if _, exists := cfg.Route["auto_detect_interface"]; exists {
		t.Error("desktop generator must not fall back to auto_detect_interface")
	}
	for _, outbound := range cfg.Outbounds {
		if _, exists := outbound["bind_interface"]; exists {
			t.Fatalf("desktop outbound must delegate Underlay selection to sing-box: %v", outbound)
		}
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

func TestGenerateDesktopTailscaleEndpoint(t *testing.T) {
	basePath := t.TempDir()
	p := &Profile{
		Lines: []Line{
			{ID: "direct", Name: "直连", Type: LineTypeDirect, Enabled: true},
			{
				ID: "ts", Name: "Tailnet", Type: LineTypeTailscale, Enabled: true,
				TailscaleExitNode: "exit-node",
				TailscaleAuthKey:  "must-not-be-persisted",
			},
		},
		Scenarios:        []Scenario{{ID: "tailnet", Name: "Tailnet", DefaultLineID: "ts"}},
		ActiveScenarioID: "tailnet",
		Tailscale:        TailscaleIdentity{Hostname: "xdial-desktop"},
	}

	data, err := GenerateSingBoxDesktop(p, 0, "", basePath, nil, "en0")
	if err != nil {
		t.Fatal(err)
	}
	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}
	if len(cfg.Endpoints) != 1 {
		t.Fatalf("expected one desktop Tailscale endpoint, got %d", len(cfg.Endpoints))
	}
	endpoint := cfg.Endpoints[0]
	if endpoint["type"] != "tailscale" ||
		endpoint["tag"] != "tailscale-ts" ||
		endpoint["state_directory"] != TailscaleStateDirectory(basePath) ||
		endpoint["hostname"] != "xdial-desktop" ||
		endpoint["exit_node"] != "exit-node" {
		t.Fatalf("unexpected desktop Tailscale endpoint: %v", endpoint)
	}
	if endpoint["system_interface"] != false || endpoint["accept_routes"] != false {
		t.Fatalf("desktop Tailscale endpoint must stay inside the existing sing-box layer: %v", endpoint)
	}
	for _, forbidden := range []string{"auth_key"} {
		if _, exists := endpoint[forbidden]; exists {
			t.Fatalf("desktop Tailscale endpoint must not contain %s: %v", forbidden, endpoint)
		}
	}
	selectorFound := false
	for _, outbound := range cfg.Outbounds {
		if outbound["tag"] != testSelectorTag {
			continue
		}
		selectorFound = true
		members := outbound["outbounds"].([]interface{})
		if !sliceContainsString(members, "tailscale-ts") {
			t.Fatalf("desktop diagnostic selector does not contain Tailscale endpoint: %v", outbound)
		}
	}
	if !selectorFound {
		t.Fatal("desktop diagnostic selector is missing")
	}
}

func TestGenerateNETailscaleEndpoint(t *testing.T) {
	basePath := t.TempDir()
	p := &Profile{
		Lines: []Line{
			{ID: "direct", Name: "直连", Type: LineTypeDirect, Enabled: true},
			{
				ID: "mobile-tailnet", Name: "Tailnet", Type: LineTypeTailscale, Enabled: true,
				TailscaleExitNode: "exit-node", TailscaleMagicDNS: true,
			},
		},
		// MagicDNS 只对被 active Scenario 引用且显式勾选的线路生成（INV1c）。
		Scenarios: []Scenario{{
			ID: "tailnet", Name: "Tailnet", DefaultLineID: "mobile-tailnet",
		}},
		ActiveScenarioID: "tailnet",
		Tailscale:        TailscaleIdentity{Hostname: "xdial-mobile"},
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
	if endpoint["system_interface"] != false || endpoint["accept_routes"] != false {
		t.Fatalf("mobile tailscale endpoint must stay inside the existing sing-box layer: %v", endpoint)
	}

	magicDNSRouteFound := false
	for _, rawRule := range cfg.Route["rules"].([]interface{}) {
		rule := rawRule.(map[string]interface{})
		if isMagicDNSRouteRule(rule, "tailscale-mobile-tailnet") {
			magicDNSRouteFound = true
			if _, hardcoded := rule["ip_cidr"]; hardcoded {
				t.Fatalf("MagicDNS route must come from the current NetMap: %v", rule)
			}
		}
	}
	if !magicDNSRouteFound {
		t.Fatal("mobile dynamic MagicDNS peer route is missing")
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
		tailscaleDNS["accept_default_resolvers"] != false ||
		tailscaleDNS["accept_search_domain"] != true {
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

func TestTailscaleMagicDNSOnUnreferencedLineHasNoSideEffects(t *testing.T) {
	profile := &Profile{
		Lines: []Line{
			{ID: "direct", Type: LineTypeDirect, Enabled: true},
			{ID: "tailnet", Type: LineTypeTailscale, Enabled: true, TailscaleMagicDNS: true},
		},
		Scenarios:        []Scenario{{ID: "scenario", DefaultLineID: "direct"}},
		ActiveScenarioID: "scenario",
	}
	data, err := GenerateSingBoxFor(profile, 0, "", PlatformNE, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), `"type": "tailscale"`) ||
		strings.Contains(string(data), `"preferred_by": "tailscale-tailnet"`) {
		t.Fatalf("unreferenced Tailscale MagicDNS changed the data plane:\n%s", data)
	}
}

func TestTailscaleLineWithoutMagicDNSToggleHasNoMagicDNSSideEffects(t *testing.T) {
	profile := &Profile{
		Lines: []Line{
			{ID: "direct", Type: LineTypeDirect, Enabled: true},
			{ID: "tailnet", Type: LineTypeTailscale, Enabled: true},
		},
		Scenarios: []Scenario{{
			ID: "scenario", DefaultLineID: "tailnet",
		}},
		ActiveScenarioID: "scenario",
	}

	data, err := GenerateSingBoxFor(profile, 0, "", PlatformNE, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}
	for _, rawServer := range cfg.DNS["servers"].([]interface{}) {
		server := rawServer.(map[string]interface{})
		if server["type"] == "tailscale" {
			t.Fatalf("Tailscale Line without the MagicDNS toggle registered a resolver: %v", server)
		}
	}
	for _, rawRule := range cfg.Route["rules"].([]interface{}) {
		rule := rawRule.(map[string]interface{})
		if isMagicDNSRouteRule(rule, "tailscale-tailnet") {
			t.Fatalf("Tailscale Line without the MagicDNS toggle registered peer routes: %v", rule)
		}
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

// Tailscale 身份（state_directory / node key）全 Profile 一份，两条 active 线路
// 会生成两个抢同一目录的 endpoint —— 生成阶段就必须拒绝，而不是让它"起来但连不通"。
func TestGenerateNERejectsMultipleActiveTailscaleLines(t *testing.T) {
	p := &Profile{
		Lines: []Line{
			{ID: "direct", Type: LineTypeDirect, Enabled: true},
			{ID: "tail-a", Type: LineTypeTailscale, Enabled: true},
			{ID: "tail-b", Type: LineTypeTailscale, Enabled: true},
		},
		RuleSets: []RuleSet{{
			ID: "tail-b-rules", Type: RuleSetTypeManual, Enabled: true,
			Domains: []string{"tail-b.example"},
		}},
		Scenarios: []Scenario{{
			ID: "scenario", DefaultLineID: "tail-a",
			Bindings: []RuleBinding{{RuleSetID: "tail-b-rules", LineID: "tail-b"}},
		}},
		ActiveScenarioID: "scenario",
	}

	if _, err := GenerateSingBoxFor(p, 0, "", PlatformNE, t.TempDir()); err == nil ||
		!strings.Contains(err.Error(), "only one active Tailscale line") {
		t.Fatalf("expected multiple-Tailscale error, got %v", err)
	}

	// 停用其中一条即可恢复：disabled 的线路不生成 endpoint，也就不抢目录。
	p.Lines[2].Enabled = false
	if _, err := GenerateSingBoxFor(p, 0, "", PlatformNE, t.TempDir()); err != nil {
		t.Fatalf("single active Tailscale line must be accepted on NE: %v", err)
	}
}

func TestGenerateNEWithoutTailscaleStillUsesMobileDNSDispatcher(t *testing.T) {
	p := &Profile{
		Lines:            []Line{{ID: "direct", Type: LineTypeDirect, Enabled: true}},
		Scenarios:        []Scenario{{ID: "scenario", DefaultLineID: "direct"}},
		ActiveScenarioID: "scenario",
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
		Scenarios:        []Scenario{{ID: "scenario", DefaultLineID: "ts"}},
		ActiveScenarioID: "scenario",
	}

	_, err := GenerateSingBoxFor(p, 0, "", PlatformNE, "relative")
	if err == nil || !strings.Contains(err.Error(), "state directory") {
		t.Fatalf("expected unavailable state directory error, got %v", err)
	}
}

// MagicDNS 的动态归属排在 Scenario 显式绑定之后：两者域名重叠时，
// 用户的 CDN / 企业线路决定必须获胜。peer 范围只来自 NetMap，不硬编码 CIDR。
func TestNETailscaleMagicDNSPreservesExplicitScenarioPriority(t *testing.T) {
	p := &Profile{
		Lines: []Line{
			{ID: "direct", Name: "直连", Type: LineTypeDirect, Enabled: true},
			{ID: "vpn", Name: "VPN", Type: LineTypeVPN, Enabled: true, VPNServer: "vpn.example.com:8443"},
			{ID: "ts", Name: "Tailnet", Type: LineTypeTailscale, Enabled: true, TailscaleExitNode: "exit-node", TailscaleMagicDNS: true},
		},
		RuleSets: []RuleSet{
			{ID: "cdn", Name: "CDN", Type: RuleSetTypeManual, Enabled: true, Domains: []string{"cdn.example.com"}},
			{ID: "peer", Name: "Peer", Type: RuleSetTypeManual, Enabled: true, Domains: []string{"peer.example.ts.net"}},
		},
		Scenarios: []Scenario{{
			ID: "split", Name: "分流",
			Bindings: []RuleBinding{
				{RuleSetID: "cdn", LineID: "vpn"},
				{RuleSetID: "peer", LineID: "ts"},
			},
			DefaultLineID: "direct",
		}},
		ActiveScenarioID: "split",
	}

	data, err := GenerateSingBoxFor(p, 10800, "", PlatformNE, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}

	explicitIndex, magicDNSIndex := -1, -1
	for index, rawRule := range cfg.Route["rules"].([]interface{}) {
		rule := rawRule.(map[string]interface{})
		if rule["outbound"] == "vpn" {
			if domains, ok := rule["domain_suffix"].([]interface{}); ok && len(domains) == 1 && domains[0] == "cdn.example.com" {
				explicitIndex = index
			}
		}
		if isMagicDNSRouteRule(rule, "tailscale-ts") {
			magicDNSIndex = index
		}
		if cidrs, exists := rule["ip_cidr"]; exists &&
			(strings.Contains(fmt.Sprint(cidrs), "100.64.0.0/10") ||
				strings.Contains(fmt.Sprint(cidrs), "fd7a:115c:a1e0::/48")) {
			t.Fatalf("MagicDNS peer ownership must not use hard-coded CIDRs: %v", rule)
		}
	}
	if explicitIndex < 0 {
		t.Fatalf("expected the explicit VPN rule to survive, got %v", cfg.Route["rules"])
	}
	if magicDNSIndex < 0 {
		t.Fatalf("dynamic MagicDNS peer route is missing: %v", cfg.Route["rules"])
	}
	if explicitIndex >= magicDNSIndex {
		t.Fatalf("explicit CDN rule must precede MagicDNS ownership: %v", cfg.Route["rules"])
	}
	// final 归场景所有：默认直连不被 exit node 抢走。
	if cfg.Route["final"] != "direct" {
		t.Fatalf("scenario default outbound must remain direct, got %v", cfg.Route["final"])
	}
}

// 企业内网域名（绑定到 AnyConnect 线路的手动规则集）的解析必须交给服务端
// 下发的企业 DNS、且查询经隧道出去：真内网名（如 oa.corp.example）在公共 DNS 上是
// NXDOMAIN（2026-07-26 实测），解析不出来内网就"不通"。
func TestGenerateDesktopRoutesEnterpriseDomainsToVPNDNS(t *testing.T) {
	p := testProfile()
	p.ActiveScenarioID = "overseas" // internal → vpn

	data, err := GenerateSingBoxDesktop(p, 10800, "1.2.3.4", t.TempDir(), []string{"10.8.0.10", "10.8.0.11"}, "en0")
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
	// public-dns 对内网名的 NXDOMAIN 不能与 enterprise-dns 共用。
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
	data, err = GenerateSingBoxDesktop(p, 10800, "1.2.3.4", t.TempDir(), nil, "en0")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "enterprise-dns") {
		t.Fatal("enterprise DNS must be omitted when the tunnel pushed none")
	}
}

// splitProfileWithProxy 是桌面核心组合：内网手动规则→AnyConnect，
// 公网规则→代理线路，其余直连。
func splitProfileWithProxy() *Profile {
	return &Profile{
		Lines: []Line{
			{ID: "direct", Name: "直连", Type: LineTypeDirect, Enabled: true},
			{ID: "vpn", Name: "Corp VPN", Type: LineTypeVPN, Enabled: true, VPNServer: "vpn.example.com:8443"},
			{ID: "px", Name: "Proxy", Type: LineTypeTrojan, Enabled: true,
				TrojanServer: "proxy.example.com", TrojanPort: 443,
				TrojanPassword: "secret", TrojanSNI: "proxy.example.com"},
		},
		RuleSets: []RuleSet{
			{ID: "internal", Name: "内网", Type: RuleSetTypeManual, Enabled: true,
				Domains: []string{"corp.example"}},
			{ID: "gfw", Name: "GFW", Type: RuleSetTypeURL, Enabled: true,
				URL: "https://example.com/geosite-gfw.srs"},
			{ID: "oversea", Name: "手动出海", Type: RuleSetTypeManual, Enabled: true,
				Domains: []string{"example.org"}},
		},
		Scenarios: []Scenario{{
			ID: "split", Name: "分流",
			Bindings: []RuleBinding{
				{RuleSetID: "internal", LineID: "vpn"},
				{RuleSetID: "gfw", LineID: "px"},
				{RuleSetID: "oversea", LineID: "px"},
			},
			DefaultLineID: "direct",
		}},
		ActiveScenarioID: "split",
	}
}

// 绑到代理型线路的域名，解析也必须经该线路出去。在本地问境内公共 DNS 拿到的是
// 污染结果，再从境外出口连过去 —— 分流白做，还会连到墙给的假地址。
func TestGenerateDesktopResolvesProxyBoundDomainsThroughTheLine(t *testing.T) {
	data, err := GenerateSingBoxDesktop(splitProfileWithProxy(), 10800, "1.2.3.4", t.TempDir(), []string{"10.8.0.10"}, "en0")
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
	if proxy["tag"] != "proxy-dns-proxy-px" || proxy["type"] != "https" ||
		proxy["server"] != "1.1.1.1" || proxy["detour"] != "proxy-px" {
		t.Fatalf("per-line resolver must be a DoH query sent through the line: %v", proxy)
	}

	rules := cfg.DNS["rules"].([]interface{})
	if len(rules) != 3 {
		t.Fatalf("expected enterprise + two proxy rules, got %v", rules)
	}
	// 顺序是语义的一部分：内网名先归企业 DNS，代理域名随后。
	if rules[0].(map[string]interface{})["server"] != "enterprise-dns" {
		t.Fatalf("enterprise rule must come first: %v", rules)
	}
	urlRule := rules[1].(map[string]interface{})
	if urlRule["server"] != "proxy-dns-proxy-px" || urlRule["rule_set"] != "ruleset-gfw" {
		t.Fatalf("URL rule set must reuse the downloaded rule_set resource: %v", urlRule)
	}
	manualRule := rules[2].(map[string]interface{})
	domains, _ := manualRule["domain_suffix"].([]interface{})
	if manualRule["server"] != "proxy-dns-proxy-px" ||
		len(domains) != 1 || domains[0] != "example.org" {
		t.Fatalf("manual rule set must be inlined as domain suffixes: %v", manualRule)
	}
}

// direct 不算承载线路：它本就要本地视角。绑到 vpn 的手动规则集归 enterprise-dns。
func TestGenerateDesktopKeepsDirectBoundRuleSetsOnPublicDNS(t *testing.T) {
	p := splitProfileWithProxy()
	p.Scenarios[0].Bindings = []RuleBinding{
		{RuleSetID: "internal", LineID: "vpn"},
		{RuleSetID: "gfw", LineID: "direct"},
		{RuleSetID: "oversea", LineID: "direct"},
	}

	data, err := GenerateSingBoxDesktop(p, 10800, "1.2.3.4", t.TempDir(), []string{"10.8.0.10"}, "en0")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "proxy-dns-") {
		t.Fatalf("direct-bound rule sets must not get a tunneled resolver:\n%s", data)
	}
}

// 预设场景"国内"就是这个组合：gfwlist（URL 规则集）绑 AnyConnect 线路。
// 它既不是内网名（enterprise-dns 只收手动规则集），又曾被当作"vpn 不是代理线路"
// 跳过，于是落到 final 的境内解析器上被污染 —— 分流白做。
func TestGenerateDesktopResolvesVPNBoundURLRuleSetThroughTheTunnel(t *testing.T) {
	p := splitProfileWithProxy()
	p.Scenarios[0].Bindings = []RuleBinding{
		{RuleSetID: "internal", LineID: "vpn"},
		{RuleSetID: "gfw", LineID: "vpn"},
	}

	data, err := GenerateSingBoxDesktop(p, 10800, "1.2.3.4", t.TempDir(), []string{"10.8.0.10"}, "en0")
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
	if len(rules) != 2 {
		t.Fatalf("expected enterprise + vpn-url rules, got %v", rules)
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
// IPv6 流量会整体绕过 XDial。
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

// RuleSet 获取线路不再从流量 binding 推断；未选择时默认直连。
func TestGenerateRuleSetDownloadDetourDefaultsToDirect(t *testing.T) {
	p := testProfile()
	p.ActiveScenarioID = "domestic-ss"

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
	if set["tag"] != "ruleset-gfw" || set["download_detour"] != "direct" {
		t.Fatalf("rule set must default to direct acquisition: %v", set)
	}
}

func TestGenerateRuleSetDownloadDetourFollowsExplicitUpdateLine(t *testing.T) {
	p := splitProfileWithProxy()
	p.Scenarios[0].Bindings = []RuleBinding{{
		RuleSetID: "gfw",
		LineID:    "px",
	}}
	p.RuleSets[1].FetchLineID = "px"

	data, err := GenerateSingBox(p, 10800, "1.2.3.4")
	if err != nil {
		t.Fatal(err)
	}
	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}
	set := cfg.Route["rule_set"].([]interface{})[0].(map[string]interface{})
	if set["download_detour"] != "proxy-px" {
		t.Fatalf("explicit update Line was ignored: %v", set)
	}
}

// direct / vpn 绑定的远程规则集由 daemon 预取，生成器兜底为 direct。
func TestGenerateRuleSetDownloadDetourFallsBackToDirect(t *testing.T) {
	for _, tc := range []struct {
		name   string
		lineID string
	}{
		{"vpn", "vpn"},
		{"direct", "direct"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			p := splitProfileWithProxy()
			p.Scenarios[0].Bindings = []RuleBinding{{RuleSetID: "gfw", LineID: tc.lineID}}

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

func TestGenerateNETailscaleExitNodeAsDefault(t *testing.T) {
	p := &Profile{
		Lines: []Line{
			{ID: "direct", Name: "直连", Type: LineTypeDirect, Enabled: true},
			{ID: "ts", Name: "Tailnet", Type: LineTypeTailscale, Enabled: true, TailscaleExitNode: "exit-node"},
		},
		Scenarios:        []Scenario{{ID: "exit", Name: "Exit", DefaultLineID: "ts"}},
		ActiveScenarioID: "exit",
	}

	data, err := GenerateSingBoxFor(p, 0, "", PlatformNE, t.TempDir())
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

// D30：多条 active AnyConnect 线路必须在所有平台被拒绝。
// 所有 VPN 线路共享 "vpn" 这一个 outbound tag，第二条线路的流量会静默钻进
// 第一条的隧道 —— 桌面和 NE 都只有一份 sslcon/VPNBridge，没有例外。
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
		Scenarios: []Scenario{{
			ID: "scenario", DefaultLineID: "vpn-a",
			Bindings: []RuleBinding{{RuleSetID: "internal", LineID: "vpn-b"}},
		}},
		ActiveScenarioID: "scenario",
	}

	for _, platform := range []Platform{PlatformNE, PlatformMacOS} {
		generate := func() ([]byte, error) {
			if platform == PlatformMacOS {
				return GenerateSingBoxFor(profile, 0, "", platform, t.TempDir(), "en0")
			}
			return GenerateSingBoxFor(profile, 0, "", platform, t.TempDir())
		}
		profile.Scenarios[0].Bindings[0].LineID = "vpn-b"
		profile.RuleSets[0].Enabled = true

		if _, err := generate(); err == nil ||
			!strings.Contains(err.Error(), "only one") {
			t.Fatalf("platform %v: expected multiple-AnyConnect error, got %v", platform, err)
		}

		profile.Scenarios[0].Bindings[0].LineID = "vpn-a"
		if _, err := generate(); err != nil {
			t.Fatalf("platform %v: same AnyConnect line referenced twice should be allowed: %v", platform, err)
		}

		profile.Scenarios[0].Bindings[0].LineID = "vpn-b"
		profile.RuleSets[0].Enabled = false
		if _, err := generate(); err != nil {
			t.Fatalf("platform %v: disabled rule must not create an AnyConnect conflict: %v", platform, err)
		}

		// 第二条线路被禁用 → 不再是 active，同样不构成冲突。
		profile.RuleSets[0].Enabled = true
		profile.Lines[2].Enabled = false
		if _, err := generate(); err != nil {
			t.Fatalf("platform %v: disabled second AnyConnect line must not conflict: %v", platform, err)
		}
		profile.Lines[2].Enabled = true
	}
}

// 场景的普通规则必须排在订阅自带规则之前：Scenario 是唯一裁决者，订阅只是供给源。
func TestGenerateScenarioRulesPrecedeSubscriptionSuppliedRules(t *testing.T) {
	p := &Profile{
		Lines: []Line{{ID: "direct", Type: LineTypeDirect, Enabled: true}},
		RuleSets: []RuleSet{{
			ID: "mine", Name: "我的显式绑定", Type: RuleSetTypeManual, Enabled: true,
			Domains: []string{"mine.example.com"},
		}},
		Subscriptions: []Subscription{{
			ID: "sub", Name: "Sub", Enabled: true, Strategy: "selector",
			Lines: []Line{{
				ID: "n1", Name: "N1", Type: LineTypeTrojan, Enabled: true,
				TrojanServer: "n1.example.com", TrojanPort: 443, TrojanPassword: "p",
			}},
			// 订阅自带的宽匹配：不加约束就会把 mine.example.com 一起吃掉。
			Rules: []SubscriptionRule{{Type: "DOMAIN-SUFFIX", Value: "example.com", Group: "DIRECT"}},
		}},
		Scenarios: []Scenario{{
			ID: "m", Name: "M",
			Bindings:      []RuleBinding{{RuleSetID: "mine", SubscriptionID: "sub"}},
			DefaultLineID: "direct",
		}},
		ActiveScenarioID: "m",
	}

	data, err := GenerateSingBox(p, 10800, "")
	if err != nil {
		t.Fatal(err)
	}
	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}

	scenarioIdx, subIdx := -1, -1
	for index, raw := range cfg.Route["rules"].([]interface{}) {
		rule := raw.(map[string]interface{})
		domains, ok := rule["domain_suffix"].([]interface{})
		if !ok || len(domains) != 1 {
			continue
		}
		switch domains[0] {
		case "mine.example.com":
			scenarioIdx = index
		case "example.com":
			subIdx = index
		}
	}
	if scenarioIdx < 0 || subIdx < 0 {
		t.Fatalf("rules missing: scenarioIdx=%d subIdx=%d", scenarioIdx, subIdx)
	}
	if scenarioIdx > subIdx {
		t.Fatalf("scenario rule (idx=%d) must precede subscription rule (idx=%d)", scenarioIdx, subIdx)
	}
}

// INV6a：悬空引用一律拒绝生成，不允许"规则整条蒸发"。
func TestGenerateRejectsDanglingReferences(t *testing.T) {
	base := func() *Profile {
		return &Profile{
			Lines: []Line{
				{ID: "direct", Type: LineTypeDirect, Enabled: true},
				{ID: "px", Type: LineTypeShadowsocks, Enabled: true,
					SSServer: "px.example.com", SSPort: 8388, SSMethod: "aes-256-gcm", SSPass: "s"},
			},
			RuleSets: []RuleSet{{
				ID: "rs", Name: "RS", Type: RuleSetTypeManual, Enabled: true,
				Domains: []string{"a.example.com"},
			}},
			Scenarios: []Scenario{{
				ID: "m", Name: "M",
				Bindings:      []RuleBinding{{RuleSetID: "rs", LineID: "px"}},
				DefaultLineID: "direct",
			}},
			ActiveScenarioID: "m",
		}
	}

	cases := map[string]func(*Profile){
		"missing rule set":       func(p *Profile) { p.Scenarios[0].Bindings[0].RuleSetID = "ghost-rs" },
		"missing line":           func(p *Profile) { p.Scenarios[0].Bindings[0].LineID = "ghost-line" },
		"missing subscription":   func(p *Profile) { p.Scenarios[0].Bindings[0].SubscriptionID = "ghost-sub" },
		"missing default line":   func(p *Profile) { p.Scenarios[0].DefaultLineID = "ghost-default" },
		"missing default sub":    func(p *Profile) { p.Scenarios[0].DefaultSubscriptionID = "ghost-default-sub" },
		"binding without target": func(p *Profile) { p.Scenarios[0].Bindings[0].LineID = "" },
		"binding without rule":   func(p *Profile) { p.Scenarios[0].Bindings[0].RuleSetID = "" },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			p := base()
			mutate(p)
			if _, err := GenerateSingBox(p, 0, ""); err == nil {
				t.Fatal("dangling reference must be rejected")
			}
			if _, err := CollectProfileWarnings(p); err == nil {
				t.Fatal("CollectProfileWarnings must report the same dangling reference")
			}
		})
	}

	// 禁用的绑定同样要校验出口存在性：不能因为"现在没生效"就放过悬空引用，
	// 否则用户哪天一勾选就变成静默错路由。
	p := base()
	p.RuleSets[0].Enabled = false
	p.Scenarios[0].Bindings[0].LineID = "ghost-line"
	if _, err := GenerateSingBox(p, 0, ""); err == nil {
		t.Fatal("dangling line under a disabled rule set must still be rejected")
	}

	// "direct" 是保留 ID：即使 profile 里没有显式直连线路也不算悬空。
	p = base()
	p.Lines = p.Lines[1:]
	p.Scenarios[0].Bindings[0].LineID = "direct"
	if _, err := GenerateSingBox(p, 0, ""); err != nil {
		t.Fatalf("builtin direct reference must be accepted: %v", err)
	}
}

// INV6b：显式禁用允许跳过，但必须结构化上报，且绝不能悄悄降级成 direct。
func TestDisabledReferencesWarnAndDoNotFallBackToDirect(t *testing.T) {
	p := &Profile{
		Lines: []Line{
			{ID: "direct", Name: "直连", Type: LineTypeDirect, Enabled: true},
			// 被禁用的直连线路：它的 tag "direct" 恒在 validTags 里，
			// 不查 Enabled 就会静默生成一条走直连的规则。
			{ID: "off-direct", Name: "备用直连", Type: LineTypeDirect, Enabled: false},
			{ID: "off-px", Name: "备用代理", Type: LineTypeShadowsocks, Enabled: false,
				SSServer: "off.example.com", SSPort: 8388, SSMethod: "aes-256-gcm", SSPass: "s"},
		},
		RuleSets: []RuleSet{
			{ID: "rs-off", Name: "禁用规则", Type: RuleSetTypeManual, Enabled: false,
				Domains: []string{"off.example.com"}},
			{ID: "rs-a", Name: "A", Type: RuleSetTypeManual, Enabled: true,
				Domains: []string{"a.example.com"}},
			{ID: "rs-b", Name: "B", Type: RuleSetTypeManual, Enabled: true,
				Domains: []string{"b.example.com"}},
		},
		Scenarios: []Scenario{{
			ID: "m", Name: "M",
			Bindings: []RuleBinding{
				{RuleSetID: "rs-off", LineID: "direct"},
				{RuleSetID: "rs-a", LineID: "off-direct"},
				{RuleSetID: "rs-b", LineID: "off-px"},
			},
			DefaultLineID: "off-px",
		}},
		ActiveScenarioID: "m",
	}

	warnings, err := CollectProfileWarnings(p)
	if err != nil {
		t.Fatalf("disabled objects must not fail generation: %v", err)
	}
	got := map[ProfileWarningKind]int{}
	for _, w := range warnings {
		got[w.Kind]++
		if w.Message == "" {
			t.Fatalf("warning %+v has no message", w)
		}
		if w.ScenarioID != "m" {
			t.Fatalf("warning %+v should carry the scenario id", w)
		}
	}
	if got[WarningDisabledRuleSet] != 1 {
		t.Fatalf("expected one disabled-rule-set warning, got %v", got)
	}
	if got[WarningDisabledLine] != 2 {
		t.Fatalf("expected two disabled-line warnings, got %v", got)
	}
	if got[WarningDisabledDefaultLine] != 1 {
		t.Fatalf("expected one disabled-default-line warning, got %v", got)
	}

	data, err := GenerateSingBox(p, 0, "")
	if err != nil {
		t.Fatal(err)
	}
	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}
	for _, raw := range cfg.Route["rules"].([]interface{}) {
		rule := raw.(map[string]interface{})
		domains, ok := rule["domain_suffix"].([]interface{})
		if !ok {
			continue
		}
		for _, domain := range domains {
			switch domain {
			case "a.example.com", "b.example.com", "off.example.com":
				t.Fatalf("binding to a disabled object must not emit a route rule: %v", rule)
			}
		}
	}
	if cfg.Route["final"] != "direct" {
		t.Fatalf("disabled default line falls back to direct, got %v", cfg.Route["final"])
	}
}

// active Scenario 直接引用的 enabled Line 若生成不出 outbound，规划和生成都必须
// fail-closed。它不是显式禁用，不能 warning 后让绑定或默认出口落到 direct。
func TestActiveEnabledUnavailableLineFailsClosed(t *testing.T) {
	lines := []Line{
		{
			ID:      "broken-ss",
			Name:    "残缺 Shadowsocks",
			Type:    LineTypeShadowsocks,
			Enabled: true,
		},
		{
			ID:             "broken-anytls",
			Name:           "不兼容 AnyTLS",
			Type:           LineTypeAnyTLS,
			Enabled:        true,
			AnyTLSServer:   "anytls.example.com",
			AnyTLSPort:     443,
			AnyTLSPassword: "secret",
			TFO:            true,
		},
	}
	for _, line := range lines {
		for _, useAsDefault := range []bool{false, true} {
			name := string(line.Type) + "/binding"
			if useAsDefault {
				name = string(line.Type) + "/default"
			}
			t.Run(name, func(t *testing.T) {
				profile := &Profile{
					Lines: []Line{
						{ID: "direct", Type: LineTypeDirect, Enabled: true},
						line,
					},
					RuleSets: []RuleSet{{
						ID:      "rs",
						Name:    "RS",
						Type:    RuleSetTypeManual,
						Enabled: true,
						Domains: []string{"a.example.com"},
					}},
					Scenarios: []Scenario{{
						ID:            "m",
						Name:          "M",
						DefaultLineID: "direct",
					}},
					ActiveScenarioID: "m",
				}
				if useAsDefault {
					profile.Scenarios[0].DefaultLineID = line.ID
				} else {
					profile.Scenarios[0].Bindings = []RuleBinding{{
						RuleSetID: "rs",
						LineID:    line.ID,
					}}
				}

				if warnings, err := CollectProfileWarnings(profile); err == nil {
					t.Fatalf("unavailable active line must be an error, got warnings %+v", warnings)
				}
				if data, err := GenerateSingBox(profile, 0, ""); err == nil {
					t.Fatalf("unavailable active line generated a config:\n%s", data)
				}
				if plan, err := BuildConnectionPlan(profile); err == nil {
					t.Fatalf("unavailable active line generated a plan: %+v", plan)
				}
			})
		}
	}
}

func TestUnavailableLineOutsideEffectiveScenarioDoesNotFail(t *testing.T) {
	profile := &Profile{
		Lines: []Line{
			{ID: "direct", Type: LineTypeDirect, Enabled: true},
			{ID: "unused", Type: LineTypeAnyTLS, Enabled: true, TFO: true},
			{ID: "disabled", Type: LineTypeAnyTLS, Enabled: false, TFO: true},
		},
		RuleSets: []RuleSet{
			{
				ID:      "disabled-rule",
				Type:    RuleSetTypeManual,
				Enabled: false,
				Domains: []string{"disabled.example.com"},
			},
			{
				ID:      "enabled-rule",
				Type:    RuleSetTypeManual,
				Enabled: true,
				Domains: []string{"enabled.example.com"},
			},
		},
		Scenarios: []Scenario{{
			ID: "m",
			Bindings: []RuleBinding{
				{RuleSetID: "disabled-rule", LineID: "unused"},
				{RuleSetID: "enabled-rule", LineID: "disabled"},
			},
			DefaultLineID: "direct",
		}},
		ActiveScenarioID: "m",
	}

	warnings, err := CollectProfileWarnings(profile)
	if err != nil {
		t.Fatalf("disabled or ineffective references must retain INV6 warning semantics: %v", err)
	}
	got := map[ProfileWarningKind]bool{}
	for _, warning := range warnings {
		got[warning.Kind] = true
	}
	for _, kind := range []ProfileWarningKind{WarningDisabledRuleSet, WarningDisabledLine} {
		if !got[kind] {
			t.Fatalf("missing %s warning: %+v", kind, warnings)
		}
	}
	if _, err := GenerateSingBox(profile, 0, ""); err != nil {
		t.Fatalf("unavailable Line outside the effective Scenario must have no data-plane effect: %v", err)
	}
	if _, err := BuildConnectionPlan(profile); err != nil {
		t.Fatalf("unavailable Line outside the effective Scenario must not enter the plan: %v", err)
	}
}

// active Scenario 直接引用的 enabled Subscription 若没有任何节点能生成 outbound，
// 必须和独立 Line 一样在校验、规划、生成三层都 fail-closed。
func TestActiveEnabledUnavailableSubscriptionFailsClosed(t *testing.T) {
	subscriptions := []Subscription{
		{
			ID:       "empty-sub",
			Name:     "空订阅",
			Enabled:  true,
			Strategy: "selector",
		},
		{
			ID:       "broken-anytls-sub",
			Name:     "不兼容 AnyTLS 订阅",
			Enabled:  true,
			Strategy: "selector",
			Lines: []Line{{
				ID:             "broken-anytls",
				Name:           "Broken AnyTLS",
				Type:           LineTypeAnyTLS,
				Enabled:        true,
				AnyTLSServer:   "anytls.example.com",
				AnyTLSPort:     443,
				AnyTLSPassword: "secret",
				TFO:            true,
			}},
		},
	}
	for _, subscription := range subscriptions {
		for _, useAsDefault := range []bool{false, true} {
			name := subscription.ID + "/binding"
			if useAsDefault {
				name = subscription.ID + "/default"
			}
			t.Run(name, func(t *testing.T) {
				profile := &Profile{
					Lines: []Line{{
						ID: "direct", Type: LineTypeDirect, Enabled: true,
					}},
					RuleSets: []RuleSet{{
						ID:      "rs",
						Name:    "RS",
						Type:    RuleSetTypeManual,
						Enabled: true,
						Domains: []string{"a.example.com"},
					}},
					Subscriptions: []Subscription{subscription},
					Scenarios: []Scenario{{
						ID:            "m",
						Name:          "M",
						DefaultLineID: "direct",
					}},
					ActiveScenarioID: "m",
				}
				if useAsDefault {
					profile.Scenarios[0].DefaultLineID = ""
					profile.Scenarios[0].DefaultSubscriptionID =
						subscription.ID
				} else {
					profile.Scenarios[0].Bindings = []RuleBinding{{
						RuleSetID:      "rs",
						SubscriptionID: subscription.ID,
					}}
				}

				if warnings, err := CollectProfileWarnings(profile); err == nil {
					t.Fatalf(
						"unavailable active subscription must be an error, got warnings %+v",
						warnings,
					)
				}
				if data, err := GenerateSingBox(profile, 0, ""); err == nil {
					t.Fatalf(
						"unavailable active subscription generated a config:\n%s",
						data,
					)
				}
				if plan, err := BuildConnectionPlan(profile); err == nil {
					t.Fatalf(
						"unavailable active subscription generated a plan: %+v",
						plan,
					)
				}
			})
		}
	}
}

// 旧移动端 Profile 仍兼容 auth_key 纯参数；节点必须保持常驻（绝不 ephemeral）。
func TestGenerateNETailscaleEndpointCarriesAuthKeyAndStaysPersistent(t *testing.T) {
	p := &Profile{
		Lines: []Line{
			{ID: "direct", Type: LineTypeDirect, Enabled: true},
			{ID: "ts", Name: "Tailnet", Type: LineTypeTailscale, Enabled: true,
				TailscaleAuthKey: "tskey-auth-example"},
		},
		Scenarios:        []Scenario{{ID: "m", Name: "M", DefaultLineID: "ts"}},
		ActiveScenarioID: "m",
	}

	data, err := GenerateSingBoxFor(p, 0, "", PlatformNE, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}
	endpoint := cfg.Endpoints[0]
	if endpoint["auth_key"] != "tskey-auth-example" {
		t.Fatalf("auth_key not emitted: %v", endpoint)
	}
	if value, ok := endpoint["ephemeral"]; ok && value != false {
		t.Fatalf("Tailscale node must stay persistent, got ephemeral=%v", value)
	}

	// 不填 auth_key 时不得出现该字段（回退 sing-box 自己的授权 URL 流程）。
	p.Lines[1].TailscaleAuthKey = ""
	data, err = GenerateSingBoxFor(p, 0, "", PlatformNE, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	// 必须解到全新的值：json.Unmarshal 会把内容合并进已存在的 map，
	// 复用上一轮的 cfg 会让 auth_key 残留，测试变成永远通过。
	var withoutKey SingBoxConfig
	if err := json.Unmarshal(data, &withoutKey); err != nil {
		t.Fatal(err)
	}
	if _, ok := withoutKey.Endpoints[0]["auth_key"]; ok {
		t.Fatalf("empty auth key must not emit the option: %v", withoutKey.Endpoints[0])
	}
}

func TestGenerateTransparentProxyUsesAuthenticatedLoopbackSOCKSWithSystemUnderlay(t *testing.T) {
	p := &Profile{
		Lines:            []Line{{ID: "direct", Type: LineTypeDirect, Enabled: true}},
		Scenarios:        []Scenario{{ID: "scenario", DefaultLineID: "direct"}},
		ActiveScenarioID: "scenario",
	}
	data, err := GenerateSingBoxTransparentProxy(
		p,
		29876,
		"session-user",
		"session-password",
		t.TempDir(),
		"utun-underlay",
		[]string{"100.100.100.100"},
	)
	if err != nil {
		t.Fatal(err)
	}
	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}
	if len(cfg.Inbounds) != 1 {
		t.Fatalf("unexpected inbounds: %v", cfg.Inbounds)
	}
	inbound := cfg.Inbounds[0]
	if inbound["type"] != "socks" ||
		inbound["listen"] != "127.0.0.1" ||
		inbound["listen_port"] != float64(29876) {
		t.Fatalf("unexpected Transparent Proxy ingress: %v", inbound)
	}
	users := inbound["users"].([]interface{})
	user := users[0].(map[string]interface{})
	if user["username"] != "session-user" ||
		user["password"] != "session-password" {
		t.Fatalf("loopback SOCKS credentials missing: %v", users)
	}
	if got := cfg.Route["default_interface"]; got != "utun-underlay" {
		t.Fatalf("Transparent Proxy must forward the system Underlay snapshot: %v", cfg.Route)
	}
	if _, exists := cfg.Route["auto_detect_interface"]; exists {
		t.Fatalf("Transparent Proxy must preserve system per-destination routing: %v", cfg.Route)
	}
	rules := cfg.Route["rules"].([]interface{})
	if len(rules) != 3 ||
		rules[0].(map[string]interface{})["action"] != "sniff" ||
		rules[1].(map[string]interface{})["action"] != "hijack-dns" ||
		rules[2].(map[string]interface{})["action"] != "resolve" ||
		rules[2].(map[string]interface{})["server"] != transparentSystemDNSTag {
		t.Fatalf("Transparent Proxy must not resolve globally before Scenario rules: %v", rules)
	}
	if cfg.Route["default_domain_resolver"] != transparentSystemDNSTag ||
		cfg.DNS["final"] != transparentSystemDNSTag {
		t.Fatalf("Transparent Proxy must use the startup system DNS snapshot: dns=%v route=%v", cfg.DNS, cfg.Route)
	}
}

func TestGenerateTransparentProxyRejectsMissingSessionCredentials(t *testing.T) {
	p := &Profile{
		Lines:            []Line{{ID: "direct", Type: LineTypeDirect, Enabled: true}},
		Scenarios:        []Scenario{{ID: "scenario", DefaultLineID: "direct"}},
		ActiveScenarioID: "scenario",
	}
	if _, err := GenerateSingBoxTransparentProxy(
		p,
		29876,
		"",
		"password",
		t.TempDir(),
		"utun-underlay",
		[]string{"100.100.100.100"},
	); err == nil {
		t.Fatal("missing loopback SOCKS credentials were accepted")
	}
}

func TestGenerateTransparentProxyRejectsMissingSystemUnderlay(t *testing.T) {
	p := &Profile{
		Lines:            []Line{{ID: "direct", Type: LineTypeDirect, Enabled: true}},
		Scenarios:        []Scenario{{ID: "scenario", DefaultLineID: "direct"}},
		ActiveScenarioID: "scenario",
	}
	if _, err := GenerateSingBoxTransparentProxy(
		p,
		29876,
		"session-user",
		"session-password",
		t.TempDir(),
		"",
		[]string{"100.100.100.100"},
	); err == nil || !strings.Contains(err.Error(), "underlay interface snapshot") {
		t.Fatalf("missing system Underlay was accepted: %v", err)
	}
}
