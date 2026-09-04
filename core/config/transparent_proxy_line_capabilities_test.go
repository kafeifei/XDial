package config

import (
	"encoding/json"
	"strings"
	"testing"
)

var (
	dualStackCapability = LineAddressFamilyCapability{
		IPv4Available: true,
		IPv6Available: true,
	}
	ipv4OnlyCapability = LineAddressFamilyCapability{IPv4Available: true}
	ipv6OnlyCapability = LineAddressFamilyCapability{IPv6Available: true}
)

func transparentProxyCapabilityTestLine(kind LineType) (Line, string, string) {
	switch kind {
	case LineTypeDirect:
		return Line{ID: "direct", Type: LineTypeDirect, Enabled: true},
			"direct", TransparentNativeDNSTag
	case LineTypeVPN:
		return Line{
			ID: "vpn", Type: LineTypeVPN, Enabled: true,
			VPNServer: "vpn.example:443", VPNUsername: "user", VPNPassword: "secret",
		}, "vpn", desktopProxyDNSTag("vpn")
	case LineTypeTailscale:
		return Line{
			ID: "tailnet", Type: LineTypeTailscale, Enabled: true,
			TailscaleExitNode: "100.118.7.9",
		}, "tailscale-tailnet", desktopProxyDNSTag("tailscale-tailnet")
	default:
		return Line{
			ID: "proxy", Type: LineTypeAnyTLS, Enabled: true,
			AnyTLSServer: "node.example", AnyTLSPort: 443, AnyTLSPassword: "secret",
		}, "proxy-proxy", desktopProxyDNSTag("proxy-proxy")
	}
}

func generateTransparentProxyCapabilityTestConfig(
	t *testing.T,
	profile *Profile,
	capabilities TransparentProxyLineCapabilities,
) SingBoxConfig {
	t.Helper()
	raw, err := GenerateSingBoxTransparentProxyWithLineCapabilities(
		profile,
		29876,
		"session-user",
		"session-password",
		t.TempDir(),
		"utun-underlay",
		[]string{"100.100.100.100"},
		capabilities,
	)
	if err != nil {
		t.Fatalf("GenerateSingBoxTransparentProxyWithLineCapabilities: %v", err)
	}
	var generated SingBoxConfig
	if err := json.Unmarshal(raw, &generated); err != nil {
		t.Fatalf("decode generated config: %v", err)
	}
	return generated
}

func transparentProxyCapabilityTestRules(
	t *testing.T,
	raw interface{},
) []map[string]interface{} {
	t.Helper()
	values, ok := raw.([]interface{})
	if !ok {
		return nil
	}
	rules := make([]map[string]interface{}, 0, len(values))
	for _, value := range values {
		rule, ok := value.(map[string]interface{})
		if !ok {
			t.Fatalf("unexpected rule type %T", value)
		}
		rules = append(rules, rule)
	}
	return rules
}

func transparentProxyCapabilityTestDNSServer(
	t *testing.T,
	generated SingBoxConfig,
	tag string,
) map[string]interface{} {
	t.Helper()
	servers := transparentProxyCapabilityTestRules(t, generated.DNS["servers"])
	for _, server := range servers {
		if server["tag"] == tag {
			return server
		}
	}
	t.Fatalf("DNS server %q was not generated: %v", tag, generated.DNS["servers"])
	return nil
}

func transparentProxyCapabilityTestRule(
	t *testing.T,
	rules []map[string]interface{},
	predicate func(map[string]interface{}) bool,
) map[string]interface{} {
	t.Helper()
	for _, rule := range rules {
		if predicate(rule) {
			return rule
		}
	}
	t.Fatal("expected rule was not generated")
	return nil
}

