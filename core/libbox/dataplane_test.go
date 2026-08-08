//go:build with_gvisor && !windows

// dataplane_test.go 是 core/libbox 的离线数据面集成测试。
//
// 目标:在没有真实 NetworkExtension 进程、没有真实 AnyConnect 服务端、没有 OS
// 文件描述符的桌面环境里,端到端验证 tvOS 引擎的数据面链路:
//
//	fake TUN inbound → sing-box 路由 → vpnOutbound(type:"vpn")→ VPNBridge → 隧道出口
//
// 打通方式(每一环都用真实组件,只在两个"物理边界"处替身):
//
//  1. TUN 打开器:通过 Libbox.SetTunOpener 注入一个基于 gVisor channel.Endpoint 的
//     fake tun.Tun(fakeGVisorTun)。sing-box 的 tun inbound 在 stack="gvisor" 时
//     只依赖 GVisorTun.NewEndpoint() 返回的 LinkEndpoint,不碰真实 fd,所以测试可以
//     直接往 endpoint 里 InjectInbound 一个构造好的原始 IP 包。
//
//  2. VPNBridge 的隧道对端:VPNBridge.Start 需要一个 *session.ConnSession 来收发
//     隧道内的裸 IP 包。这里构造一个 fake ConnSession(只有 channel + DtlsConnected
//     标志,没有真实 TLS/DTLS 连接),于是 vpnOutbound → bridge.DialTCP 打出的 TCP SYN
//     会以 proto.Payload 的形式出现在 fakeSession.PayloadOutTLS —— 那就是"离开隧道、
//     发往 VPN 服务器"的裸 IP 包,是本测试的观测点/断言点。
//
// 断言的真实性:注入的 SYN 的目的 IP 决定了 sing-box 选哪个 outbound;只有当路由
// 正确命中 type:"vpn" 且 vpnOutbound 真的把连接拨进了 VPNBridge,PayloadOutTLS 上
// 才会出现一个目的地址完全一致的 TCP SYN。任何一环断链(路由没命中 vpn、outbound
// 没接上 bridge、bridge 没把包送进隧道)都会让读取超时,测试失败。
//
// 为什么强制 stack="gvisor":system 栈把 NAT 后的包写回 tun 后,依赖 OS 内核把包
// 路由回它自己监听的本地端口——离线的内存 fake tun 没有这条内核回环,链路会断。
// gVisor 栈自带用户态 TCP/IP,SYN 一进 forwarder 就同步回调 handler,无需 OS 参与,
// 因此是唯一能在纯内存里跑通的栈。测试用 -tags with_gvisor 编译即可拿到该栈。
package libbox

import (
	"context"
	"fmt"
	"net"
	"os"
	"testing"
	"time"

	"github.com/sagernet/gvisor/pkg/buffer"
	"github.com/sagernet/gvisor/pkg/tcpip"
	"github.com/sagernet/gvisor/pkg/tcpip/checksum"
	"github.com/sagernet/gvisor/pkg/tcpip/header"
	"github.com/sagernet/gvisor/pkg/tcpip/link/channel"
	"github.com/sagernet/gvisor/pkg/tcpip/stack"
	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/option"
	singtun "github.com/sagernet/sing-tun"
	"github.com/sagernet/sing/common/json"
	"github.com/sagernet/sing/service"
	"go.uber.org/atomic"

	"github.com/kafeifei/xdial/core/config"
	"github.com/kafeifei/xdial/core/engine"
	"sslcon/proto"
	"sslcon/session"
)

// ---------------------------------------------------------------------------
// fake TUN:一个基于 gVisor channel.Endpoint 的 GVisorTun。
// ---------------------------------------------------------------------------

// fakeGVisorTun 满足 sing-tun 的 tun.Tun 与 GVisorTun 接口。
//
// sing-box 在 stack="gvisor" 下只调用 NewEndpoint()(拿 LinkEndpoint)与
// WritePacket()(仅广播/非全局单播时),不调用 io.ReadWriter 的 Read/Write,
// 所以后者只做占位。inbound 是测试往栈里灌包的入口,outbound(WritePacket)
// 收集从栈"写回 tun"方向的包(本测试用不到,留作可观测)。
type fakeGVisorTun struct {
	ep      *channel.Endpoint
	written chan []byte
}

var (
	_ singtun.Tun       = (*fakeGVisorTun)(nil)
	_ singtun.GVisorTun = (*fakeGVisorTun)(nil)
)

