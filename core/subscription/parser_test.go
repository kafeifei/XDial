package subscription

import (
	"encoding/base64"
	"testing"

	"github.com/kafeifei/xdial/core/config"
)

func TestParseClash(t *testing.T) {
	content := `
proxies:
  - name: "JP-SS"
    type: ss
    server: jp.example.com
    port: 8388
    cipher: aes-256-gcm
    password: "secret123"
  - name: "US-VMess"
    type: vmess
    server: us.example.com
    port: 443
    uuid: "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
    alterId: 0
  - name: "HK-Trojan"
    type: trojan
    server: hk.example.com
    port: 443
    password: "trojanpass"
    sni: hk.example.com
  - name: "Skip-Hysteria"
    type: hysteria2
    server: skip.example.com
    port: 443
`
	r, err := Parse("", content, "clash")
	if err != nil {
		t.Fatalf("Parse clash: %v", err)
	}
	if len(r.Lines) != 3 {
		t.Fatalf("expected 3 lines, got %d", len(r.Lines))
	}

	assertLine(t, r.Lines[0], "JP-SS", config.LineTypeShadowsocks, "jp.example.com", 8388)
	assertLine(t, r.Lines[1], "US-VMess", config.LineTypeVMess, "us.example.com", 443)
	assertLine(t, r.Lines[2], "HK-Trojan", config.LineTypeTrojan, "hk.example.com", 443)

	if r.Lines[0].SSMethod != "aes-256-gcm" {
		t.Errorf("SS method = %q, want aes-256-gcm", r.Lines[0].SSMethod)
	}
}

func TestParseSurge(t *testing.T) {
	content := `
[General]
loglevel = notify

[Proxy]
JP-SS = ss, jp.example.com, 8388, encrypt-method=aes-256-gcm, password=secret123
US-VMess = vmess, us.example.com, 443, username=a1b2c3d4-e5f6-7890-abcd-ef1234567890
HK-Trojan = trojan, hk.example.com, 443, password=trojanpass, sni=hk.example.com

[Proxy Group]
Auto = url-test, JP-SS, US-VMess, HK-Trojan, url = http://www.gstatic.com/generate_204, interval = 300
Manual = select, JP-SS, US-VMess, HK-Trojan

[Rule]
DOMAIN-SUFFIX,google.com,Auto
RULE-SET,https://example.com/rules.list,Manual
FINAL,Auto
`
	r, err := Parse("", content, "surge")
	if err != nil {
		t.Fatalf("Parse surge: %v", err)
	}
	if len(r.Lines) != 3 {
		t.Fatalf("expected 3 lines, got %d", len(r.Lines))
	}
	assertLine(t, r.Lines[0], "JP-SS", config.LineTypeShadowsocks, "jp.example.com", 8388)

	if len(r.ProxyGroups) != 2 {
		t.Fatalf("expected 2 groups, got %d", len(r.ProxyGroups))
	}
	if r.ProxyGroups[0].Name != "Auto" || r.ProxyGroups[0].Type != "url-test" {
		t.Errorf("group 0: %+v", r.ProxyGroups[0])
	}
	if len(r.ProxyGroups[0].Proxies) != 3 {
		t.Errorf("group 0 proxies: %d", len(r.ProxyGroups[0].Proxies))
	}

	if len(r.Rules) != 3 {
		t.Fatalf("expected 3 rules, got %d", len(r.Rules))
	}
	if r.Rules[0].Type != "DOMAIN-SUFFIX" || r.Rules[0].Value != "google.com" || r.Rules[0].Group != "Auto" {
		t.Errorf("rule 0: %+v", r.Rules[0])
	}
	if r.Rules[2].Type != "FINAL" || r.Rules[2].Group != "Auto" {
		t.Errorf("rule 2: %+v", r.Rules[2])
	}
}

func TestParseBase64(t *testing.T) {
	lines := "ss://YWVzLTI1Ni1nY206c2VjcmV0MTIz@jp.example.com:8388#JP-SS\n" +
		"trojan://trojanpass@hk.example.com:443?sni=hk.example.com#HK-Trojan\n"

	encoded := base64.StdEncoding.EncodeToString([]byte(lines))
	r, err := Parse("", encoded, "base64")
	if err != nil {
		t.Fatalf("Parse base64: %v", err)
	}
	if len(r.Lines) != 2 {
		t.Fatalf("expected 2 lines, got %d", len(r.Lines))
	}
	assertLine(t, r.Lines[0], "JP-SS", config.LineTypeShadowsocks, "jp.example.com", 8388)
}

func TestParseBase64VMess(t *testing.T) {
	vmessJSON := `{"v":"2","ps":"US-VMess","add":"us.example.com","port":"443","id":"a1b2c3d4","aid":"0","net":"tcp","type":"none"}`
	vmessURI := "vmess://" + base64.StdEncoding.EncodeToString([]byte(vmessJSON))

	r, err := Parse("", vmessURI, "base64")
	if err != nil {
		t.Fatalf("Parse base64 vmess: %v", err)
	}
	if len(r.Lines) != 1 {
		t.Fatalf("expected 1 line, got %d", len(r.Lines))
	}
	assertLine(t, r.Lines[0], "US-VMess", config.LineTypeVMess, "us.example.com", 443)
}

func TestDetectFormat(t *testing.T) {
	tests := []struct {
		content string
		want    string
	}{
		{"proxies:\n  - name: foo", "clash"},
		{"[Proxy]\nfoo = ss, 1.2.3.4, 443", "surge"},
		{"c3M6Ly9...", "base64"},
	}
	for _, tt := range tests {
		got := detect(tt.content)
		if got != tt.want {
			t.Errorf("detect(%q...) = %q, want %q", tt.content[:20], got, tt.want)
		}
	}
}

func assertLine(t *testing.T, line config.Line, name string, typ config.LineType, server string, portNum int) {
	t.Helper()
	if line.Name != name {
		t.Errorf("line name = %q, want %q", line.Name, name)
	}
	if line.Type != typ {
		t.Errorf("line %s type = %q, want %q", name, line.Type, typ)
	}

	var gotServer string
	var gotPort int
	switch typ {
	case config.LineTypeShadowsocks:
		gotServer = line.SSServer
		gotPort = line.SSPort
	case config.LineTypeVMess:
		gotServer = line.VMessServer
		gotPort = line.VMessPort
	case config.LineTypeTrojan:
		gotServer = line.TrojanServer
		gotPort = line.TrojanPort
	}

	if gotServer != server {
		t.Errorf("line %s server = %q, want %q", name, gotServer, server)
	}
	if gotPort != portNum {
		t.Errorf("line %s port = %d, want %d", name, gotPort, portNum)
	}
}
