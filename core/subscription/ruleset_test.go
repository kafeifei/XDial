package subscription

import (
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