func newFakeGVisorTun(mtu uint32) *fakeGVisorTun {
	return &fakeGVisorTun{
		// 队列容量给足,避免测试注入时阻塞。链路地址留空即可(点对点 tun,无 ARP)。
		ep:      channel.New(512, mtu, ""),
		written: make(chan []byte, 64),
	}
}

// NewEndpoint 交给 gVisor 栈的 LinkEndpoint 就是我们持有的 channel.Endpoint。
func (t *fakeGVisorTun) NewEndpoint() (stack.LinkEndpoint, stack.NICOptions, error) {
	return t.ep, stack.NICOptions{}, nil
}

// WritePacket 是栈"写回 tun"方向(如广播、loopback)的出口;收集 payload 供观测,
// 不做真实写入。
func (t *fakeGVisorTun) WritePacket(pkt *stack.PacketBuffer) (int, error) {
	view := pkt.ToView()
	b := make([]byte, view.Size())
	copy(b, view.AsSlice())
	select {
	case t.written <- b:
	default:
	}
	return len(b), nil
}

// injectInbound 把一个原始 IP 包灌进栈,等价于"NE packetFlow 收到一个上行包"。
func (t *fakeGVisorTun) injectInbound(ipPacket []byte) {
	pkt := stack.NewPacketBuffer(stack.PacketBufferOptions{
		Payload: buffer.MakeWithData(ipPacket),
	})
	t.ep.InjectInbound(header.IPv4ProtocolNumber, pkt)
	pkt.DecRef()
}

// tun.Tun 其余方法:gVisor 栈不经由它们收发数据,占位即可。
func (t *fakeGVisorTun) Read(p []byte) (int, error)                 { return 0, nil }
func (t *fakeGVisorTun) Write(p []byte) (int, error)                { return len(p), nil }
func (t *fakeGVisorTun) Name() (string, error)                      { return "fake-tun", nil }
func (t *fakeGVisorTun) Start() error                               { return nil }
func (t *fakeGVisorTun) Close() error                               { t.ep.Close(); return nil }
func (t *fakeGVisorTun) UpdateRouteOptions(_ singtun.Options) error { return nil }

// ---------------------------------------------------------------------------
// fake ConnSession:VPNBridge 的隧道对端,只有 channel,没有真实 TLS/DTLS。
// ---------------------------------------------------------------------------

// newFakeConnSession 构造一个可被 VPNBridge.Start 驱动的最小 ConnSession。
// DtlsConnected=false ⇒ bridge.stackToVPN 把上行包写进 PayloadOutTLS。
func newFakeConnSession() *session.ConnSession {
	return &session.ConnSession{
		CloseChan:      make(chan struct{}),
		PayloadIn:      make(chan *proto.Payload, 64),
		PayloadOutTLS:  make(chan *proto.Payload, 64),
		PayloadOutDTLS: make(chan *proto.Payload, 64),
		DtlsConnected:  atomic.NewBool(false),
	}
}

// ---------------------------------------------------------------------------
// 构造一个 TCP SYN 原始 IPv4 包。
// ---------------------------------------------------------------------------

func buildTCPSyn(srcIP, dstIP tcpip.Address, srcPort, dstPort uint16) []byte {
	const totalLen = header.IPv4MinimumSize + header.TCPMinimumSize
	pkt := make([]byte, totalLen)

	ip := header.IPv4(pkt[:header.IPv4MinimumSize])
	ip.Encode(&header.IPv4Fields{
		TotalLength: totalLen,
		TTL:         64,
		Protocol:    uint8(header.TCPProtocolNumber),
		SrcAddr:     srcIP,
		DstAddr:     dstIP,
	})
	ip.SetChecksum(^ip.CalculateChecksum())

	tcp := header.TCP(pkt[header.IPv4MinimumSize:])
	tcp.Encode(&header.TCPFields{
		SrcPort:    srcPort,
		DstPort:    dstPort,
		SeqNum:     0x1000,
		DataOffset: header.TCPMinimumSize,
		Flags:      header.TCPFlagSyn,
		WindowSize: 0xffff,
	})
	xsum := header.PseudoHeaderChecksum(header.TCPProtocolNumber, srcIP, dstIP, uint16(header.TCPMinimumSize))
	tcp.SetChecksum(^tcp.CalculateChecksum(xsum))

	return pkt
}

