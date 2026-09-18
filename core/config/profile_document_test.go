package config

import (
	"encoding/json"
	"strings"
	"testing"
)

const profileDocumentFixture = `{
  "outbounds":[
    {"type":"trojan","tag":"Hong Kong","server":"192.0.2.10","server_port":443,"password":"test-only","tls":{"enabled":true,"server_name":"proxy.example","alpn":["h2"]}},
    {"type":"selector","tag":"overseas","outbounds":["Hong Kong","direct"],"default":"Hong Kong"},
    {"type":"direct","tag":"direct"}
  ],
  "route":{"rules":[{"domain":["service.example"],"action":"route","outbound":"overseas"}],"final":"direct"}
}`

func TestProfileDocumentNativeGroupAndDomainRouting(t *testing.T) {
	profile, err := ImportProfileDocument([]byte(profileDocumentFixture), "company")
	if err != nil {
		t.Fatal(err)
	}
	if len(profile.Subscriptions) != 0 {
		t.Fatal("subscription target leaked into Profile")
	}
	group := profile.FindLine(profile.Scenarios[0].Bindings[0].LineID)
	if !group.IsGroup() || len(group.GroupMembers) != 2 {
		t.Fatalf("lost group: %+v", group)
	}
	cfg, raw := generateTransparentProxyDNSTestConfig(t, profile)
	if !strings.Contains(string(raw), `"alpn"`) {
		t.Fatal("native TLS option was lost")
	}
	var foundGroup, foundMember bool
	for _, outbound := range cfg.Outbounds {
		if outbound["type"] == "selector" && outbound["tag"] == resolveOutboundTag(group) {
			foundGroup = true
		}
		if outbound["type"] == "trojan" {
			foundMember = true
		}
	}
	if !foundGroup || !foundMember {
		t.Fatal("group dependencies were not compiled")
	}
	encodedDNS, _ := json.Marshal(cfg.DNS)
	flat, err := ExpandRuleSetGroups(profile)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(encodedDNS), sbRuleSetTag(&flat.RuleSets[0])) {
		t.Fatal("domain rule lost its DNS ownership")
	}
	singboxCheckConfig(t, raw, "profile-native-group")
}

func TestProfileDocumentRoundTripAndStableRefreshIDs(t *testing.T) {
	first, err := ImportProfileDocument([]byte(profileDocumentFixture), "company")
	if err != nil {
		t.Fatal(err)
	}
	second, err := ImportProfileDocument([]byte(profileDocumentFixture), "company")
	if err != nil {
		t.Fatal(err)
	}
	if first.Scenarios[0].ID != second.Scenarios[0].ID || first.Lines[1].ID != second.Lines[1].ID {
		t.Fatal("refresh changed stable identities")
	}
	data, err := ExportProfileDocument(first)
	if err != nil {
		t.Fatal(err)
	}
	copy, err := ImportProfileDocument(data, "copy")
	if err != nil {
		t.Fatal(err)
	}
	if len(copy.Lines) != len(first.Lines) || len(copy.RuleSets) != len(first.RuleSets) || len(copy.Scenarios) != len(first.Scenarios) {
		t.Fatal("round trip lost resources")
	}
	if copy.Scenarios[0].ID == first.Scenarios[0].ID {
		t.Fatal("different Profile namespaces share scenario IDs")
	}
}

func TestNativeResourcesFingerprintTracksMemberAndProfile(t *testing.T) {
	profile, err := ImportProfileDocument([]byte(profileDocumentFixture), "company")
	if err != nil {
		t.Fatal(err)
	}
	before, err := BuildConnectionPlan(profile)
	if err != nil {
		t.Fatal(err)
	}
	profile.Lines[1].TrojanPassword = "changed"
	after, err := BuildConnectionPlan(profile)
	if err != nil {
		t.Fatal(err)
	}
	if before.ConfigurationFingerprint == after.ConfigurationFingerprint {
		t.Fatal("group member credentials were omitted from fingerprint")
	}
	profile.ID = "personal"
	other, err := BuildConnectionPlan(profile)
	if err != nil {
		t.Fatal(err)
	}
	if after.ConfigurationFingerprint == other.ConfigurationFingerprint {
		t.Fatal("Profile identity omitted from fingerprint")
	}
}

func TestNativeResourcesRejectCyclesAndUnsupportedSemantics(t *testing.T) {
	for _, document := range []string{
		`{"outbounds":[{"type":"selector","tag":"a","outbounds":["b"]},{"type":"selector","tag":"b","outbounds":["a"]}],"route":{"final":"a"}}`,
		`{"outbounds":[{"type":"direct","tag":"direct"}],"dns":{"final":"custom"}}`,
		`{"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[{"domain":["service.example"],"action":"reject"}]}}`,
		`{"outbounds":[{"type":"direct","tag":"direct"}],"route":{"auto_detect_interface":true}}`,
	} {
		if _, err := ImportProfileDocument([]byte(document), "test"); err == nil {
			t.Fatalf("unsupported semantics silently accepted: %s", document)
		}
	}
}

