package main

import (
	"fmt"
	"os"
)

var version = "dev"

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(1)
	}

	switch os.Args[1] {
	case "daemon":
		runDaemonCmd(os.Args[2:])
	case "start":
		runStartCmd(os.Args[2:])
	case "stop":
		runStopCmd(os.Args[2:])
	case "status":
		runStatusCmd(os.Args[2:])
	case "sub":
		runSubCmd(os.Args[2:])
	case "version", "--version", "-v":
		fmt.Printf("xdial %s\n", version)
	case "help", "--help", "-h":
		printUsage()
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n\n", os.Args[1])
		printUsage()
		os.Exit(1)
	}
}

func printUsage() {
	fmt.Fprintf(os.Stderr, `Usage: xdial <command> [options]

Commands:
  start    Connect VPN in foreground (Ctrl+C to disconnect)
  stop     Tell running daemon to disconnect
  status   Query daemon status
  daemon   Run as socket daemon (for launchd/systemd)
  sub      Subscription operations
  version  Print version

Run 'xdial <command> --help' for command-specific help.
`)
}
