//go:build linux

package main

import (
	"log/slog"
	"os/exec"
)

func killOrphanSingBox(pattern string) {
	out, err := exec.Command("pgrep", "-f", pattern).Output()
	if err != nil || len(out) == 0 {
		return
	}
	slog.Info("killing orphan sing-box processes")
	exec.Command("pkill", "-f", pattern).Run()
}
