package subscription

import (
	"encoding/base64"
	"encoding/json"
	"reflect"
	"strings"
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
  - name: "SG-AnyTLS"
    type: anytls
    server: anytls.example.com
    port: 8443
    password: "anytlspass"
    sni: edge.example.com
    client-fingerprint: chrome
    idle-session-check-interval: 30
    idle-session-timeout: 30
    min-idle-session: 0
    alpn: [h2]
    skip-cert-verify: true
    udp: true
    tfo: false
  - name: "Skip-Hysteria"
    type: hysteria2
    server: skip.example.com
    port: 443
`
	r, err := Parse("", content, "clash")
	if err != nil {
		t.Fatalf("Parse clash: %v", err)
	}
	if len(r.Lines) != 4 {
		t.Fatalf("expected 4 lines, got %d", len(r.Lines))
	}

	assertLine(t, r.Lines[0], "JP-SS", config.LineTypeShadowsocks, "jp.example.com", 8388)
	assertLine(t, r.Lines[1], "US-VMess", config.LineTypeVMess, "us.example.com", 443)
	assertLine(t, r.Lines[2], "HK-Trojan", config.LineTypeTrojan, "hk.example.com", 443)
	assertLine(t, r.Lines[3], "SG-AnyTLS", config.LineTypeAnyTLS, "anytls.example.com", 8443)
	assertAnyTLSOptions(t, r.Lines[3])

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
SG-AnyTLS = anytls, anytls.example.com, 8443, password=anytlspass, sni=edge.example.com, client-fingerprint=chrome, idle-session-check-interval=30, idle-session-timeout=30, min-idle-session=0, alpn=h2, skip-cert-verify=true, udp=true, tfo=false

[Proxy Group]
Auto = url-test, JP-SS, US-VMess, HK-Trojan, SG-AnyTLS, url = http://www.gstatic.com/generate_204, interval = 300
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
	if len(r.Lines) != 4 {
		t.Fatalf("expected 4 lines, got %d", len(r.Lines))
	}
	assertLine(t, r.Lines[0], "JP-SS", config.LineTypeShadowsocks, "jp.example.com", 8388)
	assertLine(t, r.Lines[3], "SG-AnyTLS", config.LineTypeAnyTLS, "anytls.example.com", 8443)
	assertAnyTLSOptions(t, r.Lines[3])

	if len(r.ProxyGroups) != 2 {
		t.Fatalf("expected 2 groups, got %d", len(r.ProxyGroups))
	}
	if r.ProxyGroups[0].Name != "Auto" || r.ProxyGroups[0].Type != "url-test" {
		t.Errorf("group 0: %+v", r.ProxyGroups[0])
	}
	if len(r.ProxyGroups[0].Proxies) != 4 {
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

func TestParseBase64AnyTLS(t *testing.T) {
	uri := "anytls://secret%3Avalue@anytls.example.com:443" +
		"?sni=edge.example.com&insecure=1&client-fingerprint=chrome" +
		"&idle-session-check-interval=30&idle-session-timeout=30" +
		"&min-idle-session=0&alpn=h2&udp=true&tfo=false#SG-AnyTLS"

	r, err := Parse("", uri, "base64")
	if err != nil {
		t.Fatalf("Parse base64 AnyTLS: %v", err)
	}
	if len(r.Lines) != 1 {
		t.Fatalf("expected 1 line, got %d", len(r.Lines))
	}
	line := r.Lines[0]
	assertLine(t, line, "SG-AnyTLS", config.LineTypeAnyTLS, "anytls.example.com", 443)
	if line.AnyTLSPassword != "secret:value" {
		t.Fatalf("unexpected AnyTLS fields: %+v", line)
	}
	assertAnyTLSOptions(t, line)
}

func TestParseBase64AnyTLSIPv6AndDefaultSNI(t *testing.T) {
	r, err := Parse(
		"",
		"anytls://secret@[2001:db8::1]:8443#IPv6-AnyTLS",
		"base64",
	)
	if err != nil {
		t.Fatalf("Parse IPv6 AnyTLS: %v", err)
	}
	if len(r.Lines) != 1 {
		t.Fatalf("expected 1 line, got %d", len(r.Lines))
	}
	line := r.Lines[0]
	assertLine(t, line, "IPv6-AnyTLS", config.LineTypeAnyTLS, "2001:db8::1", 8443)
	if line.AnyTLSSNI != "2001:db8::1" {
		t.Fatalf("AnyTLS SNI = %q, want IPv6 server fallback", line.AnyTLSSNI)
	}
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

func TestAnyTLSParsedFieldsSurviveJSONRoundTrip(t *testing.T) {
	line := config.Line{
		ID:                             "anytls",
		Name:                           "AnyTLS",
		Type:                           config.LineTypeAnyTLS,
		Enabled:                        true,
		AnyTLSServer:                   "anytls.example.com",
		AnyTLSPort:                     443,
		AnyTLSPassword:                 "secret",
		AnyTLSSNI:                      "edge.example.com",
		AnyTLSClientFingerprint:        "chrome",
		AnyTLSALPN:                     []string{"h2", "http/1.1"},
		AnyTLSIdleSessionCheckInterval: 30,
		AnyTLSIdleSessionTimeout:       45,
		AnyTLSMinIdleSession:           4,
		AllowInsecure:                  true,
		UDP:                            true,
	}
	data, err := json.Marshal(line)
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{
		"anytls_client_fingerprint",
		"anytls_alpn",
		"anytls_idle_session_check_interval",
		"anytls_idle_session_timeout",
		"anytls_min_idle_session",
	} {
		if !strings.Contains(string(data), `"`+key+`"`) {
			t.Fatalf("persisted AnyTLS JSON is missing key %q: %s", key, data)
		}
	}
	var restored config.Line
	if err := json.Unmarshal(data, &restored); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(restored, line) {
		t.Fatalf("AnyTLS JSON round-trip changed fields:\n got: %+v\nwant: %+v", restored, line)
	}
}

func TestClashAnyTLSRejectsOutOfBoundsOptions(t *testing.T) {
	base := map[string]interface{}{
		"name":     "AnyTLS",
		"type":     "anytls",
		"server":   "anytls.example.com",
		"port":     443,
		"password": "secret",
	}
	tests := []struct {
		name  string
		key   string
		value interface{}
	}{
		{name: "zero check interval", key: "idle-session-check-interval", value: 0},
		{name: "silently rewritten check interval", key: "idle-session-check-interval", value: 5},
		{name: "too large check interval", key: "idle-session-check-interval", value: 3601},
		{name: "zero idle timeout", key: "idle-session-timeout", value: 0},
		{name: "silently rewritten idle timeout", key: "idle-session-timeout", value: 5},
		{name: "too large idle timeout", key: "idle-session-timeout", value: 3601},
		{name: "negative idle sessions", key: "min-idle-session", value: -1},
		{name: "too many idle sessions", key: "min-idle-session", value: 65},
		{name: "unknown fingerprint", key: "client-fingerprint", value: "unknown-browser"},
		{name: "duplicate ALPN", key: "alpn", value: []interface{}{"h2", "h2"}},
		{name: "empty ALPN entry", key: "alpn", value: "h2,"},
		{name: "control character in ALPN", key: "alpn", value: []interface{}{"h2\n"}},
		{name: "control character in scalar ALPN", key: "alpn", value: "h2\n"},
		{name: "oversized ALPN", key: "alpn", value: []interface{}{strings.Repeat("a", 256)}},
		{name: "too many ALPN entries", key: "alpn", value: []interface{}{
			"a", "b", "c", "d", "e", "f", "g", "h", "i",
		}},
		{name: "malformed UDP flag", key: "udp", value: "sometimes"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			proxy := make(map[string]interface{}, len(base)+1)
			for key, value := range base {
				proxy[key] = value
			}
			proxy[test.key] = test.value
			if line, ok := clashProxyToLine(proxy); ok {
				t.Fatalf("invalid AnyTLS option was accepted: %+v", line)
			}
		})
	}
}

func TestAnyTLSNonClashParsersEnforceSharedBoundaries(t *testing.T) {
	surgeCases := []string{
		"Bad = anytls, anytls.example.com, 443, password=secret, idle-session-timeout=5",
		"Bad = anytls, anytls.example.com, 443, password=secret, alpn=h2,h2",
		"Bad = anytls, anytls.example.com, 443, password=secret, alpn=h2,",
		"Bad = anytls, anytls.example.com, 443, password=secret, client-fingerprint=unknown",
	}
	for _, line := range surgeCases {
		if parsed, ok := surgeLineToLine(line); ok {
			t.Fatalf("invalid Surge AnyTLS options were accepted: %+v", parsed)
		}
	}

	base64Cases := []string{
		"anytls://secret@anytls.example.com:443?idle-session-check-interval=5",
		"anytls://secret@anytls.example.com:443?alpn=h2%0A",
		"anytls://secret@anytls.example.com:443?alpn=h2%2C",
		"anytls://secret@anytls.example.com:443?client-fingerprint=unknown",
	}
	for _, uri := range base64Cases {
		if parsed, ok := parseAnyTLS(uri); ok {
			t.Fatalf("invalid URI AnyTLS options were accepted: %+v", parsed)
		}
	}
}

func TestClashAnyTLSAcceptsDocumentedBoundsAndCustomALPN(t *testing.T) {
	line, ok := clashProxyToLine(map[string]interface{}{
		"name":                        "AnyTLS",
		"type":                        "anytls",
		"server":                      "anytls.example.com",
		"port":                        443,
		"password":                    "secret",
		"client-fingerprint":          "CHROME",
		"idle-session-check-interval": 6,
		"idle-session-timeout":        3600,
		"min-idle-session":            64,
		"alpn":                        []interface{}{"custom-protocol"},
	})
	if !ok {
		t.Fatal("valid AnyTLS boundary values were rejected")
	}
	if line.AnyTLSClientFingerprint != "chrome" ||
		line.AnyTLSIdleSessionCheckInterval != 6 ||
		line.AnyTLSIdleSessionTimeout != 3600 ||
		line.AnyTLSMinIdleSession != 64 ||
		!reflect.DeepEqual(line.AnyTLSALPN, []string{"custom-protocol"}) {
		t.Fatalf("AnyTLS boundary fields changed during import: %+v", line)
	}
}

func TestClashAnyTLSPreservesTFOForRuntimeRejection(t *testing.T) {
	line, ok := clashProxyToLine(map[string]interface{}{
		"name":     "AnyTLS",
		"type":     "anytls",
		"server":   "anytls.example.com",
		"port":     443,
		"password": "secret",
		"tfo":      true,
	})
	if !ok || !line.TFO {
		t.Fatalf("AnyTLS tfo=true was not preserved for fail-closed validation: %+v", line)
	}
	if config.LineHasUsableOutbound(&line) {
		t.Fatal("AnyTLS tfo=true must remain unavailable to the runtime")
	}
}

func assertAnyTLSOptions(t *testing.T, line config.Line) {
	t.Helper()
	if line.AnyTLSSNI != "edge.example.com" ||
		line.AnyTLSClientFingerprint != "chrome" ||
		!reflect.DeepEqual(line.AnyTLSALPN, []string{"h2"}) ||
		line.AnyTLSIdleSessionCheckInterval != 30 ||
		line.AnyTLSIdleSessionTimeout != 30 ||
		line.AnyTLSMinIdleSession != 0 ||
		!line.AllowInsecure ||
		!line.UDP ||
		line.TFO {
		t.Fatalf("AnyTLS fields were not preserved: %+v", line)
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
	case config.LineTypeAnyTLS:
		gotServer = line.AnyTLSServer
		gotPort = line.AnyTLSPort
	}

	if gotServer != server {
		t.Errorf("line %s server = %q, want %q", name, gotServer, server)
	}
	if gotPort != portNum {
		t.Errorf("line %s port = %d, want %d", name, gotPort, portNum)
	}
}
