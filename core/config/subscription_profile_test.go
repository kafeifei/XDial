package config

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/option"
	sbrule "github.com/sagernet/sing-box/route/rule"
	"reflect"
	"testing"
)

func groupedSubscriptionProfileFixture(t *testing.T, rules []SubscriptionRule) *Profile {
	t.Helper()
	profile, err := ImportSubscriptionProfile("airport", []Line{{Name: "Edge", Type: LineTypeAnyTLS, Enabled: true, AnyTLSServer: "192.0.2.1", AnyTLSPort: 443, AnyTLSPassword: "test-only", AnyTLSSNI: "edge.example"}}, []ProxyGroup{{Name: "Proxy", Type: "select", Proxies: []string{"Edge", "DIRECT"}}}, rules, false)
	if err != nil {
		t.Fatal(err)
	}
	flat, err := ExpandRuleSetGroups(profile)
	if err != nil {
		t.Fatal(err)
	}
	grouped, err := CompactProfileRuleSets(flat)
	if err != nil {
		t.Fatal(err)
	}
	return grouped
}

func subscriptionProfileFixture(t *testing.T, rules []SubscriptionRule) *Profile {
	profile, err := ExpandRuleSetGroups(groupedSubscriptionProfileFixture(t, rules))
	if err != nil {
		t.Fatal(err)
	}
	return profile
}

func TestSubscriptionProfileProcessRulesKeepPlatformSemanticsAndOrder(t *testing.T) {
	processes := []string{"Claude", "Claude Helper*", "/Applications/Example.app/Contents/MacOS/Example", "/opt/example/"}
	rules := []SubscriptionRule{{Type: "DOMAIN", Value: "first.example", Group: "DIRECT"}}
	for _, process := range processes {
		rules = append(rules, SubscriptionRule{Type: "PROCESS-NAME", Value: process, Group: "Proxy"})
	}
	rules = append(rules, SubscriptionRule{Type: "DOMAIN", Value: "last.example", Group: "Proxy"}, SubscriptionRule{Type: "FINAL", Group: "DIRECT"})
	profile := subscriptionProfileFixture(t, rules)
	scenario := profile.ActiveScenario()
	if scenario.DefaultLineID != "direct" || len(scenario.Bindings) != 3 {
		t.Fatal("source priority/default lost")
	}
	rule := profile.FindRuleSet(scenario.Bindings[1].RuleSetID)
	if rule.Type != RuleSetTypeApplication || !reflect.DeepEqual(rule.Processes, processes) {
		t.Fatal("process expressions lost during grouping")
	}
	compiled := compileTransparentProxyRuleSet(rule, "proxy", "session", "")
	if len(compiled) != 1 || len(compiled[0]["auth_user"].([]string)) != len(processes) {
		t.Fatal("existing application identity adapter not used")
	}

	cfg, raw := generateTransparentProxyDNSTestConfig(t, profile)
	if cfg.Route["rules"] == nil {
		t.Fatal("missing routing")
	}
	singboxCheckConfig(t, raw, "subscription-process-rules")
}

func TestSubscriptionProfileIPOptionsResourcesAndRoundTrip(t *testing.T) {
	profile := subscriptionProfileFixture(t, []SubscriptionRule{
		{Type: "IP-CIDR", Value: "192.0.2.0/24", Group: "DIRECT", Options: "no-resolve"},
		{Type: "IP-CIDR", Value: "198.51.100.0/24", Group: "DIRECT"},
		{Type: "GEOIP", Value: "CN", Group: "DIRECT"},
		{Type: "IP-ASN", Value: "32934", Group: "Proxy", Options: "no-resolve"},
		{Type: "USER-AGENT", Value: "Example*", Group: "Proxy"},
		{Type: "FINAL", Group: "Proxy"},
	})
	if len(profile.RuleSets) != 4 || len(profile.ImportWarnings) != 1 || profile.ImportWarnings[0].Value != "Example*" {
		t.Fatal("rules were lost without retaining review information")
	}
	for _, index := range []int{0, 3} {
		rule := &profile.RuleSets[index]
		if !rule.NoResolve {
			t.Fatal("no-resolve was lost")
		}
		compiled := compileTransparentProxyRuleSet(rule, "direct", "session", "")
		if len(compiled) != 1 || compiled[0]["action"] == "resolve" {
			t.Fatal("no-resolve initiated a DNS query")
		}
	}
	if len(compileTransparentProxyRuleSet(&profile.RuleSets[1], "direct", "session", "")) != 2 {
		t.Fatal("ordinary IP rule stopped resolving")
	}
	if profile.RuleSets[2].URL != importedGeoIPURL+"cn.srs" || profile.RuleSets[3].URL != importedASNURL+"32934.srs" {
		t.Fatal("missing explicit geographic resources")
	}
	plan, err := BuildConnectionPlan(profile)
	if err != nil {
		t.Fatal(err)
	}
	profile.RuleSets[0].NoResolve = false
	other, err := BuildConnectionPlan(profile)
	if err != nil {
		t.Fatal(err)
	}
	if plan.ConfigurationFingerprint == other.ConfigurationFingerprint {
		t.Fatal("DNS behavior not included in runtime identity")
	}
	profile.RuleSets[0].NoResolve = true
	exported, err := ExportProfileDocument(profile)
	if err != nil {
		t.Fatal(err)
	}
	copy, err := ImportProfileDocument(exported, "copy")
	if err != nil {
		t.Fatal(err)
	}
	if !copy.RuleSets[0].NoResolve || !reflect.DeepEqual(copy.ImportWarnings, profile.ImportWarnings) {
		t.Fatal("round trip lost options or unsupported source rules")
	}
}

