package config

import (
	"strings"
	"testing"
)

// testRelaySocketPath stands in for the Provider's relay socket. The
// generator only compiles the path into the entry; nothing here listens on it.
const testRelaySocketPath = "/tmp/xdial-test/relay.sock"

func TestTransparentProxyRelaySocketPathIsValidated(t *testing.T) {
	profile := &Profile{
		Lines:            []Line{{ID: "direct", Type: LineTypeDirect, Enabled: true}},
		Scenarios:        []Scenario{{ID: "scenario", DefaultLineID: "direct"}},
		ActiveScenarioID: "scenario",
	}
	longest := "/" + strings.Repeat("a", TransparentProxyRelaySocketPathLimit-1)
	for name, testCase := range map[string]struct {
		path  string
		valid bool
	}{
		"empty":                 {"", false},
		"relative":              {"relay.sock", false},
		"not clean":             {"/tmp/../tmp/relay.sock", false},
		"embedded NUL":          {"/tmp/relay\x00.sock", false},
		"at the kernel limit":   {longest, true},
		"over the kernel limit": {longest + "a", false},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := GenerateSingBoxTransparentProxy(
				profile, testCase.path, "session-user", "session-password",
				t.TempDir(), "en0", []string{"192.0.2.53"},
			)
			if testCase.valid && err != nil {
				t.Fatalf("valid relay socket path rejected: %v", err)
			}
			if !testCase.valid && err == nil {
				t.Fatal("invalid relay socket path accepted")
			}
		})
	}
}
