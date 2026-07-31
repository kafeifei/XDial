//go:build !windows && with_utls

package libbox

import (
	"context"
	"testing"
	"time"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json"
)

func TestAnyTLSChromeH2ConfigConstructsWithRuntimeRegistry(t *testing.T) {
	ctx := boxContext(context.Background())
	configJSON := []byte(`{
		"outbounds": [{
			"type": "anytls",
			"tag": "proxy-anytls",
			"server": "anytls.example.com",
			"server_port": 3489,
			"password": "secret",
			"idle_session_check_interval": "30s",
			"idle_session_timeout": "30s",
			"min_idle_session": 0,
			"tls": {
				"enabled": true,
				"server_name": "edge.example.com",
				"insecure": true,
				"alpn": ["h2"],
				"utls": {
					"enabled": true,
					"fingerprint": "chrome"
				}
			}
		}],
		"route": {
			"final": "proxy-anytls"
		}
	}`)
	options, err := json.UnmarshalExtendedContext[option.Options](ctx, configJSON)
	if err != nil {
		t.Fatalf("parse AnyTLS uTLS config with runtime registry: %v", err)
	}
	if len(options.Outbounds) != 1 {
		t.Fatalf("unexpected outbounds: %+v", options.Outbounds)
	}
	anyTLSOptions, ok := options.Outbounds[0].Options.(*option.AnyTLSOutboundOptions)
	if !ok {
		t.Fatalf("unexpected AnyTLS options type: %T", options.Outbounds[0].Options)
	}
	if anyTLSOptions.IdleSessionCheckInterval.Build() != 30*time.Second ||
		anyTLSOptions.IdleSessionTimeout.Build() != 30*time.Second ||
		anyTLSOptions.MinIdleSession != 0 {
		t.Fatalf("AnyTLS idle session options were not preserved: %+v", anyTLSOptions)
	}
	if anyTLSOptions.TLS == nil ||
		len(anyTLSOptions.TLS.ALPN) != 1 ||
		anyTLSOptions.TLS.ALPN[0] != "h2" ||
		anyTLSOptions.TLS.UTLS == nil ||
		!anyTLSOptions.TLS.UTLS.Enabled ||
		anyTLSOptions.TLS.UTLS.Fingerprint != "chrome" {
		t.Fatalf("AnyTLS TLS/uTLS options were not preserved: %+v", anyTLSOptions.TLS)
	}
	instance, err := box.New(box.Options{Options: options, Context: ctx})
	if err != nil {
		t.Fatalf("construct AnyTLS uTLS outbound with runtime registry: %v", err)
	}
	if err := instance.Start(); err != nil {
		t.Fatalf("start AnyTLS uTLS outbound with runtime registry: %v", err)
	}
	outbound, loaded := instance.Outbound().Outbound("proxy-anytls")
	if !loaded {
		t.Fatal("AnyTLS runtime outbound is missing")
	}
	networks := outbound.Network()
	if len(networks) != 2 || networks[0] != "tcp" || networks[1] != "udp" {
		t.Fatalf("AnyTLS must expose native TCP and UoT UDP: %+v", networks)
	}
	if err := instance.Close(); err != nil {
		t.Fatalf("close AnyTLS uTLS test instance: %v", err)
	}
}
