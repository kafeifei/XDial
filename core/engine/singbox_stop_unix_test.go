//go:build darwin || linux

package engine

import (
	"os/exec"
	"path/filepath"
	"strings"
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

// startWatched 复现 startConfig 的收尾接线：跑起来的子进程交给 watch 独占回收。
func startWatched(t *testing.T, script string, onExit func(error)) *SingBoxProcess {
	t.Helper()
	logWriter := &singBoxLogWriter{}
	cmd := exec.Command("sh", "-c", script)
	cmd.Stdout = logWriter
	cmd.Stderr = logWriter
	if err := cmd.Start(); err != nil {
		t.Fatalf("start process: %v", err)
	}
	exited := make(chan struct{})
	process := &SingBoxProcess{
		configPath: filepath.Join(t.TempDir(), "sing-box.json"),
		onExit:     onExit,
		cmd:        cmd,
		exited:     exited,
	}
	go process.watch(cmd, exited, logWriter)
	return process
}

// sing-box 的启动期错误（规则集首次下载失败等）发生在 spawn 之后，check 抓不到。
// 没有退出监听，engine 会一直停在"已连接"，用户看到的是"已连接但整机没网"。
func TestSingBoxUnexpectedExitReportsStderrTail(t *testing.T) {
	exitErr := make(chan error, 1)
	startWatched(t, `echo "FATAL[0000] initial rule-set: ruleset-gfw: dial tcp: i/o timeout" >&2; exit 1`,
		func(err error) { exitErr <- err })

	select {
	case err := <-exitErr:
		if !strings.Contains(err.Error(), "exit status 1") {
			t.Fatalf("exit status must be reported: %v", err)
		}
		if !strings.Contains(err.Error(), "initial rule-set: ruleset-gfw") {
			t.Fatalf("sing-box own error must be carried out: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("unexpected exit was not reported")
	}
}

// 主动 Stop 不是故障：不能把用户点的"断开"报成 sing-box 崩溃。
func TestSingBoxStopDoesNotReportExit(t *testing.T) {
	exitErr := make(chan error, 1)
	process := startWatched(t, "sleep 30", func(err error) { exitErr <- err })
	process.stop(2 * time.Second)

	select {
	case err := <-exitErr:
		t.Fatalf("deliberate stop reported as failure: %v", err)
	case <-time.After(300 * time.Millisecond):
	}
}
