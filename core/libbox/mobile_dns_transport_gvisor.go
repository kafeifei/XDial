//go:build !windows && with_gvisor && !mobile_no_tailscale

package libbox

import (
	"strings"

	"github.com/sagernet/sing-box/adapter"
	boxTailscale "github.com/sagernet/sing-box/protocol/tailscale"
	"github.com/sagernet/tailscale/ipn"
	"github.com/sagernet/tailscale/ipn/ipnlocal"
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
	server := o.endpoint.Server()
	if server == nil {
		return nil
	}
	return claimedSuffixesFromTailscaleBackend(server.ExportLocalBackend())
}

func claimedSuffixesFromTailscaleBackend(backend *ipnlocal.LocalBackend) []string {
	// tsnet 在 Server.Start 的早期阶段已经发布 LocalBackend，但 currentNode
	// 尚未就绪；此时调用 NetMap 会在 Tailscale 内部空指针崩溃。
	if backend == nil || backend.State() != ipn.Running {
		return nil
	}
	networkMap := backend.NetMap()
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
