//go:build !windows

// Command libboxtest 是 core/libbox 的手测工具(非 tvOS,跑在桌面 macOS 上)。
//
// 验证目标:不需要 NE/真机/Apple 账号,先把"sslcon 拨号 + gVisor 网桥 +
// 进程内 sing-box 分流"这条 Phase 0/2 最核心的链路在桌面上跑通。
// 用一个本地 socks 入站口(只在手测时出现,真机 NE 配置不会有这个 inbound),
// 验证内网域名走 vpn、其它域名走 direct。
//
// 凭据只通过环境变量传入,不落盘、不进源码:
//
//	ANYCONNECT_SERVER=vpn.example.com ANYCONNECT_USERNAME=xxx ANYCONNECT_PASSWORD=xxx \
//	  go run ./cmd/libboxtest -internal internal.example.com -external example.com
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"time"

	"golang.org/x/net/proxy"

	"github.com/kafeifei/xdial/core/libbox"
)

type cb struct{}

func (cb) OnStatusChanged(statusJSON string) { log.Printf("[status] %s", statusJSON) }
func (cb) OnError(code int, message string)  { log.Printf("[error %d] %s", code, message) }

func main() {
	internal := flag.String("internal", "internal.example.com", "应该走 vpn 的内网域名")
	external := flag.String("external", "example.com", "应该走 direct 的外网域名")
	flag.Parse()

	server := os.Getenv("ANYCONNECT_SERVER")
	username := os.Getenv("ANYCONNECT_USERNAME")
	password := os.Getenv("ANYCONNECT_PASSWORD")
	if server == "" || username == "" || password == "" {
		log.Fatal("需要设置 ANYCONNECT_SERVER / ANYCONNECT_USERNAME / ANYCONNECT_PASSWORD 环境变量")
	}

	const socksPort = 18964
	configJSON, err := buildConfig(socksPort, *internal)
	if err != nil {
		log.Fatalf("build config: %v", err)
	}

	lb := libbox.New(cb{})
	log.Printf("连接 %s ...", server)
	if err := lb.Start(server, username, password, configJSON); err != nil {
		log.Fatalf("start failed: %v", err)
	}
	defer func() {
		log.Println("断开...")
		_ = lb.Stop()
	}()

	log.Println("连接成功,等待路由生效...")
	time.Sleep(2 * time.Second)

	dialer, err := proxy.SOCKS5("tcp", fmt.Sprintf("127.0.0.1:%d", socksPort), nil, proxy.Direct)
	if err != nil {
		log.Fatalf("socks dialer: %v", err)
	}
	client := &http.Client{
		Transport: &http.Transport{
			DialContext: func(_ context.Context, network, addr string) (net.Conn, error) {
				return dialer.Dial(network, addr)
			},
		},
		Timeout: 10 * time.Second,
	}

	fmt.Println()
	fmt.Println("=== 分流测试 ===")
	testDomain(client, *internal, "内网(预期经 VPN 可达)")
	testDomain(client, *external, "外网(预期直连)")
}

func testDomain(client *http.Client, host, label string) {
	u := &url.URL{Scheme: "http", Host: host, Path: "/"}
	resp, err := client.Get(u.String())
	if err != nil {
		fmt.Printf("[%s] %-28s FAIL: %v\n", label, host, err)
		return
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 256))
	fmt.Printf("[%s] %-28s OK status=%d body=%dB\n", label, host, resp.StatusCode, len(body))
}

func buildConfig(socksPort int, internalDomain string) (string, error) {
	cfg := map[string]any{
		"log": map[string]any{"level": "info"},
		"inbounds": []map[string]any{
			{
				"type":        "socks",
				"tag":         "socks-in",
				"listen":      "127.0.0.1",
				"listen_port": socksPort,
			},
		},
		"outbounds": []map[string]any{
			{"type": "vpn", "tag": "vpn"},
			{"type": "direct", "tag": "direct"},
		},
		"route": map[string]any{
			"rules": []map[string]any{
				{"domain": []string{internalDomain}, "outbound": "vpn"},
			},
			"final": "direct",
		},
	}
	b, err := json.Marshal(cfg)
	return string(b), err
}
