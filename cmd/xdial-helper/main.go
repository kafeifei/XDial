package main

import (
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"syscall"

	"github.com/kafeifei/xdial/core/engine"
)

const defaultSocketPath = "/tmp/xdial.sock"

type daemonCallback struct {
	clients *ClientSet
}

func (d *daemonCallback) OnStatusChanged(statusJSON string) {
	slog.Info("status", "data", statusJSON)
	d.clients.Broadcast(Response{Type: "status", Data: statusJSON})
}

func (d *daemonCallback) OnError(code int, message string) {
	slog.Error("engine", "code", code, "msg", message)
	d.clients.Broadcast(Response{
		Type:    "error",
		Message: fmt.Sprintf("[%d] %s", code, message),
	})
}

func main() {
	socketPath := defaultSocketPath
	if len(os.Args) > 1 {
		socketPath = os.Args[1]
	}

	if isAlreadyRunning(socketPath) {
		slog.Info("another instance is already running, exiting")
		os.Exit(0)
	}

	killOrphanSingBox()

	basePath := filepath.Join(os.TempDir(), "xdial-engine")
	os.MkdirAll(basePath, 0755)

	clients := NewClientSet()
	cb := &daemonCallback{clients: clients}
	eng := engine.New(basePath, cb)

	os.Remove(socketPath)
	ln, err := net.Listen("unix", socketPath)
	if err != nil {
		slog.Error("listen failed", "path", socketPath, "err", err)
		os.Exit(1)
	}
	os.Chmod(socketPath, 0666)

	slog.Info("daemon started", "socket", socketPath, "pid", os.Getpid())

	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go handleClient(conn, eng, clients)
		}
	}()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig

	slog.Info("shutting down")
	eng.Stop()
	ln.Close()
	os.Remove(socketPath)
}

func killOrphanSingBox() {
	out, err := exec.Command("pgrep", "-f", "sing-box run.*xdial-engine").Output()
	if err != nil || len(out) == 0 {
		return
	}
	slog.Info("killing orphan sing-box processes")
	exec.Command("pkill", "-f", "sing-box run.*xdial-engine").Run()
}

func isAlreadyRunning(socketPath string) bool {
	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

func handleClient(conn net.Conn, eng *engine.Engine, clients *ClientSet) {
	client := NewClient(conn)
	clients.Add(client)
	defer func() {
		clients.Remove(client)
		client.Close()
	}()

	client.Send(Response{
		Type: "status",
		Data: eng.Status(),
	})

	reqCh := make(chan Request)
	go ReadRequests(conn, reqCh)

	for req := range reqCh {
		switch req.Cmd {
		case "start":
			if err := eng.Start(req.Profile); err != nil {
				client.Send(Response{Type: "result", Cmd: "start", OK: false, Message: err.Error()})
			} else {
				client.Send(Response{Type: "result", Cmd: "start", OK: true})
			}

		case "stop":
			if err := eng.Stop(); err != nil {
				client.Send(Response{Type: "result", Cmd: "stop", OK: false, Message: err.Error()})
			} else {
				client.Send(Response{Type: "result", Cmd: "stop", OK: true})
			}

		case "status":
			client.Send(Response{Type: "status", Data: eng.Status()})

		default:
			client.Send(Response{Type: "error", Message: "unknown command: " + req.Cmd})
		}
	}
}
