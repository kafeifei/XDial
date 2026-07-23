package subscription

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/kafeifei/xdial/core/config"
)

func TestRuleSetLineToRule(t *testing.T) {
	tests := []struct {
		line, group string
		wantOK      bool
		wantType    string
		wantValue   string
	}{
		{"DOMAIN-SUFFIX,google.com", "Proxies", true, "DOMAIN-SUFFIX", "google.com"},
		{"DOMAIN,example.com", "Proxies", true, "DOMAIN", "example.com"},
		{"DOMAIN-KEYWORD,google", "Proxies", true, "DOMAIN-KEYWORD", "google"},
		{"IP-CIDR,1.2.3.0/24", "Proxies", true, "IP-CIDR", "1.2.3.0/24"},
		{"IP-CIDR6,2001::/32", "Proxies", true, "IP-CIDR6", "2001::/32"},
		{"GEOIP,CN", "Direct", true, "GEOIP", "CN"},
		{"", "Proxies", false, "", ""},
		{"# comment line", "Proxies", false, "", ""},
		{"// another comment", "Proxies", false, "", ""},
		{"UNKNOWN,value", "Proxies", false, "", ""},
		{"no-comma", "Proxies", false, "", ""},
		{"DOMAIN-SUFFIX,  google.com  ", "Proxies", true, "DOMAIN-SUFFIX", "google.com"},
	}

	for _, tc := range tests {
		r, ok := ruleSetLineToRule(tc.line, tc.group)
		if ok != tc.wantOK {
			t.Errorf("ruleSetLineToRule(%q, %q): ok=%v, want %v", tc.line, tc.group, ok, tc.wantOK)
			continue
		}
		if ok {
			if r.Type != tc.wantType {
				t.Errorf("type=%q, want %q", r.Type, tc.wantType)
			}
			if r.Value != tc.wantValue {
				t.Errorf("value=%q, want %q", r.Value, tc.wantValue)
			}
			if r.Group != tc.group {
				t.Errorf("group=%q, want %q", r.Group, tc.group)
			}
		}
	}
}

func TestExpandRulesets_Empty(t *testing.T) {
	result := &ParseResult{
		Rules: []config.SubscriptionRule{
			{Type: "DOMAIN-SUFFIX", Value: "google.com", Group: "Proxies"},
			{Type: "FINAL", Group: "Proxies"},
		},
	}
	before := len(result.Rules)
	ExpandRulesets(result)
	if len(result.Rules) != before {
		t.Errorf("no RULE-SET rules should mean no expansion, got %d -> %d", before, len(result.Rules))
	}
}

func TestExpandRulesetsStrictRejectsInsecureRemoteRule(t *testing.T) {
	result := &ParseResult{Rules: []config.SubscriptionRule{
		{Type: "RULE-SET", Value: "http://127.0.0.1/private.list?token=secret", Group: "Proxy"},
	}}

	err := ExpandRulesetsStrict(result)
	if err == nil || !strings.Contains(err.Error(), "HTTPS") {
		t.Fatalf("expected HTTPS validation error, got %v", err)
	}
	if strings.Contains(err.Error(), "secret") {
		t.Fatalf("strict expansion leaked URL token: %v", err)
	}
	if len(result.Rules) != 1 || result.Rules[0].Type != "RULE-SET" {
		t.Fatalf("failed expansion should not partially replace rules: %+v", result.Rules)
	}
}

func TestFetchRejectsOversizedResponse(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write(make([]byte, maxRemoteContentBytes+1))
	}))
	defer server.Close()

	_, err := fetch(server.URL)
	if err == nil || !strings.Contains(err.Error(), "exceeds") {
		t.Fatalf("expected size-limit error, got %v", err)
	}
}

func TestExpandRulesetsStrictRejectsTooManySourcesBeforeFetch(t *testing.T) {
	rules := make([]config.SubscriptionRule, maxStrictRemoteRuleSets+1)
	for index := range rules {
		rules[index] = config.SubscriptionRule{
			Type: "RULE-SET", Value: "https://rules.example.com/list?token=must-not-leak", Group: "Proxy",
		}
	}
	result := &ParseResult{Rules: rules}
	fetchCalls := 0

	err := expandRulesetsWithFetcher(context.Background(), result, true,
		func(context.Context, string, bool, int64) (string, error) {
			fetchCalls++
			return "", nil
		})
	if err == nil || !strings.Contains(err.Error(), "too many") {
		t.Fatalf("expected source-count error, got %v", err)
	}
	if fetchCalls != 0 {
		t.Fatalf("fetch called %d times before source-count rejection", fetchCalls)
	}
	if strings.Contains(err.Error(), "must-not-leak") {
		t.Fatalf("budget error leaked URL token: %v", err)
	}
}

