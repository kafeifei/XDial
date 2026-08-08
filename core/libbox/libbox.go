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
	"strconv"
	"strings"
	"sync"
	"time"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/urltest"
	C "github.com/sagernet/sing-box/constant"
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
	"github.com/kafeifei/xdial/core/subscription"
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
	mu        sync.Mutex
	cb        Callback
	vpn       vpnClient
	bridge    *engine.VPNBridge
	box       *box.Box
	running   bool
	platform  *xdPlatformInterface
	lastError string
	dnsJSON   string
	session   *session.ConnSession
	// generation scopes the process-global AnyConnect session monitor. A Box
	// switch that reuses that session must not change it.
	generation uint64
	// boxGeneration scopes immutable sing-box managers and their borrowed
	// outbound leases. It advances on every committed Box switch.
	boxGeneration          uint64
	cleaning               bool
	runtimeCtx             context.Context
	runtimeCancel          context.CancelFunc
	runtimeUsers           sync.WaitGroup
	switchCandidateUsers   sync.WaitGroup
	switchPreparationUsers sync.WaitGroup
	startPreparationUsers  sync.WaitGroup
	// switchCleanupMu serializes candidate Box teardown with fatal/explicit
	// active teardown. A reusable AnyConnect Line may be referenced by both
	// Boxes, so their Close paths must finish before the shared bridge closes.
	switchCleanupMu          sync.Mutex
	debugRoutingProbeEnabled bool
	routingProbe             *routingProbeTracker
	stateLocks               []*os.File
	anyConnectDiagnostics    stdjson.RawMessage
	anyConnectLine           *anyConnectLineRuntime
	anyConnectConfig         engine.VPNConfig
	// anyConnectRuntimeIdentity is an opaque, Provider-memory-only identity
	// produced from the effective AnyConnect connection parameters (including
	// credentials).  It is deliberately separate from Line ID and the complete
	// profile fingerprint: only an exact capability identity may borrow the
	// process-global sslcon session across an immutable Box generation switch.
	anyConnectRuntimeIdentity string
	// lineRuntimes is the only owner of live Line capabilities. The fields
	// above are projections of the active generation for diagnostics and local
	// recovery; they never decide whether a capability is stopped.
	lineRuntimes                lineRuntimePool
	lineRuntimeGeneration       uint64
	activeLineRuntimeGeneration uint64
	activeAnyConnectCapability  *anyConnectRuntimeCapability
	preparedSwitch              *preparedBoxSwitch
	retiredSwitch               *retiredBoxGeneration
	startPreparing              bool
	startPreparationID          uint64
	startPreparationCancel      context.CancelFunc
	switchPreparing             bool
	switchPreparationID         uint64
	switchPreparationCancel     context.CancelFunc
	switchCommitInProgress      bool
	switchCommitDone            chan struct{}
	switchRetireInProgress      bool
	switchRetireDone            chan struct{}
	anyConnectRetryDelays       []time.Duration
	probeOutboundAddressFunc    func(
		context.Context,
		adapter.Outbound,
		outboundAddressProbeEndpoint,
		int,
	) (string, error)
}

// preparedBoxSwitch owns a fully started but not yet published immutable
// sing-box generation.  The Provider continues routing flows to the active
// generation until it has completed every readiness probe and explicitly
// commits this candidate.  Aborting therefore cannot disturb the active Box
// or its AnyConnect session.
type preparedBoxSwitch struct {
	box                       *box.Box
	platform                  *xdPlatformInterface
	runtimeCtx                context.Context
	runtimeCancel             context.CancelFunc
	routingProbe              *routingProbeTracker
	stateLocks                []*os.File
	lineRuntimeGeneration     uint64
	usesAnyConnect            bool
	anyConnectRuntimeIdentity string
	anyConnectCapability      *anyConnectRuntimeCapability
	reusedLineIDs             []string
}

// retiredBoxGeneration is the source generation retained after an atomic
// candidate adoption. Provider relay claims may still be executing inside its
// Box, so Commit cannot close any of these resources. Retire owns the sole
// transition from retained to closed.
type retiredBoxGeneration struct {
	box                   *box.Box
	runtimeCtx            context.Context
	runtimeCancel         context.CancelFunc
	stateLocks            []*os.File
	lineRuntimeGeneration uint64
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
	l.mu.Lock()
	platform := l.platform
	l.mu.Unlock()
	platform.setDefaultInterface(name, index)
}