// ---------------------------------------------------------------------------
// 生成路由到 type:"vpn" outbound 的 NE 模式 sing-box 配置。
// ---------------------------------------------------------------------------

// vpnTargetCIDR 是本测试专用的"内网目标"网段:路由规则把它绑到 vpn 出口。
const (
	vpnTargetCIDR = "10.99.0.0/16"
	vpnTargetIP   = "10.99.0.5"
	vpnTargetPort = 80
)

// buildNEConfigRoutingToVPN 用 core/config 生成 NE 模式配置(走另一并行任务新加的
// GenerateSingBoxFor(..., PlatformNE, ...) 路径),然后做两处针对本测试的改写:
//
//	(a) 把 tag="vpn" 的 outbound 从生成器默认的 type:"socks"(macOS 版本地 SOCKS5
//	    中转语义)改成 type:"vpn" —— 即 registry.go 里注册的进程内 vpnOutbound。
//	    生成器当前对所有平台都把 vpn 出口写成 socks 中转;NE 模式下真正要接的是
//	    vpn_outbound.go 的自定义出口,这一步就是把配置对齐到被测代码路径。
//	(b) 给 tun inbound 补上 stack:"gvisor",强制走用户态栈(理由见文件头)。
//
// 返回改写后的完整 JSON。basePath 传测试临时目录,让 NE 模式的 cache_file 可写。
func buildNEConfigRoutingToVPN(t *testing.T, basePath string) []byte {
	t.Helper()

	profile := &config.Profile{
		Lines: []config.Line{
			{ID: "direct", Name: "直连", Type: config.LineTypeDirect, Enabled: true},
			{ID: "vpn", Name: "VPN", Type: config.LineTypeVPN, Enabled: true,
				VPNServer: "vpn.example.com:443", VPNUsername: "u", VPNPassword: "p"},
		},
		RuleSets: []config.RuleSet{
			{ID: "intranet", Name: "内网", Type: config.RuleSetTypeManual, Enabled: true,
				CIDRs: []string{vpnTargetCIDR}},
		},
		Scenarios: []config.Scenario{
			{
				ID: "c1", Name: "默认",
				Bindings:      []config.RuleBinding{{RuleSetID: "intranet", LineID: "vpn"}},
				DefaultLineID: "direct",
			},
		},
		ActiveScenarioID: "c1",
	}

	raw, err := config.GenerateSingBoxFor(profile, 10800, "1.2.3.4", config.PlatformNE, basePath)
	if err != nil {
		t.Fatalf("GenerateSingBoxFor(NE) failed: %v", err)
	}

	var cfg map[string]any
	if err := json.Unmarshal(raw, &cfg); err != nil {
		t.Fatalf("unmarshal generated config: %v", err)
	}

	// (a) 把 vpn outbound 改成自定义 type:"vpn"。
	rewroteVPN := false
	if obs, ok := cfg["outbounds"].([]any); ok {
		for _, o := range obs {
			ob, _ := o.(map[string]any)
			if ob == nil {
				continue
			}
			if ob["tag"] == "vpn" {
				// 清掉 socks 特有字段,换成 vpn(StubOptions:无额外字段)。
				delete(ob, "server")
				delete(ob, "server_port")
				ob["type"] = "vpn"
				rewroteVPN = true
			}
		}
	}
	if !rewroteVPN {
		t.Fatal("generated config has no outbound tagged \"vpn\" to rewrite")
	}

	// (b) tun inbound 补 stack:"gvisor"。
	patchedTun := false
	if ins, ok := cfg["inbounds"].([]any); ok {
		for _, i := range ins {
			in, _ := i.(map[string]any)
			if in != nil && in["type"] == "tun" {
				in["stack"] = "gvisor"
				patchedTun = true
			}
		}
	}
	if !patchedTun {
		t.Fatal("generated config has no tun inbound to patch")
	}

	// (c) 去掉 {"action":"sniff"} 规则。
	//
	// sniff 会在路由前先从入站连接读取首包(嗅探协议)。本离线 harness 往 fake tun
	// 注入的是一个"裸 SYN":没有客户端后续 ACK,gVisor 的被动握手(gLazyConn 的
	// CreateEndpoint)永远停在 SYN-RCVD,于是 sniff 的 Read 会一直阻塞、路由永远
	// 不往下走。这纯粹是"入站 TCP 握手没走完"的产物,与被测的
	// "路由 → vpnOutbound → VPNBridge" 出站路径正交:出站拨号发生在路由选定 outbound
	// 之后、任何入站读之前(见 route.ConnectionManager.NewConnection 先 dial 后 copy),
	// 所以去掉 sniff 不影响本测试要验证的链路,只是让路由不被入站握手卡住。
	// 生成器在真机 NE 配置里保留 sniff 是对的(真实客户端会发首包),这里仅测试内改写。
	if route, ok := cfg["route"].(map[string]any); ok {
		if rules, ok := route["rules"].([]any); ok {
			kept := rules[:0]
			for _, r := range rules {
				rm, _ := r.(map[string]any)
				if rm != nil && rm["action"] == "sniff" {
					continue
				}
				kept = append(kept, r)
			}
			route["rules"] = kept
		}
	}

	// 调试:把 log level 提到 trace,便于观察路由决策(仅在 XDIAL_DP_TRACE 时)。
	if dbgTrace() {
		if lg, ok := cfg["log"].(map[string]any); ok {
			lg["level"] = "trace"
		}
	}

	out, err := json.Marshal(cfg)
	if err != nil {
		t.Fatalf("re-marshal config: %v", err)
	}
	if dbgTrace() {
		t.Logf("generated NE config:\n%s", string(out))
	}
	return out
}

