//go:build !windows

package libbox

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"

	"github.com/kafeifei/xdial/core/config"
	"github.com/kafeifei/xdial/core/subscription"
)

func TestParseSubscriptionInlineClashRules(t *testing.T) {
	content := `
proxies:
  - name: "JP-SS"
    type: ss
    server: jp.example.com
    port: 8388
    cipher: aes-256-gcm
    password: secret
proxy-groups:
  - name: Proxy
    type: select
    proxies: [JP-SS]
rules:
  - DOMAIN-SUFFIX,example.com,Proxy
  - IP-CIDR,203.0.113.0/24,Proxy
  - FINAL,Proxy
`

	raw, err := ParseSubscription("", content, "clash")
	if err != nil {
		t.Fatalf("ParseSubscription: %v", err)
	}

	var result subscription.ParseResult
	if err := json.Unmarshal([]byte(raw), &result); err != nil {
		t.Fatalf("decode result: %v", err)
	}
	if len(result.Lines) != 1 || result.Lines[0].Type != config.LineTypeShadowsocks {
		t.Fatalf("unexpected lines: %+v", result.Lines)
	}
	if len(result.Rules) != 3 {
		t.Fatalf("expected 2 rules plus FINAL, got %+v", result.Rules)
	}
	if result.Rules[0].Type != "DOMAIN-SUFFIX" || result.Rules[0].Value != "example.com" || result.Rules[0].Group != "Proxy" {
		t.Fatalf("unexpected first expanded rule: %+v", result.Rules[0])
	}
	if result.Rules[1].Type != "IP-CIDR" || result.Rules[1].Value != "203.0.113.0/24" {
		t.Fatalf("unexpected second expanded rule: %+v", result.Rules[1])
	}
	if result.Rules[2].Type != "FINAL" {
		t.Fatalf("expected FINAL to remain after expanded rules, got %+v", result.Rules[2])
	}
}

func TestParseSubscriptionRejectsInsecureRemoteRuleSet(t *testing.T) {
	content := `
proxies:
  - name: "JP-SS"
    type: ss
    server: jp.example.com
    port: 8388
    cipher: aes-256-gcm
    password: secret
proxy-groups:
  - name: Proxy
    type: select
    proxies: [JP-SS]
rules:
  - RULE-SET,http://127.0.0.1/private.list?token=must-not-leak,Proxy
`

	raw, err := ParseSubscription("", content, "clash")
	if err == nil {
		t.Fatal("expected insecure remote rule set to fail")
	}
	if raw != "" {
		t.Fatalf("error result should be empty, got %q", raw)
	}
	if !strings.Contains(err.Error(), "HTTPS") {
		t.Fatalf("unexpected error: %v", err)
	}
	if strings.Contains(err.Error(), "must-not-leak") {
		t.Fatalf("error leaked rule-set token: %v", err)
	}
}

func TestParseSubscriptionRejectsUnknownRuleGroup(t *testing.T) {
	content := `
proxies:
  - name: "JP-SS"
    type: ss
    server: jp.example.com
    port: 8388
    cipher: aes-256-gcm
    password: secret
proxy-groups:
  - name: Proxy
    type: select
    proxies: [JP-SS]
rules:
  - DOMAIN-SUFFIX,example.com,Missing
`

	raw, err := ParseSubscription("", content, "clash")
	if err == nil || !strings.Contains(err.Error(), "unavailable group") {
		t.Fatalf("expected unavailable-group error, got raw=%q err=%v", raw, err)
	}
}

func TestParseSubscriptionRejectsRuleTargetingUnusableGroup(t *testing.T) {
	content := `
proxies:
  - name: "JP-SS"
    type: ss
    server: jp.example.com
    port: 8388
    cipher: aes-256-gcm
    password: secret
proxy-groups:
  - name: Good
    type: select
    proxies: [JP-SS]
  - name: Empty
    type: select
    proxies: [Missing]
rules:
  - DOMAIN-SUFFIX,example.com,Good
  - FINAL,Empty
`

	raw, err := ParseSubscription("", content, "clash")
	if err == nil || err.Error() != "subscription rule references an unavailable group" {
		t.Fatalf("expected unusable-group error, got raw=%q err=%v", raw, err)
	}
}

func TestParseSubscriptionAllowsRuleTargetingTransitivelyUsableGroup(t *testing.T) {
	content := `
proxies:
  - name: "JP-SS"
    type: ss
    server: jp.example.com
    port: 8388
    cipher: aes-256-gcm
    password: secret
proxy-groups:
  - name: Outer
    type: select
    proxies: [Inner]
  - name: Inner
    type: select
    proxies: [JP-SS]
rules:
  - FINAL,Outer
`

	if _, err := ParseSubscription("", content, "clash"); err != nil {
		t.Fatalf("ParseSubscription: %v", err)
	}
}