// SetUnderlayInterfaceBinding controls whether sockets opened internally by
// protocol endpoints must be bound to the default Underlay interface.
//
// Packet Tunnel providers leave this disabled because NECP already excludes
// provider-owned sockets from their own tunnel. Transparent Proxy providers do
// not have that guarantee while startProxy is still in progress: an unbound
// Tailscale DERP/UDP socket can be captured by the proxy that is creating it.
func (l *Libbox) SetUnderlayInterfaceBinding(enabled bool) {
	l.mu.Lock()
	platform := l.platform
	l.mu.Unlock()
	platform.setUnderlayInterfaceBinding(enabled)
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
	l.mu.Lock()
	platform := l.platform
	l.mu.Unlock()
	return platform.setNetworkInterfaces(snapshots)
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
	if !l.running || l.box == nil || l.runtimeCtx == nil ||
		l.switchCommitInProgress {
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
	if !l.running || l.box == nil || l.runtimeCtx == nil ||
		l.switchCommitInProgress {
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
	generation := l.boxGeneration
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

// RefreshRuleSet downloads and atomically replaces one validated cache entry
// through the exact outbound and DNS transport compiled for this session. The
// running router keeps using its already-loaded snapshot; the new copy becomes
// active on the next connection transaction.
func (l *Libbox) RefreshRuleSet(refreshJSON string) error {
	var refresh transparentProxyRuleSetRefresh
	if err := stdjson.Unmarshal([]byte(refreshJSON), &refresh); err != nil {
		return fmt.Errorf("rule-set refresh request is invalid")
	}
	if refresh.RuleSetID == "" || refresh.URL == "" ||
		refresh.OutboundTag == "" || refresh.ResolverTag == "" {
		return fmt.Errorf("rule-set refresh request is incomplete")
	}
	if refresh.InputFormat != "text" && refresh.InputFormat != "source" &&
		refresh.InputFormat != "binary" {
		return fmt.Errorf("rule-set refresh input format is invalid")
	}
	if refresh.StoredFormat != "source" && refresh.StoredFormat != "binary" {
		return fmt.Errorf("rule-set refresh storage format is invalid")
	}
	cleanPath := filepath.Clean(refresh.LocalPath)
	if !filepath.IsAbs(cleanPath) ||
		filepath.Base(filepath.Dir(cleanPath)) != "xdial-rule-sets" ||
		filepath.Base(cleanPath) == "." {
		return fmt.Errorf("rule-set refresh cache path is invalid")
	}

	l.mu.Lock()
	if !l.running || l.box == nil || l.runtimeCtx == nil ||
		l.switchCommitInProgress {
		l.mu.Unlock()
		return fmt.Errorf("connection is not running")
	}
	outbound, loaded := l.box.Outbound().Outbound(refresh.OutboundTag)
	if !loaded {
		l.mu.Unlock()
		return fmt.Errorf("rule-set refresh outbound is unavailable")
	}
	dnsRouter := service.FromContext[adapter.DNSRouter](l.runtimeCtx)
	dnsTransports := service.FromContext[adapter.DNSTransportManager](l.runtimeCtx)
	if dnsRouter == nil || dnsTransports == nil {
		l.mu.Unlock()
		return fmt.Errorf("rule-set refresh resolver is unavailable")
	}
	dnsTransport, loaded := dnsTransports.Transport(refresh.ResolverTag)
	if !loaded {
		l.mu.Unlock()
		return fmt.Errorf("rule-set refresh resolver is unavailable")
	}
	runtimeCtx := l.runtimeCtx
	generation := l.boxGeneration
	l.runtimeUsers.Add(1)
	l.mu.Unlock()
	defer l.runtimeUsers.Done()

	lookup := func(ctx context.Context, _, host string) ([]netip.Addr, error) {
		return dnsRouter.Lookup(ctx, host, adapter.DNSQueryOptions{
			Transport:    dnsTransport,
			DisableCache: true,
		})
	}
	dial := func(ctx context.Context, network, address string) (net.Conn, error) {
		host, rawPort, err := net.SplitHostPort(address)
		if err != nil {
			return nil, fmt.Errorf("remote address is invalid")
		}
		ip, err := netip.ParseAddr(host)
		if err != nil {
			return nil, fmt.Errorf("remote address is invalid")
		}
		port, err := strconv.ParseUint(rawPort, 10, 16)
		if err != nil || port == 0 {
			return nil, fmt.Errorf("remote address is invalid")
		}
		return outbound.DialContext(ctx, network, M.SocksaddrFrom(ip.Unmap(), uint16(port)))
	}
	content, err := subscription.FetchStrictBytesWithNetworkContext(
		runtimeCtx,
		refresh.URL,
		maxNERuleSetBytes,
		lookup,
		dial,
	)
	if err != nil {
		return fmt.Errorf("rule-set refresh failed")
	}
	if refresh.InputFormat == "text" {
		content, err = convertTextRuleSet(content)
		if err != nil {
			return fmt.Errorf("rule-set refresh content is invalid")
		}
	}
	if _, err := validateNERuleSet(content, refresh.StoredFormat, maxNERuleSetBytes); err != nil {
		return fmt.Errorf("rule-set refresh content is invalid")
	}
	if !l.probeGenerationIsCurrent(generation) {
		return fmt.Errorf("connection changed during rule-set refresh")
	}
	if err := writeNERuleSetCache(cleanPath, content); err != nil {
		return err
	}
	return nil
}

func (l *Libbox) probeGenerationIsCurrent(generation uint64) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.running &&
		!l.cleaning &&
		l.boxGeneration == generation &&
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
	return l.start(server, "", username, password, false, "", configJSON)
}

// StartResolved is the NetworkExtension-safe Start variant. dialAddress must
// be the numeric IPv4 resolved before the system default route enters the TUN;
// server is retained separately for TLS certificate validation and HTTP Host.
func (l *Libbox) StartResolved(server, dialAddress, username, password, configJSON string) error {
	return l.start(server, dialAddress, username, password, false, "", configJSON)
}

// StartResolvedWithInsecure 保留数值地址直拨，并把所选线路的显式证书策略带过
// gomobile 边界。旧入口继续使用 false，保持默认验证证书。
func (l *Libbox) StartResolvedWithInsecure(server, dialAddress, username, password string, allowInsecure bool, configJSON string) error {
	return l.start(server, dialAddress, username, password, allowInsecure, "", configJSON)
}

// StartResolvedWithInsecureAndRuntimeIdentity is the switch-capable start
// entrypoint. runtimeIdentity is an opaque capability identity generated by
// Go from the effective AnyConnect Line. It is never logged or returned by
// diagnostics. Legacy start entrypoints intentionally leave it empty, which
// makes cross-generation reuse unavailable rather than guessing from a Line
// ID or from caller-supplied connection fields.
func (l *Libbox) StartResolvedWithInsecureAndRuntimeIdentity(
	server,
	dialAddress,
	username,
	password string,
	allowInsecure bool,
	runtimeIdentity,
	configJSON string,
) error {
	return l.start(
		server,
		dialAddress,
		username,
		password,
		allowInsecure,
		runtimeIdentity,
		configJSON,
	)
}

// StartStandalone starts the NetworkExtension data plane without creating an
// AnyConnect bridge. Direct, proxy, subscription and Tailscale outbounds are
// fully owned by sing-box and therefore do not need tunnel credentials.
func (l *Libbox) StartStandalone(configJSON string) error {
	return l.coldStart(configJSON, nil, "")
}

func (l *Libbox) start(
	server,
	dialAddress,
	username,
	password string,
	allowInsecure bool,
	runtimeIdentity,
	configJSON string,
) error {
	anyConnectConfig := startVPNConfig(
		server,
		dialAddress,
		username,
		password,
		allowInsecure,
	)
	return l.coldStart(configJSON, &anyConnectConfig, runtimeIdentity)
}

// coldStart prepares every potentially blocking Line and sing-box resource
// outside the lifecycle mutex. startPreparationID is the publication token:
// Stop invalidates it and the pool generation while holding l.mu, then waits
// for this function to close any late product before returning.
func (l *Libbox) coldStart(
	configJSON string,
	anyConnectConfig *engine.VPNConfig,
	runtimeIdentity string,
) error {
	l.mu.Lock()
	failLocked := func(code int, err error) error {
		message := err.Error()
		l.lastError = message
		cb := l.cb
		l.mu.Unlock()
		if cb != nil {
			cb.OnError(code, message)
		}
		return err
	}
	if l.cleaning {
		return failLocked(
			ErrCodeState,
			fmt.Errorf("connection cleanup in progress"),
		)
	}
	if l.startPreparing {
		return failLocked(
			ErrCodeState,
			fmt.Errorf("connection start in progress"),
		)
	}
	if l.switchPreparing || l.preparedSwitch != nil ||
		l.switchCommitInProgress || l.retiredSwitch != nil ||
		l.switchRetireInProgress {
		return failLocked(
			ErrCodeState,
			fmt.Errorf("scenario switch in progress"),
		)
	}
	if l.running {
		return failLocked(ErrCodeState, fmt.Errorf("already running"))
	}

	// A new full lifecycle never inherits capability state from an earlier
	// failed Start/retry. Only pool leases, not a startup-time Line list, decide
	// what the detached teardown must reclaim.
	staleLineRuntimes := l.lineRuntimes.detachAll()
	runtimeGeneration := l.nextLineRuntimeGenerationLocked()
	if anyConnectConfig != nil && runtimeIdentity == "" {
		// Legacy Start entrypoints deliberately receive a one-generation-only
		// opaque identity. They cannot accidentally opt into reuse without the
		// generator-produced identity used by the switch-capable entrypoint.
		runtimeIdentity = fmt.Sprintf(
			"unshared-anyconnect-runtime:%d",
			runtimeGeneration,
		)
	}
	if err := l.lineRuntimes.beginCandidate(runtimeGeneration); err != nil {
		return failLocked(ErrCodeState, err)
	}
	preparationID := l.startPreparationID + 1
	if preparationID == 0 {
		preparationID++
	}
	l.startPreparationID = preparationID
	baseCtx, cancel := context.WithCancel(context.Background())
	l.startPreparing = true
	l.startPreparationCancel = cancel
	l.startPreparationUsers.Add(1)
	platform := l.platform
	debugRoutingProbeEnabled := l.debugRoutingProbeEnabled
	l.lastError = ""
	l.dnsJSON = ""
	l.anyConnectDiagnostics = nil
	l.anyConnectLine = nil
	l.anyConnectConfig = engine.VPNConfig{}
	l.anyConnectRuntimeIdentity = ""
	l.mu.Unlock()

	stopLineRuntimeCapabilities(staleLineRuntimes)

	var (
		startErr           error
		startErrorCode     = ErrCodeState
		stateLocks         []*os.File
		capability         *anyConnectRuntimeCapability
		capabilitySnapshot anyConnectRuntimeSnapshot
		instance           *box.Box
		routingProbe       *routingProbeTracker
	)
	if err := baseCtx.Err(); err != nil {
		startErr = err
	}
	if startErr == nil {
		stateLocks, startErr = acquireTailscaleStateLocks(configJSON)
	}
	if startErr == nil && anyConnectConfig != nil {
		startErrorCode = ErrCodeNetwork
		config := *anyConnectConfig
		var pooledCapability lineRuntimeCapability
		pooledCapability, _, startErr = l.lineRuntimes.acquireCandidate(
			runtimeGeneration,
			runtimeIdentity,
			lineRuntimeCapabilityAnyConnect,
			true,
			func() (lineRuntimeCapability, error) {
				return l.createAnyConnectRuntimeCapability(config)
			},
		)
		if startErr == nil {
			var ok bool
			capability, ok = pooledCapability.(*anyConnectRuntimeCapability)
			if !ok || !capability.available() {
				startErr = fmt.Errorf(
					"AnyConnect capability is unavailable",
				)
			} else {
				capabilitySnapshot = capability.snapshot()
			}
		}
	}

	ctx := boxContext(baseCtx)
	if startErr == nil && capability != nil {
		ctx = service.ContextWith[*anyConnectLineRuntime](
			ctx,
			capabilitySnapshot.line,
		)
	}
	ctx = service.ContextWith[adapter.PlatformInterface](
		ctx,
		adapter.PlatformInterface(platform),
	)
	if startErr == nil {
		startErrorCode = ErrCodeConfig
		var options option.Options
		options, startErr = json.UnmarshalExtendedContext[option.Options](
			ctx,
			[]byte(configJSON),
		)
		if startErr != nil {
			startErr = fmt.Errorf("parse sing-box config: %w", startErr)
		} else {
			startErrorCode = ErrCodeEngine
			instance, startErr = box.New(box.Options{
				Options: options,
				Context: ctx,
			})
			if startErr != nil {
				startErr = fmt.Errorf("construct sing-box: %w", startErr)
			} else {
				if debugRoutingProbeEnabled {
					routingProbe = newRoutingProbeTracker()
					instance.Router().AppendTracker(routingProbe)
				}
				if err := instance.Start(); err != nil {
					startErr = fmt.Errorf("start sing-box: %w", err)
				}
			}
		}
	}

	l.mu.Lock()
	preparationIsCurrent := l.startPreparing &&
		l.startPreparationID == preparationID &&
		!l.cleaning && !l.running
	capabilityIsCurrent := anyConnectConfig == nil ||
		(capability != nil && capability.available() &&
			l.lineRuntimes.candidateIs(
				runtimeGeneration,
				runtimeIdentity,
				capability,
			))
	if startErr == nil && preparationIsCurrent && capabilityIsCurrent &&
		l.lineRuntimes.generationIsCandidate(runtimeGeneration) {
		if err := l.lineRuntimes.promoteCandidate(runtimeGeneration); err != nil {
			startErr = err
			startErrorCode = ErrCodeState
		} else {
			l.box = instance
			l.running = true
			l.runtimeCtx = ctx
			l.runtimeCancel = cancel
			l.routingProbe = routingProbe
			l.stateLocks = stateLocks
			l.activeLineRuntimeGeneration = runtimeGeneration
			l.activeAnyConnectCapability = capability
			if capability != nil {
				l.bridge = capabilitySnapshot.bridge
				l.session = capabilitySnapshot.session
				l.anyConnectLine = capabilitySnapshot.line
				l.anyConnectConfig = capabilitySnapshot.config
				l.anyConnectRuntimeIdentity = runtimeIdentity
				l.dnsJSON = capabilitySnapshot.dnsJSON
			} else {
				l.bridge = nil
				l.session = nil
			}
			l.generation++
			l.boxGeneration++
			monitoredGeneration := l.generation
			monitoredSession := l.session
			cb := l.cb
			l.startPreparing = false
			l.startPreparationCancel = nil
			l.startPreparationUsers.Done()
			l.mu.Unlock()

			var monitorReady chan struct{}
			if monitoredSession != nil {
				// The monitor is installed before the connected callback but stays
				// gated until that callback returns. A re-entrant Stop can therefore
				// close the session without emitting a stale failure first.
				monitorReady = make(chan struct{})
				go func() {
					<-monitorReady
					l.monitorSession(monitoredGeneration, monitoredSession)
				}()
			}
			if cb != nil {
				cb.OnStatusChanged(`{"status":"connected"}`)
			}
			if monitorReady != nil {
				close(monitorReady)
			}
			return nil
		}
	}
	if startErr == nil && preparationIsCurrent && !capabilityIsCurrent {
		startErr = fmt.Errorf("AnyConnect capability is unavailable")
		startErrorCode = ErrCodeNetwork
	}
	if startErr == nil && preparationIsCurrent {
		startErr = fmt.Errorf("Line runtime generation is unavailable")
		startErrorCode = ErrCodeState
	}
	notifyFailure := preparationIsCurrent
	if !preparationIsCurrent {
		startErr = fmt.Errorf("connection start canceled: %w", context.Canceled)
	}
	if notifyFailure {
		l.lastError = startErr.Error()
	}
	l.mu.Unlock()

	cancel()
	if instance != nil {
		_ = instance.Close()
	}
	releaseTailscaleStateLocks(stateLocks)
	l.lineRuntimes.releaseCandidate(runtimeGeneration)

	// Keep startPreparing true until every late resource has been closed. This
	// prevents Retry from adding a new preparation while Stop is waiting on the
	// reusable WaitGroup or while the old pool generation is still unwinding.
	l.mu.Lock()
	if l.startPreparing {
		l.startPreparing = false
		l.startPreparationCancel = nil
	}
	cb := l.cb
	l.startPreparationUsers.Done()
	l.mu.Unlock()
	if notifyFailure && cb != nil {
		cb.OnError(startErrorCode, startErr.Error())
	}
	return startErr
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

func (l *Libbox) nextLineRuntimeGenerationLocked() uint64 {
	l.lineRuntimeGeneration++
	if l.lineRuntimeGeneration == 0 {
		l.lineRuntimeGeneration++
	}
	return l.lineRuntimeGeneration
}

func (l *Libbox) createAnyConnectRuntimeCapability(
	config engine.VPNConfig,
) (*anyConnectRuntimeCapability, error) {
	vpnInfo, err := l.vpn.Connect(config)
	if err != nil {
		return nil, fmt.Errorf("anyconnect dial: %w", err)
	}
	dnsServers := anyConnectDNSServers(vpnInfo.DNS)
	if len(dnsServers) == 0 {
		l.vpn.Disconnect()
		return nil, fmt.Errorf("anyconnect did not provide a usable DNS server")
	}
	dnsData, err := stdjson.Marshal(dnsServers)
	if err != nil {
		l.vpn.Disconnect()
		return nil, fmt.Errorf("encode tunnel DNS settings: %w", err)
	}
	bridge, err := engine.NewVPNBridge(vpnInfo.VPNAddress, vpnInfo.MTU)
	if err != nil {
		l.vpn.Disconnect()
		return nil, fmt.Errorf("AnyConnect bridge: %w", err)
	}
	cSess := l.vpn.Session()
	if cSess == nil {
		bridge.Close()
		l.vpn.Disconnect()
		return nil, fmt.Errorf(
			"AnyConnect session ended immediately after connect",
		)
	}
	bridge.Start(cSess)
	return &anyConnectRuntimeCapability{
		vpn:     l.vpn,
		line:    newAnyConnectLineRuntime(bridge, dnsServers),
		bridge:  bridge,
		session: cSess,
		config:  config,
		dnsJSON: string(dnsData),
	}, nil
}

func (l *Libbox) installRoutingProbe(instance *box.Box) *routingProbeTracker {
	if !l.debugRoutingProbeEnabled {
		return nil
	}
	tracker := newRoutingProbeTracker()
	instance.Router().AppendTracker(tracker)
	return tracker
}

// PrepareSwitch starts a complete immutable sing-box configuration beside the
// active generation.  It never changes l.box, l.runtimeCtx, the active bridge,
// or the process-global sslcon session.  A non-empty AnyConnect identity asks
// to borrow the current stable AnyConnect capability; exact equality is the
// only reuse rule.  The caller must use a different ingress listen address for
// the candidate and must probe it before CommitPreparedSwitch.
//
// Tailscale state ownership remains protected by acquireTailscaleStateLocks.
// Consequently a candidate that would create a second endpoint for the active
// state directory is rejected during Prepare while the old generation remains
// untouched.  This is intentional until Tailscale itself has a borrowable
// runtime capability.
func (l *Libbox) PrepareSwitch(
	configJSON,
	anyConnectRuntimeIdentity,
	networkInterfacesJSON,
	defaultInterfaceName string,
	defaultInterfaceIndex int,
) error {
	return l.prepareSwitch(
		configJSON,
		"",
		anyConnectRuntimeIdentity,
		nil,
		networkInterfacesJSON,
		defaultInterfaceName,
		defaultInterfaceIndex,
	)
}

// PrepareSwitchWithLineID is the evidence-capable form of PrepareSwitch. The
// Line ID is used only for the redacted reused-Line result; capability lookup
// remains keyed solely by the opaque runtime identity.
func (l *Libbox) PrepareSwitchWithLineID(
	configJSON,
	anyConnectLineID,
	anyConnectRuntimeIdentity,
	networkInterfacesJSON,
	defaultInterfaceName string,
	defaultInterfaceIndex int,
) error {
	if anyConnectRuntimeIdentity != "" &&
		strings.TrimSpace(anyConnectLineID) == "" {
		return fmt.Errorf("AnyConnect Line ID is required")
	}
	return l.prepareSwitch(
		configJSON,
		strings.TrimSpace(anyConnectLineID),
		anyConnectRuntimeIdentity,
		nil,
		networkInterfacesJSON,
		defaultInterfaceName,
		defaultInterfaceIndex,
	)
}

// PrepareSwitchWithAnyConnect is the make-before-break entrypoint for a
// target generation that needs AnyConnect. When the active generation owns an
// exactly matching capability, the supplied connection fields are not dialed
// and the stable Line handle is borrowed. When the active generation has no
// AnyConnect capability, the candidate dials and owns a private bridge/session
// until commit. A different active identity is rejected because sslcon is a
// process-global singleton and cannot safely host two independent sessions.
func (l *Libbox) PrepareSwitchWithAnyConnect(
	server,
	dialAddress,
	username,
	password string,
	allowInsecure bool,
	anyConnectRuntimeIdentity,
	configJSON,
	networkInterfacesJSON,
	defaultInterfaceName string,
	defaultInterfaceIndex int,
) error {
	if anyConnectRuntimeIdentity == "" {
		return fmt.Errorf("AnyConnect runtime identity is required")
	}
	targetConfig := startVPNConfig(
		server,
		dialAddress,
		username,
		password,
		allowInsecure,
	)
	return l.prepareSwitch(
		configJSON,
		"",
		anyConnectRuntimeIdentity,
		&targetConfig,
		networkInterfacesJSON,
		defaultInterfaceName,
		defaultInterfaceIndex,
	)
}

// PrepareSwitchWithAnyConnectAndLineID is the evidence-capable form of
// PrepareSwitchWithAnyConnect. It reports the supplied non-secret Line ID only
// when the pool actually reused the existing opaque identity.
func (l *Libbox) PrepareSwitchWithAnyConnectAndLineID(
	server,
	dialAddress,
	username,
	password string,
	allowInsecure bool,
	anyConnectLineID,
	anyConnectRuntimeIdentity,
	configJSON,
	networkInterfacesJSON,
	defaultInterfaceName string,
	defaultInterfaceIndex int,
) error {
	if strings.TrimSpace(anyConnectLineID) == "" {
		return fmt.Errorf("AnyConnect Line ID is required")
	}
	if anyConnectRuntimeIdentity == "" {
		return fmt.Errorf("AnyConnect runtime identity is required")
	}
	targetConfig := startVPNConfig(
		server,
		dialAddress,
		username,
		password,
		allowInsecure,
	)
	return l.prepareSwitch(
		configJSON,
		strings.TrimSpace(anyConnectLineID),
		anyConnectRuntimeIdentity,
		&targetConfig,
		networkInterfacesJSON,
		defaultInterfaceName,
		defaultInterfaceIndex,
	)
}

func (l *Libbox) prepareSwitch(
	configJSON,
	anyConnectLineID,
	anyConnectRuntimeIdentity string,
	targetAnyConnectConfig *engine.VPNConfig,
	networkInterfacesJSON,
	defaultInterfaceName string,
	defaultInterfaceIndex int,
) error {
	l.mu.Lock()
	if !l.running || l.box == nil || l.runtimeCtx == nil {
		l.mu.Unlock()
		return fmt.Errorf("connection is not running")
	}
	if l.cleaning || l.switchCommitInProgress {
		l.mu.Unlock()
		return fmt.Errorf("connection cleanup in progress")
	}
	if l.switchPreparing || l.preparedSwitch != nil {
		l.mu.Unlock()
		return fmt.Errorf("switch preparation already in progress")
	}
	if l.retiredSwitch != nil || l.switchRetireInProgress {
		l.mu.Unlock()
		return fmt.Errorf("previous committed switch has not been retired")
	}

	usesAnyConnect := anyConnectRuntimeIdentity != ""
	sourceGeneration := l.boxGeneration
	sourceLineRuntimeGeneration := l.activeLineRuntimeGeneration
	sourceAnyConnectCapability := l.activeAnyConnectCapability
	sourcePlatform := l.platform
	candidatePlatform, err := sourcePlatform.switchCandidate(
		networkInterfacesJSON,
		defaultInterfaceName,
		defaultInterfaceIndex,
	)
	if err != nil {
		l.mu.Unlock()
		return fmt.Errorf("switch Underlay snapshot: %w", err)
	}
	preparationID := l.switchPreparationID + 1
	l.switchPreparationID = preparationID
	candidateLineRuntimeGeneration := l.nextLineRuntimeGenerationLocked()
	if err := l.lineRuntimes.beginCandidate(
		candidateLineRuntimeGeneration,
	); err != nil {
		l.mu.Unlock()
		return err
	}
	l.switchPreparing = true
	baseCtx, cancel := context.WithCancel(context.Background())
	l.switchPreparationCancel = cancel
	debugRoutingProbeEnabled := l.debugRoutingProbeEnabled
	// Stop cancels preparation and waits for this borrower before it closes any
	// Box or invokes the pool-wide StopAll teardown boundary.
	l.switchPreparationUsers.Add(1)
	l.mu.Unlock()
	defer l.switchPreparationUsers.Done()

	var candidate *preparedBoxSwitch
	var candidateAnyConnect *anyConnectRuntimeCapability
	reusesAnyConnect := false
	var reusedLineIDs []string
	stateLocks, err := acquireTailscaleStateLocks(configJSON)
	if err == nil && usesAnyConnect {
		var factory func() (lineRuntimeCapability, error)
		if targetAnyConnectConfig != nil {
			config := *targetAnyConnectConfig
			factory = func() (lineRuntimeCapability, error) {
				return l.createAnyConnectRuntimeCapability(config)
			}
		}
		var pooled lineRuntimeCapability
		pooled, reusesAnyConnect, err = l.lineRuntimes.acquireCandidate(
			candidateLineRuntimeGeneration,
			anyConnectRuntimeIdentity,
			lineRuntimeCapabilityAnyConnect,
			true,
			factory,
		)
		if errors.Is(err, errLineRuntimeExclusive) {
			err = fmt.Errorf("AnyConnect runtime identity is not reusable")
		}
		if err == nil {
			var ok bool
			candidateAnyConnect, ok = pooled.(*anyConnectRuntimeCapability)
			if !ok || !candidateAnyConnect.available() {
				err = fmt.Errorf("AnyConnect capability is unavailable")
			} else if reusesAnyConnect && anyConnectLineID != "" {
				reusedLineIDs = []string{anyConnectLineID}
			}
		}
	}

	ctx := boxContext(baseCtx)
	if usesAnyConnect && err == nil {
		ctx = service.ContextWith[*anyConnectLineRuntime](
			ctx,
			candidateAnyConnect.snapshot().line,
		)
	}
	ctx = service.ContextWith[adapter.PlatformInterface](
		ctx,
		adapter.PlatformInterface(candidatePlatform),
	)

	if err == nil {
		var options option.Options
		options, err = json.UnmarshalExtendedContext[option.Options](
			ctx,
			[]byte(configJSON),
		)
		if err != nil {
			err = fmt.Errorf("parse switch sing-box config: %w", err)
		}
		if err == nil {
			err = prepareSwitchCacheFile(&options)
		}
		if err == nil {
			var instance *box.Box
			instance, err = box.New(box.Options{
				Options: options,
				Context: ctx,
			})
			if err != nil {
				err = fmt.Errorf("construct switch sing-box: %w", err)
			} else {
				var routingProbe *routingProbeTracker
				if debugRoutingProbeEnabled {
					routingProbe = newRoutingProbeTracker()
					instance.Router().AppendTracker(routingProbe)
				}
				if startErr := instance.Start(); startErr != nil {
					_ = instance.Close()
					err = fmt.Errorf(
						"start switch sing-box: %w",
						startErr,
					)
				} else {
					candidate = &preparedBoxSwitch{
						box:                       instance,
						platform:                  candidatePlatform,
						runtimeCtx:                ctx,
						runtimeCancel:             cancel,
						routingProbe:              routingProbe,
						stateLocks:                stateLocks,
						lineRuntimeGeneration:     candidateLineRuntimeGeneration,
						usesAnyConnect:            usesAnyConnect,
						anyConnectRuntimeIdentity: anyConnectRuntimeIdentity,
						anyConnectCapability:      candidateAnyConnect,
						reusedLineIDs:             reusedLineIDs,
					}
				}
			}
		}
	}
	if candidate == nil {
		cancel()
		releaseTailscaleStateLocks(stateLocks)
		l.lineRuntimes.releaseCandidate(candidateLineRuntimeGeneration)
	}

	l.mu.Lock()
	preparationIsCurrent :=
		l.switchPreparing &&
			l.switchPreparationID == preparationID
	// Only one preparation may exist at a time. Abort invalidates its ID but
	// deliberately leaves switchPreparing set until this goroutine has
	// finished closing anything that Start managed to construct. This prevents
	// a new Start or Prepare from racing the cancelled candidate.
	if l.switchPreparing {
		l.switchPreparing = false
		l.switchPreparationCancel = nil
	}
	activeIsUnchanged :=
		preparationIsCurrent &&
			l.running &&
			!l.cleaning &&
			!l.switchCommitInProgress &&
			l.boxGeneration == sourceGeneration &&
			l.activeLineRuntimeGeneration == sourceLineRuntimeGeneration &&
			l.platform == sourcePlatform &&
			(!reusesAnyConnect ||
				(l.activeAnyConnectCapability ==
					candidateAnyConnect &&
					candidateAnyConnect.available() &&
					l.anyConnectRuntimeIdentity ==
						anyConnectRuntimeIdentity &&
					l.lineRuntimes.committedIs(
						sourceLineRuntimeGeneration,
						anyConnectRuntimeIdentity,
						candidateAnyConnect,
					))) &&
			(!usesAnyConnect ||
				l.lineRuntimes.candidateIs(
					candidateLineRuntimeGeneration,
					anyConnectRuntimeIdentity,
					candidateAnyConnect,
				)) &&
			(!usesAnyConnect || reusesAnyConnect ||
				sourceAnyConnectCapability == nil)
	if err == nil && candidate != nil && activeIsUnchanged {
		l.preparedSwitch = candidate
		l.mu.Unlock()
		return nil
	}
	l.mu.Unlock()

	if candidate != nil {
		l.closePreparedSwitch(candidate)
	}
	if err != nil {
		return err
	}
	return fmt.Errorf("connection changed during switch preparation")
}

// prepareSwitchCacheFile keeps the candidate from opening the active Box's
// bbolt cache file. The Transparent Proxy generator materializes remote
// RuleSets before Box startup, does not expose Clash API state, and keeps
// fake-IP/RDRC/DNS persistence disabled, so its enabled cache service carries
// no required state and may be omitted from the immutable candidate.
//
// If persistent cache semantics are introduced later, silently disabling them
// would make the committed generation differ from its configuration. Reject
// that candidate instead; a future design must give such state an explicit
// generation-scoped ownership and migration contract.
func prepareSwitchCacheFile(options *option.Options) error {
	if options == nil || options.Experimental == nil ||
		options.Experimental.CacheFile == nil ||
		!options.Experimental.CacheFile.Enabled {
		return nil
	}
	cache := options.Experimental.CacheFile
	if cache.StoreFakeIP || cache.StoreRDRC || cache.StoreDNS {
		return fmt.Errorf(
			"switch cache-file persistence requires generation-scoped ownership",
		)
	}
	if options.Experimental.ClashAPI != nil {
		return fmt.Errorf(
			"switch cache-file Clash API state requires generation-scoped ownership",
		)
	}
	if options.Route != nil {
		for _, ruleSet := range options.Route.RuleSet {
			if ruleSet.Type == C.RuleSetTypeRemote {
				return fmt.Errorf(
					"switch remote rule-set cache requires generation-scoped ownership",
				)
			}
		}
	}
	cache.Enabled = false
	return nil
}

// PreparedSwitchReusedLineIDs returns redacted reuse evidence for the current
// unpublished candidate. It contains only caller-supplied Line IDs whose
// opaque identities actually reused a pool capability; identities, tags,
// endpoints and credentials never cross this API.
func (l *Libbox) PreparedSwitchReusedLineIDs() (string, error) {
	l.mu.Lock()
	candidate := l.preparedSwitch
	if candidate == nil || l.switchCommitInProgress {
		l.mu.Unlock()
		return "", fmt.Errorf("switch candidate is not prepared")
	}
	reusedLineIDs := append([]string(nil), candidate.reusedLineIDs...)
	l.mu.Unlock()
	if reusedLineIDs == nil {
		reusedLineIDs = []string{}
	}
	encoded, err := stdjson.Marshal(reusedLineIDs)
	if err != nil {
		return "", fmt.Errorf("encode reused Line evidence: %w", err)
	}
	return string(encoded), nil
}

func preparedAnyConnectSessionAlive(cSess *session.ConnSession) bool {
	if cSess == nil {
		return false
	}
	select {
	case <-cSess.CloseChan:
		return false
	default:
		return true
	}
}

// ProbePreparedSwitchOutboundIP applies the same fixed-endpoint readiness
// contract as ProbeOutboundIP, but borrows only the unpublished candidate.
// A stale result is rejected if the candidate is aborted or committed while
// the request is in flight.
func (l *Libbox) ProbePreparedSwitchOutboundIP(
	outboundTag string,
	timeoutMS int,
) (string, error) {
	l.mu.Lock()
	candidate := l.preparedSwitch
	if candidate == nil || candidate.box == nil ||
		candidate.runtimeCtx == nil || l.switchCommitInProgress {
		l.mu.Unlock()
		return "", fmt.Errorf("switch candidate is not prepared")
	}
	if timeoutMS < 500 {
		timeoutMS = 500
	}
	if timeoutMS > 10_000 {
		timeoutMS = 10_000
	}
	outbound, loaded := candidate.box.Outbound().Outbound(outboundTag)
	if !loaded {
		l.mu.Unlock()
		return "", fmt.Errorf("switch probe outbound is unavailable")
	}
	ctx, cancel := context.WithTimeout(
		candidate.runtimeCtx,
		time.Duration(timeoutMS)*time.Millisecond,
	)
	probe := l.probeOutboundAddressFunc
	if probe == nil {
		probe = probeOutboundAddress
	}
	l.switchCandidateUsers.Add(1)
	l.mu.Unlock()
	defer l.switchCandidateUsers.Done()
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
			if !l.preparedSwitchIsCurrent(candidate) {
				return "", fmt.Errorf(
					"switch candidate changed during outbound address probe",
				)
			}
			return address, nil
		}
		probeErrors = append(probeErrors, err.Error())
	}
	if !l.preparedSwitchIsCurrent(candidate) {
		return "", fmt.Errorf(
			"switch candidate changed during outbound address probe",
		)
	}
	return "", fmt.Errorf(
		"switch outbound address probe failed: %s",
		strings.Join(probeErrors, "; "),
	)
}

func (l *Libbox) preparedSwitchIsCurrent(
	candidate *preparedBoxSwitch,
) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.running &&
		!l.cleaning &&
		!l.switchCommitInProgress &&
		l.preparedSwitch == candidate
}

