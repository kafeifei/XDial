package main

import (
	"flag"
	"fmt"
	"os"
)

func runStopCmd(args []string) {
	fs := flag.NewFlagSet("stop", flag.ExitOnError)
	socketPath := fs.String("socket", "/tmp/xdial.sock", "unix socket path")
	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: xdial stop [--socket PATH]\n\nTell daemon to disconnect VPN.\n\n")
		fs.PrintDefaults()
	}
	fs.Parse(args)

	req := Request{ID: nextRequestID(), Cmd: "stop"}
	resp, err := sendCommand(*socketPath, req)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %s\n", err)
		os.Exit(3)
	}

	if !resp.OK {
		fmt.Fprintf(os.Stderr, "Error: %s\n", resp.Message)
		os.Exit(1)
	}

	fmt.Println("VPN stopped.")
}
