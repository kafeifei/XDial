package config

import (
	"encoding/json"
	"regexp"
	"strings"
	"testing"
)

func TestTailscaleChannelNameStableDistinctAndDNSValid(t *testing.T) {
	valid := regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$`)
	for _, name := range []string{"xdial-next-526fb361", "xdial-mac-7f3a", "", "我的电脑", strings.Repeat("mac-", 30)} {
		seen := map[string]bool{}
		for _, channel := range []string{"debug", "next", "stable"} {
			got := TailscaleHostnameForChannel(name, "profile-a", channel)
			if !valid.MatchString(got) || seen[got] {
				t.Fatalf("invalid or duplicate name: %q", got)
			}
			seen[got] = true
			if again := TailscaleHostnameForChannel(got, "profile-a", channel); again != got {
				t.Fatalf("repeated runtime projection renamed %q to %q", got, again)
			}
		}
	}
}

func TestChannelProjectionPreservesIdentityPathsAndSharedDocument(t *testing.T) {
	raw := `{"profile_id":"global-configuration","tailscale":{"hostname":"xdial-next-profile"},"future":17,"lines":[{"id":"ts","type":"tailscale","enabled":true,"identity_profile_id":"source-a","identity_hostname":"xdial-next-device","future_line":true}],"scenarios":[{"id":"s","default_line_id":"ts"}],"active_scenario_id":"s"}`
	original, err := ParseRuntimeProfile([]byte(raw))
	if err != nil {
		t.Fatal(err)
	}
	wantPath, err := ProfileDataPath(original, "/state")
	if err != nil {
		t.Fatal(err)
	}
	for _, channel := range []string{"debug", "next", "stable"} {
		projected, err := ProfileWithTailscaleChannel(raw, channel)
		if err != nil {
			t.Fatal(err)
		}
		profile, err := ParseRuntimeProfile([]byte(projected))
		if err != nil {
			t.Fatal(err)
		}
		gotPath, err := ProfileDataPath(profile, "/state")
		if err != nil || gotPath != wantPath {
			t.Fatalf("renaming moved persistent identity: %s %v", gotPath, err)
		}
		endpoint, err := buildTailscaleEndpoint(&profile.Lines[0], profile.Tailscale, gotPath, "")
		if err != nil || endpoint["hostname"] != "xdial-"+channel+"-device" {
			t.Fatalf("wrong endpoint: %v %v", endpoint, err)
		}
		var doc map[string]any
		_ = json.Unmarshal([]byte(projected), &doc)
		if doc["future"] != float64(17) || !strings.Contains(projected, `"future_line":true`) {
			t.Fatal("lost future fields")
		}
		if original.Lines[0].IdentityHostname != "xdial-next-device" {
			t.Fatal("mutated shared identity")
		}
	}
}

func TestChannelProjectionRejectsNullWithoutPanic(t *testing.T) {
	for _, raw := range []string{"null", "[]", "", "{"} {
		if _, err := ProfileWithTailscaleChannel(raw, "debug"); err == nil {
			t.Fatalf("accepted %q", raw)
		}
	}
}
