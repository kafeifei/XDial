//go:build darwin

package main

import (
	"log/slog"
	"os/exec"
)

func killOrphanSingBox() {
	out, err := exec.Command("pgrep", "-f", "sing-box run.*xdial-engine").Output()
	if err != nil || len(out) == 0 {
		return
	}
	slog.Info("killing orphan sing-box processes")
	exec.Command("pkill", "-f", "sing-box run.*xdial-engine").Run()
}