func TestTransparentProxyLineCapabilitiesDefaultResolutionMatrix(t *testing.T) {
	tests := []struct {
		name       string
		lineType   LineType
		capability LineAddressFamilyCapability
		strategy   string
	}{
		{name: "direct-dual", lineType: LineTypeDirect, capability: dualStackCapability},
		{name: "direct-ipv4", lineType: LineTypeDirect, capability: ipv4OnlyCapability, strategy: "ipv4_only"},
		{name: "proxy-dual", lineType: LineTypeAnyTLS, capability: dualStackCapability},
		{name: "proxy-ipv4", lineType: LineTypeAnyTLS, capability: ipv4OnlyCapability, strategy: "ipv4_only"},
		{name: "proxy-ipv6", lineType: LineTypeAnyTLS, capability: ipv6OnlyCapability, strategy: "ipv6_only"},
		{name: "vpn-dual", lineType: LineTypeVPN, capability: dualStackCapability},
		{name: "vpn-ipv4", lineType: LineTypeVPN, capability: ipv4OnlyCapability, strategy: "ipv4_only"},
		{name: "vpn-ipv6", lineType: LineTypeVPN, capability: ipv6OnlyCapability, strategy: "ipv6_only"},
		{name: "tailscale-dual", lineType: LineTypeTailscale, capability: dualStackCapability},
		{name: "tailscale-ipv4", lineType: LineTypeTailscale, capability: ipv4OnlyCapability, strategy: "ipv4_only"},
		{name: "tailscale-ipv6", lineType: LineTypeTailscale, capability: ipv6OnlyCapability, strategy: "ipv6_only"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			line, outboundTag, resolverTag := transparentProxyCapabilityTestLine(test.lineType)
			profile := &Profile{
				Lines:            []Line{line},
				Scenarios:        []Scenario{{ID: "scenario", DefaultLineID: line.ID}},
				ActiveScenarioID: "scenario",
			}
			capabilities := TransparentProxyLineCapabilities{line.ID: test.capability}
			if line.ID != builtinDirectLineID {
				profile.Lines = append(profile.Lines,
					Line{ID: builtinDirectLineID, Type: LineTypeDirect, Enabled: true})
				capabilities[builtinDirectLineID] = dualStackCapability
			}
			generated := generateTransparentProxyCapabilityTestConfig(t, profile, capabilities)

			if generated.Route["final"] != outboundTag || generated.DNS["final"] != resolverTag {
				t.Fatalf("default ownership drifted: route=%v dns=%v", generated.Route, generated.DNS)
			}
			if line.ID != builtinDirectLineID {
				resolver := transparentProxyCapabilityTestDNSServer(t, generated, resolverTag)
				wantServer := transparentProxyDoHIPv4Server
				if test.strategy == "ipv6_only" {
					wantServer = transparentProxyDoHIPv6Server
				}
				if resolver["type"] != "https" || resolver["server"] != wantServer ||
					resolver["detour"] != outboundTag {
					t.Fatalf("default resolver transport does not match Line capability: %v", resolver)
				}
				tls, ok := resolver["tls"].(map[string]interface{})
				if !ok || tls["enabled"] != true || tls["server_name"] != "one.one.one.one" {
					t.Fatalf("Line resolver TLS identity is unavailable: %v", resolver)
				}
			}
			routeRule := transparentProxyCapabilityTestRule(
				t,
				transparentProxyCapabilityTestRules(t, generated.Route["rules"]),
				func(rule map[string]interface{}) bool {
					return rule["action"] == "resolve" && rule["server"] == resolverTag
				},
			)
			if got, _ := routeRule["strategy"].(string); got != test.strategy {
				t.Fatalf("default route strategy = %q, want %q: %v", got, test.strategy, routeRule)
			}
			dnsRules := transparentProxyCapabilityTestRules(t, generated.DNS["rules"])
			var defaultDNS map[string]interface{}
			for _, rule := range dnsRules {
				if len(rule) <= 2 && rule["server"] == resolverTag {
					defaultDNS = rule
				}
			}
			if test.strategy == "" {
				if defaultDNS != nil {
					t.Fatalf("dual-stack default unexpectedly emitted a strategy rule: %v", defaultDNS)
				}
			} else if defaultDNS == nil || defaultDNS["strategy"] != test.strategy {
				t.Fatalf("default DNS strategy mismatch: %v", generated.DNS["rules"])
			}

			inbound := generated.Inbounds[0]
			if inbound["xdial_reresolve_ipv4_flow_domains"] != nil ||
				inbound["xdial_reresolve_ipv6_flow_domains"] != nil {
				t.Fatalf("Line capability leaked into the shared ingress: %v", inbound)
			}

			directOutbound := transparentProxyOutboundByTag(t, generated, "direct")
			if line.ID == builtinDirectLineID && test.strategy != "" {
				resolver, ok := directOutbound["domain_resolver"].(map[string]interface{})
				if !ok || resolver["server"] != TransparentNativeDNSTag || resolver["strategy"] != test.strategy {
					t.Fatalf("Direct outbound strategy mismatch: %v", directOutbound)
				}
			} else if _, exists := directOutbound["domain_resolver"]; exists {
				t.Fatalf("Direct outbound inherited another Line's capability: %v", directOutbound)
			}
			if test.lineType == LineTypeAnyTLS {
				proxyOutbound := transparentProxyOutboundByTag(t, generated, outboundTag)
				if proxyOutbound["domain_resolver"] != desktopPublicDNSTag {
					t.Fatalf("proxy endpoint bootstrap resolver was polluted: %v", proxyOutbound)
				}
			}
		})
	}
}

