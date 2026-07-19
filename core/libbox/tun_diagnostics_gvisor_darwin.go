//go:build with_gvisor && darwin

package libbox

import (
	tun "github.com/sagernet/sing-tun"
)

// Keep the production packet path identical to sing-tun. Wrapping its concrete
// gVisor endpoint can hide optional endpoint capabilities and is not worth the
// risk merely to collect counters; the end-to-end probe and bridge stats remain.
func wrapTunWithDiagnostics(device tun.Tun, _ *xdPlatformInterface) tun.Tun {
	return device
}
