package main

import (
	"flag"
	"fmt"
	"os"
)

func runDaemonCmd(args []string) {
	fs := flag.NewFlagSet("daemon", flag.ExitOnError)
	socketPath := fs.String("socket", "/tmp/xdial.sock", "unix socket path")
	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: xdial daemon [--socket PATH]\n\nRun as a socket daemon for UI or CLI clients.\n\n")
		fs.PrintDefaults()
	}
	fs.Parse(args)
	runDaemon(*socketPath)
}
