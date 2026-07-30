//go:build darwin

package engine

import (
	"context"
	"fmt"
	"net"
	"os/exec"
	"time"
)

const defaultRouteProbeTimeout = 2 * time.Second

// detectUnderlayInterface 读取数据面启动前操作系统已经选定的 IPv4 默认接口。
//
// 不能使用 sing-tun 的 darwin auto_detect_interface 代替：它要求默认路由带
// RTF_GATEWAY，会跳过 Tailscale 等无网关 utun，再错误绑定到物理接口。
// 这里不识别产品，也不判断物理/虚拟类型，只转交 route(8) 的既有裁决。
func detectUnderlayInterface(parent context.Context) (string, error) {
	name, _, err := detectUnderlayRoute(parent)
	return name, err
}

// detectDataPlaneUnderlayInterface 在任何数据面副作用之前拒绝 D34 已证伪的入口组合。
// 配置会话仍调用 detectUnderlayInterface：它们没有 TUN、DNS 或系统路由副作用，不受
// 这个入口能力边界约束。
func detectDataPlaneUnderlayInterface(parent context.Context) (string, error) {
	name, global, err := detectUnderlayRoute(parent)
	if err != nil {
		return "", err
	}
	if global {
		return "", fmt.Errorf("当前系统网络使用全局 VPN 路由，XDial 原生 TUN 暂时无法可靠叠加；已在接管流量前取消连接")
	}
	return name, nil
}

func detectUnderlayRoute(parent context.Context) (string, bool, error) {
	ctx, cancel := context.WithTimeout(parent, defaultRouteProbeTimeout)
	defer cancel()

	output, err := exec.CommandContext(ctx, "/sbin/route", "-n", "get", "default").CombinedOutput()
	if err != nil {
		if ctx.Err() != nil {
			return "", false, fmt.Errorf("读取系统默认接口超时: %w", ctx.Err())
		}
		return "", false, fmt.Errorf("读取系统默认接口失败: %w", err)
	}
	name, err := parseDefaultRouteInterface(string(output))
	if err != nil {
		return "", false, err
	}
	global, err := parseDefaultRouteIsGlobal(string(output))
	if err != nil {
		return "", false, err
	}
	iface, err := net.InterfaceByName(name)
	if err != nil {
		return "", false, fmt.Errorf("系统默认接口 %q 已消失: %w", name, err)
	}
	if iface.Flags&net.FlagUp == 0 {
		return "", false, fmt.Errorf("系统默认接口 %q 未启用", name)
	}
	if iface.Flags&net.FlagLoopback != 0 {
		return "", false, fmt.Errorf("系统默认接口不能是回环接口 %q", name)
	}
	return name, global, nil
}
