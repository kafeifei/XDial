package config

import (
	"reflect"
	"testing"
)

func TestBuildConnectionPlanUsesOnlyActiveModeDependenciesInBindingOrder(t *testing.T) {
	profile := invBaseProfile()
	profile.Lines = append(profile.Lines, invUnusedTrojanLine(), invTailscaleLine())
	profile.RuleSets = append(profile.RuleSets, invUnusedRuleSet())
	profile.Subscriptions = append(profile.Subscriptions, invUnusedSubscription())

	plan, err := BuildConnectionPlan(profile)
	if err != nil {
		t.Fatal(err)
	}
	got := connectionPlanTaskIDs(plan)
	want := []string{
		"underlay:system",
		"line:corp",
		"rule-set:intranet",
		"line:px",
		"rule-set:remote",
		"line:direct",
		"dns:mode",
		"data-plane:sing-box",
		"ingress:transparent-proxy",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("tasks = %#v, want %#v", got, want)
	}
	for _, forbidden := range []string{
		"line:ghost",
		"line:ts",
		"rule-set:ghost-rs",
		"subscription:ghost-sub",
	} {
		if containsString(got, forbidden) {
			t.Fatalf("unreferenced task leaked into plan: %s", forbidden)
		}
	}
}

func TestBuildConnectionPlanReportsDisabledBindingWithoutPreparingIt(t *testing.T) {
	profile := invBaseProfile()
	profile.RuleSets[1].Enabled = false

	plan, err := BuildConnectionPlan(profile)
	if err != nil {
		t.Fatal(err)
	}
	got := connectionPlanTaskIDs(plan)
	if containsString(got, "rule-set:remote") || containsString(got, "line:px") {
		t.Fatalf("disabled binding leaked into prepare plan: %#v", got)
	}
	if len(plan.Warnings) != 1 || plan.Warnings[0].Kind != WarningDisabledRuleSet {
		t.Fatalf("warnings = %#v", plan.Warnings)
	}
}

func TestBuildConnectionPlanIncludesDynamicTailscaleAndGeneratedSubscriptionRuleSet(t *testing.T) {
	profile := invBaseProfile()
	profile.Lines = append(profile.Lines, invTailscaleLine())
	profile.Subscriptions = append(profile.Subscriptions, Subscription{
		ID:       "sub",
		Name:     "Surge",
		Enabled:  true,
		Strategy: "select",
		Lines: []Line{{
			ID: "us", Name: "US", Type: LineTypeTrojan, Enabled: true,
			TrojanServer: "us.example.com", TrojanPort: 443,
			TrojanPassword: "secret",
		}},
		Rules: []SubscriptionRule{{
			Type: "GEOIP", Value: "JP", Group: "__default__",
		}},
	})
	profile.Modes[0] = Mode{
		ID: "m", Name: "动态模式",
		Bindings: []RuleBinding{
			{RuleSetID: "intranet", LineID: "ts"},
			{RuleSetID: "remote", SubscriptionID: "sub"},
		},
		DefaultLineID: "direct",
	}

	plan, err := BuildConnectionPlan(profile)
	if err != nil {
		t.Fatal(err)
	}
	got := connectionPlanTaskIDs(plan)
	for _, required := range []string{
		"line:ts",
		"subscription:sub",
		"rule-set:generated:sub-geoip-sub-jp",
	} {
		if !containsString(got, required) {
			t.Fatalf("missing dynamic task %q in %#v", required, got)
		}
	}
}

func TestBuildConnectionPlanRejectsBrokenReferencesBeforeSideEffects(t *testing.T) {
	profile := invBaseProfile()
	profile.Modes[0].Bindings[0].LineID = "missing"
	if _, err := BuildConnectionPlan(profile); err == nil {
		t.Fatal("expected broken reference to fail planning")
	}
}

func connectionPlanTaskIDs(plan *ConnectionPlan) []string {
	ids := make([]string, 0, len(plan.Tasks))
	for _, task := range plan.Tasks {
		ids = append(ids, task.ID)
	}
	return ids
}

func containsString(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}
