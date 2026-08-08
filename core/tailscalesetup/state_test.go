package tailscalesetup

import (
	"os"
	"path/filepath"
	"testing"
)

func TestPreparePersistentStateMovesLegacyIdentityOnce(t *testing.T) {
	root := t.TempDir()
	legacy := filepath.Join(root, "legacy")
	active := filepath.Join(root, "active")
	legacyState := filepath.Join(legacy, "tailscale")
	if err := os.MkdirAll(legacyState, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(legacyState, "identity"),
		[]byte("logged-in"),
		0o600,
	); err != nil {
		t.Fatal(err)
	}

	if err := PreparePersistentState(legacy, active); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(legacyState); !os.IsNotExist(err) {
		t.Fatalf("legacy state still exists: %v", err)
	}
	data, err := os.ReadFile(filepath.Join(active, "tailscale", "identity"))
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "logged-in" {
		t.Fatalf("identity = %q", data)
	}

	recreatedLegacy := filepath.Join(legacyState, "identity")
	if err := os.MkdirAll(filepath.Dir(recreatedLegacy), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(recreatedLegacy, []byte("stale"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := PreparePersistentState(legacy, active); err != nil {
		t.Fatal(err)
	}
	data, err = os.ReadFile(filepath.Join(active, "tailscale", "identity"))
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "logged-in" {
		t.Fatalf("second run replaced active identity with %q", data)
	}
}

func TestPreparePersistentStatePreservesUnregisteredDestination(t *testing.T) {
	root := t.TempDir()
	legacy := filepath.Join(root, "legacy")
	active := filepath.Join(root, "active")
	if err := os.MkdirAll(filepath.Join(legacy, "tailscale"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(legacy, "tailscale", "identity"),
		[]byte("logged-in"),
		0o600,
	); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(active, "tailscale"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(active, "tailscale", "identity"),
		[]byte("unregistered"),
		0o600,
	); err != nil {
		t.Fatal(err)
	}

	if err := PreparePersistentState(legacy, active); err != nil {
		t.Fatal(err)
	}
	backup, err := os.ReadFile(
		filepath.Join(active, "tailscale.pre-migration", "identity"),
	)
	if err != nil {
		t.Fatal(err)
	}
	if string(backup) != "unregistered" {
		t.Fatalf("backup = %q", backup)
	}
}

func TestPreparePersistentStateRejectsRelativeAndSymlinkPaths(t *testing.T) {
	if err := PreparePersistentState("relative", t.TempDir()); err == nil {
		t.Fatal("relative legacy path should be rejected")
	}

	root := t.TempDir()
	legacy := filepath.Join(root, "legacy")
	active := filepath.Join(root, "active")
	if err := os.MkdirAll(legacy, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(root, filepath.Join(legacy, "tailscale")); err != nil {
		t.Fatal(err)
	}
	if err := PreparePersistentState(legacy, active); err == nil {
		t.Fatal("symlink state should be rejected")
	}
}
