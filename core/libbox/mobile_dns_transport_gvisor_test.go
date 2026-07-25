//go:build !windows && with_gvisor && !mobile_no_tailscale

package libbox

import (
	"testing"

	"github.com/sagernet/tailscale/ipn/ipnlocal"
)

func TestTailscaleMobileDNSDoesNotReadNetMapBeforeBackendIsRunning(t *testing.T) {
	for name, backend := range map[string]*ipnlocal.LocalBackend{
		"missing":   nil,
		"not ready": {},
	} {
		suffixes := claimedSuffixesFromTailscaleBackend(backend)
		if len(suffixes) != 0 {
			t.Fatalf("%s backend claimed unexpected suffixes: %v", name, suffixes)
		}
	}
}