func TestTransparentProxyLineCapabilitiesBindingResolutionMatrix(t *testing.T) {
	for _, lineType := range []LineType{
		LineTypeDirect,
		LineTypeAnyTLS,
		LineTypeVPN,
		LineTypeTailscale,
	} {
		t.Run(string(lineType), func(t *testing.T) {
			line, outboundTag, resolverTag := transparentProxyCapabilityTestLine(lineType)
			if lineType == LineTypeVPN {
				resolverTag = transparentEnterpriseDNSTag
			}
			profile := &Profile{
				Lines: []Line{line},
				RuleSets: []RuleSet{{
					ID: "domain", Type: RuleSetTypeManual, Enabled: true,
					Domains: []string{"example.test"},
				}},
				Scenarios: []Scenario{{
					ID:            "scenario",
					Bindings:      []RuleBinding{{RuleSetID: "domain", LineID: line.ID}},
					DefaultLineID: builtinDirectLineID,
				}},
				ActiveScenarioID: "scenario",
			}
			capabilities := TransparentProxyLineCapabilities{
				line.ID: ipv4OnlyCapability,
			}
			if line.ID != builtinDirectLineID {
				profile.Lines = append(profile.Lines,
					Line{ID: builtinDirectLineID, Type: LineTypeDirect, Enabled: true})
				capabilities[builtinDirectLineID] = dualStackCapability
			}
			generated := generateTransparentProxyCapabilityTestConfig(t, profile, capabilities)

			dnsRule := transparentProxyCapabilityTestRule(
				t,
				transparentProxyCapabilityTestRules(t, generated.DNS["rules"]),
				func(rule map[string]interface{}) bool {
					return rule["server"] == resolverTag && rule["domain_suffix"] != nil
				},
			)
			if dnsRule["strategy"] != "ipv4_only" {
				t.Fatalf("binding DNS strategy mismatch: %v", dnsRule)
			}
			routeRules := transparentProxyCapabilityTestRules(t, generated.Route["rules"])
			resolve := transparentProxyCapabilityTestRule(t, routeRules, func(rule map[string]interface{}) bool {
				return rule["action"] == "resolve" && rule["server"] == resolverTag && rule["domain_suffix"] != nil
			})
			if resolve["strategy"] != "ipv4_only" {
				t.Fatalf("binding route strategy mismatch: %v", resolve)
			}
			transparentProxyCapabilityTestRule(t, routeRules, func(rule map[string]interface{}) bool {
				return rule["outbound"] == outboundTag && rule["domain_suffix"] != nil
			})
		})
	}
}

