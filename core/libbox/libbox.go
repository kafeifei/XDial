//go:build !windows

// Package libbox 是 XDial tvOS 自研引擎的进程内门面:
// sslcon(AnyConnect) + gVisor 用户态栈 + sing-box(库,非外置进程)整合成
// 单个 gomobile 可绑定的 API,供 NEPacketTunnelProvider(Swift)调用。
//
// 对照 macOS 版 core/engine.Engine:那边 sing-box 是 exec 出去的外置二进制,
// "vpn" 出口经本地 SOCKS5 中转;这里 sing-box 作为库直接跑在同一进程,
// "vpn" 出口(vpn_outbound.go)直接拨 VPNBridge,省掉中转那一跳。
//
// Phase 0 范围:验证 sslcon+gVisor+sing-box 这条依赖链能否被 gomobile 绑定到 tvOS,
// 并跑通到 AnyConnect 服务端的真实连接。TUN inbound 与 NE packetFlow 的对接
// (adapter.PlatformInterface)留到 Phase 2 —— 那需要真实的 NEPacketTunnelProvider
// 才能验证,在没有 Xcode/真机的情况下无法有意义地测试。
package libbox

import (
	"context"
	"crypto/tls"
	stdjson "encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strings"
	"sync"
	"time"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/urltest"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing-box/protocol/group"
	tun "github.com/sagernet/sing-tun"
	"github.com/sagernet/sing/common/json"
	M "github.com/sagernet/sing/common/metadata"
	"github.com/sagernet/sing/common/ntp"
	"github.com/sagernet/sing/service"
	"sslcon/session"

	"github.com/kafeifei/xdial/core/engine"
)

// Callback 镜像 core/engine.StatusCallback 的形状,保持 gomobile 可绑定
// (方法参数只用 string/int 等基础类型)。
type Callback interface {
	OnStatusChanged(statusJSON string)
	OnError(code int, message string)
}

type vpnClient interface {
	Connect(cfg engine.VPNConfig) (*engine.VPNInfo, error)
	Session() *session.ConnSession
	Disconnect()
}

// 错误分类码:通过 Callback.OnError 传给 Swift 侧,让上层能按大类做区分处理
// (比如"配置错" vs "网络错"给不同的用户提示),而不必解析 Go error 字符串。
// 刻意只分几大类,不做细粒度设计。
const (
	// ErrCodeState 引擎状态非法(如已在运行时又调 Start)。
	ErrCodeState = 1
	// ErrCodeNetwork AnyConnect 拨号/网桥建立等网络层失败。
	ErrCodeNetwork = 2
	// ErrCodeConfig sing-box 配置解析失败。
	ErrCodeConfig = 3
	// ErrCodeEngine sing-box 实例构建/启动失败。
	ErrCodeEngine = 4
)

type Libbox struct {
	mu           sync.Mutex
	cb           Callback
	vpn          vpnClient
	bridge       *engine.VPNBridge
	box          *box.Box
	running      bool
	platform     *xdPlatformInterface
	lastError    string
	dnsJSON      string
	session      *session.ConnSession
	generation   uint64
	cleaning     bool
	runtimeCtx   context.Context
	routingProbe *routingProbeTracker
}

func New(cb Callback) *Libbox {
	return &Libbox{
		cb:       cb,
		vpn:      engine.NewVPNClient(),
		platform: &xdPlatformInterface{},
	}
}

// SetTunFD 记录 NE packetFlow 对应的文件描述符,供 sing-box 的 TUN inbound 复用。
//
// 调用时机:Swift 的 NEPacketTunnelProvider.startTunnel 里,在拿到 packetFlow 的
// fd(通过 packetFlow.value(forKeyPath: "socket.fileDescriptor") 之类的方式取得)
// 之后、调用 Start 之前调用一次。Start 内部会把这个 fd dup 一份交给 sing-box
// (见 platform.go 的 OpenInterface),原始 fd 的所有权仍归 NE。
//
// 若引擎跑的是不含 tun inbound 的配置(如桌面手测用 socks inbound),不设置也没关系。
func (l *Libbox) SetTunFD(fd int) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.platform.tunFD = fd
}

