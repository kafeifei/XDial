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
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"sort"
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
	"golang.org/x/sys/unix"
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

// DetectUnderlayInterface 返回宿主操作系统当前默认路由已经选定的接口。
// 调用方只能把这个结果与同一时刻的完整接口快照一起转交给 sing-box，不能按名称、
// 类型或产品重写。放在 libbox 门面是为了让 macOS App 与旧桌面引擎复用同一份
// route(8) 解析和存活校验，而不是在 Swift 再复制一套。
func DetectUnderlayInterface() (string, error) {
	return engine.DetectUnderlayInterface(context.Background())
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

const maxAnyConnectReconnectAttempts = 3

var anyConnectReconnectDelays = [...]time.Duration{
	0,
	2 * time.Second,
	5 * time.Second,
}

type Libbox struct {
	mu                       sync.Mutex
	cb                       Callback
	vpn                      vpnClient
	bridge                   *engine.VPNBridge
	box                      *box.Box
	running                  bool
	platform                 *xdPlatformInterface
	lastError                string
	dnsJSON                  string
	session                  *session.ConnSession
	generation               uint64
	cleaning                 bool
	runtimeCtx               context.Context
	runtimeCancel            context.CancelFunc
	runtimeUsers             sync.WaitGroup
	debugRoutingProbeEnabled bool
	routingProbe             *routingProbeTracker
	stateLocks               []*os.File
	anyConnectDiagnostics    stdjson.RawMessage
	anyConnectLine           *anyConnectLineRuntime
	anyConnectConfig         engine.VPNConfig
	anyConnectRetryDelays    []time.Duration
	probeOutboundAddressFunc func(
		context.Context,
		adapter.Outbound,
		outboundAddressProbeEndpoint,
		int,
	) (string, error)
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

// SetDefaultInterface 接收 Swift NWPathMonitor 报告的默认 Underlay 接口。
// 它可以是网线、Wi-Fi，也可以是启动 XDial 前已经存在的 utun；平台层只排除
// RegisterMyInterface 明确登记的 XDial 自身接口。
func (l *Libbox) SetDefaultInterface(name string, index int) {
	l.platform.setDefaultInterface(name, index)
}

// SetUnderlayInterfaceBinding controls whether sockets opened internally by
// protocol endpoints must be bound to the default Underlay interface.
//
// Packet Tunnel providers leave this disabled because NECP already excludes
// provider-owned sockets from their own tunnel. Transparent Proxy providers do
// not have that guarantee while startProxy is still in progress: an unbound
// Tailscale DERP/UDP socket can be captured by the proxy that is creating it.
func (l *Libbox) SetUnderlayInterfaceBinding(enabled bool) {
	l.platform.setUnderlayInterfaceBinding(enabled)
}

// SetDebugRoutingProbeEnabled controls whether the next Start installs the
// routing tracker in sing-box's flow hot path. It is deliberately disabled by
// default: only a Debug host may opt in before Start, and changing it while a
// generation is running never mutates that generation.
func (l *Libbox) SetDebugRoutingProbeEnabled(enabled bool) {
	l.mu.Lock()
	l.debugRoutingProbeEnabled = enabled
	l.mu.Unlock()
}

// SetNetworkInterfaces 接收 NWPath.availableInterfaces 的完整快照。
// JSON 形如 [{"name":"utun13","index":21,"type":"other"},{"name":"en0","index":7,"type":"wifi"}]。
// 不能只发物理接口：下层 VPN 正是以虚拟接口组成 XDial 的 Underlay。
func (l *Libbox) SetNetworkInterfaces(interfacesJSON string) error {
	var snapshots []platformNetworkInterfaceSnapshot
	if err := stdjson.Unmarshal([]byte(interfacesJSON), &snapshots); err != nil {
		return fmt.Errorf("decode platform network interfaces: %w", err)
	}
	return l.platform.setNetworkInterfaces(snapshots)
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

// StartupStage captures a process-local goroutine snapshot without taking the
// Libbox lifecycle mutex. It is intentionally callable while Start is blocked,
// and returns only a coarse allow-listed stage instead of raw stack content.
func (l *Libbox) StartupStage() string {
	buffer := make([]byte, 256*1024)
	length := runtime.Stack(buffer, true)
	return startupStageFromStack(string(buffer[:length]))
}

func startupStageFromStack(stack string) string {
	stages := []struct {
		marker string
		stage  string
	}{
		{"protocol/tailscale.(*Endpoint).postStart", "tailscale_backend_starting"},
		{"protocol/tailscale.(*Endpoint).start", "tailscale_endpoint_starting"},
		{"tailscale/tsnet.(*Server).start", "tailscale_backend_starting"},
		{"tailscale/tsnet.(*Server).Start", "tailscale_backend_starting"},
		{"protocol/tun.(*Inbound).Start", "tun_starting"},
		{"route.(*NetworkManager).UpdateInterfaces", "interfaces_updating"},
		{"sing-box.(*Box).start", "singbox_starting"},
		{"libbox.(*Libbox).start", "engine_starting"},
	}
	for _, candidate := range stages {
		if strings.Contains(stack, candidate.marker) {
			return candidate.stage
		}
	}
	return "unknown_starting"
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

type outboundAddressProbeEndpoint struct {
	url         string
	destination M.Socksaddr
}

var outboundAddressProbeEndpoints = []outboundAddressProbeEndpoint{
	{
		url:         "https://checkip.amazonaws.com/",
		destination: M.ParseSocksaddrHostPortStr("checkip.amazonaws.com", "443"),
	},
	{
		url:         "https://1.1.1.1/cdn-cgi/trace",
		destination: M.ParseSocksaddrHostPortStr("1.1.1.1", "443"),
	},
}

// ProbeOutboundIP fetches a public address through one exact running outbound.
// Both endpoints are fixed so provider messages cannot turn this into an
// arbitrary network fetch primitive. The named HTTPS endpoint is the primary
// reachability/address assertion; the numeric HTTPS endpoint keeps the probe
// usable when an enterprise tunnel DNS server cannot resolve public names.
func (l *Libbox) ProbeOutboundIP(outboundTag string, timeoutMS int) (string, error) {
	l.mu.Lock()
	if !l.running || l.box == nil || l.runtimeCtx == nil {
		l.mu.Unlock()
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
		l.mu.Unlock()
		return "", fmt.Errorf("probe outbound is unavailable")
	}
	ctx, cancel := context.WithTimeout(l.runtimeCtx, time.Duration(timeoutMS)*time.Millisecond)
	generation := l.generation
	probe := l.probeOutboundAddressFunc
	if probe == nil {
		probe = probeOutboundAddress
	}
	// adapter.Outbound is a bare Dialer and does not grant an external caller
	// a lifetime lease. Box.Close closes its outbound manager and endpoint
	// implementations, so cleanup must wait until this borrowed outbound is
	// no longer in use. Add happens under l.mu while the generation is still
	// running; detach flips running/cleaning under the same lock before Wait.
	l.runtimeUsers.Add(1)
	l.mu.Unlock()
	defer l.runtimeUsers.Done()
	defer cancel()

	var probeErrors []string
	for index, endpoint := range outboundAddressProbeEndpoints {
		address, err := probe(
			ctx,
			outbound,
			endpoint,
			len(outboundAddressProbeEndpoints)-index,
		)
		if err == nil {
			if !l.probeGenerationIsCurrent(generation) {
				return "", fmt.Errorf("connection changed during outbound address probe")
			}
			return address, nil
		}
		probeErrors = append(probeErrors, err.Error())
	}
	if !l.probeGenerationIsCurrent(generation) {
		return "", fmt.Errorf("connection changed during outbound address probe")
	}
	return "", fmt.Errorf("outbound address probe failed: %s", strings.Join(probeErrors, "; "))
}

func (l *Libbox) probeGenerationIsCurrent(generation uint64) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.running &&
		!l.cleaning &&
		l.generation == generation &&
		l.runtimeCtx != nil
}

func probeOutboundAddress(
	parentCtx context.Context,
	outbound adapter.Outbound,
	endpoint outboundAddressProbeEndpoint,
	remainingEndpoints int,
) (string, error) {
	remainingTime := time.Until(deadlineFromContext(parentCtx))
	if remainingTime <= 0 {
		return "", context.DeadlineExceeded
	}
	attemptTimeout := remainingTime / time.Duration(remainingEndpoints)
	if attemptTimeout < 500*time.Millisecond {
		attemptTimeout = remainingTime
	}
	ctx, cancel := context.WithTimeout(parentCtx, attemptTimeout)
	defer cancel()

	conn, err := outbound.DialContext(ctx, "tcp", endpoint.destination)
	if err != nil {
		return "", fmt.Errorf("outbound address probe dial failed: %w", err)
	}
	defer conn.Close()

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint.url, nil)
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
		Timeout:       attemptTimeout,
	}
	defer client.CloseIdleConnections()
	response, err := client.Do(request)
	if err != nil {
		return "", fmt.Errorf("outbound address probe request failed: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf(
			"address probe returned HTTP %d",
			response.StatusCode,
		)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 64<<10))
	if err != nil {
		return "", fmt.Errorf("read address probe response: %w", err)
	}
	return parsePublicProbeAddress(string(body))
}

