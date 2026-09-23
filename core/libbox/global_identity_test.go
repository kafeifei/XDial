//go:build !windows

package libbox

import (
	"github.com/kafeifei/xdial/core/config"
	"testing"
)

func TestGlobalRuntimeIdentityMatchesOriginalTailscaleSource(t *testing.T) {
	source := &config.Profile{ID: "source", Tailscale: config.TailscaleIdentity{Hostname: "xdial-existing"}}
	line := &config.Line{ID: "node", Type: config.LineTypeTailscale, Enabled: true, TailscaleMagicDNS: true}
	before, err := lineRuntimeIdentity(source, line)
	if err != nil {
		t.Fatal(err)
	}
	global := &config.Profile{ID: "global-configuration"}
	moved := *line
	moved.IdentityProfileID = source.ID
	moved.IdentityHostname = source.Tailscale.Hostname
	after, err := lineRuntimeIdentity(global, &moved)
	if err != nil {
		t.Fatal(err)
	}
	if before != after {
		t.Fatal("promoting to global configuration changed protocol identity")
	}
	moved.IdentityProfileID = "other-source"
	different, err := lineRuntimeIdentity(global, &moved)
	if err != nil {
		t.Fatal(err)
	}
	if after == different {
		t.Fatal("independent source identities collapsed")
	}
}