func dbgTrace() bool { return os.Getenv("XDIAL_DP_TRACE") != "" }

// ---------------------------------------------------------------------------
// 直接在包内构造 box:复刻 Libbox.Start 的注入逻辑,但跳过真实 AnyConnect 拨号。
// ---------------------------------------------------------------------------

// startBoxOffline 用 fake platform + fake bridge 起一个进程内 sing-box。
// 返回 box、fakeTun、注入用的 fake session,以及一个清理函数。
func startBoxOffline(t *testing.T, configJSON []byte, bridge *engine.VPNBridge) (*box.Box, *fakeGVisorTun, func()) {
	t.Helper()

	fakeTun := newFakeGVisorTun(9000)

	platform := &xdPlatformInterface{
		opener: func(options *singtun.Options, _ option.TunPlatformOptions) (singtun.Tun, error) {
			// options 里带着 sing-box 依据配置算出的 tun 参数;这里不需要用,
			// 直接返回持有 gVisor endpoint 的 fake。
			return fakeTun, nil
		},
	}
	// 生产环境由 Swift NWPathMonitor 在 Start 前注入真实 Wi-Fi/蜂窝接口。
	// 离线测试没有 Swift 层，选宿主机任一已知接口作为等价启动前置条件。
	interfaces, err := net.Interfaces()
	if err != nil || len(interfaces) == 0 {
		t.Fatalf("discover test interface: %v", err)
	}
	platform.setDefaultInterface(interfaces[0].Name, interfaces[0].Index)

	ctx := boxContext(context.Background())
	ctx = service.ContextWith[*anyConnectLineRuntime](
		ctx,
		newAnyConnectLineRuntime(bridge, nil),
	)
	ctx = service.ContextWith[adapter.PlatformInterface](ctx, adapter.PlatformInterface(platform))

	opts, err := json.UnmarshalExtendedContext[option.Options](ctx, configJSON)
	if err != nil {
		t.Fatalf("parse sing-box config: %v", err)
	}

	instance, err := box.New(box.Options{Options: opts, Context: ctx})
	if err != nil {
		t.Fatalf("construct sing-box: %v", err)
	}
	if err := instance.Start(); err != nil {
		instance.Close()
		t.Fatalf("start sing-box: %v", err)
	}

	cleanup := func() {
		instance.Close()
	}
	return instance, fakeTun, cleanup
}

// ---------------------------------------------------------------------------
// 测试:TCP 数据面。
// ---------------------------------------------------------------------------