// AbortPreparedSwitch cancels an in-flight preparation or destroys an already
// prepared candidate.  It never closes the active Box, bridge, or sslcon
// session.
func (l *Libbox) AbortPreparedSwitch() error {
	l.mu.Lock()
	if l.switchCommitInProgress || l.retiredSwitch != nil ||
		l.switchRetireInProgress {
		l.mu.Unlock()
		return fmt.Errorf("switch is already committed")
	}
	if l.switchPreparing {
		// Cancellation is cooperative. Invalidate the preparation token as well
		// so even a dependency that returns success after observing cancellation
		// can never publish its candidate.
		l.switchPreparationID++
		if l.switchPreparationCancel != nil {
			l.switchPreparationCancel()
		}
		l.mu.Unlock()
		return nil
	}
	candidate := l.preparedSwitch
	l.preparedSwitch = nil
	l.mu.Unlock()
	if candidate == nil {
		return nil
	}
	l.closePreparedSwitch(candidate)
	return nil
}

func (l *Libbox) closePreparedSwitch(candidate *preparedBoxSwitch) {
	l.switchCleanupMu.Lock()
	defer l.switchCleanupMu.Unlock()
	l.closePreparedSwitchLocked(candidate)
}

func (l *Libbox) closePreparedSwitchLocked(candidate *preparedBoxSwitch) {
	if candidate == nil {
		return
	}
	if candidate.runtimeCancel != nil {
		candidate.runtimeCancel()
	}
	l.switchCandidateUsers.Wait()
	if candidate.box != nil {
		_ = candidate.box.Close()
	}
	releaseTailscaleStateLocks(candidate.stateLocks)
	l.lineRuntimes.releaseCandidate(candidate.lineRuntimeGeneration)
}

