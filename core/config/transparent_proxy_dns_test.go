package config

import (
	"encoding/json"
	"net/netip"
	"reflect"
	"strings"
	"testing"
)

func TestTransparentProxyDNSRejectsMissingOrInvalidSystemSnapshot(t *testing.T) {
	profile := &Profile{
		Lines:        []Line{{ID: "direct", Type: LineTypeDirect, Enabled: true}},
		Modes:        []Mode{{ID: "mode", DefaultLineID: "direct"}},
		ActiveModeID: "mode",
	}
	tests := []struct {
		name      string
		systemDNS []string
	}{
		{name: "missing"},
		{name: "empty", systemDNS: []string{}},
		{name: "not an address", systemDNS: []string{"resolver.example"}},
		{name: "unspecified IPv4", systemDNS: []string{"0.0.0.0"}},
		{name: "unspecified IPv6", systemDNS: []string{"::"}},
		{name: "multicast", systemDNS: []string{"224.0.0.251"}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := GenerateSingBoxTransparentProxy(
				profile,
				29876,
				"session-user",
				"session-password",
				t.TempDir(),
				"utun-underlay",
				test.systemDNS,
			)
			if err == nil || !strings.Contains(err.Error(), "system DNS snapshot") {
				t.Fatalf("system DNS snapshot %v was accepted: %v", test.systemDNS, err)
			}
		})
	}
}

func TestTransparentProxyDomainEndpointUsesIsolatedBootstrapResolver(t *testing.T) {
	profile := &Profile{
		Lines: []Line{
			{ID: "direct", Type: LineTypeDirect, Enabled: true},
			{
				ID:             "taiwan",
				Type:           LineTypeAnyTLS,
				Enabled:        true,
				AnyTLSServer:   "node.example.com",
				AnyTLSPort:     3489,
				AnyTLSPassword: "secret",
				AnyTLSSNI:      "cover.example.com",
			},
		},
		Modes:        []Mode{{ID: "mode", DefaultLineID: "taiwan"}},
		ActiveModeID: "mode",
	}

	cfg, _ := generateTransparentProxyDNSTestConfig(t, profile)
	outbound := transparentProxyOutboundByTag(t, cfg, "proxy-taiwan")
	if outbound["domain_resolver"] != desktopPublicDNSTag {
		t.Fatalf("domain proxy endpoint did not use the bootstrap resolver: %v", outbound)
	}

	bootstrap := transparentProxyDNSServerByTag(t, cfg, desktopPublicDNSTag)
	if bootstrap["type"] != "https" || bootstrap["server"] != "223.5.5.5" {
		t.Fatalf("unexpected proxy endpoint bootstrap resolver: %v", bootstrap)
	}
	if _, err := netip.ParseAddr(bootstrap["server"].(string)); err != nil {
		t.Fatalf("bootstrap resolver must not require another DNS lookup: %v", bootstrap)
	}
	if _, exists := bootstrap["detour"]; exists {
		t.Fatalf("bootstrap resolver must not detour through the proxy it starts: %v", bootstrap)
	}

	lineResolver := desktopProxyDNSTag("proxy-taiwan")
	if cfg.Route["default_domain_resolver"] != transparentSystemDNSTag {
		t.Fatalf("proxy endpoint bootstrap changed the Underlay resolver: %v", cfg.Route)
	}
	if cfg.DNS["final"] != lineResolver {
		t.Fatalf("Mode default Line lost user-traffic DNS ownership: %v", cfg.DNS)
	}
	assertTransparentProxyRules(t, transparentProxyUserRules(t, cfg), []string{
		`{"action":"resolve","server":"` + lineResolver + `"}`,
	})
}