func TestParseSubscriptionAllowsGroupsBackedByBuiltInTargets(t *testing.T) {
	content := `
proxies:
  - name: "JP-SS"
    type: ss
    server: jp.example.com
    port: 8388
    cipher: aes-256-gcm
    password: secret
proxy-groups:
  - name: DirectOnly
    type: select
    proxies: [DIRECT]
  - name: RejectOnly
    type: select
    proxies: [REJECT]
rules:
  - DOMAIN-SUFFIX,ads.example,RejectOnly
  - FINAL,DirectOnly
`

	if _, err := ParseSubscription("", content, "clash"); err != nil {
		t.Fatalf("ParseSubscription: %v", err)
	}
}

func TestParseSubscriptionRejectsDuplicateGroupNames(t *testing.T) {
	content := `
proxies:
  - name: "JP-SS"
    type: ss
    server: jp.example.com
    port: 8388
    cipher: aes-256-gcm
    password: secret
proxy-groups:
  - name: Proxy
    type: select
    proxies: [JP-SS]
  - name: Proxy
    type: select
    proxies: [DIRECT]
rules:
  - FINAL,Proxy
`

	raw, err := ParseSubscription("", content, "clash")
	if err == nil || err.Error() != "subscription contains duplicate group names" {
		t.Fatalf("expected duplicate-group error, got raw=%q err=%v", raw, err)
	}
}

func TestParseSubscriptionRejectsDuplicateNodeNames(t *testing.T) {
	content := `
proxies:
  - name: "Duplicate"
    type: ss
    server: one.example.com
    port: 8388
    cipher: aes-256-gcm
    password: secret
  - name: "Duplicate"
    type: ss
    server: two.example.com
    port: 8388
    cipher: aes-256-gcm
    password: secret
proxy-groups:
  - name: Proxy
    type: select
    proxies: [Duplicate]
rules:
  - FINAL,Proxy
`

	raw, err := ParseSubscription("", content, "clash")
	if err == nil || err.Error() != "subscription contains duplicate node names" {
		t.Fatalf("expected duplicate-node error, got raw=%q err=%v", raw, err)
	}
}

func TestParseSubscriptionRejectsUnsupportedClashRuleTypeWithoutLeakingContent(t *testing.T) {
	for _, ruleType := range []string{"GEOSITE", "DST-PORT"} {
		t.Run(ruleType, func(t *testing.T) {
			content := `
proxies:
  - name: "JP-SS"
    type: ss
    server: jp.example.com
    port: 8388
    cipher: aes-256-gcm
    password: secret
proxy-groups:
  - name: Proxy
    type: select
    proxies: [JP-SS]
rules:
  - ` + ruleType + `,must-not-leak.example,Proxy
`

			raw, err := ParseSubscription("", content, "clash")
			if err == nil {
				t.Fatal("expected unsupported Clash rule type to fail")
			}
			if raw != "" || err.Error() != "subscription contains unsupported rules" {
				t.Fatalf("unexpected or leaking error: raw=%q err=%v", raw, err)
			}
		})
	}
}

func TestParseSubscriptionRejectsUnsupportedSurgeRuleTypeWithoutLeakingContent(t *testing.T) {
	for _, ruleType := range []string{"PROCESS-NAME", "SRC-IP-CIDR"} {
		t.Run(ruleType, func(t *testing.T) {
			content := `
[Proxy]
JP-SS = ss, jp.example.com, 8388, encrypt-method=aes-256-gcm, password=secret
[Proxy Group]
Proxy = select, JP-SS
[Rule]
` + ruleType + `,must-not-leak,Proxy
`

			raw, err := ParseSubscription("", content, "surge")
			if err == nil {
				t.Fatal("expected unsupported Surge rule type to fail")
			}
			if raw != "" || err.Error() != "subscription contains unsupported rules" {
				t.Fatalf("unexpected or leaking error: raw=%q err=%v", raw, err)
			}
		})
	}
}

func TestParseSubscriptionAllowsSupportedSurgeRules(t *testing.T) {
	content := `
[Proxy]
JP-SS = ss, jp.example.com, 8388, encrypt-method=aes-256-gcm, password=secret
[Proxy Group]
Proxy = select, JP-SS
[Rule]
DOMAIN-KEYWORD,example,Proxy
IP-CIDR6,2001:db8::/32,Proxy
FINAL,Proxy
`

	raw, err := ParseSubscription("", content, "surge")
	if err != nil {
		t.Fatalf("ParseSubscription: %v", err)
	}
	var result subscription.ParseResult
	if err := json.Unmarshal([]byte(raw), &result); err != nil {
		t.Fatalf("decode result: %v", err)
	}
	if len(result.Rules) != 3 || result.Rules[0].Type != "DOMAIN-KEYWORD" || result.Rules[1].Type != "IP-CIDR6" || result.Rules[2].Type != "FINAL" {
		t.Fatalf("unexpected rules: %+v", result.Rules)
	}
}