// CommitPreparedSwitch atomically adopts the fully validated candidate but
// deliberately retains the source generation. Provider may switch its relay
// generation only after this method succeeds; existing source claims remain
// valid until RetireCommittedSwitch is called after bounded drain/cancel.
// Candidate and source capabilities are validated once before the adoption
// barrier and again after all pre-barrier borrowers drain. A session may close
// while Commit waits, so the second check is required before any ownership move.
func (l *Libbox) CommitPreparedSwitch() error {
	l.mu.Lock()
	candidate := l.preparedSwitch
	if candidate == nil || candidate.box == nil {
		l.mu.Unlock()
		return fmt.Errorf("switch candidate is not prepared")
	}
	if l.switchPreparing || l.cleaning || l.switchCommitInProgress ||
		l.switchRetireInProgress || l.retiredSwitch != nil ||
		!l.running || l.box == nil {
		l.mu.Unlock()
		return fmt.Errorf("switch cannot commit in the current state")
	}
	if err := l.validatePreparedSwitchCommitLocked(candidate); err != nil {
		l.mu.Unlock()
		return err
	}
	sourceBox := l.box
	sourcePlatform := l.platform
	sourceRuntimeCtx := l.runtimeCtx
	sourceRuntimeCancel := l.runtimeCancel
	sourceStateLocks := l.stateLocks
	sourceLineRuntimeGeneration := l.activeLineRuntimeGeneration
	sourceAnyConnectCapability := l.activeAnyConnectCapability
	sourceAnyConnectRuntimeIdentity := l.anyConnectRuntimeIdentity

	l.switchCommitInProgress = true
	l.switchCommitDone = make(chan struct{})
	l.preparedSwitch = nil
	l.mu.Unlock()

	// Add is forbidden by switchCommitInProgress under l.mu, so both WaitGroups
	// contain only operations issued before commit. Draining them before the
	// ownership swap lets the zero-valued groups be reused by the new active
	// generation while the source Box itself remains alive for relay flows.
	l.switchCandidateUsers.Wait()
	l.runtimeUsers.Wait()

	l.mu.Lock()
	if l.box != sourceBox || l.platform != sourcePlatform ||
		l.runtimeCtx != sourceRuntimeCtx ||
		l.activeLineRuntimeGeneration != sourceLineRuntimeGeneration ||
		l.activeAnyConnectCapability != sourceAnyConnectCapability ||
		l.anyConnectRuntimeIdentity != sourceAnyConnectRuntimeIdentity ||
		!sameStateLockFiles(l.stateLocks, sourceStateLocks) {
		l.restorePreparedSwitchAfterCommitFailureLocked(candidate)
		l.mu.Unlock()
		return fmt.Errorf("connection changed during switch commit")
	}
	if err := l.validatePreparedSwitchCommitLocked(candidate); err != nil {
		l.restorePreparedSwitchAfterCommitFailureLocked(candidate)
		l.mu.Unlock()
		return err
	}
	retired := &retiredBoxGeneration{
		box:                   sourceBox,
		runtimeCtx:            sourceRuntimeCtx,
		runtimeCancel:         sourceRuntimeCancel,
		stateLocks:            sourceStateLocks,
		lineRuntimeGeneration: sourceLineRuntimeGeneration,
	}
	if err := l.lineRuntimes.promoteCandidate(
		candidate.lineRuntimeGeneration,
	); err != nil {
		// Leave the source published and make the candidate abortable again.
		l.restorePreparedSwitchAfterCommitFailureLocked(candidate)
		l.mu.Unlock()
		return err
	}

	l.box = candidate.box
	l.platform = candidate.platform
	l.runtimeCtx = candidate.runtimeCtx
	l.runtimeCancel = candidate.runtimeCancel
	l.routingProbe = candidate.routingProbe
	l.stateLocks = candidate.stateLocks
	l.activeLineRuntimeGeneration = candidate.lineRuntimeGeneration
	l.boxGeneration++

	var monitoredSession *session.ConnSession
	var monitoredGeneration uint64
	previousAnyConnect := l.activeAnyConnectCapability
	l.activeAnyConnectCapability = candidate.anyConnectCapability
	if candidate.anyConnectCapability != nil {
		snapshot := candidate.anyConnectCapability.snapshot()
		l.bridge = snapshot.bridge
		l.session = snapshot.session
		l.anyConnectLine = snapshot.line
		l.anyConnectConfig = snapshot.config
		l.anyConnectRuntimeIdentity = candidate.anyConnectRuntimeIdentity
		l.dnsJSON = snapshot.dnsJSON
		l.anyConnectDiagnostics = nil
		l.lastError = ""
		if previousAnyConnect != candidate.anyConnectCapability {
			l.generation++
			monitoredSession = snapshot.session
			monitoredGeneration = l.generation
		}
	} else {
		if previousAnyConnect != nil {
			l.generation++
		}
		l.bridge = nil
		l.session = nil
		l.dnsJSON = ""
		l.anyConnectLine = nil
		l.anyConnectConfig = engine.VPNConfig{}
		l.anyConnectRuntimeIdentity = ""
		l.anyConnectDiagnostics = nil
		l.lastError = ""
	}
	l.retiredSwitch = retired
	l.switchCommitInProgress = false
	commitDone := l.switchCommitDone
	l.switchCommitDone = nil
	if commitDone != nil {
		close(commitDone)
	}
	l.mu.Unlock()
	if monitoredSession != nil {
		go l.monitorSession(monitoredGeneration, monitoredSession)
	}
	return nil
}