// SetDefaultInterface 接收 Swift NWPathMonitor 报告的真实物理出口。
// 必须在 Start 前至少调用一次；网络从 Wi-Fi/蜂窝之间切换时继续调用即可。
func (l *Libbox) SetDefaultInterface(name string, index int) {
	l.platform.setDefaultInterface(name, index)
}

// SetTunOpener 替换 TUN 打开器(默认走 dup(tunFD)+tun.New 的真实路径)。
//
// 这是刻意留给离线集成测试的缝隙:测试代码可从包外注入一个返回 fake tun.Tun 的
// opener,从而在没有 NE/真实 fd 的桌面环境跑通 sing-box 启动链路。参数是函数类型,
// gomobile 绑定时会自动跳过本方法,不影响 tvOS 导出面。生产代码无需调用。
func (l *Libbox) SetTunOpener(opener TunOpener) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.platform.opener = opener
}

// IsRunning 返回引擎当前是否处于已启动状态。
func (l *Libbox) IsRunning() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.running
}

// Status 返回一个 JSON 字符串描述当前状态,形如 {"running":true}。
// 与 OnStatusChanged 推送的语义一致,但供 Swift 侧主动轮询用。
func (l *Libbox) Status() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.running {
		return `{"running":true}`
	}
	return `{"running":false}`
}

// TunnelNameServers 返回当前 AnyConnect 握手下发的 DNS IPv4 地址 JSON 数组。
// 使用 JSON 字符串保持 gomobile 导出面只含基础类型；Swift 在重新应用
// NEPacketTunnelNetworkSettings 前仍会逐项做数值地址校验。
func (l *Libbox) TunnelNameServers() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.dnsJSON == "" {
		return "[]"
	}
	return l.dnsJSON
}

// RefreshDNS 清除运行中 sing-box 的 DNS 缓存并重置 transport 连接。
// Tailscale endpoint 从 NeedsLogin 进入 Running 后会原地收到新的分域配置；
// 清缓存后下一次查询即可由移动 dispatcher 按最新归属选择 resolver。
func (l *Libbox) RefreshDNS() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if !l.running || l.box == nil {
		return fmt.Errorf("connection is not running")
	}
	l.box.Router().ResetNetwork()
	return nil
}

// SelectOutbound switches a running sing-box selector to one of its declared
// members. Tags must come from SubscriptionRuntimeCatalog; no user input is
// interpreted as a URL or configuration fragment here.
func (l *Libbox) SelectOutbound(groupTag, outboundTag string) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if !l.running || l.box == nil {
		return fmt.Errorf("connection is not running")
	}
	outbound, loaded := l.box.Outbound().Outbound(groupTag)
	if !loaded {
		return fmt.Errorf("selector group is unavailable")
	}
	selector, ok := outbound.(*group.Selector)
	if !ok {
		return fmt.Errorf("outbound group is not selectable")
	}
	if !selector.SelectOutbound(outboundTag) {
		return fmt.Errorf("selector member is unavailable")
	}
	return nil
}

// TestOutbound performs one bounded HTTPS HEAD request through a specific
// running outbound and returns round-trip milliseconds.
func (l *Libbox) TestOutbound(outboundTag, testURL string, timeoutMS int) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if !l.running || l.box == nil || l.runtimeCtx == nil {
		return 0, fmt.Errorf("connection is not running")
	}
	if testURL == "" {
		testURL = "https://www.gstatic.com/generate_204"
	}
	parsed, err := url.Parse(testURL)
	if err != nil || !strings.EqualFold(parsed.Scheme, "https") || parsed.Hostname() == "" || parsed.User != nil {
		return 0, fmt.Errorf("test address must be HTTPS")
	}
	if timeoutMS < 500 {
		timeoutMS = 500
	}
	if timeoutMS > 10_000 {
		timeoutMS = 10_000
	}
	outbound, loaded := l.box.Outbound().Outbound(outboundTag)
	if !loaded {
		return 0, fmt.Errorf("test outbound is unavailable")
	}
	ctx, cancel := context.WithTimeout(l.runtimeCtx, time.Duration(timeoutMS)*time.Millisecond)
	defer cancel()
	delay, err := urltest.URLTest(ctx, testURL, outbound)
	if err != nil {
		return 0, fmt.Errorf("outbound test failed")
	}
	return int(delay), nil
}

