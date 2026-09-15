package config

import (
	"encoding/json"
	"reflect"
	"testing"
)

func policySelectorFixture(t *testing.T) *Profile {
	t.Helper()
	p := &Profile{ID: "source", Lines: []Line{
		{ID: "direct", Name: "Direct", Type: LineTypeDirect, Enabled: true},
		{ID: "a", Name: "A", Type: LineTypeAnyTLS, Enabled: true, AnyTLSServer: "192.0.2.1", AnyTLSPort: 443, AnyTLSPassword: "fixture"},
		{ID: "b", Name: "B", Type: LineTypeAnyTLS, Enabled: true, AnyTLSServer: "192.0.2.2", AnyTLSPort: 443, AnyTLSPassword: "fixture"},
		{ID: "pool", Name: "Shared", Type: LineTypeSelector, Enabled: true, GroupMembers: []string{"a", "b"}, GroupDefault: "b"},
		{ID: "direct-policy", Name: "Local", Type: LineTypeSelector, Enabled: true, GroupMembers: []string{"direct", "pool"}},
		{ID: "ai", Name: "AI", Type: LineTypeSelector, Enabled: true, GroupMembers: []string{"pool", "direct-policy", "a", "b"}},
		{ID: "video", Name: "Video", Type: LineTypeSelector, Enabled: true, GroupMembers: []string{"pool", "direct-policy", "a", "b"}, GroupDefault: "a"},
		{ID: "apple", Name: "Apple", Type: LineTypeSelector, Enabled: true, GroupMembers: []string{"direct-policy", "pool", "a", "b"}},
		{ID: "final", Name: "Final", Type: LineTypeSelector, Enabled: true, GroupMembers: []string{"pool", "direct-policy", "a", "b"}},
		{ID: "test", Name: "Local Auto", Type: LineTypeURLTest, Enabled: true, GroupMembers: []string{"a", "b"}, GroupInterval: "3m"},
	}, ActiveScenarioID: "base"}
	p.RuleSets = []RuleSet{
		{ID: "first", Name: "First", Type: RuleSetTypeManual, Enabled: true, Domains: []string{"ai.example"}},
		{ID: "second", Name: "Second", Type: RuleSetTypeManual, Enabled: true, Domains: []string{"video.example"}},
		{ID: "third", Name: "Third", Type: RuleSetTypeNative, Enabled: true, NativeRule: json.RawMessage(`{"ip_cidr":["192.0.2.0/24"]}`), NoResolve: true},
		{ID: "fourth", Name: "Fourth", Type: RuleSetTypeManual, Enabled: true, Domains: []string{"apple.example"}},
	}
	p.Scenarios = []Scenario{{ID: "base", Name: "Default", DefaultLineID: "final", Bindings: []RuleBinding{
		{RuleSetID: "first", LineID: "ai"}, {RuleSetID: "second", LineID: "video"},
		{RuleSetID: "third", LineID: "ai"}, {RuleSetID: "fourth", LineID: "apple"},
	}}}
	grouped, err := GroupProfileRulesByDestination(p, "base")
	if err != nil {
		t.Fatal(err)
	}
	grouped.Scenarios = append(grouped.Scenarios, Scenario{ID: "local", Name: "Local", DefaultLineID: "direct", Bindings: []RuleBinding{{RuleSetID: grouped.RuleSets[0].ID, ConditionIDs: []string{"first"}, LineID: "test"}}})
	return grouped
}

