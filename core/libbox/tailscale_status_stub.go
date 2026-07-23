//go:build !windows && (!with_gvisor || mobile_no_tailscale)

package libbox

import "fmt"

// TailscaleStatus 保留 gomobile API 形状；未包含 gVisor/Tailscale 的构建明确失败。
func (l *Libbox) TailscaleStatus(_ string) (string, error) {
	return "", fmt.Errorf("Tailscale is unavailable in this build")
}