func deadlineFromContext(ctx context.Context) time.Time {
	if deadline, ok := ctx.Deadline(); ok {
		return deadline
	}
	return time.Now()
}

func parsePublicProbeAddress(body string) (string, error) {
	for _, line := range strings.Split(body, "\n") {
		if !strings.HasPrefix(line, "ip=") {
			continue
		}
		return validatePublicProbeAddress(strings.TrimSpace(strings.TrimPrefix(line, "ip=")))
	}
	return validatePublicProbeAddress(strings.TrimSpace(body))
}

func validatePublicProbeAddress(rawAddress string) (string, error) {
	address, err := netip.ParseAddr(rawAddress)
	if err != nil || !address.IsGlobalUnicast() || address.IsPrivate() || address.IsLoopback() {
		return "", fmt.Errorf("address probe returned an invalid address")
	}
	return address.String(), nil
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
	AnyConnect            stdjson.RawMessage    `json:"anyconnect,omitempty"`
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
		AnyConnect:            l.anyConnectDiagnostics,
	}
	if l.session != nil {
		if current := validAnyConnectDiagnostics(
			engine.AnyConnectSessionDiagnostics(l.session),
		); current != nil {
			result.AnyConnect = current
		}
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
	l.anyConnectDiagnostics = nil
	l.anyConnectLine = nil
	l.anyConnectConfig = engine.VPNConfig{}

	ctx := boxContext(context.Background())
	ctx = service.ContextWith[adapter.PlatformInterface](ctx, adapter.PlatformInterface(l.platform))
	opts, err := json.UnmarshalExtendedContext[option.Options](ctx, []byte(configJSON))
	if err != nil {
		return fail(ErrCodeConfig, fmt.Errorf("parse sing-box config: %w", err))
	}
	stateLocks, err := acquireTailscaleStateLocks(configJSON)
	if err != nil {
		return fail(ErrCodeState, err)
	}
	keepStateLocks := false
	defer func() {
		if !keepStateLocks {
			releaseTailscaleStateLocks(stateLocks)
		}
	}()
	instance, err := box.New(box.Options{Options: opts, Context: ctx})
	if err != nil {
		return fail(ErrCodeEngine, fmt.Errorf("construct sing-box: %w", err))
	}
	routingProbe := l.installRoutingProbe(instance)
	if err := instance.Start(); err != nil {
		instance.Close()
		return fail(ErrCodeEngine, fmt.Errorf("start sing-box: %w", err))
	}

	l.bridge = nil
	l.box = instance
	l.running = true
	l.session = nil
	l.runtimeCtx, l.runtimeCancel = context.WithCancel(ctx)
	l.routingProbe = routingProbe
	l.stateLocks = stateLocks
	keepStateLocks = true
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
	l.anyConnectDiagnostics = nil
	l.anyConnectLine = nil
	l.anyConnectConfig = engine.VPNConfig{}

	stateLocks, err := acquireTailscaleStateLocks(configJSON)
	if err != nil {
		return fail(ErrCodeState, err)
	}
	keepStateLocks := false
	defer func() {
		if !keepStateLocks {
			releaseTailscaleStateLocks(stateLocks)
		}
	}()

	vpnInfo, err := l.vpn.Connect(startVPNConfig(server, dialAddress, username, password, allowInsecure))
	if err != nil {
		return fail(ErrCodeNetwork, fmt.Errorf("anyconnect dial: %w", err))
	}
	dnsServers := anyConnectDNSServers(vpnInfo.DNS)
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
	line := newAnyConnectLineRuntime(bridge, dnsServers)

	ctx := boxContext(context.Background())
	ctx = service.ContextWith[*anyConnectLineRuntime](ctx, line)
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

	routingProbe := l.installRoutingProbe(instance)
	if err := instance.Start(); err != nil {
		instance.Close()
		bridge.Close()
		l.vpn.Disconnect()
		return fail(ErrCodeEngine, fmt.Errorf("start sing-box: %w", err))
	}

	l.bridge = bridge
	l.box = instance
	l.running = true
	l.session = cSess
	l.runtimeCtx, l.runtimeCancel = context.WithCancel(ctx)
	l.routingProbe = routingProbe
	l.stateLocks = stateLocks
	l.anyConnectLine = line
	l.anyConnectConfig = startVPNConfig(
		server,
		dialAddress,
		username,
		password,
		allowInsecure,
	)
	keepStateLocks = true
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

func (l *Libbox) installRoutingProbe(instance *box.Box) *routingProbeTracker {
	if !l.debugRoutingProbeEnabled {
		return nil
	}
	tracker := newRoutingProbeTracker()
	instance.Router().AppendTracker(tracker)
	return tracker
}

func (l *Libbox) Stop() error {
	l.mu.Lock()
	if !l.running {
		l.mu.Unlock()
		return nil
	}

	instance, bridge, stateLocks := l.detachRunningLocked()
	cb := l.cb
	l.mu.Unlock()
	defer l.finishCleaning()

	l.closeDetached(instance, bridge, stateLocks)

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
	anyConnectDiagnostics := validAnyConnectDiagnostics(
		engine.AnyConnectSessionDiagnostics(cSess),
	)
	bridge := l.bridge
	line := l.anyConnectLine
	config := l.anyConnectConfig
	runtimeCtx := l.runtimeCtx
	if line == nil || bridge == nil || runtimeCtx == nil ||
		!line.deactivate(bridge) {
		l.mu.Unlock()
		return
	}
	l.bridge = nil
	l.session = nil
	l.dnsJSON = "[]"
	l.anyConnectDiagnostics = anyConnectDiagnostics
	failureMessage := anyConnectFailureMessage(anyConnectDiagnostics)
	l.lastError = failureMessage
	l.runtimeUsers.Add(1)
	l.mu.Unlock()

	// Close only the failed Line's bridge. The sing-box instance, Tailscale
	// endpoint, Transparent Proxy ingress and state locks remain owned by the
	// same data-plane generation.
	bridge.Close()
	if l.vpn != nil {
		l.vpn.Disconnect()
	}

	reconnected := l.reconnectAnyConnect(
		runtimeCtx,
		generation,
		line,
		config,
	)
	l.runtimeUsers.Done()
	if reconnected || runtimeCtx.Err() != nil {
		return
	}

	// Local recovery is bounded. Only after its budget is exhausted does the
	// existing fatal path tear down the complete transaction.
	l.failAfterAnyConnectReconnect(
		generation,
		line,
		failureMessage,
	)
}

func (l *Libbox) reconnectAnyConnect(
	runtimeCtx context.Context,
	generation uint64,
	line *anyConnectLineRuntime,
	config engine.VPNConfig,
) bool {
	for attempt := 1; attempt <= maxAnyConnectReconnectAttempts; attempt++ {
		delay := l.anyConnectReconnectDelay(attempt)
		if !waitForAnyConnectReconnect(runtimeCtx, delay) {
			return false
		}
		l.notifyStatus(anyConnectLineStatusJSON(
			"line_reconnecting",
			attempt,
			maxAnyConnectReconnectAttempts,
		))

		vpnInfo, err := l.vpn.Connect(config)
		if err != nil {
			l.vpn.Disconnect()
			continue
		}
		dnsServers := anyConnectDNSServers(vpnInfo.DNS)
		if len(dnsServers) == 0 {
			l.vpn.Disconnect()
			continue
		}
		bridge, err := engine.NewVPNBridge(vpnInfo.VPNAddress, vpnInfo.MTU)
		if err != nil {
			l.vpn.Disconnect()
			continue
		}
		cSess := l.vpn.Session()
		if cSess == nil {
			bridge.Close()
			l.vpn.Disconnect()
			continue
		}
		bridge.Start(cSess)

		l.mu.Lock()
		if !l.running || l.cleaning ||
			l.generation != generation ||
			l.anyConnectLine != line ||
			l.session != nil ||
			runtimeCtx.Err() != nil {
			l.mu.Unlock()
			bridge.Close()
			l.vpn.Disconnect()
			return false
		}
		line.activate(bridge, dnsServers)
		l.bridge = bridge
		l.session = cSess
		dnsData, _ := stdjson.Marshal(dnsServers)
		l.dnsJSON = string(dnsData)
		l.lastError = ""
		l.anyConnectDiagnostics = nil
		l.mu.Unlock()

		l.notifyStatus(anyConnectLineStatusJSON(
			"line_connected",
			attempt,
			maxAnyConnectReconnectAttempts,
		))
		go l.monitorSession(generation, cSess)
		return true
	}
	return false
}

func (l *Libbox) anyConnectReconnectDelay(attempt int) time.Duration {
	if attempt > 0 && attempt <= len(l.anyConnectRetryDelays) {
		return l.anyConnectRetryDelays[attempt-1]
	}
	return anyConnectReconnectDelays[attempt-1]
}

func waitForAnyConnectReconnect(
	ctx context.Context,
	delay time.Duration,
) bool {
	if delay <= 0 {
		return ctx.Err() == nil
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func anyConnectLineStatusJSON(
	status string,
	attempt,
	maxAttempts int,
) string {
	data, err := stdjson.Marshal(struct {
		Status      string `json:"status"`
		LineType    string `json:"line_type"`
		Attempt     int    `json:"attempt"`
		MaxAttempts int    `json:"max_attempts"`
	}{
		Status:      status,
		LineType:    "vpn",
		Attempt:     attempt,
		MaxAttempts: maxAttempts,
	})
	if err != nil {
		return `{"status":"line_reconnecting","line_type":"vpn"}`
	}
	return string(data)
}

func (l *Libbox) notifyStatus(statusJSON string) {
	l.mu.Lock()
	cb := l.cb
	l.mu.Unlock()
	if cb != nil {
		cb.OnStatusChanged(statusJSON)
	}
}

func (l *Libbox) failAfterAnyConnectReconnect(
	generation uint64,
	line *anyConnectLineRuntime,
	failureMessage string,
) {
	l.mu.Lock()
	if !l.running || l.cleaning ||
		l.generation != generation ||
		l.anyConnectLine != line ||
		l.session != nil {
		l.mu.Unlock()
		return
	}
	instance, bridge, stateLocks := l.detachRunningLocked()
	cb := l.cb
	l.mu.Unlock()
	defer l.finishCleaning()

	l.closeDetached(instance, bridge, stateLocks)
	if cb != nil {
		cb.OnError(ErrCodeNetwork, failureMessage)
		cb.OnStatusChanged(`{"status":"disconnected"}`)
	}
}

func validAnyConnectDiagnostics(raw string) stdjson.RawMessage {
	if raw == "" || !stdjson.Valid([]byte(raw)) {
		return nil
	}
	var object map[string]any
	if err := stdjson.Unmarshal([]byte(raw), &object); err != nil ||
		len(object) == 0 {
		return nil
	}
	return append(stdjson.RawMessage(nil), raw...)
}

func anyConnectFailureMessage(snapshot stdjson.RawMessage) string {
	var state struct {
		Close *struct {
			Code string `json:"code"`
		} `json:"close"`
	}
	if len(snapshot) == 0 ||
		stdjson.Unmarshal(snapshot, &state) != nil ||
		state.Close == nil {
		return unexpectedSessionCloseError
	}
	switch state.Close.Code {
	case "tls-dpd-timeout":
		return "AnyConnect TLS control channel did not answer DPD"
	case "tls-read-timeout":
		return "AnyConnect TLS control channel read timed out"
	case "tls-read-eof":
		return "AnyConnect TLS control channel reached EOF"
	case "tls-read-reset", "tls-write-reset":
		return "AnyConnect TLS control channel was reset"
	case "peer-disconnect":
		return "AnyConnect server requested disconnect"
	case "peer-terminate":
		return "AnyConnect server terminated the session"
	default:
		return unexpectedSessionCloseError
	}
}

// detachRunningLocked 在状态锁内一次性切断当前运行代际；实际 Close 放在锁外，
// 避免关闭 box/session 时反向等待 monitor 而形成锁与 channel 的闭环。
func (l *Libbox) detachRunningLocked() (*box.Box, *engine.VPNBridge, []*os.File) {
	instance := l.box
	bridge := l.bridge
	stateLocks := l.stateLocks
	l.box = nil
	l.bridge = nil
	l.anyConnectLine = nil
	l.anyConnectConfig = engine.VPNConfig{}
	l.stateLocks = nil
	l.session = nil
	if l.runtimeCancel != nil {
		l.runtimeCancel()
	}
	l.runtimeCtx = nil
	l.runtimeCancel = nil
	l.routingProbe = nil
	l.running = false
	l.dnsJSON = ""
	l.generation++
	l.cleaning = true
	return instance, bridge, stateLocks
}

func (l *Libbox) closeDetached(
	instance *box.Box,
	bridge *engine.VPNBridge,
	stateLocks []*os.File,
) {
	// detachRunningLocked cancels runtimeCtx before reaching this wait. A
	// well-behaved probe therefore exits promptly, while this barrier prevents
	// Box.Close (and VPNBridge.Close for the vpn outbound) from racing the
	// borrowed adapter.Outbound.
	l.runtimeUsers.Wait()
	if instance != nil {
		instance.Close()
	}
	if bridge != nil {
		bridge.Close()
	}
	if l.vpn != nil {
		l.vpn.Disconnect()
	}
	releaseTailscaleStateLocks(stateLocks)
}

func (l *Libbox) finishCleaning() {
	l.mu.Lock()
	l.cleaning = false
	l.mu.Unlock()
}

var errTailscaleStateInUse = errors.New("Tailscale state is already in use by another XDial session")

type tailscaleStateLockDocument struct {
	Endpoints []struct {
		Type           string `json:"type"`
		StateDirectory string `json:"state_directory"`
	} `json:"endpoints"`
}

func acquireTailscaleStateLocks(configJSON string) ([]*os.File, error) {
	var document tailscaleStateLockDocument
	if err := stdjson.Unmarshal([]byte(configJSON), &document); err != nil {
		return nil, fmt.Errorf("inspect Tailscale state configuration: %w", err)
	}

	lockPaths := make([]string, 0, len(document.Endpoints))
	seen := make(map[string]struct{}, len(document.Endpoints))
	for _, endpoint := range document.Endpoints {
		if endpoint.Type != "tailscale" {
			continue
		}
		stateDirectory := filepath.Clean(strings.TrimSpace(endpoint.StateDirectory))
		if stateDirectory == "." || !filepath.IsAbs(stateDirectory) {
			return nil, fmt.Errorf("Tailscale state directory is unavailable")
		}
		lockPath := filepath.Join(
			filepath.Dir(stateDirectory),
			"."+filepath.Base(stateDirectory)+".xdial-runtime.lock",
		)
		if _, exists := seen[lockPath]; exists {
			continue
		}
		seen[lockPath] = struct{}{}
		lockPaths = append(lockPaths, lockPath)
	}
	sort.Strings(lockPaths)

	locks := make([]*os.File, 0, len(lockPaths))
	for _, lockPath := range lockPaths {
		if err := os.MkdirAll(filepath.Dir(lockPath), 0o700); err != nil {
			releaseTailscaleStateLocks(locks)
			return nil, fmt.Errorf("prepare Tailscale state lock: %w", err)
		}
		lockFile, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o600)
		if err != nil {
			releaseTailscaleStateLocks(locks)
			return nil, fmt.Errorf("open Tailscale state lock: %w", err)
		}
		if err := unix.Flock(int(lockFile.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
			_ = lockFile.Close()
			releaseTailscaleStateLocks(locks)
			if errors.Is(err, unix.EWOULDBLOCK) {
				return nil, errTailscaleStateInUse
			}
			return nil, fmt.Errorf("lock Tailscale state: %w", err)
		}
		locks = append(locks, lockFile)
	}
	return locks, nil
}

func releaseTailscaleStateLocks(locks []*os.File) {
	for index := len(locks) - 1; index >= 0; index-- {
		_ = unix.Flock(int(locks[index].Fd()), unix.LOCK_UN)
		_ = locks[index].Close()
	}
}
