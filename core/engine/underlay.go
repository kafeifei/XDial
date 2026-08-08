package engine

import (
	"bufio"
	"context"
	"fmt"
	"strings"
)

// DetectUnderlayInterface exposes the same product-agnostic default-route snapshot used
// by the desktop data plane to bounded setup runtimes. Callers must forward the result
// unchanged; product detection and interface reordering remain forbidden by D-UNDERLAY.
func DetectUnderlayInterface(ctx context.Context) (string, error) {
	return detectUnderlayInterface(ctx)
}

// parseDefaultRouteInterface 只解析 route(8) 已经裁决出的 interface 字段。它不按
// 接口名称、类型或产品做推断；调用方再用 net.InterfaceByName 验证该快照仍存在。
func parseDefaultRouteInterface(output string) (string, error) {
	scanner := bufio.NewScanner(strings.NewReader(output))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		value, found := strings.CutPrefix(line, "interface:")
		if !found {
			continue
		}
		name := strings.TrimSpace(value)
		if name == "" || strings.ContainsAny(name, " \t\r\n") {
			return "", fmt.Errorf("invalid default route interface %q", name)
		}
		return name, nil
	}
	if err := scanner.Err(); err != nil {
		return "", fmt.Errorf("read default route: %w", err)
	}
	return "", fmt.Errorf("default route has no interface")
}

// parseDefaultRouteIsGlobal 只读取 route(8) 已经给出的内核路由标志。GLOBAL 是 macOS
// Network Extension 的系统级作用域，不代表任何具体产品；D34 已实机证明普通 TUN
// 无法在它外层形成密封入口。
func parseDefaultRouteIsGlobal(output string) (bool, error) {
	scanner := bufio.NewScanner(strings.NewReader(output))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		value, found := strings.CutPrefix(line, "flags:")
		if !found {
			continue
		}
		flags := strings.TrimSpace(value)
		if len(flags) < 2 || flags[0] != '<' || flags[len(flags)-1] != '>' {
			return false, fmt.Errorf("invalid default route flags %q", flags)
		}
		for _, flag := range strings.Split(flags[1:len(flags)-1], ",") {
			if strings.EqualFold(strings.TrimSpace(flag), "GLOBAL") {
				return true, nil
			}
		}
		return false, nil
	}
	if err := scanner.Err(); err != nil {
		return false, fmt.Errorf("read default route: %w", err)
	}
	return false, fmt.Errorf("default route has no flags")
}
