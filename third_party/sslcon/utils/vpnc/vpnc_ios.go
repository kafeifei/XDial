//go:build ios

package vpnc

import (
	"fmt"
	"net"

	"sslcon/base"
	"sslcon/session"
)

// VPNAddress 与桌面版保持同名,供包内路由函数引用(ios 下为死代码)。
var VPNAddress string

// 说明: iOS/tvOS 沙盒禁止 fork/exec,系统里也没有 netstat/route/ifconfig/scutil
// 这些二进制,而桌面版 vpnc_darwin.go 依赖 github.com/jackpal/gateway(内部
// shell 出去跑 netstat -rn)和 os/exec 直接调用系统命令,在沙盒里会崩。
//
// XDial 在 tvOS 上恒为 base.Cfg.NoTUN == true,不创建 tun、不下发路由,所以
// 下面这些路由/DNS 操作函数本就是死代码;这里提供签名一致的空实现,仅为让
// ios 平台链接得过。GetLocalInterface 用纯标准库 net.Interfaces() 拿到基本
// 接口信息(Name/Ip4/Mac),Gateway 留空 —— AnyConnect 握手只用到 Ip4/Mac
// 作为客户端标识,Gateway 仅供路由操作使用,NoTUN 下无意义。

// ConfigInterface 在 tvOS(NoTUN)下为空操作。
func ConfigInterface(cSess *session.ConnSession) error {
	return nil
}

// SetRoutes 在 tvOS(NoTUN)下为空操作。
func SetRoutes(cSess *session.ConnSession) error {
	return nil
}

// ResetRoutes 在 tvOS(NoTUN)下为空操作。
func ResetRoutes(cSess *session.ConnSession) {
}

// DynamicAddIncludeRoutes 在 tvOS(NoTUN)下为空操作。
func DynamicAddIncludeRoutes(ips []string) {
}

// DynamicAddExcludeRoutes 在 tvOS(NoTUN)下为空操作。
func DynamicAddExcludeRoutes(ips []string) {
}

// GetLocalInterface 用纯 Go 标准库获取本地接口信息,不依赖 jackpal/gateway
// 和 os/exec。选取第一个 up、非 loopback、拥有 IPv4 地址的接口。Gateway 留空。
func GetLocalInterface() error {
	ifaces, err := net.Interfaces()
	if err != nil {
		return err
	}

	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}

		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}

		for _, addr := range addrs {
			ipnet, ok := addr.(*net.IPNet)
			if !ok {
				continue
			}

			ip4 := ipnet.IP.To4()
			if ip4 == nil || ip4.IsLoopback() || ip4.IsLinkLocalUnicast() {
				continue
			}

			base.LocalInterface.Name = iface.Name
			base.LocalInterface.Ip4 = ip4.String()
			base.LocalInterface.Gateway = ""
			base.LocalInterface.Mac = iface.HardwareAddr.String()

			base.Info("GetLocalInterface:", fmt.Sprintf("%+v", *base.LocalInterface))
			return nil
		}
	}

	return fmt.Errorf("no active non-loopback IPv4 interface found")
}