// ProbeOutboundIP fetches Cloudflare's small trace document through one exact
// running outbound and returns only the validated public address. The endpoint
// is fixed so provider messages cannot turn this into an arbitrary network
// fetch primitive.
func (l *Libbox) ProbeOutboundIP(outboundTag string, timeoutMS int) (string, error) {
	const probeURL = "https://1.1.1.1/cdn-cgi/trace"
	l.mu.Lock()
	defer l.mu.Unlock()
	if !l.running || l.box == nil || l.runtimeCtx == nil {
		return "", fmt.Errorf("connection is not running")
	}
	if timeoutMS < 500 {
		timeoutMS = 500
	}
	if timeoutMS > 10_000 {
		timeoutMS = 10_000
	}
	outbound, loaded := l.box.Outbound().Outbound(outboundTag)
	if !loaded {
		return "", fmt.Errorf("probe outbound is unavailable")
	}

	ctx, cancel := context.WithTimeout(l.runtimeCtx, time.Duration(timeoutMS)*time.Millisecond)
	defer cancel()
	conn, err := outbound.DialContext(ctx, "tcp", M.ParseSocksaddrHostPortStr("1.1.1.1", "443"))
	if err != nil {
		return "", fmt.Errorf("outbound address probe failed")
	}
	defer conn.Close()

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, probeURL, nil)
	if err != nil {
		return "", fmt.Errorf("create address probe request: %w", err)
	}
	client := http.Client{
		Transport: &http.Transport{
			DialContext: func(context.Context, string, string) (net.Conn, error) {
				return conn, nil
			},
			TLSClientConfig: &tls.Config{
				MinVersion: tls.VersionTLS12,
				Time:       ntp.TimeFuncFromContext(ctx),
				RootCAs:    adapter.RootPoolFromContext(ctx),
			},
		},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		Timeout:       time.Duration(timeoutMS) * time.Millisecond,
	}
	defer client.CloseIdleConnections()
	response, err := client.Do(request)
	if err != nil {
		return "", fmt.Errorf("outbound address probe failed")
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("address probe returned an unexpected status")
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 64<<10))
	if err != nil {
		return "", fmt.Errorf("read address probe response: %w", err)
	}
	return parsePublicProbeAddress(string(body))
}

func parsePublicProbeAddress(body string) (string, error) {
	for _, line := range strings.Split(body, "\n") {
		if !strings.HasPrefix(line, "ip=") {
			continue
		}
		address, parseErr := netip.ParseAddr(strings.TrimSpace(strings.TrimPrefix(line, "ip=")))
		if parseErr != nil || !address.IsGlobalUnicast() || address.IsPrivate() || address.IsLoopback() {
			return "", fmt.Errorf("address probe returned an invalid address")
		}
		return address.String(), nil
	}
	return "", fmt.Errorf("address probe response did not contain an address")
}

type diagnostics struct {
	Running               bool                  `json:"running"`
	GVisorCompiled        bool                  `json:"gvisor_compiled"`
	SelectedStack         string                `json:"selected_stack"`
	TunFDReady            bool                  `json:"tun_fd_ready"`
	TunName               string                `json:"tun_name,omitempty"`
	DefaultInterfaceName  string                `json:"default_interface_name,omitempty"`
	DefaultInterfaceIndex int                   `json:"default_interface_index,omitempty"`
	HandshakeCompleted    bool                  `json:"handshake_completed"`
	TunInPackets          uint64                `json:"tun_in_packets"`
	TunInBytes            uint64                `json:"tun_in_bytes"`
	TunOutPackets         uint64                `json:"tun_out_packets"`
	TunOutBytes           uint64                `json:"tun_out_bytes"`
	Bridge                engine.VPNBridgeStats `json:"bridge"`
	LastError             string                `json:"last_error,omitempty"`
}

