package config

import (
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
)

func TestSubscriptionGeoIPRuleSetRequiresExplicitValidTemplateWhenEffective(t *testing.T) {
	tests := []struct {
		name     string
		template string
		code     string
		want     string
	}{
		{name: "missing", code: "JP", want: "geoip_rule_set_url_template is required"},
		{
			name:     "placeholder missing",
			template: "https://rules.example/geoip-jp.srs",
			code:     "JP",
			want:     `must contain "{code}"`,
		},
		{
			name:     "insecure remote scheme",
			template: "http://rules.example/geoip-{code}.srs",
			code:     "JP",
			want:     "must use https:// or file://",
		},
		{
			name:     "relative local path",
			template: "file://rules/geoip-{code}.srs",
			code:     "JP",
			want:     "absolute local path",
		},
		{
			name:     "invalid code",
			template: "https://rules.example/geoip-{code}.srs",
			code:     "../JP",
			want:     "unsupported characters",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			profile := subscriptionGeoIPProfile(test.template, test.code)
			if data, err := GenerateSingBox(profile, 0, ""); err == nil {
				t.Fatalf("invalid GEOIP source generated a formal config:\n%s", data)
			} else if !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %q, want substring %q", err, test.want)
			}
			if plan, err := BuildConnectionPlan(profile); err == nil {
				t.Fatalf("invalid GEOIP source generated a connection plan: %+v", plan)
			}
		})
	}
}

func TestSubscriptionGeoIPPrivateCodesDoNotRequireTemplate(t *testing.T) {
	for _, code := range []string{"LAN", "private"} {
		t.Run(code, func(t *testing.T) {
			profile := subscriptionGeoIPProfile("", code)
			data, err := GenerateSingBox(profile, 0, "")
			if err != nil {
				t.Fatal(err)
			}
			var cfg SingBoxConfig
			if err := json.Unmarshal(data, &cfg); err != nil {
				t.Fatal(err)
			}
			if _, exists := cfg.Route["rule_set"]; exists {
				t.Fatalf("private GEOIP code created a rule-set resource: %s", data)
			}
		})
	}
}

func TestSubscriptionGeoIPRuleSetGeneratesExplicitRemoteAndLocalResources(t *testing.T) {
	t.Run("https", func(t *testing.T) {
		profile := subscriptionGeoIPProfile(
			"https://enterprise.example/rules/geoip-{code}.srs?revision=1",
			"JP",
		)
		set := generatedSubscriptionGeoIPRuleSet(t, profile)
		if set["type"] != "remote" ||
			set["url"] != "https://enterprise.example/rules/geoip-jp.srs?revision=1" ||
			set["download_detour"] != "direct" {
			t.Fatalf("unexpected remote GEOIP resource: %+v", set)
		}
		assertGeneratedSubscriptionRuleSetPlanTask(t, profile, "remote", "cache-or-download")
	})

	t.Run("file", func(t *testing.T) {
		templatePath := filepath.Join(t.TempDir(), "geoip-{code}.srs")
		profile := subscriptionGeoIPProfile("file://"+templatePath, "JP")
		set := generatedSubscriptionGeoIPRuleSet(t, profile)
		if set["type"] != "local" || set["path"] != strings.ReplaceAll(templatePath, "{code}", "jp") {
			t.Fatalf("unexpected local GEOIP resource: %+v", set)
		}
		if set["url"] != nil || set["download_detour"] != nil {
			t.Fatalf("local GEOIP resource leaked remote fields: %+v", set)
		}
		assertGeneratedSubscriptionRuleSetPlanTask(t, profile, "local", "load-local")
	})
}

func TestSubscriptionGeoIPRuleSetTemplateAffectsRuntimeFingerprintOnlyWhenUsed(t *testing.T) {
	profile := subscriptionGeoIPProfile(
		"https://enterprise.example/v1/geoip-{code}.srs",
		"JP",
	)
	before, err := BuildConnectionPlan(profile)
	if err != nil {
		t.Fatal(err)
	}
	profile.Subscriptions[0].GeoIPRuleSetURLTemplate =
		"https://enterprise.example/v2/geoip-{code}.srs"
	after, err := BuildConnectionPlan(profile)
	if err != nil {
		t.Fatal(err)
	}
	if before.ConfigurationFingerprint == after.ConfigurationFingerprint {
		t.Fatal("changing an effective GEOIP source did not change the runtime fingerprint")
	}

	privateProfile := subscriptionGeoIPProfile("", "LAN")
	privateBefore, err := BuildConnectionPlan(privateProfile)
	if err != nil {
		t.Fatal(err)
	}
	privateProfile.Subscriptions[0].GeoIPRuleSetURLTemplate =
		"https://enterprise.example/unused/geoip-{code}.srs"
	privateAfter, err := BuildConnectionPlan(privateProfile)
	if err != nil {
		t.Fatal(err)
	}
	if privateBefore.ConfigurationFingerprint != privateAfter.ConfigurationFingerprint {
		t.Fatal("an unused GEOIP source changed the runtime fingerprint")
	}
}