func (l *Libbox) validatePreparedSwitchCommitLocked(
	candidate *preparedBoxSwitch,
) error {
	if candidate == nil || candidate.box == nil ||
		candidate.runtimeCtx == nil || candidate.runtimeCtx.Err() != nil {
		return fmt.Errorf("switch candidate is unavailable before commit")
	}
	if !l.lineRuntimes.generationIsCandidate(
		candidate.lineRuntimeGeneration,
	) {
		return fmt.Errorf("switch candidate Line runtime leases are unavailable")
	}
	if candidate.usesAnyConnect {
		if candidate.anyConnectRuntimeIdentity == "" ||
			candidate.anyConnectCapability == nil ||
			!candidate.anyConnectCapability.available() ||
			!l.lineRuntimes.candidateIs(
				candidate.lineRuntimeGeneration,
				candidate.anyConnectRuntimeIdentity,
				candidate.anyConnectCapability,
			) ||
			(l.activeAnyConnectCapability != nil &&
				l.activeAnyConnectCapability !=
					candidate.anyConnectCapability) {
			return fmt.Errorf(
				"AnyConnect capability is unavailable before commit",
			)
		}
	} else if candidate.anyConnectCapability != nil ||
		candidate.anyConnectRuntimeIdentity != "" {
		return fmt.Errorf("switch candidate Line runtime state is inconsistent")
	}
	if !l.running || l.box == nil || l.runtimeCtx == nil ||
		l.runtimeCtx.Err() != nil || l.activeLineRuntimeGeneration == 0 ||
		!l.lineRuntimes.generationIsCommitted(
			l.activeLineRuntimeGeneration,
		) {
		return fmt.Errorf("source Line runtime leases are unavailable before commit")
	}
	if l.activeAnyConnectCapability != nil &&
		(!l.activeAnyConnectCapability.available() ||
			l.anyConnectRuntimeIdentity == "" ||
			!l.lineRuntimes.committedIs(
				l.activeLineRuntimeGeneration,
				l.anyConnectRuntimeIdentity,
				l.activeAnyConnectCapability,
			)) {
		return fmt.Errorf("source AnyConnect capability is unavailable before commit")
	}
	return nil
}

