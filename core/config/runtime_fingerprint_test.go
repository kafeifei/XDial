package config

import (
	"encoding/hex"
	"encoding/json"
	"strings"
	"testing"
)

func TestRuntimeConfigurationFingerprintClassifiesEffectiveChanges(t *testing.T) {
	base := runtimeFingerprintTestProfile()
	baseline := runtimeFingerprintForTest(t, base)

	tests := []struct {
		name       string
		wantChange bool
		mutate     func(*Profile)
	}{
		{
			name: "presentation names icon and SSIDs",
			mutate: func(profile *Profile) {
				profile.Scenarios[0].Name = "Renamed scenario"
				profile.Scenarios[0].Icon = "hotel"
				profile.Scenarios[0].MatchSSIDs = []string{"Office", "Home"}
				profile.Lines[1].Name = "Renamed VPN"
				profile.RuleSets[0].Name = "Renamed rule"
				profile.Subscriptions[0].Name = "Renamed subscription"
				profile.FindRuleSet("apps").Applications[0].Name = "Renamed app"
			},
		},
		{
			name: "subscription import metadata",
			mutate: func(profile *Profile) {
				subscription := profile.FindSubscription("sub1")
				subscription.URL = "https://new.example/import"
				subscription.Format = "clash"
				subscription.UpdatedAt++
			},
		},
		{
			name: "unreferenced resources and inactive scenario",
			mutate: func(profile *Profile) {
				profile.FindLine("ghost").TrojanPassword = "changed-unused-secret"
				profile.FindRuleSet("ghost-rs").Domains = []string{"changed.example"}
				profile.FindSubscription("ghost-sub").Lines[0].TrojanPassword = "changed"
				profile.Scenarios[1].Name = "Changed inactive scenario"
				profile.Scenarios[1].Bindings = nil
			},
		},
		{
			name: "inactive Tailscale identity",
			mutate: func(profile *Profile) {
				profile.Tailscale.Hostname = "xdial-unused-renamed"
			},
		},
		{
			name: "top-level resource ordering",
			mutate: func(profile *Profile) {
				reverseRuntimeFingerprintSlice(profile.Lines)
				reverseRuntimeFingerprintSlice(profile.RuleSets)
				reverseRuntimeFingerprintSlice(profile.Subscriptions)
				reverseRuntimeFingerprintSlice(profile.Scenarios)
			},
		},
		{
			name: "disabled binding contents",
			mutate: func(profile *Profile) {
				profile.FindRuleSet("disabled-rs").Domains = []string{"changed.example"}
				profile.FindLine("disabled-line").TrojanPassword = "changed"
			},
		},
		{
			name: "consistent subscription node display rename",
			mutate: func(profile *Profile) {
				subscription := profile.FindSubscription("sub1")
				subscription.Lines[0].Name = "Hong Kong"
				subscription.Selected = "Hong Kong"
			},
		},
		{
			name:       "binding order",
			wantChange: true,
			mutate: func(profile *Profile) {
				profile.Scenarios[0].Bindings[0], profile.Scenarios[0].Bindings[1] =
					profile.Scenarios[0].Bindings[1], profile.Scenarios[0].Bindings[0]
			},
		},
		{
			name:       "manual RuleSet contents",
			wantChange: true,
			mutate: func(profile *Profile) {
				profile.FindRuleSet("intranet").Domains = append(
					profile.FindRuleSet("intranet").Domains,
					"new.corp.example",
				)
			},
		},
		{
			name:       "URL RuleSet source",
			wantChange: true,
			mutate: func(profile *Profile) {
				ruleSet := profile.FindRuleSet("remote")
				ruleSet.URL = "https://new.example/rules.srs"
				ruleSet.Format = "binary"
			},
		},
		{
			name:       "traffic Line protocol configuration",
			wantChange: true,
			mutate: func(profile *Profile) {
				profile.FindLine("px").TrojanPassword = "rotated-secret"
			},
		},
		{
			name:       "subscription selected node",
			wantChange: true,
			mutate: func(profile *Profile) {
				profile.FindSubscription("sub1").Selected = "US"
			},
		},
		{
			name:       "subscription internal Line order",
			wantChange: true,
			mutate: func(profile *Profile) {
				subscription := profile.FindSubscription("sub1")
				subscription.Lines[0], subscription.Lines[1] =
					subscription.Lines[1], subscription.Lines[0]
			},
		},
		{
			name:       "subscription rule order",
			wantChange: true,
			mutate: func(profile *Profile) {
				subscription := profile.FindSubscription("sub1")
				subscription.Rules[0], subscription.Rules[1] =
					subscription.Rules[1], subscription.Rules[0]
			},
		},
		{
			name:       "default target",
			wantChange: true,
			mutate: func(profile *Profile) {
				profile.Scenarios[0].DefaultLineID = "px"
			},
		},
		{
			name:       "disabled binding becomes effective",
			wantChange: true,
			mutate: func(profile *Profile) {
				profile.FindRuleSet("disabled-rs").Enabled = true
				profile.FindLine("disabled-line").Enabled = true
			},
		},
		{
			name:       "active Scenario identity",
			wantChange: true,
			mutate: func(profile *Profile) {
				profile.Scenarios[0].ID = "renamed-active"
				profile.ActiveScenarioID = "renamed-active"
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			profile := cloneRuntimeFingerprintProfile(t, base)
			test.mutate(profile)
			got := runtimeFingerprintForTest(t, profile)
			changed := got != baseline
			if changed != test.wantChange {
				t.Fatalf("fingerprint changed = %v, want %v\nbefore: %s\nafter:  %s",
					changed, test.wantChange, baseline, got)
			}
		})
	}
}