func TestTransparentProxyLineCapabilitiesCombineActiveSignalsWithoutCrossing(t *testing.T) {
	proxy, _, proxyResolver := transparentProxyCapabilityTestLine(LineTypeAnyTLS)
	profile := &Profile{
		Lines: []Line{
			{ID: "direct", Type: LineTypeDirect, Enabled: true},
			proxy,
		},
		RuleSets: []RuleSet{{
			ID: "direct-domain", Type: RuleSetTypeManual, Enabled: true,
			Domains: []string{"direct.example"},
		}},
		Scenarios: []Scenario{{
			ID:            "scenario",
			Bindings:      []RuleBinding{{RuleSetID: "direct-domain", LineID: "direct"}},
			DefaultLineID: "proxy",
		}},
		ActiveScenarioID: "scenario",
	}
	generated := generateTransparentProxyCapabilityTestConfig(t, profile,
		TransparentProxyLineCapabilities{
			"direct": ipv4OnlyCapability,
			"proxy":  ipv6OnlyCapability,
		})
	inbound := generated.Inbounds[0]
	if inbound["xdial_reresolve_ipv4_flow_domains"] != nil ||
		inbound["xdial_reresolve_ipv6_flow_domains"] != nil {
		t.Fatalf("single-stack Line capability leaked into the shared ingress: %v", inbound)
	}
	routeRules := transparentProxyCapabilityTestRules(t, generated.Route["rules"])
	directResolve := transparentProxyCapabilityTestRule(t, routeRules, func(rule map[string]interface{}) bool {
		return rule["domain_suffix"] != nil && rule["server"] == TransparentNativeDNSTag
	})
	defaultResolve := transparentProxyCapabilityTestRule(t, routeRules, func(rule map[string]interface{}) bool {
		return rule["domain_suffix"] == nil && rule["server"] == proxyResolver
	})
	if directResolve["strategy"] != "ipv4_only" || defaultResolve["strategy"] != "ipv6_only" {
		t.Fatalf("Line strategies crossed: direct=%v default=%v", directResolve, defaultResolve)
	}
}

func TestTransparentProxyLineCapabilityAppliesToURLDomainBinding(t *testing.T) {
	proxy, _, resolverTag := transparentProxyCapabilityTestLine(LineTypeAnyTLS)
	profile := &Profile{
		Lines: []Line{
			{ID: "direct", Type: LineTypeDirect, Enabled: true},
			proxy,
		},
		RuleSets: []RuleSet{{
			ID: "remote-domain", Type: RuleSetTypeURL, Enabled: true,
			URL: "file:///tmp/remote-domain.srs", Format: "binary",
			RuntimeMatchKind: RuleSetMatchDomain,
		}},
		Scenarios: []Scenario{{
			ID:            "scenario",
			Bindings:      []RuleBinding{{RuleSetID: "remote-domain", LineID: "proxy"}},
			DefaultLineID: "direct",
		}},
		ActiveScenarioID: "scenario",
	}
	generated := generateTransparentProxyCapabilityTestConfig(t, profile,
		TransparentProxyLineCapabilities{
			"direct": dualStackCapability,
			"proxy":  ipv6OnlyCapability,
		})
	for surface, rawRules := range map[string]interface{}{
		"dns":   generated.DNS["rules"],
		"route": generated.Route["rules"],
	} {
		rule := transparentProxyCapabilityTestRule(
			t,
			transparentProxyCapabilityTestRules(t, rawRules),
			func(rule map[string]interface{}) bool {
				return rule["rule_set"] == "ruleset-remote-domain" && rule["server"] == resolverTag
			},
		)
		if rule["strategy"] != "ipv6_only" {
			t.Fatalf("%s URL-domain strategy mismatch: %v", surface, rule)
		}
	}
}

func TestTransparentProxyConstrainedApplicationBindingResolvesWithSameIdentity(t *testing.T) {
	profile := testProfile()
	profile.RuleSets = append(profile.RuleSets, applicationRuleSetForTest())
	profile.Scenarios[0].Bindings = append(profile.Scenarios[0].Bindings, RuleBinding{
		RuleSetID: "claude-app",
		LineID:    "ss",
	})
	generated := generateTransparentProxyCapabilityTestConfig(t, profile,
		TransparentProxyLineCapabilities{
			"direct": dualStackCapability,
			"vpn":    dualStackCapability,
			"ss":     ipv4OnlyCapability,
		})

	routeRules := transparentProxyCapabilityTestRules(t, generated.Route["rules"])
	resolveIndex := -1
	for index, rule := range routeRules {
		if rule["action"] == "resolve" && rule["server"] == desktopProxyDNSTag("proxy-ss") {
			if _, ok := rule["auth_user"]; ok {
				resolveIndex = index
				break
			}
		}
	}
	if resolveIndex < 0 || resolveIndex+1 >= len(routeRules) {
		t.Fatalf("constrained application resolve was not generated: %v", routeRules)
	}
	resolve := routeRules[resolveIndex]
	route := routeRules[resolveIndex+1]
	if resolve["strategy"] != "ipv4_only" || route["outbound"] != "proxy-ss" ||
		!jsonValuesEqual(resolve["auth_user"], route["auth_user"]) {
		t.Fatalf("application resolve/route identity drifted: resolve=%v route=%v", resolve, route)
	}
	dnsRule := transparentProxyCapabilityTestRule(
		t,
		transparentProxyCapabilityTestRules(t, generated.DNS["rules"]),
		func(rule map[string]interface{}) bool {
			return rule["server"] == desktopProxyDNSTag("proxy-ss") && rule["auth_user"] != nil
		},
	)
	if dnsRule["strategy"] != "ipv4_only" || !jsonValuesEqual(dnsRule["auth_user"], resolve["auth_user"]) {
		t.Fatalf("application DNS identity/strategy drifted: dns=%v resolve=%v", dnsRule, resolve)
	}
}

