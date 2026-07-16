//go:build darwin || linux

package engine

import (
	"os/exec"
	"testing"
	"time"
)

func TestSingBoxStopKillsHungProcess(t *testing.T) {
	cmd := exec.Command("sh", "-c", "trap '' INT TERM; while :; do :; done")
	if err := cmd.Start(); err != nil {
		t.Fatalf("start process: %v", err)
	}

	process := &SingBoxProcess{cmd: cmd}
	started := time.Now()
	process.stop(100 * time.Millisecond)
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("Stop took %s, want less than 1s", elapsed)
	}
	if process.cmd != nil {
		t.Fatal("command was not cleared")
	}
}
