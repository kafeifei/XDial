//go:build windows

package main

import (
	"log/slog"
	"os/exec"
)

// killOrphanSingBox 清理残留的 sing-box 进程（Windows 桌面 CLI 跨平台脚手架，
// 尚未实际投产）。按镜像名结束，taskkill 在无匹配进程时返回非零，静默忽略。
func killOrphanSingBox() {
	if err := exec.Command("taskkill", "/F", "/IM", "sing-box.exe").Run(); err == nil {
		slog.Info("killed orphan sing-box processes")
	}
}
