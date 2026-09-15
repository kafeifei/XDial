package config

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func TestImportedRulesDescribeMatchesWhileScenarioKeepsDestinations(t *testing.T) {
	lines := []Line{{Name: "Edge", Type: LineTypeAnyTLS, Enabled: true, AnyTLSServer: "192.0.2.1", AnyTLSPort: 443, AnyTLSPassword: "test", AnyTLSSNI: "edge.example"}}
	groups := []ProxyGroup{{Name: "Proxies", Type: "select", Proxies: []string{"Edge"}}}
	rules := []SubscriptionRule{
		{Type: "DOMAIN-SUFFIX", Value: "push.apple.com", Group: "Proxies"},
		{Type: "DOMAIN-SUFFIX", Value: "apple.com", Group: "DIRECT"},
		{Type: "DOMAIN-SUFFIX", Value: "foreign.example", Group: "Proxies"},
		{Type: "IP-CIDR", Value: "192.0.2.0/24", Group: "Proxies", Options: "no-resolve"},
		{Type: "FINAL", Group: "DIRECT"},
	}
	p, err := ImportSubscriptionProfile("fixture", lines, groups, rules, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(p.RuleSets) != 2 || p.RuleSets[0].Name != "Proxies" || len(p.RuleSets[0].Conditions) != 3 || len(p.Scenarios[0].MatchOrder) != 4 {
		t.Fatal("destination grouping or original priority lost")
	}
	p, err = ExpandRuleSetGroups(p)
	if err != nil {
		t.Fatal(err)
	}
	if len(p.RuleSets) != 4 || len(p.ActiveScenario().Bindings) != 4 {
		t.Fatal("source segments lost")
	}
	if p.FindRuleSet(p.ActiveScenario().Bindings[0].RuleSetID).Name != "域名 · push.apple.com" {
		t.Fatal(p.RuleSets[0].Name)
	}
	for _, rule := range p.RuleSets {
		if rule.Type == RuleSetTypeGroup || strings.Contains(rule.Name, "Proxies") || strings.Contains(rule.Name, "Direct") {
			t.Fatal("destination leaked into matching resources")
		}
	}
	b := p.ActiveScenario().Bindings
	if b[0].LineID != b[2].LineID || b[1].LineID != "direct" || b[3].LineID != b[0].LineID || p.ActiveScenario().DefaultLineID != "direct" {
		t.Fatal("Scenario destination or order lost")
	}
	if !p.FindRuleSet(b[3].RuleSetID).NoResolve {
		t.Fatal("DNS semantics lost")
	}
	original, err := CompactProfileRuleSets(p)
	if err != nil {
		t.Fatal(err)
	}
	for _, scene := range p.Scenarios {
		p.ActiveScenarioID, original.ActiveScenarioID = scene.ID, scene.ID
		before, e1 := BuildConnectionPlan(original)
		after, e2 := BuildConnectionPlan(p)
		if e1 != nil || e2 != nil || before.ConfigurationFingerprint != after.ConfigurationFingerprint {
			t.Fatal("separation changed execution")
		}
	}
}

func TestSeparateImportedRulesPreservesEveryLocalScenarioAndSharedLine(t *testing.T) {
	p := mixedGroupedFixture(t)
	p.Scenarios = append(p.Scenarios, Scenario{ID: "local", Name: "海外", DefaultLineID: "direct", Bindings: []RuleBinding{{RuleSetID: p.RuleSets[2].ID, LineID: "direct"}, {RuleSetID: p.RuleSets[0].ID, LineID: p.Scenarios[0].Bindings[0].LineID}}})
	p.Scenarios[1].MatchSSIDs = []string{"custom"}
	raw, _ := json.Marshal(p)
	flat, err := SeparateImportedRuleResources(p)
	if err != nil {
		t.Fatal(err)
	}
	if len(flat.RuleSets) != 6 || len(flat.Scenarios[1].Bindings) != 5 {
		t.Fatal("local Scenario was not expanded")
	}
	if !reflect.DeepEqual(p.Lines, flat.Lines) || flat.Scenarios[1].Name != "海外" || !reflect.DeepEqual(flat.Scenarios[1].MatchSSIDs, p.Scenarios[1].MatchSSIDs) {
		t.Fatal("user state changed")
	}
	for i, scene := range p.Scenarios {
		beforeP, afterP := *p, *flat
		beforeP.ActiveScenarioID, afterP.ActiveScenarioID = scene.ID, scene.ID
		before, e1 := BuildConnectionPlan(&beforeP)
		after, e2 := BuildConnectionPlan(&afterP)
		if e1 != nil || e2 != nil || before.ConfigurationFingerprint != after.ConfigurationFingerprint {
			t.Fatalf("Scenario %d changed", i)
		}
	}
	afterRaw, _ := json.Marshal(p)
	if string(raw) != string(afterRaw) {
		t.Fatal("input mutated")
	}
	again, err := SeparateImportedRuleResources(flat)
	if err != nil || !reflect.DeepEqual(flat, again) {
		t.Fatal("migration is not idempotent")
	}
}

func TestSeparateImportedRulesRetainsCustomGroupsAndDisabledState(t *testing.T) {
	p := mixedGroupedFixture(t)
	p.RuleSets[0].Enabled = false
	p.RuleSets[1].ID = "user-group"
	p.RuleSets[1].Name = "我的自定义条件"
	p.Scenarios[0].Bindings[1].RuleSetID = "user-group"
	original := p.RuleSets[1]
	result, err := SeparateImportedRuleResources(p)
	if err != nil {
		t.Fatal(err)
	}
	for _, rule := range result.RuleSets[:4] {
		if rule.Enabled {
			t.Fatal("disabled condition enabled")
		}
	}
	if !reflect.DeepEqual(*result.FindRuleSet("user-group"), original) {
		t.Fatal("custom group was rewritten")
	}
}

func TestRemoteRuleSourceNameDoesNotExposeURLCredentials(t *testing.T) {
	rule := RuleSet{Type: RuleSetTypeURL, URL: "https://example.com/geoip-cn.srs?token=private"}
	if name := MatchingRuleName(rule); name != "远程规则 · geoip-cn.srs" {
		t.Fatal(name)
	}
}
