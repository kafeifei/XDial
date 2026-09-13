//go:build !windows

package libbox

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/kafeifei/xdial/core/config"
)

func TestProfileImportExportRedactedDraft(t *testing.T) {
	input := `{"outbounds":[{"type":"trojan","tag":"node","server":"192.0.2.1","server_port":443,"password":"example-private-password","tls":{"enabled":true},"transport":{"type":"ws","path":"/proxy","headers":{"Authorization":"example-private-header"}}}],"route":{"final":"node"}}`
	imported, err := ImportProfile(input, "auto", "first", false)
	if err != nil {
		t.Fatal(err)
	}
	exported, err := ExportProfile(imported)
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{"example-private-password", "example-private-header"} {
		if strings.Contains(exported, secret) {
			t.Fatal("export leaked a credential")
		}
	}
	draft, err := ImportProfile(exported, "auto", "second", false)
	if err != nil {
		t.Fatalf("redacted document cannot be edited after import: %v", err)
	}
	profile, err := config.ParseProfile([]byte(draft))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := config.BuildConnectionPlan(profile); err == nil {
		t.Fatal("incomplete credentials became a connectable configuration")
	}
}

func TestProfileImportNativeUnknownOptionsAndExplicitLinesOnly(t *testing.T) {
	input := `{"outbounds":[{"type":"trojan","tag":"node","server":"192.0.2.1","server_port":443,"password":"test-only","tls":{"enabled":true}}],"dns":{"final":"external"},"route":{"final":"node"}}`
	if _, err := ImportProfile(input, "auto", "first", false); err == nil {
		t.Fatal("custom DNS silently lost")
	}
	text, err := ImportProfile(input, "auto", "first", true)
	if err != nil {
		t.Fatal(err)
	}
	var profile config.Profile
	if err := json.Unmarshal([]byte(text), &profile); err != nil {
		t.Fatal(err)
	}
	if len(profile.Subscriptions) != 0 || len(profile.Scenarios) != 1 || !profile.FindLine(profile.Scenarios[0].DefaultLineID).IsGroup() {
		t.Fatal("lines-only import did not create a self-contained default Scenario")
	}
	invalid := strings.Replace(strings.Replace(input, `,"dns":{"final":"external"}`, "", 1), `"enabled":true`, `"enabled":true,"unknown_tls_option":true`, 1)
	if _, err := ImportProfile(invalid, "auto", "first", false); err == nil {
		t.Fatal("unsupported TLS option silently lost")
	}
}

func TestProfileImportClashPromotesSharedResources(t *testing.T) {
	input := `proxies:
  - {name: Edge, type: trojan, server: 192.0.2.1, port: 443, password: test-only}
proxy-groups:
  - {name: Proxy, type: select, proxies: [Edge, DIRECT]}
rules:
  - DOMAIN-SUFFIX,example.com,Proxy
  - MATCH,DIRECT
`
	text, err := ImportProfile(input, "auto", "airport", false)
	if err != nil {
		t.Fatal(err)
	}
	profile, err := config.ParseProfile([]byte(text))
	if err != nil {
		t.Fatal(err)
	}
	if len(profile.Subscriptions) != 0 || len(profile.RuleSets) != 1 || len(profile.Scenarios[0].Bindings) != 1 {
		t.Fatal("Clash resources were not promoted into the Profile")
	}
	if _, err := config.BuildConnectionPlan(profile); err != nil {
		t.Fatal(err)
	}
}