func TestSubscriptionProfileRejectsInvalidRulesAndOptions(t *testing.T) {
	for _, entry := range []SubscriptionRule{
		{Type: "PROCESS-NAME", Value: "bad/name"}, {Type: "GEOIP", Value: "../CN"},
		{Type: "IP-ASN", Value: "4294967296"}, {Type: "IP-ASN", Value: "0"},
		{Type: "DOMAIN", Value: "example.com", Options: "no-resolve"},
		{Type: "IP-CIDR", Value: "192.0.2.0/24", Options: "unknown"},
		{Type: "UNKNOWN", Value: "example"},
	} {
		if _, err := importSubscriptionRule(entry); err == nil {
			t.Fatalf("invalid %s accepted", entry.Type)
		}
	}
}

func TestSubscriptionProfileGroupsLargeSourcesAndKeepsStableIDs(t *testing.T) {
	rules := []SubscriptionRule{}
	for i := 0; i < 7000; i++ {
		rules = append(rules, SubscriptionRule{Type: "DOMAIN", Value: fmt.Sprintf("host%d.example", i), Group: "Proxy"})
	}
	profile := subscriptionProfileFixture(t, rules)
	if len(profile.RuleSets) != 1 || len(profile.ActiveScenario().Bindings) != 1 {
		t.Fatal("each match became a UI rule set")
	}
	var fields map[string][]string
	_ = json.Unmarshal(profile.RuleSets[0].NativeRule, &fields)
	if len(fields["domain"]) != 7000 {
		t.Fatal("grouping discarded conditions")
	}
	rules = append(rules, SubscriptionRule{Type: "DOMAIN-SUFFIX", Value: "new.example", Group: "Proxy"})
	updated := subscriptionProfileFixture(t, rules)
	if updated.RuleSets[0].ID != profile.RuleSets[0].ID {
		t.Fatal("adding a condition changed the shared resource identity")
	}
}

func TestSubscriptionProfileGroupingPreservesSingBoxFirstMatch(t *testing.T) {
	profile := subscriptionProfileFixture(t, []SubscriptionRule{
		{Type: "DOMAIN", Value: "first.example", Group: "Proxy"},
		{Type: "DOMAIN-SUFFIX", Value: "video.example", Group: "Proxy"},
		{Type: "DOMAIN-KEYWORD", Value: "media", Group: "Proxy"},
		{Type: "DOMAIN", Value: "specific.example", Group: "DIRECT"},
		{Type: "DOMAIN-SUFFIX", Value: "example", Group: "Proxy"},
		{Type: "FINAL", Group: "DIRECT"},
	})
	if len(profile.RuleSets) != 3 {
		t.Fatal("nonadjacent policies merged")
	}
	for _, tc := range []struct {
		domain string
		direct bool
	}{
		{"first.example", false}, {"sub.video.example", false}, {"media.test", false}, {"specific.example", true}, {"other.example", false}, {"unmatched.test", true},
	} {
		target := profile.ActiveScenario().DefaultLineID
		for _, binding := range profile.ActiveScenario().Bindings {
			var opt option.HeadlessRule
			if err := json.Unmarshal(profile.FindRuleSet(binding.RuleSetID).NativeRule, &opt); err != nil {
				t.Fatal(err)
			}
			matcher, err := sbrule.NewHeadlessRule(context.Background(), opt)
			if err != nil {
				t.Fatal(err)
			}
			if matcher.Match(&adapter.InboundContext{Domain: tc.domain}) {
				target = binding.LineID
				break
			}
		}
		if (target == "direct") != tc.direct {
			t.Fatalf("sing-box selected the wrong policy for %s", tc.domain)
		}
	}
	_, raw := generateTransparentProxyDNSTestConfig(t, profile)
	singboxCheckConfig(t, raw, "grouped-subscription")
}

func TestSubscriptionProfileKeepsRemoteSourceAndDNSBoundaries(t *testing.T) {
	profile := subscriptionProfileFixture(t, []SubscriptionRule{
		{Type: "DOMAIN", Value: "one.example", Group: "Proxy", SourceID: "one"},
		{Type: "DOMAIN", Value: "two.example", Group: "Proxy", SourceID: "two"},
		{Type: "IP-CIDR", Value: "192.0.2.0/24", Group: "Proxy", Options: "no-resolve"},
		{Type: "IP-CIDR", Value: "198.51.100.0/24", Group: "Proxy"},
	})
	if len(profile.RuleSets) != 4 {
		t.Fatal("different sources or DNS behavior were conflated")
	}
}
