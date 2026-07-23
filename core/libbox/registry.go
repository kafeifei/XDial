//go:build !windows

package libbox

import (
	"context"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/adapter/endpoint"
	"github.com/sagernet/sing-box/adapter/inbound"
	"github.com/sagernet/sing-box/adapter/outbound"
	boxservice "github.com/sagernet/sing-box/adapter/service"
	"github.com/sagernet/sing-box/dns"
	"github.com/sagernet/sing-box/dns/transport"
	"github.com/sagernet/sing-box/dns/transport/hosts"
	"github.com/sagernet/sing-box/dns/transport/local"
	"github.com/sagernet/sing-box/protocol/direct"
	"github.com/sagernet/sing-box/protocol/group"
	"github.com/sagernet/sing-box/protocol/shadowsocks"
	"github.com/sagernet/sing-box/protocol/socks"
	"github.com/sagernet/sing-box/protocol/trojan"
	"github.com/sagernet/sing-box/protocol/tun"
	"github.com/sagernet/sing-box/protocol/vmess"
)

// boxContext 构造一个只注册 XDial 实际用到的协议的精简 sing-box 上下文。
//
// 不用 sing-box 官方的 include 包(它会拉入 tor/ssh/naive/QUIC 等用不到的协议),
// 是因为 tvOS NetworkExtension 进程内存预算极紧(iOS 17 起仅 15MB 量级),
// 多余的协议注册会直接挤占内存预算。
func boxContext(ctx context.Context) context.Context {
	endpointRegistry := endpoint.NewRegistry()
	registerTailscaleEndpoint(endpointRegistry)
	return box.Context(ctx, inboundRegistry(), outboundRegistry(), endpointRegistry, dnsTransportRegistry(), boxservice.NewRegistry())
}

func inboundRegistry() *inbound.Registry {
	registry := inbound.NewRegistry()
	tun.RegisterInbound(registry)
	// socks inbound 是本地手测/调试用(经 SOCKS5 验证分流路由),
	// 真机 NE 模式下不会出现在生成的配置里,体积负担可忽略。
	socks.RegisterInbound(registry)
	return registry
}

func outboundRegistry() *outbound.Registry {
	registry := outbound.NewRegistry()

	direct.RegisterOutbound(registry)
	group.RegisterSelector(registry)
	group.RegisterURLTest(registry)
	trojan.RegisterOutbound(registry)
	shadowsocks.RegisterOutbound(registry)
	vmess.RegisterOutbound(registry)
	registerVPNOutbound(registry)

	return registry
}

func dnsTransportRegistry() *dns.TransportRegistry {
	registry := dns.NewTransportRegistry()
	transport.RegisterUDP(registry)
	transport.RegisterTLS(registry)
	transport.RegisterHTTPS(registry)
	hosts.RegisterTransport(registry)
	local.RegisterTransport(registry)
	registerTailscaleDNSTransport(registry)
	registerMobileDNSTransport(registry)
	return registry
}