// Diagnostics 返回不含凭据和服务器地址的运行快照，供 NetworkExtension 在发布版
// 出现数据链路故障时回传给主 App。字段只描述阶段、接口和收发计数。
func (l *Libbox) Diagnostics() string {
	l.mu.Lock()
	defer l.mu.Unlock()

	platform := l.platform.diagnostics()
	result := diagnostics{
		Running:               l.running,
		GVisorCompiled:        tun.WithGVisor,
		SelectedStack:         "gvisor",
		TunFDReady:            platform.TunFD > 0,
		TunName:               platform.TunName,
		DefaultInterfaceName:  platform.DefaultInterfaceName,
		DefaultInterfaceIndex: platform.DefaultInterfaceIndex,
		HandshakeCompleted:    l.bridge != nil,
		TunInPackets:          platform.TunInPackets,
		TunInBytes:            platform.TunInBytes,
		TunOutPackets:         platform.TunOutPackets,
		TunOutBytes:           platform.TunOutBytes,
		LastError:             l.lastError,
	}
	if l.bridge != nil {
		result.Bridge = l.bridge.Stats()
	}
	data, err := stdjson.Marshal(result)
	if err != nil {
		return `{"running":false,"last_error":"diagnostics encoding failed"}`
	}
	return string(data)
}

// Start 连接 AnyConnect 服务端,起 gVisor 网桥,再用 configJSON 启动进程内 sing-box。
//
// configJSON 是标准 sing-box 配置(由 core/config.GenerateSingBox 产出,
// inbound 段在 Phase 2 改为 NE 模式),outbounds 里 "vpn" 类型的条目会
// 路由到本次连接建立的 VPNBridge。
func (l *Libbox) Start(server, username, password, configJSON string) error {
	return l.start(server, "", username, password, false, configJSON)
}

// StartResolved is the NetworkExtension-safe Start variant. dialAddress must
// be the numeric IPv4 resolved before the system default route enters the TUN;
// server is retained separately for TLS certificate validation and HTTP Host.
func (l *Libbox) StartResolved(server, dialAddress, username, password, configJSON string) error {
	return l.start(server, dialAddress, username, password, false, configJSON)
}

// StartResolvedWithInsecure 保留数值地址直拨，并把所选线路的显式证书策略带过
// gomobile 边界。旧入口继续使用 false，保持默认验证证书。
func (l *Libbox) StartResolvedWithInsecure(server, dialAddress, username, password string, allowInsecure bool, configJSON string) error {
	return l.start(server, dialAddress, username, password, allowInsecure, configJSON)
}

// StartStandalone starts the NetworkExtension data plane without creating an
// AnyConnect bridge. Direct, proxy, subscription and Tailscale outbounds are
// fully owned by sing-box and therefore do not need tunnel credentials.
func (l *Libbox) StartStandalone(configJSON string) error {
	l.mu.Lock()
	var notify func()
	defer func() {
		l.mu.Unlock()
		if notify != nil {
			notify()
		}
	}()
	fail := func(code int, err error) error {
		message := err.Error()
		l.lastError = message
		if cb := l.cb; cb != nil {
			notify = func() {
				cb.OnError(code, message)
			}
		}
		return err
	}

	if l.cleaning {
		return fail(ErrCodeState, fmt.Errorf("connection cleanup in progress"))
	}
	if l.running {
		return fail(ErrCodeState, fmt.Errorf("already running"))
	}
	l.lastError = ""
	l.dnsJSON = ""

	ctx := boxContext(context.Background())
	ctx = service.ContextWith[adapter.PlatformInterface](ctx, adapter.PlatformInterface(l.platform))
	opts, err := json.UnmarshalExtendedContext[option.Options](ctx, []byte(configJSON))
	if err != nil {
		return fail(ErrCodeConfig, fmt.Errorf("parse sing-box config: %w", err))
	}
	instance, err := box.New(box.Options{Options: opts, Context: ctx})
	if err != nil {
		return fail(ErrCodeEngine, fmt.Errorf("construct sing-box: %w", err))
	}
	routingProbe := newRoutingProbeTracker()
	instance.Router().AppendTracker(routingProbe)
	if err := instance.Start(); err != nil {
		return fail(ErrCodeEngine, fmt.Errorf("start sing-box: %w", err))
	}

	l.bridge = nil
	l.box = instance
	l.running = true
	l.session = nil
	l.runtimeCtx = ctx
	l.routingProbe = routingProbe
	l.generation++
	if cb := l.cb; cb != nil {
		notify = func() {
			cb.OnStatusChanged(`{"status":"connected"}`)
		}
	}
	return nil
}

