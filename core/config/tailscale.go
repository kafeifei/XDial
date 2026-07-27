package config

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// tailscaleHostnamePrefix 让 XDial 注册的节点在 tailnet 设备列表里一眼可辨。
// 不加前缀的话，本机若同时装了官方 Tailscale 客户端，两台设备会用同一个机器名，
// 在后台分不清谁是谁，删的时候容易删错。
const tailscaleHostnamePrefix = "xdial-"

// tailscaleHostnameBaseMax 限制机器名部分的长度。DNS label 上限 63 字节，
// 前缀 6 + 随机后缀 5 已占 11，这里留足余量。
const tailscaleHostnameBaseMax = 40

// TailscaleStateDirectory 返回 tailnet 身份的 state 目录。
//
// 全局单份：所有 Tailscale 线路共享同一次登录。早期版本按 lineID 哈希分目录，
// 结果是每条线路各自注册一台设备、各自要登录一次，退出登录也无法一次清干净。
func TailscaleStateDirectory(basePath string) string {
	return filepath.Join(basePath, "tailscale")
}

// GenerateTailscaleHostname 基于本机名生成一个唯一的 tailnet 设备名，
// 形如 xdial-kafeifei-macbook-pro-7f3a。
//
// 随机后缀防重名：换机器、清掉 state 重新登录都会生成新节点，没有后缀就会撞上
// 旧节点，控制面会自动加 -1 -2，越堆越乱。
//
// 生成结果由调用方持久化到 Profile.Tailscale.Hostname，之后固定不变 —— 不能每次
// 启动重算，否则用户改了机器名就会变成一台新设备重新注册。
func GenerateTailscaleHostname() string {
	base := sanitizeDNSLabel(hostnameBase())
	if base == "" {
		base = "mac"
	}
	return tailscaleHostnamePrefix + base + "-" + randomHexSuffix()
}

func hostnameBase() string {
	name, err := os.Hostname()
	if err != nil {
		return ""
	}
	// macOS 的 os.Hostname() 常带 .local 之类的后缀，对设备名没有意义。
	if index := strings.IndexByte(name, '.'); index > 0 {
		name = name[:index]
	}
	return name
}

// sanitizeDNSLabel 把任意机器名压成合法 DNS label：小写、只留 [a-z0-9-]、
// 不出现连续或首尾的连字符。中文机器名会被整段替换掉，结果可能为空，由调用方兜底。
func sanitizeDNSLabel(name string) string {
	var b strings.Builder
	lastDash := true // 置 true 以吃掉开头的连字符
	for _, r := range strings.ToLower(name) {
		if b.Len() >= tailscaleHostnameBaseMax {
			break
		}
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
			lastDash = false
			continue
		}
		if !lastDash {
			b.WriteByte('-')
			lastDash = true
		}
	}
	return strings.Trim(b.String(), "-")
}

func randomHexSuffix() string {
	var buf [2]byte
	if _, err := rand.Read(buf[:]); err != nil {
		// crypto/rand 失败时退回固定后缀总比生成空名字强；
		// 撞名由控制面自动加 -1 兜底，不影响可用性。
		return "0000"
	}
	return hex.EncodeToString(buf[:])
}

// buildTailscaleEndpoint 生成 sing-box 的 tailscale endpoint。
//
// 刻意不设的字段：
//   - accept_routes：XDial 里 Tailscale 只是一条出口线路，只有模式显式绑定的流量
//     才走它。接受 peer 广播的子网路由会把一堆用户没要求的网段拉进来，
//     还可能和本地网段撞上（例如公司和家里都是 192.168.1.0/24）。
//   - advertise_routes / advertise_exit_node：XDial 是工具，不提供网络出口。
//     一旦能 advertise 就变成在分发线路了，性质完全不同。
//     （sing-box 本身也禁止同时 advertise 和使用 exit node。）
func buildTailscaleEndpoint(line *Line, identity TailscaleIdentity, basePath string) (map[string]interface{}, error) {
	if line == nil || line.Type != LineTypeTailscale {
		return nil, fmt.Errorf("line is not a Tailscale line")
	}
	if line.ID == "" {
		return nil, fmt.Errorf("Tailscale line ID is empty")
	}

	endpoint := map[string]interface{}{
		"type":            "tailscale",
		"tag":             tailscaleEndpointTag(line),
		"state_directory": TailscaleStateDirectory(basePath),
		// 常驻节点。不能 ephemeral：登录会话关闭后控制面会立刻回收 node key，
		// 连接时复用 state 会被要求重新登录。设备不堆积由全局唯一 state +
		// 固定 hostname 保证；退出登录走 Logout 显式删除设备记录。
	}
	if identity.Hostname != "" {
		endpoint["hostname"] = identity.Hostname
	}
	if line.TailscaleExitNode != "" {
		endpoint["exit_node"] = line.TailscaleExitNode
	}
	return endpoint, nil
}
