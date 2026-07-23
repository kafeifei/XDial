//go:build !windows && with_gvisor && !mobile_no_tailscale

package libbox

import (
	"strings"

	"github.com/sagernet/sing-box/adapter"
	boxTailscale "github.com/sagernet/sing-box/protocol/tailscale"
)

type tailscaleMobileDNSOwner struct {
	endpoint *boxTailscale.Endpoint
}

func newMobileDNSOwner(manager adapter.EndpointManager, endpointTag string) (mobileDNSOwner, error) {
	endpoint, loaded := manager.Get(endpointTag)
	if !loaded {
		return nil, errMobileDNSFailed
	}
	tailscaleEndpoint, ok := endpoint.(*boxTailscale.Endpoint)
	if !ok {
		return nil, errMobileDNSFailed
	}
	return &tailscaleMobileDNSOwner{endpoint: tailscaleEndpoint}, nil
}

func (o *tailscaleMobileDNSOwner) claimedSuffixes() []string {
	if o == nil || o.endpoint == nil {
		return nil
	}
	networkMap := o.endpoint.Server().ExportLocalBackend().NetMap()
	if networkMap == nil {
		return nil
	}
	suffixes := make([]string, 0, len(networkMap.DNS.Routes)+1)
	for suffix := range networkMap.DNS.Routes {
		suffixes = append(suffixes, suffix)
	}
	if networkMap.DNS.Proxied {
		if suffix := strings.TrimSpace(networkMap.MagicDNSSuffix()); suffix != "" {
			suffixes = append(suffixes, suffix)
		}
	}
	return normalizeMobileDNSSuffixes(suffixes)
}

var _ mobileDNSOwner = (*tailscaleMobileDNSOwner)(nil)