func TestSubscriptionGeoIPDanglingGroupIsNotAnEffectiveDependency(t *testing.T) {
	profile := subscriptionGeoIPProfile("", "JP")
	subscription := &profile.Subscriptions[0]
	subscription.ProxyGroups = []ProxyGroup{{
		Name: "Live", Type: "select", Proxies: []string{"Node"},
	}}
	subscription.Rules[0].Group = "Deleted Group"

	before, err := BuildConnectionPlan(profile)
	if err != nil {
		t.Fatalf("dangling GEOIP group blocked the effective subscription: %v", err)
	}
	for _, task := range before.Tasks {
		if strings.HasPrefix(task.ID, "rule-set:generated:") {
			t.Fatalf("dangling GEOIP group created a plan dependency: %+v", task)
		}
	}

	data, err := GenerateSingBox(profile, 0, "")
	if err != nil {
		t.Fatal(err)
	}
	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}
	if _, exists := cfg.Route["rule_set"]; exists {
		t.Fatalf("dangling GEOIP group created a data-plane resource: %s", data)
	}

	subscription.GeoIPRuleSetURLTemplate =
		"https://enterprise.example/unused/geoip-{code}.srs"
	after, err := BuildConnectionPlan(profile)
	if err != nil {
		t.Fatal(err)
	}
	if before.ConfigurationFingerprint != after.ConfigurationFingerprint {
		t.Fatal("an ineffective dangling GEOIP source changed the runtime fingerprint")
	}
}

func subscriptionGeoIPProfile(template, code string) *Profile {
	return &Profile{
		Lines: []Line{{
			ID: "direct", Name: "Direct", Type: LineTypeDirect, Enabled: true,
		}},
		Subscriptions: []Subscription{{
			ID: "enterprise-sub", Name: "Enterprise", Enabled: true, Strategy: "selector",
			GeoIPRuleSetURLTemplate: template,
			Lines: []Line{{
				ID: "node", Name: "Node", Type: LineTypeTrojan, Enabled: true,
				TrojanServer: "node.example", TrojanPort: 443, TrojanPassword: "secret",
			}},
			Rules: []SubscriptionRule{{
				Type: "GEOIP", Value: code, Group: "__default__",
			}},
		}},
		Scenarios: []Scenario{{
			ID: "enterprise", Name: "Enterprise", DefaultSubscriptionID: "enterprise-sub",
		}},
		ActiveScenarioID: "enterprise",
	}
}

func generatedSubscriptionGeoIPRuleSet(t *testing.T, profile *Profile) map[string]interface{} {
	t.Helper()
	data, err := GenerateSingBox(profile, 0, "")
	if err != nil {
		t.Fatal(err)
	}
	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}
	sets, ok := cfg.Route["rule_set"].([]interface{})
	if !ok || len(sets) != 1 {
		t.Fatalf("generated rule sets = %#v", cfg.Route["rule_set"])
	}
	set, ok := sets[0].(map[string]interface{})
	if !ok || set["tag"] != "sub-geoip-enterprise-sub-jp" || set["format"] != "binary" {
		t.Fatalf("unexpected GEOIP resource: %#v", sets[0])
	}
	return set
}

func assertGeneratedSubscriptionRuleSetPlanTask(
	t *testing.T,
	profile *Profile,
	resourceType string,
	preparation string,
) {
	t.Helper()
	plan, err := BuildConnectionPlan(profile)
	if err != nil {
		t.Fatal(err)
	}
	for _, task := range plan.Tasks {
		if task.ID != "rule-set:generated:sub-geoip-enterprise-sub-jp" {
			continue
		}
		if task.ResourceType != resourceType || task.Preparation != preparation {
			t.Fatalf("unexpected generated rule-set task: %+v", task)
		}
		return
	}
	t.Fatalf("generated GEOIP task is missing: %+v", plan.Tasks)
}
