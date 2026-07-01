package main

import (
	"encoding/json"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"github.com/kafeifei/xdial/core/config"
	"github.com/kafeifei/xdial/core/engine"
	"github.com/kafeifei/xdial/core/subscription"
)

type daemonCallback struct {
	clients *ClientSet
}

func (d *daemonCallback) OnStatusChanged(statusJSON string) {
	slog.Info("status", "data", statusJSON)
	d.clients.BroadcastEvent(Event{Event: "status", Data: statusJSON})
}

func (d *daemonCallback) OnError(code int, message string) {
	slog.Error("engine", "code", code, "msg", message)
	d.clients.BroadcastEvent(Event{Event: "error", Data: message})
}

func runDaemon(socketPath string) {
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

	client.SendEvent(Event{Event: "status", Data: eng.Status()})

	reqCh := make(chan Request)
	go ReadRequests(conn, reqCh)

	for req := range reqCh {
		switch req.Cmd {
		case "start":
			profile, err := config.ParseProfile([]byte(req.Profile))
			if err != nil {
				client.SendResponse(Response{ID: req.ID, OK: false, Message: "invalid profile: " + err.Error()})
			} else if err := eng.Start(profile); err != nil {
				client.SendResponse(Response{ID: req.ID, OK: false, Message: err.Error()})
			} else {
				client.SendResponse(Response{ID: req.ID, OK: true})
			}

		case "stop":
			if err := eng.Stop(); err != nil {
				client.SendResponse(Response{ID: req.ID, OK: false, Message: err.Error()})
			} else {
				client.SendResponse(Response{ID: req.ID, OK: true})
			}

		case "kill-session":
			eng.KillSession()
			client.SendResponse(Response{ID: req.ID, OK: true})

		case "status":
			client.SendResponse(Response{ID: req.ID, OK: true, Data: eng.Status()})

		case "parse-sub":
			result, err := subscription.Parse(req.SubURL, req.SubContent, req.SubFormat)
			if err != nil {
				client.SendResponse(Response{ID: req.ID, OK: false, Message: err.Error()})
			} else {
				subscription.ExpandRulesets(result)
				data, _ := json.Marshal(result)
				client.SendResponse(Response{ID: req.ID, OK: true, Data: string(data)})
			}

		default:
			client.SendResponse(Response{ID: req.ID, OK: false, Message: "unknown command: " + req.Cmd})
		}
	}
}
