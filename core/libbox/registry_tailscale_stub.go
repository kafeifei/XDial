//go:build !windows && (!with_gvisor || mobile_no_tailscale)

package libbox

import (
	"github.com/sagernet/sing-box/adapter/endpoint"
	"github.com/sagernet/sing-box/dns"
)

func registerTailscaleEndpoint(_ *endpoint.Registry) {}

func registerTailscaleDNSTransport(_ *dns.TransportRegistry) {}