func TestTransparentProxyEndpointBootstrapOnlyCoversActiveDomainServers(t *testing.T) {
	t.Run("numeric active endpoint", func(t *testing.T) {
		profile := &Profile{
			Lines: []Line{
				{ID: "direct", Type: LineTypeDirect, Enabled: true},
				{
					ID:             "taiwan",
					Type:           LineTypeAnyTLS,
					Enabled:        true,
					AnyTLSServer:   "192.0.2.10",
					AnyTLSPort:     3489,
					AnyTLSPassword: "secret",
					AnyTLSSNI:      "cover.example.com",
				},
			},
			Modes:        []Mode{{ID: "mode", DefaultLineID: "taiwan"}},
			ActiveModeID: "mode",
		}

		cfg, _ := generateTransparentProxyDNSTestConfig(t, profile)
		outbound := transparentProxyOutboundByTag(t, cfg, "proxy-taiwan")
		if _, exists := outbound["domain_resolver"]; exists {
			t.Fatalf("numeric endpoint unexpectedly acquired a resolver: %v", outbound)
		}
		assertTransparentProxyNoDNSServerTag(t, cfg, desktopPublicDNSTag)
	})

	t.Run("unreferenced domain endpoint", func(t *testing.T) {
		profile := &Profile{
			Lines: []Line{
				{ID: "direct", Type: LineTypeDirect, Enabled: true},
				{
					ID:             "unused",
					Type:           LineTypeAnyTLS,
					Enabled:        true,
					AnyTLSServer:   "unused.example.com",
					AnyTLSPort:     3489,
					AnyTLSPassword: "secret",
				},
			},
			Modes:        []Mode{{ID: "mode", DefaultLineID: "direct"}},
			ActiveModeID: "mode",
		}

		cfg, _ := generateTransparentProxyDNSTestConfig(t, profile)
		for _, outbound := range cfg.Outbounds {
			if outbound["tag"] == "proxy-unused" {
				t.Fatalf("unreferenced Line leaked into active outbounds: %v", outbound)
			}
		}
		assertTransparentProxyNoDNSServerTag(t, cfg, desktopPublicDNSTag)
	})
}

