package config

import (
	"encoding/json"
	"testing"
)

func mixedGroupedFixture(t *testing.T) *Profile {
	return groupedSubscriptionProfileFixture(t, []SubscriptionRule{
		{Type: "DOMAIN", Value: "first.example", Group: "Proxy", SourceID: "source-one"},
		{Type: "IP-CIDR", Value: "192.0.2.0/24", Group: "Proxy", Options: "no-resolve", SourceID: "source-two"},
		{Type: "PROCESS-NAME", Value: "Example Helper*", Group: "Proxy"},
		{Type: "GEOIP", Value: "CN", Group: "Proxy"},
		{Type: "DOMAIN", Value: "special.example", Group: "DIRECT"},
		{Type: "DOMAIN-SUFFIX", Value: "example", Group: "Proxy"},
		{Type: "FINAL", Group: "DIRECT"},
	})
}

func TestGroupedRuleSetsKeepExactCompiledRoutingAndDNS(t *testing.T) {
	profile := mixedGroupedFixture(t)
	if len(profile.RuleSets) != 3 || len(profile.RuleSets[0].Conditions) != 4 || len(profile.ActiveScenario().Bindings) != 3 {
		t.Fatal("mixed conditions did not become one contiguous policy resource")
	}
	before, _ := json.Marshal(profile)
	flat, err := ExpandRuleSetGroups(profile)
	if err != nil {
		t.Fatal(err)
	}
	if len(flat.RuleSets) != 6 || len(flat.ActiveScenario().Bindings) != 6 {
		t.Fatal("ordered resources lost")
	}
	base := t.TempDir()
	generate := func(p *Profile) []byte {
		raw, err := GenerateSingBoxTransparentProxy(p, 29876, "session-user", "session-password", base, "utun-underlay", []string{"192.0.2.53"})
		if err != nil {
			t.Fatal(err)
		}
		return raw
	}
	groupedRaw, flatRaw := generate(profile), generate(flat)
	if string(groupedRaw) != string(flatRaw) {
		t.Fatal("grouping changed executable configuration")
	}
	singboxCheckConfig(t, groupedRaw, "mixed-grouped-rules")
	credentials, err := ActiveApplicationSOCKSCredentials(profile, "session")
	if err != nil || len(credentials) != 1 {
		t.Fatalf("application credentials lost: %v", err)
	}
	plan, err := BuildConnectionPlan(profile)
	if err != nil {
		t.Fatal(err)
	}
	flatPlan, err := BuildConnectionPlan(flat)
	if err != nil {
		t.Fatal(err)
	}
	if plan.ConfigurationFingerprint != flatPlan.ConfigurationFingerprint {
		t.Fatal("grouping changed runtime identity")
	}
	profile.RuleSets[0].Conditions[1].NoResolve = false
	changed, err := BuildConnectionPlan(profile)
	if err != nil {
		t.Fatal(err)
	}
	if changed.ConfigurationFingerprint == plan.ConfigurationFingerprint {
		t.Fatal("nested DNS change not fingerprinted")
	}
	profile.RuleSets[0].Conditions[1].NoResolve = true
	after, _ := json.Marshal(profile)
	if string(after) != string(before) {
		t.Fatal("compiler mutated persisted profile")
	}
}

func TestGroupedRuleSetsDocumentCloneAndDisabledRoundTrip(t *testing.T) {
	profile := mixedGroupedFixture(t)
	profile.RuleSets[0].Enabled = false
	doc, err := ExportProfileDocument(profile)
	if err != nil {
		t.Fatal(err)
	}
	restored, err := ImportProfileDocument(doc, "restored")
	if err != nil {
		t.Fatal(err)
	}
	for _, copy := range []*Profile{restored, CloneProfile(profile, "clone")} {
		if err := ValidateDocumentProfile(copy); err != nil {
			t.Fatal(err)
		}
		if len(copy.RuleSets) != 3 || len(copy.RuleSets[0].Conditions) != 4 || copy.RuleSets[0].Enabled || !copy.RuleSets[0].Conditions[0].Enabled || !copy.RuleSets[0].Conditions[1].NoResolve {
			t.Fatal("group state or DNS options lost")
		}
		if copy.RuleSets[0].Conditions[0].ID == profile.RuleSets[0].Conditions[0].ID {
			t.Fatal("private condition identity not remapped")
		}
		flat, err := ExpandRuleSetGroups(copy)
		if err != nil {
			t.Fatal(err)
		}
		for _, rule := range flat.RuleSets[:4] {
			if rule.Enabled {
				t.Fatal("disabled group still enables a condition")
			}
		}
		copy.RuleSets[0].Enabled = true
		if _, err := BuildConnectionPlan(copy); err != nil {
			t.Fatal(err)
		}
	}
}

func TestGroupedRuleSetsRejectAmbiguousComposition(t *testing.T) {
	for _, mutate := range []func(*Profile){
		func(p *Profile) { p.RuleSets[0].Invert = true },
		func(p *Profile) { p.RuleSets[0].NoResolve = true },
		func(p *Profile) { p.RuleSets[0].Conditions = nil },
		func(p *Profile) { p.RuleSets[0].Conditions[0].ID = p.RuleSets[1].ID },
		func(p *Profile) { p.RuleSets[0].Conditions[0].Type = RuleSetTypeGroup },
		func(p *Profile) { p.Scenarios[0].Bindings[0].RuleSetID = p.RuleSets[0].Conditions[0].ID },
	} {
		p := mixedGroupedFixture(t)
		mutate(p)
		if _, err := ExpandRuleSetGroups(p); err == nil {
			t.Fatal("ambiguous composition accepted")
		}
		if _, err := ExportProfileDocument(p); err == nil {
			t.Fatal("ambiguous composition exported")
		}
	}
}

func TestGroupedSubscriptionIdentitySurvivesNewMatchFamily(t *testing.T) {
	rules := []SubscriptionRule{{Type: "DOMAIN", Value: "one.example", Group: "Proxy"}}
	first := groupedSubscriptionProfileFixture(t, rules)
	rules = append(rules, SubscriptionRule{Type: "PROCESS-NAME", Value: "Example", Group: "Proxy"})
	second := groupedSubscriptionProfileFixture(t, rules)
	if first.RuleSets[0].ID != second.RuleSets[0].ID || len(second.RuleSets) != 1 || len(second.RuleSets[0].Conditions) != 2 {
		t.Fatal("adding a matching family changed shared identity")
	}
}