func (l *Libbox) restorePreparedSwitchAfterCommitFailureLocked(
	candidate *preparedBoxSwitch,
) {
	l.preparedSwitch = candidate
	l.switchCommitInProgress = false
	commitDone := l.switchCommitDone
	l.switchCommitDone = nil
	if commitDone != nil {
		close(commitDone)
	}
}

func sameStateLockFiles(left, right []*os.File) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

// RetireCommittedSwitch closes the source generation retained by the most
// recent successful CommitPreparedSwitch. It is idempotent. Provider calls it
// only after old relay claims have drained or been cancelled; a shared
// AnyConnect capability remains owned by the active generation, whereas an
// old-only capability is disconnected here and never during Commit.
func (l *Libbox) RetireCommittedSwitch() error {
	l.mu.Lock()
	if l.switchCommitInProgress {
		l.mu.Unlock()
		return fmt.Errorf("switch commit in progress")
	}
	if l.switchRetireInProgress {
		done := l.switchRetireDone
		l.mu.Unlock()
		if done != nil {
			<-done
		}
		return nil
	}
	retired := l.retiredSwitch
	if retired == nil {
		l.mu.Unlock()
		return nil
	}
	l.retiredSwitch = nil
	l.switchRetireInProgress = true
	l.switchRetireDone = make(chan struct{})
	l.mu.Unlock()

	l.switchCleanupMu.Lock()
	l.closeRetiredGenerationLocked(retired)
	l.switchCleanupMu.Unlock()

	l.mu.Lock()
	l.switchRetireInProgress = false
	done := l.switchRetireDone
	l.switchRetireDone = nil
	if done != nil {
		close(done)
	}
	l.mu.Unlock()
	return nil
}

