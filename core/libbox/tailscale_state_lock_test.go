//go:build !windows

package libbox

import (
	"errors"
	"path/filepath"
	"testing"
)

func TestTailscaleStateLockExcludesConcurrentRuntimeAndReleases(t *testing.T) {
	stateDirectory := filepath.Join(t.TempDir(), "tailscale", "home")
	configJSON := `{"endpoints":[` +
		`{"type":"tailscale","tag":"tailscale-home","state_directory":"` +
		stateDirectory +
		`"}]}`

	first, err := acquireTailscaleStateLocks(configJSON)
	if err != nil {
		t.Fatalf("first lock: %v", err)
	}
	t.Cleanup(func() {
		releaseTailscaleStateLocks(first)
	})

	second, err := acquireTailscaleStateLocks(configJSON)
	if !errors.Is(err, errTailscaleStateInUse) {
		releaseTailscaleStateLocks(second)
		t.Fatalf("second lock error = %v, want %v", err, errTailscaleStateInUse)
	}

	releaseTailscaleStateLocks(first)
	first = nil
	third, err := acquireTailscaleStateLocks(configJSON)
	if err != nil {
		t.Fatalf("lock after release: %v", err)
	}
	releaseTailscaleStateLocks(third)
}

func TestTailscaleStateLockIgnoresConfigsWithoutTailscale(t *testing.T) {
	locks, err := acquireTailscaleStateLocks(
		`{"endpoints":[{"type":"wireguard","tag":"other"}]}`,
	)
	if err != nil {
		t.Fatalf("lock direct config: %v", err)
	}
	if len(locks) != 0 {
		releaseTailscaleStateLocks(locks)
		t.Fatalf("locks = %d, want 0", len(locks))
	}
}
