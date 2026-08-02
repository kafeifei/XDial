package config

import (
	"encoding/json"
	"reflect"
	"testing"
)

func applicationRuleSetForTest() RuleSet {
	return RuleSet{
		ID:      "claude-app",
		Name:    "Claude",
		Type:    RuleSetTypeApplication,
		Enabled: true,
		Applications: []ApplicationMatch{
			{
				Name: "Claude",
				Path: "/Applications/Claude.app",
				Identities: []string{
					"Q6L2SF6YDW/com.anthropic.claudefordesktop",
					"Q6L2SF6YDW/com.anthropic.claudefordesktop.helper",
				},
			},
			{
				Name: "Claude Code",
				Identities: []string{
					"Q6L2SF6YDW/com.anthropic.claudefordesktop.helper",
					"Q6L2SF6YDW/com.anthropic.claude-code",
				},
			},
		},
	}
}

func applicationRouteRulesForTest(t *testing.T, raw []byte) []map[string]interface{} {
	t.Helper()
	var config map[string]interface{}
	if err := json.Unmarshal(raw, &config); err != nil {
		t.Fatalf("invalid generated JSON: %v", err)
	}
	route, ok := config["route"].(map[string]interface{})
	if !ok {
		t.Fatalf("generated config has no route object: %v", config["route"])
	}
	values, ok := route["rules"].([]interface{})
	if !ok {
		t.Fatalf("generated config has no route rules: %v", route["rules"])
	}
	rules := make([]map[string]interface{}, 0, len(values))
	for _, value := range values {
		rule, ok := value.(map[string]interface{})
		if !ok {
			t.Fatalf("route rule has unexpected type %T", value)
		}
		rules = append(rules, rule)
	}
	return rules
}

func applicationRuleIndexForTest(rules []map[string]interface{}) int {
	for index, rule := range rules {
		if _, ok := rule["auth_user"]; ok {
			return index
		}
	}
	return -1
}

func TestApplicationRuleSetIsModeBoundAndFailsClosedOutsideTransparentProxy(t *testing.T) {
	profile := testProfile()
	profile.RuleSets = append(profile.RuleSets, applicationRuleSetForTest())

	// Merely declaring an enabled application RuleSet cannot affect the active
	// data plane. This is the same zero-effect boundary as every other RuleSet.
	raw, err := GenerateSingBox(profile, 0, "")
	if err != nil {
		t.Fatalf("GenerateSingBox with unbound application rule: %v", err)
	}
	if index := applicationRuleIndexForTest(applicationRouteRulesForTest(t, raw)); index >= 0 {
		t.Fatalf("unbound application rule leaked into route rule #%d", index)
	}

	profile.Modes[0].Bindings = append(profile.Modes[0].Bindings, RuleBinding{
		RuleSetID: "claude-app",
		LineID:    "ss",
	})
	raw, err = GenerateSingBox(profile, 0, "")
	if err == nil {
		t.Fatal("a bound application rule must fail closed outside Transparent Proxy")
	}
}

func TestApplicationRuleSetTransparentProxyDoesNotEmitDNSActions(t *testing.T) {
	profile := testProfile()
	profile.RuleSets = append(profile.RuleSets, applicationRuleSetForTest())
	profile.Modes[0].Bindings = append(profile.Modes[0].Bindings, RuleBinding{
		RuleSetID: "claude-app",
		LineID:    "ss",
	})

	raw, err := GenerateSingBoxTransparentProxy(
		profile, 11080, "session-user", "session-password", t.TempDir(), "en0", []string{"1.1.1.1"},
	)
	if err != nil {
		t.Fatalf("GenerateSingBoxTransparentProxy: %v", err)
	}
	rules := applicationRouteRulesForTest(t, raw)
	applicationIndex := applicationRuleIndexForTest(rules)
	if applicationIndex < 0 {
		t.Fatal("transparent proxy did not compile the application rule")
	}
	if action, exists := rules[applicationIndex]["action"]; exists {
		t.Fatalf("application rule must not emit a DNS resolve action, got %v", action)
	}
	manualRouteIndex := -1
	for index, rule := range rules {
		if reflect.DeepEqual(rule["domain_suffix"], []interface{}{"example.com", "internal.corp"}) &&
			rule["outbound"] == "vpn" {
			manualRouteIndex = index
			break
		}
	}
	if manualRouteIndex < 0 || manualRouteIndex >= applicationIndex {
		t.Fatalf("application route must follow its Mode binding position: manual=%d app=%d", manualRouteIndex, applicationIndex)
	}
	applicationRule := rules[applicationIndex]
	if applicationRule["outbound"] != "proxy-ss" {
		t.Fatalf("application rule outbound = %v, want proxy-ss", applicationRule["outbound"])
	}
	if _, hasDomain := applicationRule["domain_suffix"]; hasDomain {
		t.Fatalf("application rule must not depend on DNS: %v", applicationRule)
	}
	wantUsers := []interface{}{
		ApplicationSOCKSUsername("session-user", "Q6L2SF6YDW/com.anthropic.claudefordesktop"),
		ApplicationSOCKSUsername("session-user", "Q6L2SF6YDW/com.anthropic.claudefordesktop.helper"),
		ApplicationSOCKSUsername("session-user", "Q6L2SF6YDW/com.anthropic.claude-code"),
	}
	if got := applicationRule["auth_user"]; !reflect.DeepEqual(got, wantUsers) {
		t.Fatalf("application route users = %#v, want %#v", got, wantUsers)
	}

	var config SingBoxConfig
	if err := json.Unmarshal(raw, &config); err != nil {
		t.Fatalf("invalid generated JSON: %v", err)
	}
	users := config.Inbounds[0]["users"].([]interface{})
	if len(users) != 4 { // base session user + three unique application identities
		t.Fatalf("SOCKS users = %v, want base + 3 application users", users)
	}
	credentials, err := ActiveApplicationSOCKSCredentials(profile, "session-user")
	if err != nil {
		t.Fatalf("ActiveApplicationSOCKSCredentials: %v", err)
	}
	if credentials["Q6L2SF6YDW/com.anthropic.claude-code"] != wantUsers[2] {
		t.Fatalf("session envelope credential drifted from route credential: %v", credentials)
	}
}

func TestApplicationRuleSetRejectsEmptyAndMalformedIdentities(t *testing.T) {
	makeProfile := func(applications []ApplicationMatch) *Profile {
		return &Profile{
			Lines: []Line{{ID: "direct", Type: LineTypeDirect, Enabled: true}},
			RuleSets: []RuleSet{{
				ID: "app", Type: RuleSetTypeApplication, Enabled: true, Applications: applications,
			}},
			Modes: []Mode{{
				ID: "mode", Bindings: []RuleBinding{{RuleSetID: "app", LineID: "direct"}}, DefaultLineID: "direct",
			}},
			ActiveModeID: "mode",
		}
	}

	for name, applications := range map[string][]ApplicationMatch{
		"no applications":           nil,
		"no identities":             {{Name: "Claude"}},
		"empty identity":            {{Identities: []string{""}}},
		"bare bundle identifier":    {{Identities: []string{"com.anthropic.claudefordesktop"}}},
		"malformed team identifier": {{Identities: []string{"anthropic/com.anthropic.claudefordesktop"}}},
		"surrounding whitespace":    {{Identities: []string{" Q6L2SF6YDW/com.anthropic.claudefordesktop"}}},
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := GenerateSingBox(makeProfile(applications), 0, ""); err == nil {
				t.Fatal("invalid application identities must reject generation")
			}
		})
	}
}