func TestExpandRulesetsStrictRejectsCumulativeResponseSize(t *testing.T) {
	chunk := strings.Repeat("#", maxStrictRuleSetBytes/2+1)
	result := &ParseResult{Rules: []config.SubscriptionRule{
		{Type: "RULE-SET", Value: "https://one.example.com/list?token=one", Group: "Proxy"},
		{Type: "RULE-SET", Value: "https://two.example.com/list?token=two", Group: "Proxy"},
	}}
	original := append([]config.SubscriptionRule(nil), result.Rules...)

	err := expandRulesetsWithFetcher(context.Background(), result, true,
		func(context.Context, string, bool, int64) (string, error) { return chunk, nil })
	if err == nil || !strings.Contains(err.Error(), "size") {
		t.Fatalf("expected cumulative-size error, got %v", err)
	}
	if len(result.Rules) != len(original) || result.Rules[0] != original[0] || result.Rules[1] != original[1] {
		t.Fatalf("failed strict expansion mutated result: %+v", result.Rules)
	}
	if strings.Contains(err.Error(), "token=") {
		t.Fatalf("budget error leaked URL token: %v", err)
	}
}

func TestExpandRulesetsStrictRejectsTooManyRawLines(t *testing.T) {
	result := &ParseResult{Rules: []config.SubscriptionRule{
		{Type: "RULE-SET", Value: "https://rules.example.com/list?token=secret", Group: "Proxy"},
	}}
	content := strings.Repeat("\n", maxStrictRuleSetLines)

	err := expandRulesetsWithFetcher(context.Background(), result, true,
		func(context.Context, string, bool, int64) (string, error) { return content, nil })
	if err == nil || !strings.Contains(err.Error(), "lines") {
		t.Fatalf("expected line-budget error, got %v", err)
	}
	if len(result.Rules) != 1 || result.Rules[0].Type != "RULE-SET" {
		t.Fatalf("failed strict expansion mutated result: %+v", result.Rules)
	}
}

func TestExpandRulesetsStrictRejectsTooManyExpandedRules(t *testing.T) {
	rules := make([]config.SubscriptionRule, maxStrictExpandedRules)
	for index := 0; index < len(rules)-1; index++ {
		rules[index] = config.SubscriptionRule{
			Type: "DOMAIN", Value: "example.com", Group: "Proxy",
		}
	}
	rules[len(rules)-1] = config.SubscriptionRule{
		Type: "RULE-SET", Value: "https://rules.example.com/list", Group: "Proxy",
	}
	result := &ParseResult{Rules: rules}

	err := expandRulesetsWithFetcher(context.Background(), result, true,
		func(context.Context, string, bool, int64) (string, error) {
			return "DOMAIN,one.example\nDOMAIN,two.example", nil
		})
	if err == nil || !strings.Contains(err.Error(), "expanded") {
		t.Fatalf("expected expanded-rule budget error, got %v", err)
	}
	if len(result.Rules) != len(rules) || result.Rules[len(result.Rules)-1].Type != "RULE-SET" {
		t.Fatal("failed strict expansion mutated result")
	}
}

func TestRuleSetLineToRule_EdgeCases(t *testing.T) {
	// 空值
	_, ok := ruleSetLineToRule("DOMAIN-SUFFIX,", "G")
	if ok {
		t.Error("empty value should not be ok")
	}
	_, ok = ruleSetLineToRule(",google.com", "G")
	if ok {
		t.Error("empty type should not be ok")
	}
	// 多余逗号会被 SplitN(x, \",\", 2) 归入 value
	r, ok := ruleSetLineToRule("DOMAIN-SUFFIX,google.com,extra", "G")
	if !ok {
		t.Error("SplitN with limit=2 puts extra commas in value, should be ok")
	}
	if r.Value != "google.com,extra" {
		t.Errorf("value=%q, want google.com,extra (commas in value)", r.Value)
	}
}
