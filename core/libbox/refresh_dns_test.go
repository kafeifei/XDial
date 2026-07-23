//go:build !windows

package libbox

import (
	"strings"
	"testing"
)

func TestRefreshDNSRejectsStoppedEngine(t *testing.T) {
	engine := New(nil)
	err := engine.RefreshDNS()
	if err == nil {
		t.Fatal("expected stopped engine error")
	}
	if !strings.Contains(err.Error(), "not running") {
		t.Fatalf("unexpected stopped engine error: %v", err)
	}
}
