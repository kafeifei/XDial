//go:build !windows

package libbox

import (
	"github.com/kafeifei/xdial/core/config"
)

// GenerateNEConfig 供 Swift App 侧调用:把当前 Profile(JSON,字段与 core/config.Profile
// 兼容 —— 即 macOS 版 AppState.buildProfileJSON() 同款格式)转换成 NE 模式的 sing-box
// 配置 JSON,产出结果直接传给 Libbox.Start 的 configJSON 参数。
//
// App 侧调用时机:TunnelManager 在把隧道交给系统拉起之前,用当前 AppState.profile
// 序列化出 profileJSON,连同 AnyConnect 凭据一起写进 App Group 共享存储,供
// PacketTunnelProvider.startTunnel 读取。
//
// vpnServerIP 是 AnyConnect 服务端地址,只在生成器的路由排除逻辑里使用(macOS 场景才
// 有意义);NE 模式下没有系统级路由排除概念,传空字符串即可。
// basePath 是 App Group 共享容器的绝对路径(FileManager
// .containerURL(forSecurityApplicationGroupIdentifier:) 拿到的路径),用于拼
// cache_file 的绝对路径,必须是扩展进程可写的目录。
func GenerateNEConfig(profileJSON string, vpnServerIP string, basePath string) (string, error) {
	profile, err := config.ParseProfile([]byte(profileJSON))
	if err != nil {
		return "", err
	}
	// socksPort 在 NE 模式下不生效(vpn 出口固定用自研 type:"vpn",见
	// generator.go 里 platform == PlatformNE 的分支),这里固定传 0。
	data, err := config.GenerateSingBoxFor(profile, 0, vpnServerIP, config.PlatformNE, basePath)
	if err != nil {
		return "", err
	}
	return string(data), nil
}