func (l *Libbox) start(server, dialAddress, username, password string, allowInsecure bool, configJSON string) error {
	l.mu.Lock()
	var notify func()
	var monitoredSession *session.ConnSession
	var monitoredGeneration uint64
	defer func() {
		l.mu.Unlock()
		if monitoredSession != nil {
			// 先建立监听但暂不放行，保证服务端立即断开时也一定先送达
			// connected；回调重入 Stop 后，代际校验会让监听静默退出。
			ready := make(chan struct{})
			go func() {
				<-ready
				l.monitorSession(monitoredGeneration, monitoredSession)
			}()
			defer close(ready)
		}
		if notify != nil {
			notify()
		}
	}()
	fail := func(code int, err error) error {
		message := err.Error()
		l.lastError = message
		if cb := l.cb; cb != nil {
			notify = func() {
				cb.OnError(code, message)
			}
		}
		return err
	}

	if l.cleaning {
		return fail(ErrCodeState, fmt.Errorf("connection cleanup in progress"))
	}
	if l.running {
		return fail(ErrCodeState, fmt.Errorf("already running"))
	}
	l.lastError = ""
	l.dnsJSON = ""

	vpnInfo, err := l.vpn.Connect(startVPNConfig(server, dialAddress, username, password, allowInsecure))
	if err != nil {
		return fail(ErrCodeNetwork, fmt.Errorf("anyconnect dial: %w", err))
	}
	var dnsServers []string
	for _, raw := range vpnInfo.DNS {
		addr, parseErr := netip.ParseAddr(strings.TrimSpace(raw))
		if parseErr == nil && addr.Is4() {
			dnsServers = append(dnsServers, addr.String())
		}
	}
	if len(dnsServers) == 0 {
		l.vpn.Disconnect()
		return fail(ErrCodeNetwork, fmt.Errorf("anyconnect did not provide a usable DNS server"))
	}
	dnsData, err := stdjson.Marshal(dnsServers)
	if err != nil {
		l.vpn.Disconnect()
		return fail(ErrCodeNetwork, fmt.Errorf("encode tunnel DNS settings: %w", err))
	}
	l.dnsJSON = string(dnsData)

	bridge, err := engine.NewVPNBridge(vpnInfo.VPNAddress, vpnInfo.MTU)
	if err != nil {
		l.vpn.Disconnect()
		return fail(ErrCodeNetwork, fmt.Errorf("AnyConnect bridge: %w", err))
	}
	cSess := l.vpn.Session()
	if cSess == nil {
		bridge.Close()
		l.vpn.Disconnect()
		return fail(ErrCodeNetwork, fmt.Errorf("AnyConnect session ended immediately after connect"))
	}
	bridge.Start(cSess)

	ctx := boxContext(context.Background())
	ctx = service.ContextWith[*engine.VPNBridge](ctx, bridge)
	// 注入 PlatformInterface:sing-box 的 TUN inbound 靠它拿到 NE packetFlow 的 fd。
	// 与上面注入 VPNBridge 同一套 service.ContextWith 机制。
	ctx = service.ContextWith[adapter.PlatformInterface](ctx, adapter.PlatformInterface(l.platform))

	opts, err := json.UnmarshalExtendedContext[option.Options](ctx, []byte(configJSON))
	if err != nil {
		bridge.Close()
		l.vpn.Disconnect()
		return fail(ErrCodeConfig, fmt.Errorf("parse sing-box config: %w", err))
	}

	instance, err := box.New(box.Options{Options: opts, Context: ctx})
	if err != nil {
		bridge.Close()
		l.vpn.Disconnect()
		return fail(ErrCodeEngine, fmt.Errorf("construct sing-box: %w", err))
	}

	routingProbe := newRoutingProbeTracker()
	instance.Router().AppendTracker(routingProbe)
	if err := instance.Start(); err != nil {
		bridge.Close()
		l.vpn.Disconnect()
		return fail(ErrCodeEngine, fmt.Errorf("start sing-box: %w", err))
	}

	l.bridge = bridge
	l.box = instance
	l.running = true
	l.session = cSess
	l.runtimeCtx = ctx
	l.routingProbe = routingProbe
	l.generation++
	monitoredSession = cSess
	monitoredGeneration = l.generation
	if cb := l.cb; cb != nil {
		notify = func() {
			cb.OnStatusChanged(`{"status":"connected"}`)
		}
	}
	return nil
}

