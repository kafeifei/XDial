//go:build !windows

package libbox

import (
	"context"
	"net"
	"net/netip"
	"strconv"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/adapter/outbound"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	E "github.com/sagernet/sing/common/exceptions"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/sing/service"
	"golang.org/x/net/dns/dnsmessage"
)

const typeVPN = "vpn"

// dnsQueryTimeout 是单个隧道 DNS 服务器一次 A 查询的超时。
// 取值偏小是为了在隧道 DNS 不通时快速失败，避免查询旁路到物理网络。
const dnsQueryTimeout = 3 * time.Second

// vpnOutbound 是替代 macOS 版"本地 SOCKS5 中转"的进程内出口:
// sing-box 路由命中 "vpn" 时直接经 engine.VPNBridge(sslcon + gVisor)拨号,
// 不再经过一次额外的本地 socks 跳转,省一层内存/延迟开销。
//
// TCP 与 UDP 均经隧道出口;FQDN 域名优先经隧道内 DNS 解析(AnyConnect 握手
// 下发的 X-CSTP-DNS)。解析失败必须 fail closed，不能回退系统 DNS 泄露
// 内部域名，或把公共 DNS 的 NXDOMAIN 当作企业域名不存在。
type vpnOutbound struct {
	outbound.Adapter
	line *anyConnectLineRuntime
}

var (
	_ adapter.Outbound = (*vpnOutbound)(nil)
	_ N.Dialer         = (*vpnOutbound)(nil)
)

func registerVPNOutbound(registry *outbound.Registry) {
	outbound.Register[option.StubOptions](registry, typeVPN, newVPNOutbound)
}

func newVPNOutbound(ctx context.Context, _ adapter.Router, _ log.ContextLogger, tag string, _ option.StubOptions) (adapter.Outbound, error) {
	line := service.FromContext[*anyConnectLineRuntime](ctx)
	if line == nil {
		return nil, E.New("AnyConnect outbound: no active tunnel bridge in context (engine must connect before starting sing-box)")
	}
	return &vpnOutbound{
		Adapter: outbound.NewAdapter(typeVPN, tag, []string{N.NetworkTCP, N.NetworkUDP}, nil),
		line:    line,
	}, nil
}

func (o *vpnOutbound) DialContext(ctx context.Context, network string, destination M.Socksaddr) (net.Conn, error) {
	if N.NetworkName(network) != N.NetworkTCP {
		return nil, E.New("AnyConnect outbound: ", network, " not supported for DialContext")
	}

	addr := destination.Addr
	if destination.IsFqdn() {
		resolved, err := o.resolve(ctx, destination.Fqdn)
		if err != nil {
			return nil, err
		}
		addr = resolved
	}
	if !addr.Is4() {
		if !addr.Is4In6() {
			// 抓到 IPv6 后必须在受控出口明确失败，不能让 bridge.As4 panic，
			// 更不能绕过 packetFlow 改走物理网络。
			return nil, E.New("AnyConnect outbound: IPv6 TCP destination not supported: ", destination)
		}
		addr = netip.AddrFrom4(addr.As4())
	}

	return o.line.DialTCP(ctx, net.JoinHostPort(addr.String(), strconv.Itoa(int(destination.Port))))
}

func (o *vpnOutbound) ListenPacket(ctx context.Context, destination M.Socksaddr) (net.PacketConn, error) {
	addr := destination.Addr
	if destination.IsFqdn() {
		resolved, err := o.resolve(ctx, destination.Fqdn)
		if err != nil {
			return nil, err
		}
		addr = resolved
	}
	if !addr.Is4() {
		if !addr.Is4In6() {
			// VPNBridge 是 IPv4-only 的 gVisor 栈,纯 IPv6 目标无法经隧道送达。
			return nil, E.New("AnyConnect outbound: IPv6 UDP destination not supported: ", destination)
		}
		// 4-in-6 形式归一化到 4 字节。
		addr = netip.AddrFrom4(addr.As4())
	}

	raddr := &net.UDPAddr{IP: net.IP(addr.AsSlice()), Port: int(destination.Port)}
	// 连接到解析后的目标:读方向只会收到该 peer 的包(源地址天然正确),
	// 写方向即便 sing-box 传来的是 FQDN(空 IP)的 UDPAddr,也由 vpnPacketConn
	// 重定向到 raddr。ListenPacket 语义是"每个目标一条流",连接式最贴合。
	conn, err := o.line.DialUDP(nil, raddr)
	if err != nil {
		return nil, E.Cause(err, "AnyConnect outbound: listen packet to ", destination)
	}
	return &vpnPacketConn{Conn: conn, remote: raddr}, nil
}