func TestParseSubscriptionRejectsInvalidNodes(t *testing.T) {
	content := `
proxies:
  - name: Good
    type: ss
    server: good.example.com
    port: 8388
    cipher: aes-256-gcm
    password: secret
  - name: Broken
    type: trojan
    server: broken.example.com
    port: 70000
    password: ""
proxy-groups:
  - name: Proxy
    type: select
    proxies: [Good]
rules:
  - FINAL,Proxy
`
	raw, err := ParseSubscription("", content, "clash")
	if err == nil || raw != "" || err.Error() != "subscription contains invalid nodes" {
		t.Fatalf("expected generic invalid-node error, raw=%q err=%v", raw, err)
	}
}

func TestParseSubscriptionRejectsUnsupportedGroupType(t *testing.T) {
	content := `
proxies:
  - name: Good
    type: ss
    server: good.example.com
    port: 8388
    cipher: aes-256-gcm
    password: secret
proxy-groups:
  - name: Proxy
    type: fallback
    proxies: [Good]
rules:
  - FINAL,Proxy
`
	raw, err := ParseSubscription("", content, "clash")
	if err == nil || raw != "" || err.Error() != "subscription contains unsupported group types" {
		t.Fatalf("expected unsupported-group error, raw=%q err=%v", raw, err)
	}
}

func TestParseSubscriptionRemovesUntrustedGroupTestURLs(t *testing.T) {
	tests := []struct {
		name    string
		format  string
		content string
	}{
		{
			name:   "Clash",
			format: "clash",
			content: `
proxies:
  - name: "JP-SS"
    type: ss
    server: jp.example.com
    port: 8388
    cipher: aes-256-gcm
    password: secret
proxy-groups:
  - name: Auto
    type: url-test
    proxies: [JP-SS]
    url: http://127.0.0.1/clash?token=must-not-leak
rules:
  - FINAL,Auto
`,
		},
		{
			name:   "Surge",
			format: "surge",
			content: `
[Proxy]
JP-SS = ss, jp.example.com, 8388, encrypt-method=aes-256-gcm, password=secret
[Proxy Group]
Auto = url-test, JP-SS, url=http://127.0.0.1/surge?token=must-not-leak
[Rule]
FINAL,Auto
`,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			raw, err := ParseSubscription("", tt.content, tt.format)
			if err != nil {
				t.Fatalf("ParseSubscription: %v", err)
			}
			if strings.Contains(raw, "must-not-leak") || strings.Contains(raw, "127.0.0.1") {
				t.Fatalf("untrusted test URL remained in result: %s", raw)
			}
			var result subscription.ParseResult
			if err := json.Unmarshal([]byte(raw), &result); err != nil {
				t.Fatalf("decode result: %v", err)
			}
			if len(result.ProxyGroups) != 1 || result.ProxyGroups[0].URL != "" {
				t.Fatalf("unexpected groups: %+v", result.ProxyGroups)
			}
		})
	}
}

func TestParseSubscriptionRejectsPrivateSubscriptionAddressWithoutLeakingToken(t *testing.T) {
	raw, err := ParseSubscription("https://127.0.0.1/list?token=must-not-leak", "", "auto")
	if err == nil {
		t.Fatal("expected private address to fail")
	}
	if raw != "" || strings.Contains(err.Error(), "must-not-leak") {
		t.Fatalf("unexpected or leaking error: raw=%q err=%v", raw, err)
	}
}

func TestParseSubscriptionInlineBase64(t *testing.T) {
	uri := "trojan://secret@hk.example.com:443?sni=hk.example.com#HK-Trojan"
	content := base64.StdEncoding.EncodeToString([]byte(uri))

	raw, err := ParseSubscription("", content, "base64")
	if err != nil {
		t.Fatalf("ParseSubscription: %v", err)
	}

	var result subscription.ParseResult
	if err := json.Unmarshal([]byte(raw), &result); err != nil {
		t.Fatalf("decode result: %v", err)
	}
	if len(result.Lines) != 1 || result.Lines[0].Type != config.LineTypeTrojan {
		t.Fatalf("unexpected lines: %+v", result.Lines)
	}
}

func TestParseSubscriptionReturnsParseError(t *testing.T) {
	raw, err := ParseSubscription("", "not a subscription", "unknown")
	if err == nil {
		t.Fatal("expected parse error")
	}
	if raw != "" {
		t.Fatalf("error result should be empty, got %q", raw)
	}
	if !strings.Contains(err.Error(), "unknown format") {
		t.Fatalf("unexpected error: %v", err)
	}
}
