package libbox

import (
	"os"
	"path/filepath"
	"testing"
)

// testRelaySocketPath returns a relay socket path in a short private
// directory. The temporary directory Go hands to tests is already longer than
// a socket path may be, and a shared path would let two test processes take
// each other's socket for a stale one.
func testRelaySocketPath(t testing.TB) string {
	t.Helper()
	directory, err := os.MkdirTemp("/tmp", "xdr")
	if err != nil {
		t.Fatalf("create relay socket directory: %v", err)
	}
	t.Cleanup(func() { os.RemoveAll(directory) })
	return filepath.Join(directory, "relay")
}
