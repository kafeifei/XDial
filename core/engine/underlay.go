package engine

import (
	"bufio"
	"fmt"
	"strings"
)

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