func TestRuntimeConfigurationFingerprintIncludesFetchOnlyAndTailscaleDependencies(t *testing.T) {
	tests := []struct {
		name            string
		setup           func(*Profile)
		mutate          func(*Profile)
		taskID          string
		wantTrafficTask bool
	}{
		{
			name: "D38 fetch-only proxy Line",
			setup: func(profile *Profile) {
				profile.FindRuleSet("remote").FetchLineID = "ghost"
			},
			mutate: func(profile *Profile) {
				profile.FindLine("ghost").TrojanPassword = "rotated-fetch-secret"
			},
			taskID: "line:ghost",
		},
		{
			name: "D38 fetch-only Tailscale identity",
			setup: func(profile *Profile) {
				profile.FindRuleSet("remote").FetchLineID = "ts"
			},
			mutate: func(profile *Profile) {
				profile.Tailscale.Hostname = "xdial-fetch-renamed"
			},
			taskID: "line:ts",
		},
		{
			name: "traffic Tailscale identity",
			setup: func(profile *Profile) {
				profile.Scenarios[0].DefaultLineID = "ts"
			},
			mutate: func(profile *Profile) {
				profile.Tailscale.Hostname = "xdial-traffic-renamed"
			},
			taskID:          "line:ts",
			wantTrafficTask: true,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			beforeProfile := runtimeFingerprintTestProfile()
			test.setup(beforeProfile)
			before, err := BuildConnectionPlan(beforeProfile)
			if err != nil {
				t.Fatal(err)
			}

			afterProfile := cloneRuntimeFingerprintProfile(t, beforeProfile)
			test.mutate(afterProfile)
			after, err := BuildConnectionPlan(afterProfile)
			if err != nil {
				t.Fatal(err)
			}
			if before.ConfigurationFingerprint == after.ConfigurationFingerprint {
				t.Fatalf("effective dependency change did not change fingerprint: %s",
					before.ConfigurationFingerprint)
			}
			gotTrafficTask := containsString(connectionPlanTaskIDs(before), test.taskID)
			if gotTrafficTask != test.wantTrafficTask {
				t.Fatalf("traffic task %q present = %v, want %v; tasks = %#v",
					test.taskID, gotTrafficTask, test.wantTrafficTask,
					connectionPlanTaskIDs(before))
			}
		})
	}
}