func (l *Libbox) closeRetiredGenerationLocked(
	retired *retiredBoxGeneration,
) {
	if retired == nil {
		return
	}
	if retired.runtimeCancel != nil {
		retired.runtimeCancel()
	}
	if retired.box != nil {
		_ = retired.box.Close()
	}
	releaseTailscaleStateLocks(retired.stateLocks)
	l.lineRuntimes.releaseCommitted(retired.lineRuntimeGeneration)
}

func (l *Libbox) Stop() error {
	for {
		l.mu.Lock()
		if !l.switchCommitInProgress {
			break
		}
		commitDone := l.switchCommitDone
		l.mu.Unlock()
		if commitDone == nil {
			return fmt.Errorf("switch commit in progress")
		}
		// Explicit Stop has priority over Switch, but an adoption that already
		// crossed its validation boundary contains no rollback point. Wait for
		// that bounded in-memory adoption, then tear down both active and retained
		// generations in one cleanup transaction.
		<-commitDone
	}
	if !l.running {
		ownsCleaning := false
		if l.startPreparing {
			// Invalidate publication before cancellation. Dependencies are allowed
			// to return success late; the preparer must then close the product
			// instead of publishing it as the active generation.
			l.startPreparationID++
			if l.startPreparationCancel != nil {
				l.startPreparationCancel()
			}
			if !l.cleaning {
				l.cleaning = true
				ownsCleaning = true
			}
		}
		if l.switchPreparationCancel != nil {
			l.switchPreparationCancel()
		}
		detachedLineRuntimes := l.lineRuntimes.detachAll()
		if len(detachedLineRuntimes) != 0 && !l.cleaning {
			l.cleaning = true
			ownsCleaning = true
		}
		l.mu.Unlock()
		// Candidate Boxes may already borrow a capability published by the
		// factory. Let the preparer close those Boxes and state locks before the
		// detached capability is stopped.
		l.startPreparationUsers.Wait()
		l.switchPreparationUsers.Wait()
		stopLineRuntimeCapabilities(detachedLineRuntimes)
		if ownsCleaning {
			l.finishCleaning()
		}
		return nil
	}
	if l.switchPreparationCancel != nil {
		l.switchPreparationCancel()
	}
	candidate := l.preparedSwitch
	l.preparedSwitch = nil
	retired := l.retiredSwitch
	l.retiredSwitch = nil

	instance, stateLocks, detachedLineRuntimes := l.detachRunningLocked()
	cb := l.cb
	l.mu.Unlock()
	defer l.finishCleaning()

	l.switchPreparationUsers.Wait()
	l.switchCleanupMu.Lock()
	defer l.switchCleanupMu.Unlock()
	if candidate != nil {
		l.closePreparedSwitchLocked(candidate)
	}
	if retired != nil {
		l.closeRetiredGenerationLocked(retired)
	}
	l.closeDetached(instance, stateLocks, detachedLineRuntimes)

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

	for {
		l.mu.Lock()
		if l.switchCommitInProgress && l.switchCommitDone != nil {
			commitDone := l.switchCommitDone
			l.mu.Unlock()
			<-commitDone
			continue
		}
		break
	}
	if !l.running || l.cleaning || l.generation != generation || l.session != cSess {
		l.mu.Unlock()
		return
	}
	anyConnectDiagnostics := validAnyConnectDiagnostics(
		engine.AnyConnectSessionDiagnostics(cSess),
	)
	bridge := l.bridge
	line := l.anyConnectLine
	capability := l.activeAnyConnectCapability
	config := l.anyConnectConfig
	runtimeCtx := l.runtimeCtx
	if line == nil || bridge == nil || runtimeCtx == nil ||
		(capability != nil &&
			!capability.deactivate(bridge, cSess)) ||
		(capability == nil && !line.deactivate(bridge)) {
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
		capability,
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
	capability *anyConnectRuntimeCapability,
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
		dnsData, _ := stdjson.Marshal(dnsServers)
		dnsJSON := string(dnsData)
		if capability != nil {
			if l.activeAnyConnectCapability != capability ||
				!capability.activate(
					bridge,
					cSess,
					dnsJSON,
					dnsServers,
				) {
				l.mu.Unlock()
				bridge.Close()
				l.vpn.Disconnect()
				return false
			}
		} else {
			line.activate(bridge, dnsServers)
		}
		l.bridge = bridge
		l.session = cSess
		l.dnsJSON = dnsJSON
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
	if l.switchPreparationCancel != nil {
		l.switchPreparationCancel()
	}
	candidate := l.preparedSwitch
	l.preparedSwitch = nil
	retired := l.retiredSwitch
	l.retiredSwitch = nil
	instance, stateLocks, detachedLineRuntimes := l.detachRunningLocked()
	cb := l.cb
	l.mu.Unlock()
	defer l.finishCleaning()

	l.switchPreparationUsers.Wait()
	l.switchCleanupMu.Lock()
	defer l.switchCleanupMu.Unlock()
	if candidate != nil {
		l.closePreparedSwitchLocked(candidate)
	}
	if retired != nil {
		l.closeRetiredGenerationLocked(retired)
	}
	l.closeDetached(instance, stateLocks, detachedLineRuntimes)
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
func (l *Libbox) detachRunningLocked() (
	*box.Box,
	[]*os.File,
	[]lineRuntimeCapability,
) {
	instance := l.box
	stateLocks := l.stateLocks
	detachedLineRuntimes := l.lineRuntimes.detachAll()
	l.box = nil
	l.bridge = nil
	l.anyConnectLine = nil
	l.anyConnectConfig = engine.VPNConfig{}
	l.anyConnectRuntimeIdentity = ""
	l.activeAnyConnectCapability = nil
	l.activeLineRuntimeGeneration = 0
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
	l.boxGeneration++
	l.cleaning = true
	return instance, stateLocks, detachedLineRuntimes
}

func (l *Libbox) closeDetached(
	instance *box.Box,
	stateLocks []*os.File,
	detachedLineRuntimes []lineRuntimeCapability,
) {
	// detachRunningLocked cancels runtimeCtx before reaching this wait. A
	// well-behaved probe therefore exits promptly, while this barrier prevents
	// Box.Close (and VPNBridge.Close for the vpn outbound) from racing the
	// borrowed adapter.Outbound.
	l.runtimeUsers.Wait()
	if instance != nil {
		instance.Close()
	}
	releaseTailscaleStateLocks(stateLocks)
	stopLineRuntimeCapabilities(detachedLineRuntimes)
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