// TestDataplaneTCP_RoutesToVPNBridge 验证:一个目的落在 vpn 网段的 TCP SYN,
// 从 fake tun 注入后,经 sing-box 路由命中 vpn 出口、由 vpnOutbound 拨进 VPNBridge,
// 最终以一个目的地址一致的 TCP SYN 出现在隧道出口(fake session 的 PayloadOutTLS)。
func TestDataplaneTCP_RoutesToVPNBridge(t *testing.T) {
	basePath := t.TempDir()

	// VPNBridge 用一个测试网关地址;MTU 取常见值。fake session 充当隧道对端。
	bridge, err := engine.NewVPNBridge("10.0.0.2", 1400)
	if err != nil {
		t.Fatalf("NewVPNBridge: %v", err)
	}
	fakeSess := newFakeConnSession()
	bridge.Start(fakeSess)
	defer func() {
		close(fakeSess.CloseChan) // 让 bridge 的 vpnToStack goroutine 退出
		bridge.Close()
	}()

	cfg := buildNEConfigRoutingToVPN(t, basePath)

	_, fakeTun, cleanup := startBoxOffline(t, cfg, bridge)
	defer cleanup()

	// 注入一个 TCP SYN:198.18.0.2:12345 → 10.99.0.5:80(目的落在 vpn 网段)。
	syn := buildTCPSyn(
		tcpip.AddrFromSlice([]byte{198, 18, 0, 2}),
		tcpip.AddrFromSlice([]byte{10, 99, 0, 5}),
		12345, vpnTargetPort,
	)
	// 前置健全性检查:box 起来后 tun inbound 应已调用 fake tun 的 NewEndpoint 并把
	// gVisor 栈 attach 上去;否则 InjectInbound 会被静默丢弃,后面注定超时。
	if !fakeTun.ep.IsAttached() {
		t.Fatal("tun stack did not attach fake endpoint after box start")
	}
	fakeTun.injectInbound(syn)

	// 在隧道出口等一个目的为 10.99.0.5:80 的 TCP SYN。
	waitForTunnelTCPSyn(t, fakeSess, vpnTargetIP, vpnTargetPort, 5*time.Second)
}

// waitForTunnelTCPSyn 从 fake session 的 PayloadOutTLS 读取隧道上行包,
// 直到出现一个目的 IP:Port 与期望一致的 TCP SYN,或超时失败。
//
// 这是全链路的真实断言点:如果路由没命中 vpn、outbound 没接上 bridge、或 bridge
// 没把包送进隧道,这里永远读不到匹配包,测试超时失败。
func waitForTunnelTCPSyn(t *testing.T, sess *session.ConnSession, wantIP string, wantPort uint16, timeout time.Duration) {
	t.Helper()
	deadline := time.After(timeout)
	seen := 0
	for {
		select {
		case pl := <-sess.PayloadOutTLS:
			// 只关心 DATA(0x00);跳过 DPD/keepalive 等控制包。
			if pl == nil || pl.Type != 0x00 || len(pl.Data) < header.IPv4MinimumSize {
				continue
			}
			seen++
			ip := header.IPv4(pl.Data)
			if ip.Protocol() != uint8(header.TCPProtocolNumber) {
				continue
			}
			if ip.DestinationAddress() != tcpip.AddrFromSlice(parseIP4(t, wantIP)) {
				continue
			}
			tcp := header.TCP(ip.Payload())
			if tcp.DestinationPort() != wantPort {
				continue
			}
			if tcp.Flags()&header.TCPFlagSyn == 0 {
				continue
			}
			// 命中:一个目的完全一致的 TCP SYN 真的离开了隧道。
			t.Logf("observed tunnel TCP SYN to %s:%d after %d tunnel packet(s)", wantIP, wantPort, seen)
			return
		case <-deadline:
			t.Fatalf("timed out waiting for TCP SYN to %s:%d on tunnel egress (saw %d data packet(s)); "+
				"data plane did not route to vpn outbound / reach VPNBridge", wantIP, wantPort, seen)
		}
	}
}

// ---------------------------------------------------------------------------
// 测试:UDP/DNS 数据面(附加用例,验证 vpnOutbound.ListenPacket → VPNBridge)。
// ---------------------------------------------------------------------------

// TestDataplaneUDP_RoutesToVPNBridge 验证 UDP 路径:一个目的落在 vpn 网段的 UDP
// 包(53 端口,DNS 语义)注入后,经 sing-box 的 UDP 转发 → vpnOutbound.ListenPacket
// → VPNBridge.DialUDP,应在隧道出口看到一个目的一致的 UDP 包。
//
// 这条路径依赖并行任务在 vpn_outbound.go 里实现的 ListenPacket + vpnPacketConn。
func TestDataplaneUDP_RoutesToVPNBridge(t *testing.T) {
	basePath := t.TempDir()

	bridge, err := engine.NewVPNBridge("10.0.0.2", 1400)
	if err != nil {
		t.Fatalf("NewVPNBridge: %v", err)
	}
	fakeSess := newFakeConnSession()
	bridge.Start(fakeSess)
	defer func() {
		close(fakeSess.CloseChan)
		bridge.Close()
	}()

	cfg := buildNEConfigRoutingToVPN(t, basePath)
	_, fakeTun, cleanup := startBoxOffline(t, cfg, bridge)
	defer cleanup()

	if !fakeTun.ep.IsAttached() {
		t.Fatal("tun stack did not attach fake endpoint after box start")
	}

	// 注入一个 UDP 包:198.18.0.2:40000 → 10.99.0.53:53,payload 是一个最小 DNS 查询。
	udp := buildUDPPacket(
		tcpip.AddrFromSlice([]byte{198, 18, 0, 2}),
		tcpip.AddrFromSlice([]byte{10, 99, 0, 53}),
		40000, 53, minimalDNSQuery(),
	)
	fakeTun.injectInbound(udp)

	waitForTunnelUDP(t, fakeSess, "10.99.0.53", 53, 5*time.Second)
}