func TestTransparentProxySubscriptionNodeDomainEndpointsUseBootstrapResolver(t *testing.T) {
	profile := &Profile{
		Lines: []Line{{ID: "direct", Type: LineTypeDirect, Enabled: true}},
		RuleSets: []RuleSet{{
			ID:      "stream",
			Type:    RuleSetTypeManual,
			Enabled: true,
			Domains: []string{"video.example"},
		}},
		Subscriptions: []Subscription{{
			ID:       "sub",
			Enabled:  true,
			Strategy: "selector",
			Lines: []Line{
				{
					ID:             "domain-node",
					Name:           "Domain node",
					Type:           LineTypeAnyTLS,
					Enabled:        true,
					AnyTLSServer:   "node.example.com",
					AnyTLSPort:     3489,
					AnyTLSPassword: "secret",
				},
				{
					ID:             "ip-node",
					Name:           "IP node",
					Type:           LineTypeAnyTLS,
					Enabled:        true,
					AnyTLSServer:   "192.0.2.20",
					AnyTLSPort:     3489,
					AnyTLSPassword: "secret",
				},
			},
		}},
		Modes: []Mode{{
			ID: "mode",
			Bindings: []RuleBinding{{
				RuleSetID:      "stream",
				SubscriptionID: "sub",
			}},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "mode",
	}

	cfg, _ := generateTransparentProxyDNSTestConfig(t, profile)
	domainNode := transparentProxyOutboundByTag(t, cfg, "proxy-sub-domain-node")
	if domainNode["domain_resolver"] != desktopPublicDNSTag {
		t.Fatalf("subscription domain endpoint did not use bootstrap resolver: %v", domainNode)
	}
	ipNode := transparentProxyOutboundByTag(t, cfg, "proxy-sub-ip-node")
	if _, exists := ipNode["domain_resolver"]; exists {
		t.Fatalf("subscription numeric endpoint unexpectedly acquired a resolver: %v", ipNode)
	}
	transparentProxyDNSServerByTag(t, cfg, desktopPublicDNSTag)
}

func TestTransparentProxyDNSCompilesManualDomainThenCIDRInCausalOrder(t *testing.T) {
	profile := &Profile{
		Lines: []Line{
			{ID: "direct", Type: LineTypeDirect, Enabled: true},
			{ID: "company", Type: LineTypeVPN, Enabled: true},
		},
		RuleSets: []RuleSet{{
			ID:      "company",
			Type:    RuleSetTypeManual,
			Enabled: true,
			Domains: []string{"corp.example"},
			CIDRs:   []string{"10.0.0.0/8"},
		}},
		Modes: []Mode{{
			ID: "mode",
			Bindings: []RuleBinding{{
				RuleSetID: "company",
				LineID:    "company",
			}},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "mode",
	}

	cfg, raw := generateTransparentProxyDNSTestConfig(t, profile)
	rules := transparentProxyUserRules(t, cfg)
	assertTransparentProxyRules(t, rules, []string{
		`{"action":"resolve","domain_suffix":["corp.example"],"server":"xdial-anyconnect-dns"}`,
		`{"domain_suffix":["corp.example"],"outbound":"vpn"}`,
		`{"action":"resolve","server":"xdial-system-dns"}`,
		`{"ip_cidr":["10.0.0.0/8"],"outbound":"vpn"}`,
		`{"action":"resolve","server":"xdial-system-dns"}`,
	})

	servers := cfg.DNS["servers"].([]interface{})
	if len(servers) != 2 {
		t.Fatalf("unexpected DNS servers: %v", servers)
	}
	system := servers[0].(map[string]interface{})
	enterprise := servers[1].(map[string]interface{})
	if system["tag"] != transparentSystemDNSTag ||
		system["server"] != "100.100.100.100" ||
		enterprise["type"] != "xdial-anyconnect" ||
		enterprise["tag"] != transparentEnterpriseDNSTag {
		t.Fatalf("manual domain resolvers do not match their routes: %v", servers)
	}
	assertTransparentProxyHasNoMobileDNSFallback(t, raw)
}

func TestTransparentProxyDNSClassifiesURLRulesAndPreservesBindingOrder(t *testing.T) {
	profile := &Profile{
		Lines: []Line{
			{ID: "direct", Type: LineTypeDirect, Enabled: true},
			{
				ID:             "japan",
				Type:           LineTypeTrojan,
				Enabled:        true,
				TrojanServer:   "192.0.2.10",
				TrojanPort:     443,
				TrojanPassword: "secret",
				TrojanSNI:      "proxy.example",
			},
		},
		RuleSets: []RuleSet{
			{
				ID: "domain", Type: RuleSetTypeURL, Enabled: true,
				URL: "file:///tmp/domain.srs", Format: "binary",
				RuntimeMatchKind: RuleSetMatchDomain,
			},
			{
				ID: "ip", Type: RuleSetTypeURL, Enabled: true,
				URL: "file:///tmp/ip.srs", Format: "binary",
				RuntimeMatchKind: RuleSetMatchIP,
			},
			{
				ID: "mixed", Type: RuleSetTypeURL, Enabled: true,
				URL: "file:///tmp/mixed.srs", Format: "binary",
				RuntimeMatchKind: RuleSetMatchMixed,
			},
		},
		Modes: []Mode{{
			ID: "mode",
			// 故意与 RuleSets 声明顺序不同，锁定唯一合法顺序来源是 Mode bindings。
			Bindings: []RuleBinding{
				{RuleSetID: "mixed", LineID: "japan"},
				{RuleSetID: "domain", LineID: "japan"},
				{RuleSetID: "ip", LineID: "japan"},
			},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "mode",
	}

	cfg, raw := generateTransparentProxyDNSTestConfig(t, profile)
	rules := transparentProxyUserRules(t, cfg)
	assertTransparentProxyRules(t, rules, []string{
		`{"action":"resolve","server":"xdial-system-dns"}`,
		`{"outbound":"proxy-japan","rule_set":"ruleset-mixed"}`,
		`{"action":"resolve","rule_set":"ruleset-domain","server":"proxy-dns-proxy-japan"}`,
		`{"outbound":"proxy-japan","rule_set":"ruleset-domain"}`,
		`{"action":"resolve","server":"xdial-system-dns"}`,
		`{"outbound":"proxy-japan","rule_set":"ruleset-ip"}`,
		`{"action":"resolve","server":"xdial-system-dns"}`,
	})

	if dnsRules, ok := cfg.DNS["rules"].([]interface{}); ok && len(dnsRules) > 0 {
		t.Fatalf("a mixed rule before the domain rule must close the DNS ownership chain: %v", dnsRules)
	}

	servers := cfg.DNS["servers"].([]interface{})
	if len(servers) != 2 {
		t.Fatalf("route-time domain resolution is missing its Line resolver: %v", servers)
	}
	lineResolver := servers[1].(map[string]interface{})
	if lineResolver["tag"] != "proxy-dns-proxy-japan" ||
		lineResolver["type"] != "https" ||
		lineResolver["detour"] != "proxy-japan" {
		t.Fatalf("pure-domain URL rule did not resolve through its target Line: %v", lineResolver)
	}
	if cfg.DNS["final"] != transparentSystemDNSTag {
		t.Fatalf("the conservative DNS path must use the startup system DNS: %v", cfg.DNS)
	}
	assertTransparentProxyHasNoMobileDNSFallback(t, raw)
}

func TestTransparentProxyDefaultLineOwnsFinalResolution(t *testing.T) {
	profile := &Profile{
		Lines: []Line{
			{ID: "direct", Type: LineTypeDirect, Enabled: true},
			{
				ID:                "tailnet",
				Type:              LineTypeTailscale,
				Enabled:           true,
				TailscaleExitNode: "100.118.7.9",
			},
		},
		RuleSets: []RuleSet{{
			ID:               "cnip",
			Type:             RuleSetTypeURL,
			Enabled:          true,
			URL:              "file:///tmp/cnip.srs",
			Format:           "binary",
			RuntimeMatchKind: RuleSetMatchIP,
		}},
		Modes: []Mode{{
			ID: "mode",
			Bindings: []RuleBinding{{
				RuleSetID: "cnip",
				LineID:    "direct",
			}},
			DefaultLineID: "tailnet",
		}},
		ActiveModeID: "mode",
	}

	cfg, raw := generateTransparentProxyDNSTestConfig(t, profile)
	defaultResolver := desktopProxyDNSTag("tailscale-tailnet")
	if cfg.DNS["final"] != defaultResolver {
		t.Fatalf("default Line does not own DNS final: %v", cfg.DNS)
	}

	var foundDefaultResolver bool
	for _, rawServer := range cfg.DNS["servers"].([]interface{}) {
		server := rawServer.(map[string]interface{})
		if server["tag"] != defaultResolver {
			continue
		}
		foundDefaultResolver = true
		if server["type"] != "https" ||
			server["server"] != "1.1.1.1" ||
			server["detour"] != "tailscale-tailnet" {
			t.Fatalf("unexpected default Line resolver: %v", server)
		}
	}
	if !foundDefaultResolver {
		t.Fatalf("default Line resolver is missing: %v", cfg.DNS["servers"])
	}

	assertTransparentProxyRules(t, transparentProxyUserRules(t, cfg), []string{
		`{"action":"resolve","server":"xdial-system-dns"}`,
		`{"outbound":"direct","rule_set":"ruleset-cnip"}`,
		`{"action":"resolve","server":"proxy-dns-tailscale-tailnet"}`,
	})
	assertTransparentProxyHasNoMobileDNSFallback(t, raw)
}

func TestTransparentProxyMagicDNSToggleCompilesDynamicDNSAndPeerRoutes(t *testing.T) {
	profile := &Profile{
		Lines: []Line{
			{ID: "direct", Type: LineTypeDirect, Enabled: true},
			{
				ID: "tailnet", Type: LineTypeTailscale, Enabled: true,
				TailscaleExitNode: "100.118.7.9", TailscaleMagicDNS: true,
			},
		},
		RuleSets: []RuleSet{
			{
				ID: "ip-first", Name: "IP First", Type: RuleSetTypeManual,
				Enabled: true, CIDRs: []string{"203.0.113.0/24"},
			},
			{
				ID: "cdn", Name: "CDN", Type: RuleSetTypeManual,
				Enabled: true, Domains: []string{"cdn.example.com"},
			},
		},
		Modes: []Mode{{
			ID: "mode",
			Bindings: []RuleBinding{
				{RuleSetID: "ip-first", LineID: "direct"},
				{RuleSetID: "cdn", LineID: "direct"},
			},
			DefaultLineID: "tailnet",
		}},
		ActiveModeID: "mode",
	}

	cfg, raw := generateTransparentProxyDNSTestConfig(t, profile)
	resolverTag := mobileTailscaleDNSTag("tailscale-tailnet")
	assertTransparentProxyRules(t, transparentProxyUserRules(t, cfg), []string{
		`{"action":"resolve","server":"xdial-system-dns"}`,
		`{"ip_cidr":["203.0.113.0/24"],"outbound":"direct"}`,
		`{"action":"resolve","domain_suffix":["cdn.example.com"],"server":"xdial-system-dns"}`,
		`{"domain_suffix":["cdn.example.com"],"outbound":"direct"}`,
		`{"action":"resolve","domain_regex":["^[^.]+$"],"server":"` + resolverTag + `"}`,
		`{"action":"resolve","preferred_by":"tailscale-tailnet","server":"` + resolverTag + `"}`,
		`{"outbound":"tailscale-tailnet","preferred_by":"tailscale-tailnet"}`,
		`{"action":"resolve","server":"proxy-dns-tailscale-tailnet"}`,
	})

	servers := cfg.DNS["servers"].([]interface{})
	if len(servers) != 3 {
		t.Fatalf("expected system, Tailscale, and default-Line DNS servers, got %v", servers)
	}
	tailnetDNS := servers[1].(map[string]interface{})
	if tailnetDNS["type"] != "tailscale" ||
		tailnetDNS["tag"] != resolverTag ||
		tailnetDNS["endpoint"] != "tailscale-tailnet" ||
		tailnetDNS["accept_default_resolvers"] != false ||
		tailnetDNS["accept_search_domain"] != true {
		t.Fatalf("unexpected Tailnet DNS server: %v", tailnetDNS)
	}
	dnsRules := cfg.DNS["rules"].([]interface{})
	if len(dnsRules) != 3 {
		t.Fatalf("expected explicit CDN followed by dynamic MagicDNS rules, got %v", dnsRules)
	}
	first := dnsRules[0].(map[string]interface{})
	second := dnsRules[1].(map[string]interface{})
	third := dnsRules[2].(map[string]interface{})
	if first["server"] != transparentSystemDNSTag ||
		!reflect.DeepEqual(first["domain_suffix"], []interface{}{"cdn.example.com"}) {
		t.Fatalf("explicit CDN DNS ownership must precede MagicDNS: %v", dnsRules)
	}
	if second["preferred_by"] != resolverTag || second["server"] != resolverTag {
		t.Fatalf("MagicDNS ownership is not dynamic: %v", second)
	}
	if third["server"] != resolverTag ||
		!reflect.DeepEqual(third["domain_regex"], []interface{}{tailnetSingleLabelDomainRegex}) {
		t.Fatalf("short Tailnet names are not routed to MagicDNS: %v", third)
	}
	for _, forbidden := range []string{"100.64.0.0/10", "fd7a:115c:a1e0::/48"} {
		if strings.Contains(string(raw), forbidden) {
			t.Fatalf("MagicDNS must not hard-code Tailnet ranges (%s):\n%s", forbidden, raw)
		}
	}
}

func TestTransparentProxyInvertedURLIPRuleKeepsSystemResolutionAndInvertsRoute(t *testing.T) {
	profile := &Profile{
		Lines: []Line{
			{ID: "direct", Type: LineTypeDirect, Enabled: true},
			{
				ID:             "japan",
				Type:           LineTypeTrojan,
				Enabled:        true,
				TrojanServer:   "192.0.2.10",
				TrojanPort:     443,
				TrojanPassword: "secret",
				TrojanSNI:      "proxy.example",
			},
		},
		RuleSets: []RuleSet{{
			ID:               "outside-cn",
			Type:             RuleSetTypeURL,
			Enabled:          true,
			URL:              "file:///tmp/cn.srs",
			Format:           "binary",
			Invert:           true,
			RuntimeMatchKind: RuleSetMatchIP,
		}},
		Modes: []Mode{{
			ID: "mode",
			Bindings: []RuleBinding{{
				RuleSetID: "outside-cn",
				LineID:    "japan",
			}},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "mode",
	}

	cfg, _ := generateTransparentProxyDNSTestConfig(t, profile)
	assertTransparentProxyRules(t, transparentProxyUserRules(t, cfg), []string{
		`{"action":"resolve","server":"xdial-system-dns"}`,
		`{"invert":true,"outbound":"proxy-japan","rule_set":"ruleset-outside-cn"}`,
		`{"action":"resolve","server":"xdial-system-dns"}`,
	})
}

func generateTransparentProxyDNSTestConfig(t *testing.T, profile *Profile) (SingBoxConfig, []byte) {
	t.Helper()
	raw, err := GenerateSingBoxTransparentProxy(
		profile,
		29876,
		"session-user",
		"session-password",
		t.TempDir(),
		"utun-underlay",
		[]string{"100.100.100.100", "172.20.1.1"},
	)
	if err != nil {
		t.Fatal(err)
	}
	var cfg SingBoxConfig
	if err := json.Unmarshal(raw, &cfg); err != nil {
		t.Fatal(err)
	}
	return cfg, raw
}

func transparentProxyOutboundByTag(t *testing.T, cfg SingBoxConfig, tag string) map[string]interface{} {
	t.Helper()
	for _, outbound := range cfg.Outbounds {
		if outbound["tag"] == tag {
			return outbound
		}
	}
	t.Fatalf("outbound %q is missing: %v", tag, cfg.Outbounds)
	return nil
}

func transparentProxyDNSServerByTag(t *testing.T, cfg SingBoxConfig, tag string) map[string]interface{} {
	t.Helper()
	servers, ok := cfg.DNS["servers"].([]interface{})
	if !ok {
		t.Fatalf("invalid DNS servers: %v", cfg.DNS["servers"])
	}
	for _, rawServer := range servers {
		server := rawServer.(map[string]interface{})
		if server["tag"] == tag {
			return server
		}
	}
	t.Fatalf("DNS server %q is missing: %v", tag, servers)
	return nil
}

func assertTransparentProxyNoDNSServerTag(t *testing.T, cfg SingBoxConfig, tag string) {
	t.Helper()
	servers, ok := cfg.DNS["servers"].([]interface{})
	if !ok {
		t.Fatalf("invalid DNS servers: %v", cfg.DNS["servers"])
	}
	for _, rawServer := range servers {
		server := rawServer.(map[string]interface{})
		if server["tag"] == tag {
			t.Fatalf("unexpected DNS server %q: %v", tag, server)
		}
	}
}

func transparentProxyUserRules(t *testing.T, cfg SingBoxConfig) []interface{} {
	t.Helper()
	rules, ok := cfg.Route["rules"].([]interface{})
	if !ok || len(rules) < 2 {
		t.Fatalf("invalid Transparent Proxy route rules: %v", cfg.Route["rules"])
	}
	for index, action := range []string{"sniff", "hijack-dns"} {
		rule, ok := rules[index].(map[string]interface{})
		if !ok || rule["action"] != action {
			t.Fatalf("invalid system route rule %d: %v", index, rules[index])
		}
	}
	return rules[2:]
}

func assertTransparentProxyRules(t *testing.T, got []interface{}, want []string) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("unexpected rule count: got=%d want=%d\nrules=%v", len(got), len(want), got)
	}
	for index := range want {
		encoded, err := json.Marshal(got[index])
		if err != nil {
			t.Fatal(err)
		}
		if string(encoded) != want[index] {
			t.Fatalf("rule %d mismatch:\n got %s\nwant %s", index, encoded, want[index])
		}
	}
}

func assertTransparentProxyHasNoMobileDNSFallback(t *testing.T, raw []byte) {
	t.Helper()
	for _, forbidden := range []string{"xdial-mobile", "public_fallback"} {
		if strings.Contains(string(raw), forbidden) {
			t.Fatalf("Transparent Proxy config contains mobile DNS fallback %q:\n%s", forbidden, raw)
		}
	}
}
