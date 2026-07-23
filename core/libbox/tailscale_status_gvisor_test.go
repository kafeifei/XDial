//go:build !windows && with_gvisor && !mobile_no_tailscale

package libbox

import (
	"context"
	stdjson "encoding/json"
	"net/netip"
	"strings"
	"testing"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json"
	"github.com/sagernet/tailscale/ipn/ipnstate"
	"github.com/sagernet/tailscale/types/key"
)

func TestEncodeTailscaleStatusAllowlist(t *testing.T) {
	status := &ipnstate.Status{
		Version:        "must-not-leak-version",
		BackendState:   "NeedsLogin",
		AuthURL:        "https://login.tailscale.example/auth/required-token",
		Health:         []string{"must-not-leak-health"},
		MagicDNSSuffix: "must-not-leak-legacy-suffix",
		CurrentTailnet: &ipnstate.TailnetStatus{
			Name:           "must-not-leak-tailnet",
			MagicDNSSuffix: "private-tailnet.ts.net",
		},
		Peer: map[key.NodePublic]*ipnstate.PeerStatus{
			key.NewNode().Public(): {
				ID:             "online-node",
				DNSName:        "home-mac.private-tailnet.ts.net.",
				OS:             "macOS",
				TailscaleIPs:   []netip.Addr{netip.MustParseAddr("fd7a:115c:a1e0::1"), netip.MustParseAddr("100.64.0.8")},
				Online:         true,
				ExitNodeOption: true,
				Addrs:          []string{"must-not-leak-endpoint"},
			},
			key.NewNode().Public(): {
				ID:             "offline-node",
				HostName:       "offline-host",
				OS:             "linux",
				TailscaleIPs:   []netip.Addr{netip.MustParseAddr("fd7a:115c:a1e0::2")},
				ExitNodeOption: true,
			},
			key.NewNode().Public(): {
				ID:           "ordinary-peer",
				DNSName:      "ordinary.private-tailnet.ts.net.",
				TailscaleIPs: []netip.Addr{netip.MustParseAddr("100.64.0.9")},
			},
		},
	}

	encoded, err := encodeTailscaleStatus(status)
	if err != nil {
		t.Fatal(err)
	}
	var payload map[string]interface{}
	if err := stdjson.Unmarshal([]byte(encoded), &payload); err != nil {
		t.Fatal(err)
	}
	if len(payload) != 3 || payload["backend_state"] != "NeedsLogin" || payload["auth_url"] != status.AuthURL {
		t.Fatalf("unexpected status payload: %v", payload)
	}
	nodes, ok := payload["exit_nodes"].([]interface{})
	if !ok || len(nodes) != 2 {
		t.Fatalf("unexpected exit nodes: %v", payload["exit_nodes"])
	}
	first := nodes[0].(map[string]interface{})
	if first["id"] != "online-node" || first["name"] != "home-mac" || first["ip"] != "100.64.0.8" || first["online"] != true || first["os"] != "macOS" {
		t.Fatalf("unexpected first exit node: %v", first)
	}
	for _, forbidden := range []string{
		"must-not-leak-version",
		"must-not-leak-health",
		"must-not-leak-tailnet",
		"must-not-leak-legacy-suffix",
		"must-not-leak-endpoint",
		"ordinary-peer",
		"private-tailnet.ts.net",
	} {
		if strings.Contains(encoded, forbidden) {
			t.Fatalf("status leaked %q: %s", forbidden, encoded)
		}
	}
}

func TestTailscaleStatusErrorDoesNotEchoEndpointTag(t *testing.T) {
	engine := New(nil)
	_, err := engine.TailscaleStatus("private-endpoint-name")
	if err == nil {
		t.Fatal("expected stopped engine error")
	}
	if strings.Contains(err.Error(), "private-endpoint-name") {
		t.Fatalf("error leaked endpoint tag: %v", err)
	}
}

func TestBoxContextRegistersTailscale(t *testing.T) {
	configJSON := []byte(`{
		"log":{"disabled":true},
		"dns":{"servers":[
			{"type":"udp","tag":"xdial-public-dns","server":"1.1.1.1","server_port":53},
			{"type":"tailscale","tag":"tailscale-dns","endpoint":"tailscale-test","accept_default_resolvers":false},
			{"type":"xdial-mobile","tag":"xdial-mobile-dns","public_fallback":"xdial-public-dns",
				"tailscale":[{"endpoint":"tailscale-test","server":"tailscale-dns"}]}
		],"final":"xdial-mobile-dns"},
		"endpoints":[{
			"type":"tailscale",
			"tag":"tailscale-test",
			"state_directory":"` + t.TempDir() + `"
		}],
		"inbounds":[],
		"outbounds":[{"type":"direct","tag":"direct"}],
		"route":{"final":"direct","default_domain_resolver":"xdial-public-dns"}
	}`)
	ctx := boxContext(context.Background())
	opts, err := json.UnmarshalExtendedContext[option.Options](ctx, configJSON)
	if err != nil {
		t.Fatalf("parse Tailscale config: %v", err)
	}
	instance, err := box.New(box.Options{Options: opts, Context: ctx})
	if err != nil {
		t.Fatalf("construct box with Tailscale endpoint: %v", err)
	}
	if _, found := instance.Endpoint().Get("tailscale-test"); !found {
		t.Fatal("registered Tailscale endpoint missing from box")
	}
	_ = instance.Close()
}
