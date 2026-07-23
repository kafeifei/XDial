//go:build !windows && (!with_gvisor || mobile_no_tailscale)

package libbox

import "github.com/sagernet/sing-box/adapter"

func newMobileDNSOwner(_ adapter.EndpointManager, _ string) (mobileDNSOwner, error) {
	return nil, errMobileDNSFailed
}