// vpnPacketConn 把隧道内的连接式 UDP conn 适配成 sing-box 期望的 net.PacketConn。
//
// 底层 gonet UDPConn 已实现 ReadFrom/WriteTo/Close/LocalAddr/Deadline(满足
// net.PacketConn),这里唯一要纠正的是写方向:sing-box 上层(bufio.ExtendedPacketConn)
// 会用 destination.UDPAddr() 调 WriteTo,当 destination 是 FQDN 时该 UDPAddr 的 IP 为空,
// 直接写会被 gVisor 拒绝。因为本 conn 是"每目标一条流"且已连接到解析后的 remote,
// 所有写都重定向到 remote 即可。
type vpnPacketConn struct {
	net.Conn
	remote *net.UDPAddr
}

var _ net.PacketConn = (*vpnPacketConn)(nil)

func (c *vpnPacketConn) ReadFrom(p []byte) (int, net.Addr, error) {
	// 底层是连接式 UDP,Read 只会收到 remote 的包;补回源地址给上层 NAT。
	n, err := c.Conn.Read(p)
	return n, c.remote, err
}

func (c *vpnPacketConn) WriteTo(p []byte, _ net.Addr) (int, error) {
	// 忽略传入 addr(可能是 FQDN 的空 IP),统一发往已连接的 remote。
	return c.Conn.Write(p)
}

// resolve 只经隧道内 DNS 把 FQDN 解析成 IPv4；失败时 fail closed。
func (o *vpnOutbound) resolve(ctx context.Context, fqdn string) (netip.Addr, error) {
	_, tunnelDNS := o.line.snapshot()
	for _, server := range tunnelDNS {
		if addr, ok := o.resolveViaTunnel(ctx, server, fqdn); ok {
			return addr, nil
		}
	}

	return netip.Addr{}, E.New("AnyConnect outbound: tunnel DNS failed to resolve ", fqdn)
}

// resolveViaTunnel 向隧道内某个 DNS 服务器的 53/udp 发一次 A 查询并解析响应。
// 返回 (地址, true) 表示成功;任何错误都返回 ok=false,由调用方决定降级。
func (o *vpnOutbound) resolveViaTunnel(ctx context.Context, server netip.Addr, fqdn string) (netip.Addr, bool) {
	name, err := dnsmessage.NewName(dnsName(fqdn))
	if err != nil {
		return netip.Addr{}, false
	}

	query, err := buildDNSQuery(name)
	if err != nil {
		return netip.Addr{}, false
	}

	raddr := &net.UDPAddr{IP: net.IP(server.AsSlice()), Port: 53}
	conn, err := o.line.DialUDP(nil, raddr)
	if err != nil {
		return netip.Addr{}, false
	}
	defer conn.Close()

	deadline := time.Now().Add(dnsQueryTimeout)
	if dl, ok := ctx.Deadline(); ok && dl.Before(deadline) {
		deadline = dl
	}
	_ = conn.SetDeadline(deadline)

	if _, err := conn.Write(query); err != nil {
		return netip.Addr{}, false
	}

	buf := make([]byte, 1500)
	n, err := conn.Read(buf)
	if err != nil {
		return netip.Addr{}, false
	}

	return parseFirstA(buf[:n])
}

// buildDNSQuery 构造一个标准递归 A 查询报文。
func buildDNSQuery(name dnsmessage.Name) ([]byte, error) {
	// ID 固定为 0 即可:每次查询用独立的短连接,响应就是本次的应答,无需匹配 ID。
	builder := dnsmessage.NewBuilder(nil, dnsmessage.Header{
		RecursionDesired: true,
	})
	if err := builder.StartQuestions(); err != nil {
		return nil, err
	}
	if err := builder.Question(dnsmessage.Question{
		Name:  name,
		Type:  dnsmessage.TypeA,
		Class: dnsmessage.ClassINET,
	}); err != nil {
		return nil, err
	}
	return builder.Finish()
}

// parseFirstA 从 DNS 响应里取第一条 A 记录。
func parseFirstA(msg []byte) (netip.Addr, bool) {
	var parser dnsmessage.Parser
	if _, err := parser.Start(msg); err != nil {
		return netip.Addr{}, false
	}
	if err := parser.SkipAllQuestions(); err != nil {
		return netip.Addr{}, false
	}
	for {
		hdr, err := parser.AnswerHeader()
		if err != nil {
			// io.EOF 之类:遍历完仍无 A 记录。
			return netip.Addr{}, false
		}
		if hdr.Type != dnsmessage.TypeA {
			if err := parser.SkipAnswer(); err != nil {
				return netip.Addr{}, false
			}
			continue
		}
		a, err := parser.AResource()
		if err != nil {
			return netip.Addr{}, false
		}
		return netip.AddrFrom4(a.A), true
	}
}

// dnsName 把 FQDN 规范成 DNS wire 需要的以点结尾的形式。
func dnsName(fqdn string) string {
	if len(fqdn) == 0 || fqdn[len(fqdn)-1] != '.' {
		return fqdn + "."
	}
	return fqdn
}
