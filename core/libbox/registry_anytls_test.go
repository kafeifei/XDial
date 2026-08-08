//go:build !windows

package libbox

import (
	"context"
	"strings"
	"testing"

	"github.com/kafeifei/xdial/core/config"
	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json"
)

func TestAnyTLSSubscriptionUsabilityMatchesGeneratorBoundaries(t *testing.T) {
	line := config.Line{
		ID:                             "anytls",
		Name:                           "AnyTLS",
		Type:                           config.LineTypeAnyTLS,
		Enabled:                        true,
		AnyTLSServer:                   "anytls.example.com",
		AnyTLSPort:                     3489,
		AnyTLSPassword:                 "secret",
		AnyTLSClientFingerprint:        "chrome",
		AnyTLSALPN:                     []string{"h2"},
		AnyTLSIdleSessionCheckInterval: 30,
		AnyTLSIdleSessionTimeout:       30,
	}
	if !subscriptionNodeUsable(line) {
		t.Fatal("valid AnyTLS subscription node must be usable")
	}

	line.AnyTLSClientFingerprint = "unknown"
	if subscriptionNodeUsable(line) {
		t.Fatal("unsupported AnyTLS fingerprint must make the node unavailable")
	}
	line.AnyTLSClientFingerprint = "chrome"
	line.AnyTLSALPN = []string{strings.Repeat("a", 256)}
	if subscriptionNodeUsable(line) {
		t.Fatal("invalid AnyTLS ALPN must make the node unavailable")
	}
}

func TestOutboundRegistryIncludesAnyTLS(t *testing.T) {
	options, ok := outboundRegistry().CreateOptions("anytls")
	if !ok {
		t.Fatal("AnyTLS outbound is not registered")
	}
	if _, ok := options.(*option.AnyTLSOutboundOptions); !ok {
		t.Fatalf("unexpected AnyTLS options type: %T", options)
	}
}

func TestAnyTLSConfigConstructsWithRuntimeRegistry(t *testing.T) {
	ctx := boxContext(context.Background())
	configJSON := []byte(`{
		"outbounds": [{
			"type": "anytls",
			"tag": "proxy-anytls",
			"server": "anytls.example.com",
			"server_port": 443,
			"password": "secret",
			"tls": {
				"enabled": true,
				"server_name": "edge.example.com"
			}
		}],
		"route": {
			"final": "proxy-anytls"
		}
	}`)
	options, err := json.UnmarshalExtendedContext[option.Options](ctx, configJSON)
	if err != nil {
		t.Fatalf("parse AnyTLS config with runtime registry: %v", err)
	}
	instance, err := box.New(box.Options{Options: options, Context: ctx})
	if err != nil {
		t.Fatalf("construct AnyTLS outbound with runtime registry: %v", err)
	}
	if err := instance.Close(); err != nil {
		t.Fatalf("close AnyTLS test instance: %v", err)
	}
}
