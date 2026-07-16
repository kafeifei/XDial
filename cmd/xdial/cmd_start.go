package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"github.com/kafeifei/xdial/core/config"
	"github.com/kafeifei/xdial/core/engine"
)

type cliCallback struct {
	jsonMode bool
}

func (c *cliCallback) OnStatusChanged(statusJSON string) {
	if c.jsonMode {
		fmt.Println(statusJSON)
		return
	}
	var msg engine.StatusMessage
	if err := json.Unmarshal([]byte(statusJSON), &msg); err != nil {
		fmt.Fprintf(os.Stderr, "[status] %s\n", statusJSON)
		return
	}
	switch msg.Status {
	case "connecting":
		fmt.Fprintf(os.Stderr, "[connecting] VPN...\n")
	case "connected":
		fmt.Fprintf(os.Stderr, "[connected]  Press Ctrl+C to disconnect.\n")
	case "reconnecting":
		fmt.Fprintf(os.Stderr, "[reconnecting]\n")
	case "disconnecting":
		fmt.Fprintf(os.Stderr, "[disconnecting]\n")
	case "disconnected":
		fmt.Fprintf(os.Stderr, "[disconnected]\n")
	default:
		fmt.Fprintf(os.Stderr, "[%s]\n", msg.Status)
	}
}

func (c *cliCallback) OnError(code int, message string) {
	if c.jsonMode {
		data, _ := json.Marshal(map[string]any{"error": message, "code": code})
		fmt.Println(string(data))
		return
	}
	fmt.Fprintf(os.Stderr, "[error] %s\n", message)
}

func (c *cliCallback) OnAuthRequired(authURL string) {
	if c.jsonMode {
		data, _ := json.Marshal(map[string]any{"event": "tailscale-auth-required", "data": authURL})
		fmt.Println(string(data))
		return
	}
	fmt.Fprintf(os.Stderr, "[tailscale] Open to authenticate: %s\n", authURL)
}

func runStartCmd(args []string) {
	fs := flag.NewFlagSet("start", flag.ExitOnError)
	profilePath := fs.String("f", "", "path to profile JSON file (required)")
	jsonOutput := fs.Bool("json", false, "output status as JSONL to stdout")
	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: xdial start -f <profile.json> [--json]\n\nConnect VPN in foreground. Ctrl+C to disconnect.\n\n")
		fs.PrintDefaults()
	}
	fs.Parse(args)
	rejectLeftoverArgs(fs)

	if *profilePath == "" {
		fs.Usage()
		os.Exit(1)
	}

	data, err := os.ReadFile(*profilePath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error reading profile: %s\n", err)
		os.Exit(1)
	}

	profile, err := config.ParseProfile(data)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error parsing profile JSON: %s\n", err)
		os.Exit(1)
	}

	basePath := filepath.Join(os.TempDir(), "xdial-engine")
	os.MkdirAll(basePath, 0755)
	statePath := filepath.Join(basePath, "state")
	if home, err := os.UserHomeDir(); err == nil {
		statePath = filepath.Join(home, ".xdial")
	}
	os.MkdirAll(statePath, 0700)

	killOrphanSingBox()

	cb := &cliCallback{jsonMode: *jsonOutput}
	eng := engine.New(basePath, statePath, cb)

	if err := eng.Start(profile); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %s\n", err)
		os.Exit(1)
	}

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig

	if !*jsonOutput {
		fmt.Fprintf(os.Stderr, "\n")
	}
	eng.Stop()

	slog.Info("stopped")
}