func buildUDPPacket(srcIP, dstIP tcpip.Address, srcPort, dstPort uint16, payload []byte) []byte {
	totalLen := header.IPv4MinimumSize + header.UDPMinimumSize + len(payload)
	pkt := make([]byte, totalLen)

	ip := header.IPv4(pkt[:header.IPv4MinimumSize])
	ip.Encode(&header.IPv4Fields{
		TotalLength: uint16(totalLen),
		TTL:         64,
		Protocol:    uint8(header.UDPProtocolNumber),
		SrcAddr:     srcIP,
		DstAddr:     dstIP,
	})
	ip.SetChecksum(^ip.CalculateChecksum())

	udp := header.UDP(pkt[header.IPv4MinimumSize:])
	udp.Encode(&header.UDPFields{
		SrcPort: srcPort,
		DstPort: dstPort,
		Length:  uint16(header.UDPMinimumSize + len(payload)),
	})
	copy(pkt[header.IPv4MinimumSize+header.UDPMinimumSize:], payload)
	xsum := header.PseudoHeaderChecksum(header.UDPProtocolNumber, srcIP, dstIP, uint16(header.UDPMinimumSize+len(payload)))
	xsum = checksum.Checksum(payload, xsum)
	udp.SetChecksum(^udp.CalculateChecksum(xsum))

	return pkt
}

// minimalDNSQuery 返回一个 12 字节 DNS header + 一个问题的极简 A 查询(example.com)。
// 内容不需要被解析——只要是合法 UDP payload 让栈能转发即可。
func minimalDNSQuery() []byte {
	return []byte{
		0x00, 0x01, // ID
		0x01, 0x00, // flags: RD
		0x00, 0x01, // QDCOUNT=1
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x07, 'e', 'x', 'a', 'm', 'p', 'l', 'e',
		0x03, 'c', 'o', 'm',
		0x00,       // root
		0x00, 0x01, // QTYPE=A
		0x00, 0x01, // QCLASS=IN
	}
}

func waitForTunnelUDP(t *testing.T, sess *session.ConnSession, wantIP string, wantPort uint16, timeout time.Duration) {
	t.Helper()
	deadline := time.After(timeout)
	seen := 0
	for {
		select {
		case pl := <-sess.PayloadOutTLS:
			if pl == nil || pl.Type != 0x00 || len(pl.Data) < header.IPv4MinimumSize {
				continue
			}
			seen++
			ip := header.IPv4(pl.Data)
			if ip.Protocol() != uint8(header.UDPProtocolNumber) {
				continue
			}
			if ip.DestinationAddress() != tcpip.AddrFromSlice(parseIP4(t, wantIP)) {
				continue
			}
			udp := header.UDP(ip.Payload())
			if udp.DestinationPort() != wantPort {
				continue
			}
			t.Logf("observed tunnel UDP to %s:%d after %d tunnel packet(s)", wantIP, wantPort, seen)
			return
		case <-deadline:
			t.Fatalf("timed out waiting for UDP to %s:%d on tunnel egress (saw %d data packet(s)); "+
				"UDP data plane did not route to vpn outbound / reach VPNBridge", wantIP, wantPort, seen)
		}
	}
}

// parseIP4 把点分十进制解析成 4 字节 slice。
func parseIP4(t *testing.T, s string) []byte {
	t.Helper()
	var a, b, c, d int
	if _, err := fmt.Sscanf(s, "%d.%d.%d.%d", &a, &b, &c, &d); err != nil {
		t.Fatalf("parse ip %q: %v", s, err)
	}
	return []byte{byte(a), byte(b), byte(c), byte(d)}
}
