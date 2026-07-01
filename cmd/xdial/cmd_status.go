package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
)

func runStatusCmd(args []string) {
	fs := flag.NewFlagSet("status", flag.ExitOnError)
	socketPath := fs.String("socket", "/tmp/xdial.sock", "unix socket path")
	jsonOutput := fs.Bool("json", false, "output as JSON")
	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: xdial status [--socket PATH] [--json]\n\nQuery daemon VPN status.\n\nExit codes: 0=connected, 1=disconnected, 2=transient, 3=daemon not running\n\n")
		fs.PrintDefaults()
	}
	fs.Parse(args)

	req := Request{ID: nextRequestID(), Cmd: "status"}
	resp, err := sendCommand(*socketPath, req)
	if err != nil {
		if *jsonOutput {
			fmt.Printf(`{"status":"error","message":"daemon not running"}` + "\n")
		} else {
			fmt.Fprintf(os.Stderr, "Error: %s\n", err)
		}
		os.Exit(3)
	}

	if !resp.OK {
		fmt.Fprintf(os.Stderr, "Error: %s\n", resp.Message)
		os.Exit(1)
	}

	if *jsonOutput {
		fmt.Println(resp.Data)
	} else {
		var status struct {
			Status string `json:"status"`
		}
		json.Unmarshal([]byte(resp.Data), &status)
		fmt.Printf("Status: %s\n", status.Status)
	}

	var status struct {
		Status string `json:"status"`
	}
	json.Unmarshal([]byte(resp.Data), &status)

	switch status.Status {
	case "connected":
		os.Exit(0)
	case "connecting", "reconnecting", "disconnecting":
		os.Exit(2)
	default:
		os.Exit(1)
	}
}