func TestRuntimeConfigurationFingerprintContractIsOpaqueAndDeterministic(t *testing.T) {
	profile := runtimeFingerprintTestProfile()
	first, err := BuildConnectionPlan(profile)
	if err != nil {
		t.Fatal(err)
	}
	second, err := BuildConnectionPlan(cloneRuntimeFingerprintProfile(t, profile))
	if err != nil {
		t.Fatal(err)
	}
	if first.ConfigurationFingerprint != second.ConfigurationFingerprint {
		t.Fatalf("fingerprint is not deterministic: %q != %q",
			first.ConfigurationFingerprint, second.ConfigurationFingerprint)
	}

	fingerprint := first.ConfigurationFingerprint
	if !strings.HasPrefix(fingerprint, runtimeConfigurationFingerprintPrefix) {
		t.Fatalf("fingerprint = %q, want %q prefix",
			fingerprint, runtimeConfigurationFingerprintPrefix)
	}
	digest := strings.TrimPrefix(fingerprint, runtimeConfigurationFingerprintPrefix)
	decoded, err := hex.DecodeString(digest)
	if err != nil || len(decoded) != 32 {
		t.Fatalf("fingerprint digest is not SHA-256 hex: %q (decoded=%d, err=%v)",
			digest, len(decoded), err)
	}

	encoded, err := json.Marshal(first)
	if err != nil {
		t.Fatal(err)
	}
	var document map[string]json.RawMessage
	if err := json.Unmarshal(encoded, &document); err != nil {
		t.Fatal(err)
	}
	if _, exists := document["configuration_fingerprint"]; !exists {
		t.Fatalf("configuration_fingerprint is missing: %s", encoded)
	}
	for _, secret := range []string{"secret", "vpn.example.com", "hk.example.com"} {
		if strings.Contains(string(encoded), secret) {
			t.Fatalf("connection plan exposed runtime projection material %q: %s",
				secret, encoded)
		}
	}
}

func runtimeFingerprintTestProfile() *Profile {
	profile := invBaseProfile()
	profile.Lines = append(
		profile.Lines,
		invUnusedTrojanLine(),
		invTailscaleLine(),
		Line{
			ID: "disabled-line", Name: "Disabled", Type: LineTypeTrojan,
			Enabled: false, TrojanServer: "disabled.example.com", TrojanPort: 443,
			TrojanPassword: "disabled-secret", TrojanSNI: "disabled.example.com",
		},
	)
	profile.RuleSets = append(
		profile.RuleSets,
		invStreamRuleSet(),
		RuleSet{
			ID: "apps", Name: "Applications", Type: RuleSetTypeApplication, Enabled: true,
			Applications: []ApplicationMatch{{
				Name: "Safari", Path: "/Applications/Safari.app",
				BundleIdentifier: "com.apple.Safari",
			}},
		},
		RuleSet{
			ID: "disabled-rs", Name: "Disabled rule", Type: RuleSetTypeManual,
			Enabled: false, Domains: []string{"disabled.example"},
		},
		invUnusedRuleSet(),
	)

	subscription := invReferencedSubscription()
	subscription.Format = "surge"
	subscription.UpdatedAt = 1_700_000_000
	subscription.Strategy = "selector"
	subscription.Selected = "HK"
	subscription.Lines = append(subscription.Lines, Line{
		ID: "n2", Name: "US", Type: LineTypeTrojan, Enabled: true,
		TrojanServer: "us.example.com", TrojanPort: 443,
		TrojanPassword: "us-secret", TrojanSNI: "us.example.com",
	})
	profile.Subscriptions = append(
		profile.Subscriptions,
		subscription,
		invUnusedSubscription(),
	)
	profile.Scenarios[0].Bindings = append(
		profile.Scenarios[0].Bindings,
		RuleBinding{RuleSetID: "stream", SubscriptionID: "sub1"},
		RuleBinding{RuleSetID: "apps", LineID: builtinDirectLineID},
		RuleBinding{RuleSetID: "disabled-rs", LineID: "disabled-line"},
	)
	profile.Scenarios = append(profile.Scenarios, Scenario{
		ID: "inactive", Name: "Inactive", DefaultLineID: builtinDirectLineID,
		Bindings: []RuleBinding{{RuleSetID: "ghost-rs", LineID: "ghost"}},
	})
	profile.Tailscale.Hostname = "xdial-test"
	return profile
}

func runtimeFingerprintForTest(t *testing.T, profile *Profile) string {
	t.Helper()
	plan, err := BuildConnectionPlan(profile)
	if err != nil {
		t.Fatal(err)
	}
	return plan.ConfigurationFingerprint
}

func cloneRuntimeFingerprintProfile(t *testing.T, profile *Profile) *Profile {
	t.Helper()
	encoded, err := json.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}
	var result Profile
	if err := json.Unmarshal(encoded, &result); err != nil {
		t.Fatal(err)
	}
	return &result
}

func reverseRuntimeFingerprintSlice[T any](values []T) {
	for left, right := 0, len(values)-1; left < right; left, right = left+1, right-1 {
		values[left], values[right] = values[right], values[left]
	}
}