func TestPolicySelectorsBecomeIndependentScenarioChoices(t *testing.T) {
	before := policySelectorFixture(t)
	original, _ := json.Marshal(before)
	after, err := NormalizeImportedPolicySelectors(before)
	if err != nil {
		t.Fatal(err)
	}
	if len(after.Lines) != 5 || after.FindLine("pool") == nil || after.FindLine("test") == nil {
		t.Fatal("shared selection or automatic group was lost")
	}
	if !reflect.DeepEqual(before.RuleSets, after.RuleSets) || !reflect.DeepEqual(before.Scenarios[0].MatchOrder, after.Scenarios[0].MatchOrder) {
		t.Fatal("business categories or source priority changed")
	}
	if got := after.Scenarios[0]; got.DefaultLineID != "pool" || got.Bindings[0].LineID != "pool" || got.Bindings[1].LineID != "a" || got.Bindings[2].LineID != "direct" {
		t.Fatal("independent choices or default policy lost", got)
	}
	if !reflect.DeepEqual(before.Scenarios[1], after.Scenarios[1]) {
		t.Fatal("local Scenario changed")
	}
	unchanged, _ := json.Marshal(before)
	if string(original) != string(unchanged) {
		t.Fatal("input was mutated")
	}
	again, err := NormalizeImportedPolicySelectors(after)
	if err != nil || !reflect.DeepEqual(again, after) {
		t.Fatal("normalization is not idempotent", err)
	}
	_, raw := generateTransparentProxyDNSTestConfig(t, after)
	singboxCheckConfig(t, raw, "policy-selectors-in-scenarios")
	doc, err := ExportProfileDocument(after)
	if err != nil {
		t.Fatal(err)
	}
	restored, err := ImportProfileDocument(doc, "roundtrip")
	if err != nil || len(restored.RuleSets) != 3 || len(restored.Lines) != 5 {
		t.Fatal("roundtrip collapsed categories sharing an exit", err)
	}
	// Changing AI's Scene binding cannot change Video's selection or the pool.
	after.Scenarios[0].Bindings[0].LineID = "test"
	if after.Scenarios[0].Bindings[1].LineID != "a" || after.FindLine("pool").GroupDefault != "b" {
		t.Fatal("independent selection became shared")
	}
}

func TestPolicyNormalizationPreservesDistinctOrSharedConsumers(t *testing.T) {
	for _, kind := range []string{"filtered", "automatic-consumer", "download", "native", "cycle"} {
		t.Run(kind, func(t *testing.T) {
			p := policySelectorFixture(t)
			switch kind {
			case "filtered":
				p.FindLine("ai").GroupMembers = []string{"pool", "a"}
			case "automatic-consumer":
				p.FindLine("ai").GroupMembers = []string{"pool", "a", "b"}
				p.FindLine("test").GroupMembers = []string{"ai"}
			case "download":
				p.RuleSets = append(p.RuleSets, RuleSet{ID: "remote", Name: "Remote", Type: RuleSetTypeURL, Enabled: true, URL: "https://example.com/rules.srs", Format: "binary", FetchLineID: "ai"})
			case "native":
				p.FindLine("ai").NativeOptions = json.RawMessage(`{"interrupt_exist_connections":true}`)
			case "cycle":
				p.FindLine("pool").GroupMembers = []string{"ai"}
			}
			result, err := NormalizeImportedPolicySelectors(p)
			if kind == "cycle" {
				if err == nil {
					t.Fatal("cycle accepted")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if result.FindLine("ai") == nil {
				t.Fatal("nonredundant selector removed")
			}
		})
	}
}

func TestSavedScenarioReimportIsFreshAndKeepsSource(t *testing.T) {
	source := policySelectorFixture(t)
	original, _ := json.Marshal(source)
	copy, err := ReimportScenario(source, "base", "new-profile")
	if err != nil {
		t.Fatal(err)
	}
	if copy.ID != "new-profile" || len(copy.Scenarios) != 1 || len(copy.Lines) != 4 || len(copy.RuleSets) != 3 {
		t.Fatal("new import retained unrelated local objects or lost categories")
	}
	if copy.Lines[1].AnyTLSPassword != "fixture" {
		t.Fatal("credentials were lost")
	}
	if copy.Scenarios[0].ID == "base" || copy.RuleSets[0].ID == source.RuleSets[0].ID {
		t.Fatal("identities shared across Profiles")
	}
	if err := validateDocumentProfile(copy); err != nil {
		t.Fatal(err)
	}
	unchanged, _ := json.Marshal(source)
	if string(original) != string(unchanged) {
		t.Fatal("existing Profile mutated")
	}
	second, err := ReimportScenario(copy, copy.Scenarios[0].ID, "third-profile")
	if err != nil || len(second.RuleSets) != len(copy.RuleSets) {
		t.Fatal("reimport merged categories sharing an exit", err)
	}
}
