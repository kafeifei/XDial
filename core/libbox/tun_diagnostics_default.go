//go:build !with_gvisor || !darwin

package libbox

import tun "github.com/sagernet/sing-tun"

func wrapTunWithDiagnostics(device tun.Tun, _ *xdPlatformInterface) tun.Tun {
	return device
}
