package main

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/kafeifei/xdial/core/engine"
	"github.com/kafeifei/xdial/core/tailscalesetup"
)

// 当前用户下的任意进程都能连上 daemon socket，所以退役命令必须在进入 engine 之前
// 被拒绝：不启动数据面、不创建 engineBasePath，也不占用注册交接的工作计数。
func TestDaemonRejectsRetiredCommands(t *testing.T) {
	basePath := filepath.Join(t.TempDir(), "engine")
	clients := NewClientSet()
	eng := engine.New(basePath, t.TempDir(), &daemonCallback{clients: clients})
	gate := &daemonRegistrationGate{}

	server, peer := net.Pipe()
	done := make(chan struct{})
	go func() {
		defer close(done)
		handleClient(server, eng, tailscalesetup.New(t.TempDir()), newResolverRefresher(), &sync.Mutex{}, clients, gate)
	}()
	defer func() {
		peer.Close()
		<-done
	}()
	if err := peer.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatal(err)
	}

	encoder := json.NewEncoder(peer)
	scanner := bufio.NewScanner(peer)
	// handleClient 先推送一条 status 事件；net.Pipe 无缓冲，不读掉它就发不出请求。
	if !scanner.Scan() {
		t.Fatalf("missing initial status event: %v", scanner.Err())
	}
	roundTrip := func(req Request) Response {
		t.Helper()
		if err := encoder.Encode(req); err != nil {
			t.Fatalf("send %s: %v", req.Cmd, err)
		}
		for scanner.Scan() {
			var msg serverMessage
			if err := json.Unmarshal(scanner.Bytes(), &msg); err != nil {
				t.Fatalf("decode daemon message: %v", err)
			}
			if msg.isResponse() && msg.ID == req.ID {
				return Response{ID: msg.ID, OK: msg.OK, Message: msg.Message, Data: msg.Data}
			}
		}
		t.Fatalf("no response for %s: %v", req.Cmd, scanner.Err())
		return Response{}
	}

	profile := `{"lines":[{"id":"direct","type":"direct"}],"scenarios":[{"id":"default","default_line_id":"direct"}],"active_scenario_id":"default"}`
	for _, command := range []string{"start", "stop", "kill-session", "runtime-lines", "parse-sub"} {
		resp := roundTrip(Request{ID: "retired-" + command, Cmd: command, Profile: profile})
		if resp.OK || resp.Message != "retired command: "+command {
			t.Fatalf("%s should be rejected as retired, got ok=%v message=%q", command, resp.OK, resp.Message)
		}
	}

	if status := engineStatus(eng); status != "disconnected" {
		t.Fatalf("retired commands must not touch the engine, status=%q", status)
	}
	if _, err := os.Stat(basePath); !os.IsNotExist(err) {
		t.Fatalf("retired commands must not create the engine directory, stat err=%v", err)
	}
	if !gate.beginWork() {
		t.Fatal("retired commands must not leave registration work open")
	}
	gate.endWork()

	if resp := roundTrip(Request{ID: "info", Cmd: "daemon-info"}); !resp.OK {
		t.Fatalf("daemon-info should still be served, got %q", resp.Message)
	}
}
