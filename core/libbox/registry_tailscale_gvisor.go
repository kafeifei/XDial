//go:build !windows && with_gvisor && !mobile_no_tailscale

package libbox

import (
	"github.com/sagernet/sing-box/adapter/endpoint"
	"github.com/sagernet/sing-box/dns"
	"github.com/sagernet/sing-box/protocol/tailscale"
)

func registerTailscaleEndpoint(registry *endpoint.Registry) {
	tailscale.RegisterEndpoint(registry)
}

func registerTailscaleDNSTransport(registry *dns.TransportRegistry) {
	tailscale.RegistryTransport(registry)
}
