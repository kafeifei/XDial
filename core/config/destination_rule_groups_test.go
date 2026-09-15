package config

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestDestinationGroupsKeepInterleavingAndLocalPartialScope(t *testing.T) {
	before, err := ExpandRuleSetGroups(mixedGroupedFixture(t))
	if err != nil {
		t.Fatal(err)
	}
	base := before.Scenarios[0]
	before.Scenarios = append(before.Scenarios, Scenario{ID: "local", Name: "海外", DefaultLineID: "direct", Bindings: []RuleBinding{base.Bindings[0]}})
	before.Scenarios[1].Bindings[0].LineID = "direct"
	grouped, err := GroupProfileRulesByDestination(before, base.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(grouped.RuleSets) != 2 || len(grouped.Scenarios[0].Bindings) != 2 || len(grouped.Scenarios[0].MatchOrder) != 6 {
		t.Fatal("did not combine repeated destinations")
	}
	if len(grouped.Scenarios[1].Bindings[0].ConditionIDs) != 1 {
		t.Fatal("migration widened local matching scope")
	}
	flat, err := ExpandRuleSetGroups(grouped)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(before.Scenarios, flat.Scenarios) {
		t.Fatal("original execution order changed")
	}
	for _, scene := range before.Scenarios {
		a, b := *before, *grouped
		a.ActiveScenarioID, b.ActiveScenarioID = scene.ID, scene.ID
		pa, e1 := BuildConnectionPlan(&a)
		pb, e2 := BuildConnectionPlan(&b)
		if e1 != nil || e2 != nil || pa.ConfigurationFingerprint != pb.ConfigurationFingerprint {
			t.Fatal("runtime semantics changed", e1, e2)
		}
	}
	// Check actual generated DNS, application identities and route order too.
	dir := t.TempDir()
	rawA, e1 := GenerateSingBoxTransparentProxy(before, 29876, "test", "test", dir, "utun-underlay", []string{"192.0.2.53"})
	rawB, e2 := GenerateSingBoxTransparentProxy(grouped, 29876, "test", "test", dir, "utun-underlay", []string{"192.0.2.53"})
	if e1 != nil || e2 != nil || string(rawA) != string(rawB) {
		t.Fatal("executable configuration changed", e1, e2)
	}
	singboxCheckConfig(t, rawB, "destination-groups")
	again, err := GroupProfileRulesByDestination(grouped, base.ID)
	if err != nil || !reflect.DeepEqual(again, grouped) {
		t.Fatal("not idempotent")
	}
	doc, err := ExportProfileDocument(grouped)
	if err != nil {
		t.Fatal(err)
	}
	restored, err := ImportProfileDocument(doc, "copy")
	if err != nil {
		t.Fatal(err)
	}
	cloned := CloneProfile(grouped, "copy")
	for _, p := range []*Profile{restored, cloned} {
		flat, err := ExpandRuleSetGroups(p)
		if err != nil || len(flat.Scenarios[0].Bindings) != 6 || len(flat.Scenarios[1].Bindings) != 1 {
			t.Fatal("scope/order lost in roundtrip", err)
		}
		for i, b := range flat.Scenarios[0].Bindings {
			if b.RuleSetID != documentID("copy", "rule", base.Bindings[i].RuleSetID) {
				t.Fatal("order identity changed")
			}
		}
	}
}

func TestDestinationOrderRejectsDanglingOrDuplicateScopes(t *testing.T) {
	p, _ := ExpandRuleSetGroups(mixedGroupedFixture(t))
	p, _ = GroupProfileRulesByDestination(p, p.ActiveScenarioID)
	for _, invalid := range []string{"missing", p.Scenarios[0].MatchOrder[0]} {
		data, _ := json.Marshal(p)
		var copy Profile
		_ = json.Unmarshal(data, &copy)
		copy.Scenarios[0].MatchOrder = append(copy.Scenarios[0].MatchOrder, invalid)
		if _, err := ExpandRuleSetGroups(&copy); err == nil {
			t.Fatal("invalid priority accepted")
		}
	}
	p.Scenarios[0].Bindings[0].ConditionIDs = []string{"missing"}
	if _, err := ExpandRuleSetGroups(p); err == nil {
		t.Fatal("invalid scope accepted")
	}
}

func TestNewConditionUsesLastSourcePositionWithoutReordering(t *testing.T) {
	p, _ := ExpandRuleSetGroups(mixedGroupedFixture(t))
	p, _ = GroupProfileRulesByDestination(p, p.ActiveScenarioID)
	oldOrder := append([]string(nil), p.Scenarios[0].MatchOrder...)
	p.RuleSets[0].Conditions = append(p.RuleSets[0].Conditions, RuleSet{ID: "new", Name: "new", Type: RuleSetTypeManual, Enabled: true, Domains: []string{"new.example"}})
	flat, err := ExpandRuleSetGroups(p)
	if err != nil {
		t.Fatal(err)
	}
	var old []string
	for _, b := range flat.Scenarios[0].Bindings {
		if b.RuleSetID != "new" {
			old = append(old, b.RuleSetID)
		}
	}
	if !reflect.DeepEqual(old, oldOrder) || flat.Scenarios[0].Bindings[6].RuleSetID != "new" {
		t.Fatal("new condition reordered source")
	}
}