func TestNativeResourcesProfileStorageIsolationAndClone(t *testing.T) {
	profile, err := ImportProfileDocument([]byte(profileDocumentFixture), "company")
	if err != nil {
		t.Fatal(err)
	}
	base := t.TempDir()
	company, err := ProfileDataPath(profile, base)
	if err != nil {
		t.Fatal(err)
	}
	clone := CloneProfile(profile, "personal")
	personal, err := ProfileDataPath(clone, base)
	if err != nil || company == personal {
		t.Fatal("Profile state directories overlap")
	}
	if err := ValidateDocumentProfile(clone); err != nil {
		t.Fatal(err)
	}
	if clone.Scenarios[0].ID == profile.Scenarios[0].ID {
		t.Fatal("clone shares scenario identity")
	}
	profile.ID = "../escape"
	if _, err := ProfileDataPath(profile, base); err == nil {
		t.Fatal("path traversal accepted")
	}
}

func TestProfileDocumentSelectorDirectKeepsUnderlayDNS(t *testing.T) {
	input := strings.Replace(profileDocumentFixture, `"default":"Hong Kong"`, `"default":"direct"`, 1)
	profile, err := ImportProfileDocument([]byte(input), "company")
	if err != nil {
		t.Fatal(err)
	}
	_, raw := generateTransparentProxyDNSTestConfig(t, profile)
	var root map[string]interface{}
	_ = json.Unmarshal(raw, &root)
	group := profile.FindLine(profile.Scenarios[0].Bindings[0].LineID)
	tag := transparentProxyResolverForOutbound(resolveOutboundTag(group))
	found := false
	for _, entry := range root["dns"].(map[string]interface{})["servers"].([]interface{}) {
		server := entry.(map[string]interface{})
		if server["tag"] == tag {
			found = true
			if server["type"] != "local" || server["xdial_use_system_resolver"] != true {
				t.Fatal("selector Direct did not retain the Underlay resolver")
			}
		}
	}
	if !found {
		t.Fatal("selector resolver missing")
	}
	singboxCheckConfig(t, raw, "profile-selector-direct")
}

func TestProfileDocumentMatchIdentitySurvivesPrependingRule(t *testing.T) {
	first, err := ImportProfileDocument([]byte(profileDocumentFixture), "company")
	if err != nil {
		t.Fatal(err)
	}
	input := strings.Replace(profileDocumentFixture, `"rules":[`, `"rules":[{"domain":["new.example"],"outbound":"direct"},`, 1)
	updated, err := ImportProfileDocument([]byte(input), "company")
	if err != nil {
		t.Fatal(err)
	}
	if first.Scenarios[0].Bindings[0].RuleSetID != updated.Scenarios[0].Bindings[1].RuleSetID {
		t.Fatal("inserting a source rule changed an existing rule identity")
	}
	before, _ := json.Marshal(GroupLineOutbounds(first, first.Scenarios[0].Bindings[0].LineID))
	first.Lines[1], first.Lines[2] = first.Lines[2], first.Lines[1]
	after, _ := json.Marshal(GroupLineOutbounds(first, first.Scenarios[0].Bindings[0].LineID))
	if string(before) != string(after) {
		t.Fatal("visual order changed group runtime identity")
	}
}

func TestPinnedGroupRetainsAutomaticProbeSettingsAcrossExport(t *testing.T) {
	profile, err := ImportProfileDocument([]byte(profileDocumentFixture), "source")
	if err != nil {
		t.Fatal(err)
	}
	group := profile.FindLine(profile.Scenarios[0].Bindings[0].LineID)
	group.GroupURL, group.GroupInterval = "https://example.com/test", "5m"
	encoded, err := ExportProfileDocument(profile)
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]interface{}
	_ = json.Unmarshal(encoded, &doc)
	for _, item := range doc["outbounds"].([]interface{}) {
		outbound := item.(map[string]interface{})
		if outbound["type"] == "selector" && (outbound["url"] != nil || outbound["interval"] != nil) {
			t.Fatal("selector received invalid native URLTest fields")
		}
	}
	restored, err := ImportProfileDocument(encoded, "copy")
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, line := range restored.Lines {
		if line.IsGroup() {
			found = true
			if line.GroupURL != group.GroupURL || line.GroupInterval != group.GroupInterval {
				t.Fatal("lost automatic test settings")
			}
		}
	}
	if !found {
		t.Fatal("lost pinned group")
	}
}