func startVPNConfig(server, dialAddress, username, password string, allowInsecure bool) engine.VPNConfig {
	return engine.VPNConfig{
		Server:        server,
		DialAddress:   dialAddress,
		Username:      username,
		Password:      password,
		AllowInsecure: allowInsecure,
	}
}

func (l *Libbox) Stop() error {
	l.mu.Lock()
	if !l.running {
		l.mu.Unlock()
		return nil
	}

	instance, bridge := l.detachRunningLocked()
	cb := l.cb
	l.mu.Unlock()
	defer l.finishCleaning()

	l.closeDetached(instance, bridge)

	if cb != nil {
		cb.OnStatusChanged(`{"status":"disconnected"}`)
	}
	return nil
}

const unexpectedSessionCloseError = "AnyConnect connection ended unexpectedly"

// monitorSession 只处理创建它的那一代连接。Stop 会先失效 generation，旧连接的
// CloseChan 即使晚于新连接关闭，也不能清理新连接或发送过期回调。
func (l *Libbox) monitorSession(generation uint64, cSess *session.ConnSession) {
	<-cSess.CloseChan

	l.mu.Lock()
	if !l.running || l.cleaning || l.generation != generation || l.session != cSess {
		l.mu.Unlock()
		return
	}
	instance, bridge := l.detachRunningLocked()
	l.lastError = unexpectedSessionCloseError
	cb := l.cb
	l.mu.Unlock()
	defer l.finishCleaning()

	l.closeDetached(instance, bridge)

	// 外部回调不持有内部锁，允许上层同步读取 Diagnostics 或调用 Stop。
	// cleaning 在回调完成前保持为 true，避免旧连接的回调落到已启动的新连接上。
	if cb != nil {
		cb.OnError(ErrCodeNetwork, unexpectedSessionCloseError)
		cb.OnStatusChanged(`{"status":"disconnected"}`)
	}
}

// detachRunningLocked 在状态锁内一次性切断当前运行代际；实际 Close 放在锁外，
// 避免关闭 box/session 时反向等待 monitor 而形成锁与 channel 的闭环。
func (l *Libbox) detachRunningLocked() (*box.Box, *engine.VPNBridge) {
	instance := l.box
	bridge := l.bridge
	l.box = nil
	l.bridge = nil
	l.session = nil
	l.runtimeCtx = nil
	l.routingProbe = nil
	l.running = false
	l.dnsJSON = ""
	l.generation++
	l.cleaning = true
	return instance, bridge
}

func (l *Libbox) closeDetached(instance *box.Box, bridge *engine.VPNBridge) {
	if instance != nil {
		instance.Close()
	}
	if bridge != nil {
		bridge.Close()
	}
	if l.vpn != nil {
		l.vpn.Disconnect()
	}
}

func (l *Libbox) finishCleaning() {
	l.mu.Lock()
	l.cleaning = false
	l.mu.Unlock()
}
