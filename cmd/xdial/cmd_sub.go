package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"github.com/kafeifei/xdial/core/subscription"
)

func runSubCmd(args []string) {
	if len(args) < 1 {
		fmt.Fprintf(os.Stderr, "Usage: xdial sub <command>\n\nCommands:\n  parse    Parse a subscription URL\n")
		os.Exit(1)
	}

	switch args[0] {
	case "parse":
		runSubParseCmd(args[1:])
	default:
		fmt.Fprintf(os.Stderr, "unknown sub command: %s\n", args[0])
		os.Exit(1)
	}
}

func runSubParseCmd(args []string) {
	fs := flag.NewFlagSet("sub parse", flag.ExitOnError)
	format := fs.String("format", "auto", "subscription format (auto/clash/surge/base64)")
	jsonOutput := fs.Bool("json", false, "output as JSON")
	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: xdial sub parse [--format auto] [--json] <url>\n\nParse a subscription URL and print the result.\n\n")
		fs.PrintDefaults()
	}
	fs.Parse(args)

	if fs.NArg() < 1 {
		fs.Usage()
		os.Exit(1)
	}
	url := fs.Arg(0)

	result, err := subscription.Parse(url, "", *format)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %s\n", err)
		os.Exit(1)
	}
	subscription.ExpandRulesets(result)

	if *jsonOutput {
		data, _ := json.MarshalIndent(result, "", "  ")
		fmt.Println(string(data))
	} else {
		fmt.Printf("Found %d line(s), %d group(s), %d rule(s)\n",
			len(result.Lines), len(result.ProxyGroups), len(result.Rules))
		for _, l := range result.Lines {
			fmt.Printf("  %-20s %-15s\n", l.Name, string(l.Type))
		}
	}
}