func TestTransparentProxyIPv6OnlyApplicationUsesIPv6DoHTransport(t *testing.T) {
	profile := &Profile{
		Lines: []Line{
			{ID: "direct", Type: LineTypeDirect, Enabled: true},
			{
				ID: "ss", Type: LineTypeTrojan, Enabled: true,
				TrojanServer: "proxy.example.com", TrojanPort: 443,
				TrojanPassword: "secret", TrojanSNI: "proxy.example.com",
			},
		},
		RuleSets: []RuleSet{applicationRuleSetForTest()},
		Scenarios: []Scenario{{
			ID: "scenario",
			Bindings: []RuleBinding{{
				RuleSetID: "claude-app",
				LineID:    "ss",
			}},
			DefaultLineID: "direct",
		}},
		ActiveScenarioID: "scenario",
	}
	generated := generateTransparentProxyCapabilityTestConfig(t, profile,
		TransparentProxyLineCapabilities{
			"direct": dualStackCapability,
			"ss":     ipv6OnlyCapability,
		})

	resolverTag := desktopProxyDNSTag("proxy-ss")
	resolver := transparentProxyCapabilityTestDNSServer(t, generated, resolverTag)
	if resolver["type"] != "https" ||
		resolver["server"] != transparentProxyDoHIPv6Server ||
		resolver["detour"] != "proxy-ss" {
		t.Fatalf("IPv6-only application resolver still depends on IPv4: %v", resolver)
	}
	tls, ok := resolver["tls"].(map[string]interface{})
	if !ok || tls["enabled"] != true || tls["server_name"] != "one.one.one.one" {
		t.Fatalf("IPv6-only application resolver cannot authenticate TLS by name: %v", resolver)
	}
	for surface, rawRules := range map[string]interface{}{
		"dns":   generated.DNS["rules"],
		"route": generated.Route["rules"],
	} {
		rule := transparentProxyCapabilityTestRule(
			t,
			transparentProxyCapabilityTestRules(t, rawRules),
			func(rule map[string]interface{}) bool {
				return rule["server"] == resolverTag && rule["auth_user"] != nil
			},
		)
		if rule["strategy"] != "ipv6_only" {
			t.Fatalf("%s application strategy mismatch: %v", surface, rule)
		}
	}
	raw, err := json.Marshal(generated)
	if err != nil {
		t.Fatalf("encode IPv6-only application config: %v", err)
	}
	singboxCheckConfig(t, raw, "transparent-ipv6-only-application")
}

func TestTransparentProxyLineCapabilitiesDoNotRewriteSubscriptionRules(t *testing.T) {
	profile := &Profile{
		Lines: []Line{{ID: "direct", Type: LineTypeDirect, Enabled: true}},
		RuleSets: []RuleSet{{
			ID: "stream", Type: RuleSetTypeManual, Enabled: true,
			Domains: []string{"video.example"},
		}},
		Subscriptions: []Subscription{{
			ID: "sub", Enabled: true, Strategy: "selector",
			Lines: []Line{{
				ID: "node", Type: LineTypeAnyTLS, Enabled: true,
				AnyTLSServer: "node.example", AnyTLSPort: 443, AnyTLSPassword: "secret",
			}},
		}},
		Scenarios: []Scenario{{
			ID:            "scenario",
			Bindings:      []RuleBinding{{RuleSetID: "stream", SubscriptionID: "sub"}},
			DefaultLineID: "direct",
		}},
		ActiveScenarioID: "scenario",
	}
	generated := generateTransparentProxyCapabilityTestConfig(t, profile,
		TransparentProxyLineCapabilities{"direct": ipv4OnlyCapability})
	resolverTag := desktopProxyDNSTag("sub-sub")
	dnsRule := transparentProxyCapabilityTestRule(
		t,
		transparentProxyCapabilityTestRules(t, generated.DNS["rules"]),
		func(rule map[string]interface{}) bool {
			return rule["domain_suffix"] != nil && rule["server"] == resolverTag
		},
	)
	if _, exists := dnsRule["strategy"]; exists {
		t.Fatalf("subscription DNS rule inherited a Line capability: %v", dnsRule)
	}
	routeRule := transparentProxyCapabilityTestRule(
		t,
		transparentProxyCapabilityTestRules(t, generated.Route["rules"]),
		func(rule map[string]interface{}) bool {
			return rule["domain_suffix"] != nil && rule["action"] == "resolve" &&
				rule["server"] == resolverTag
		},
	)
	if _, exists := routeRule["strategy"]; exists {
		t.Fatalf("subscription route rule inherited a Line capability: %v", routeRule)
	}
}

func TestTransparentProxyInactiveLineCapabilityHasZeroEffect(t *testing.T) {
	profile := &Profile{
		Lines: []Line{
			{ID: "direct", Type: LineTypeDirect, Enabled: true},
			{
				ID: "unused", Type: LineTypeAnyTLS, Enabled: true,
				AnyTLSServer: "unused.example", AnyTLSPort: 443, AnyTLSPassword: "secret",
			},
		},
		Scenarios:        []Scenario{{ID: "scenario", DefaultLineID: "direct"}},
		ActiveScenarioID: "scenario",
	}
	generated := generateTransparentProxyCapabilityTestConfig(t, profile,
		TransparentProxyLineCapabilities{
			"direct": dualStackCapability,
			"unused": ipv4OnlyCapability,
		})
	inbound := generated.Inbounds[0]
	if inbound["xdial_reresolve_ipv4_flow_domains"] == true ||
		inbound["xdial_reresolve_ipv6_flow_domains"] == true {
		t.Fatalf("inactive Line capability changed ingress: %v", inbound)
	}
	for _, outbound := range generated.Outbounds {
		if outbound["tag"] == "proxy-unused" {
			t.Fatalf("inactive Line entered the generated data plane: %v", outbound)
		}
	}
}

func jsonValuesEqual(left, right interface{}) bool {
	leftJSON, _ := json.Marshal(left)
	rightJSON, _ := json.Marshal(right)
	return string(leftJSON) == string(rightJSON)
}

func TestTransparentProxyLineCapabilitiesValidation(t *testing.T) {
	profile := &Profile{
		Lines: []Line{
			{ID: "direct", Type: LineTypeDirect, Enabled: true},
			{ID: "proxy", Type: LineTypeAnyTLS, Enabled: true,
				AnyTLSServer: "192.0.2.10", AnyTLSPort: 443, AnyTLSPassword: "secret"},
		},
		Scenarios:        []Scenario{{ID: "scenario", DefaultLineID: "proxy"}},
		ActiveScenarioID: "scenario",
	}
	generate := func(capabilities TransparentProxyLineCapabilities) error {
		_, err := GenerateSingBoxTransparentProxyWithLineCapabilities(
			profile, 29876, "user", "password", t.TempDir(), "en0",
			[]string{"100.100.100.100"}, capabilities,
		)
		return err
	}
	for _, test := range []struct {
		name         string
		capabilities TransparentProxyLineCapabilities
		want         string
	}{
		{name: "nil", want: "capabilities are unavailable"},
		{name: "missing-active", capabilities: TransparentProxyLineCapabilities{"direct": dualStackCapability}, want: "active Line \"proxy\" is missing"},
		{name: "empty-id", capabilities: TransparentProxyLineCapabilities{"": dualStackCapability, "proxy": dualStackCapability}, want: "empty Line ID"},
		{name: "neither-family", capabilities: TransparentProxyLineCapabilities{"proxy": {}}, want: "neither IPv4 nor IPv6"},
		{name: "pure-ipv6-direct", capabilities: TransparentProxyLineCapabilities{
			"direct": ipv6OnlyCapability,
			"proxy":  dualStackCapability,
		}, want: "pure IPv6 Direct capability is unsupported"},
	} {
		t.Run(test.name, func(t *testing.T) {
			err := generate(test.capabilities)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want substring %q", err, test.want)
			}
		})
	}
}
