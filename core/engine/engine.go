package engine

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"log/slog"
	"net"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/things-go/go-socks5"

	"github.com/kafeifei/xdial/core/config"
	"sslcon/session"
)

const (
	maxReconnectAttempts      = 3
	stableConnectionThreshold = 60 * time.Second
)

// dnsSelfHealInterval 是周期自愈的 tick 间隔。
//
// 为什么需要它：恢复的软失败出口（服务还在、只是当前被禁用）故意不报错、不排后台重试
// ——报错会引来重试风暴，而那些条目本来就大概率写不进去。代价是它们只能等"下次 daemon
// 启动"，而 daemon 由 launchd KeepAlive 托管，可能几星期都不重启一次。那几星期里，用户
// 把 iPhone USB / 某块网卡重新启用的那一刻起，这个服务就带着一个指向已消失 tun 的 DNS
// 继续跑，没有任何路径去救它。
//
// 5 分钟是这样定的：没有残留文件时一个 tick 只花一次 stat（零外部命令、零系统状态变更），
// 所以密一点没有成本；而有残留时用户能等的极限大约就是这个量级。
const dnsSelfHealInterval = 5 * time.Minute

type Engine struct {
	mu      sync.Mutex
	status  Status
	vpn     *VPNClient
	bridge  *VPNBridge
	socks   *socks5.Server
	socksLn net.Listener
	singbox *SingBoxProcess
	dns     *dnsTakeover
	// allowDNSTakeover 见 AllowSystemDNSTakeover：默认关闭，只有 daemon 打开。
	allowDNSTakeover bool
	callback         StatusCallback
	cancel           context.CancelFunc
	basePath         string
	statePath        string
	profile          *config.Profile
	reconnectCount   int

	// 周期 DNS 自愈的句柄（见 StartDNSSelfHeal）。Close 时取消并等它真正退出。
	dnsSelfHealCancel context.CancelFunc
	dnsSelfHealDone   chan struct{}
	// dnsSelfHealInterval 可注入，零值表示用 dnsSelfHealInterval 常量。单测不可能真等
	// 5 分钟。
	dnsSelfHealEvery time.Duration
}

func New(basePath, statePath string, cb StatusCallback) *Engine {
	return &Engine{
		vpn:       NewVPNClient(),
		dns:       newDNSTakeover(statePath),
		callback:  cb,
		basePath:  basePath,
		statePath: statePath,
	}
}

// AllowSystemDNSTakeover 决定这个引擎实例是否允许接管系统 DNS。默认关闭，只有
// daemon 打开。
//
// 接管改的是系统全局状态，所以只有"进程被 kill -9 之后还有自愈入口"的宿主才配拥
// 有它：daemon 由 launchd KeepAlive 拉起，启动第一件事就是 RestoreLeftoverDNS。
// CLI（xdial start）是前台调试工具，没人托管它，被 kill -9 就永远没有第二次机会把
// 系统 DNS 从已消失的 tun 上救回来——那是整机断网，代价远超"分流更准"这点收益。
func (e *Engine) AllowSystemDNSTakeover(allow bool) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.allowDNSTakeover = allow
}

// Close 是进程退出前的收尾：停掉周期 DNS 自愈、取消 DNS 恢复的后台重试。此刻要么已经
// 恢复成功，要么状态文件还在（下次 daemon 启动会再自愈），这两个 goroutine 都没有继续
// 存在的意义。
//
// 自愈 goroutine 要等它真正退出再返回：它会发 networksetup，让它跑在进程退出之后等于
// 把系统 DNS 的改动扔进一个没人再观测的窗口。等之前必须先放开 e.mu —— goroutine 自己
// 要拿这把锁读状态。
func (e *Engine) Close() {
	e.mu.Lock()
	cancel, done := e.dnsSelfHealCancel, e.dnsSelfHealDone
	e.dnsSelfHealCancel, e.dnsSelfHealDone = nil, nil
	e.mu.Unlock()

	if cancel != nil {
		cancel()
		<-done
	}
	if e.dns != nil {
		e.dns.Close()
	}
}

// RestoreLeftoverDNS 在 daemon 启动时自愈上一次没恢复干净的系统 DNS 接管
// （daemon 被 SIGKILL、崩溃、掉电）。必须在开始服务请求之前调用：残留状态下整机
// 解析是死的，用户连点"连接"所需的网络都没有。
func (e *Engine) RestoreLeftoverDNS() {
	e.mu.Lock()
	status := e.status
	e.mu.Unlock()
	// 引擎已经在连接态说明这份接管是当前生效的，不是残留。
	if status != StatusDisconnected {
		return
	}
	if err := e.dns.RestoreLeftover(); err != nil {
		slog.Error("restore leftover system DNS failed", "err", err)
	}
	e.reportDNSPending()
}

// StartDNSSelfHeal 起一个常驻的周期自愈 goroutine（间隔见 dnsSelfHealInterval）。只有
// daemon 该调用它 —— 判据和 AllowSystemDNSTakeover 一样：只有受 launchd 托管、被 kill -9
// 之后还会被拉起来的宿主才配碰系统全局状态。
//
// 每个 tick 干两件事：引擎处于断开态时跑一次 SelfHealLeftover（没有残留文件的话只是一次
// stat），然后把首次出现的软失败条目上报给用户一次。
//
// 幂等：已经起过就直接返回，绝不留下两个 goroutine 同时发 networksetup。
//
// 关于"新接管时是否该取消"：故意不取消。取消掉之后没有任何路径会把它重新拉起来，daemon
// 余下的整个生命周期就再没有周期自愈了。而它也不可能推翻一个新接管 —— SelfHealLeftover
// 的 !active 闸门和 restoreLocked 在同一把 t.mu 之内完成，Takeover 也持同一把锁，两者被
// 串成前后关系，中间不存在可插入的窗口（见 SelfHealLeftover 注释）。
func (e *Engine) StartDNSSelfHeal() {
	e.mu.Lock()
	if e.dnsSelfHealCancel != nil {
		e.mu.Unlock()
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	e.dnsSelfHealCancel = cancel
	e.dnsSelfHealDone = done
	interval := orDuration(e.dnsSelfHealEvery, dnsSelfHealInterval)
	e.mu.Unlock()

	go func() {
		defer close(done)
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
			e.selfHealDNSOnce()
		}
	}()
}

// selfHealDNSOnce 是一个 tick 的全部工作。每次调用各自走 restoreLocked 里那份 15 秒总
// 预算，所以一个卡死的 networksetup 最坏只能拖住这一个 tick。
func (e *Engine) selfHealDNSOnce() {
	e.mu.Lock()
	status := e.status
	e.mu.Unlock()
	// 连接态下这份接管是当前生效的，不是残留。这只是省掉一次 stat 的粗筛，真正防住
	// "刚接管就被自愈推翻"的是 SelfHealLeftover 锁内的 !active 闸门。
	if status != StatusDisconnected {
		return
	}
	if err := e.dns.SelfHealLeftover(); err != nil {
		slog.Error("periodic system DNS self-heal failed", "err", err)
	}
	e.reportDNSPending()
}

// reportDNSPending 把首次出现的软失败条目上报一次。这些服务当前被禁用，写不回去；用户
// 不知道的话，重新启用它的那一刻就带着一个指向已消失 tun 的 DNS 上线。
//
// 故意不持 e.mu：takeNewPendingSoftFailures 要拿 t.mu，而这个包里所有正常路径都是先
// e.mu 再 t.mu（takeoverDNSLocked / cleanupLocked），在这里反序取锁就是 AB-BA 死锁。
// e.callback 只在 New 里赋值、此后只读，不需要锁保护。
func (e *Engine) reportDNSPending() {
	if e.callback == nil || e.dns == nil {
		return
	}
	pending := e.dns.takeNewPendingSoftFailures()
	if len(pending) == 0 {
		return
	}
	e.callback.OnError(2, "以下网络服务当前被禁用，系统 DNS 尚未恢复，重新启用后会自动收拾："+strings.Join(pending, ", "))
}

func (e *Engine) Start(profile *config.Profile) error {
	e.mu.Lock()
	defer e.mu.Unlock()

	if e.status == StatusConnected || e.status == StatusConnecting || e.status == StatusReconnecting {
		return fmt.Errorf("already %s", e.status)
	}

	e.profile = profile
	e.reconnectCount = 0
	e.setStatus(StatusConnecting)

	ctx, cancel := context.WithCancel(context.Background())
	e.cancel = cancel

	go e.connect(ctx, profile)
	return nil
}

// ResetTailscaleState 清除本机 tailnet 身份（state 目录），下次连接时用当前
// auth key 重新注册为一台新设备。
//
// D29 之后 Tailscale 是纯参数线路：auth key 只是 Line 上的一个字段，引擎不再
// 持有任何 tsnet 会话，也就无从向控制面发注销请求。这里只做本地清除——换 auth
// key / 换 tailnet 时必须有这一步，否则 sing-box 会直接复用已登录的旧 state，
// 新填的 key 根本不会生效。控制面里那条旧设备记录需要用户自己在后台删。
//
// 身份是全局单份的，所以清除会让所有 Tailscale 线路一并重新注册。
//
// 要求先断开：state 目录正被运行中的 sing-box 打开，边跑边删是在拆自己脚下的
// 地板。这不是 Line 溢出到状态机，而是"别删正在用的文件"。
func (e *Engine) ResetTailscaleState() error {
	e.mu.Lock()
	defer e.mu.Unlock()

	if e.status != StatusDisconnected {
		return fmt.Errorf("请先断开 XDial，再清除 Tailscale 本机状态")
	}
	if err := os.RemoveAll(config.TailscaleStateDirectory(e.statePath)); err != nil {
		return fmt.Errorf("清除 Tailscale 本机状态: %w", err)
	}
	return nil
}

func (e *Engine) connect(ctx context.Context, profile *config.Profile) {
	if err := e.connectInternal(ctx, profile); err != nil {
		// ctx 被取消 = 用户主动断开，Stop 已把状态置为 Disconnected，不再报错
		if ctx.Err() != nil {
			return
		}
		e.fail(err.Error())
	}
}

func (e *Engine) connectInternal(ctx context.Context, profile *config.Profile) error {
	vpnLine := profile.ActiveVPNLine()
	var bridge *VPNBridge
	var socksAddr string
	var vpnServerIP string
	var enterpriseDNS []string
	var closeCh chan struct{}

	if vpnLine != nil {
		if vpnLine.VPNServer == "" {
			return fmt.Errorf("AnyConnect 服务器地址未填写")
		}
		if vpnLine.VPNUsername == "" || vpnLine.VPNPassword == "" {
			return fmt.Errorf("AnyConnect 用户名或密码未填写")
		}

		slog.Info("connecting to VPN", "server", vpnLine.VPNServer)
		vpnInfo, err := e.vpn.Connect(VPNConfig{
			Server:        vpnLine.VPNServer,
			Username:      vpnLine.VPNUsername,
			Password:      vpnLine.VPNPassword,
			AllowInsecure: vpnLine.AllowInsecure,
		})
		if err != nil {
			return fmt.Errorf("%s", humanizeVPNError(err, vpnLine.VPNServer))
		}
		if ctx.Err() != nil {
			e.vpn.Disconnect()
			return ctx.Err()
		}

		slog.Info("VPN connected", "addr", vpnInfo.VPNAddress, "dns", vpnInfo.DNS)
		bridge, err = NewVPNBridge(vpnInfo.VPNAddress, vpnInfo.MTU)
		if err != nil {
			e.vpn.Disconnect()
			return fmt.Errorf("AnyConnect 隧道初始化失败")
		}
		cSess := e.vpn.Session()
		if cSess == nil {
			bridge.Close()
			e.vpn.Disconnect()
			return fmt.Errorf("AnyConnect 会话已断开")
		}
		bridge.Start(cSess)
		closeCh = cSess.CloseChan

		socksAddr, err = e.startSOCKS(bridge)
		if err != nil {
			bridge.Close()
			e.vpn.Disconnect()
			return fmt.Errorf("本地代理启动失败")
		}
		vpnServerIP = vpnInfo.ServerAddr
		// 服务端下发的企业 DNS：绑定到该 VPN 的内网域名要经隧道向它查询。
		enterpriseDNS = vpnInfo.DNS
		slog.Info("SOCKS5 proxy ready", "addr", socksAddr)
	}

	// releasePartial 回收"隧道已建、sing-box 还没起"这半程持有的资源。
	releasePartial := func() {
		if e.socksLn != nil {
			e.socksLn.Close()
			e.socksLn = nil
		}
		if bridge != nil {
			bridge.Close()
			e.vpn.Disconnect()
		}
	}

	// 远程规则集必须在 sing-box 之前落成本地文件：首次下载失败会让 router 在
	// 启动阶段直接 FATAL，而它自己能用的下载出口覆盖不到 Tailscale / vpn / direct
	// 这几类绑定（详见 prepareRuleSets）。
	prefetchCtx, cancelPrefetch := context.WithTimeout(ctx, ruleSetPrepareBudget)
	prepared, ruleSetProblems := prepareRuleSets(
		prefetchCtx,
		profile,
		ruleSetCacheDirectory(e.statePath),
		newRuleSetFetcher(bridge, enterpriseDNS),
	)
	cancelPrefetch()
	if ctx.Err() != nil {
		// 用户在预取期间点了断开：ruleSetProblems 只是被取消的副产物，不必上报。
		releasePartial()
		return ctx.Err()
	}
	for _, problem := range ruleSetProblems {
		slog.Error("rule set unavailable", "detail", problem)
		if e.callback != nil {
			// 用非致命码：连接照常建立，只是少了这条规则，用户需要知道。
			e.callback.OnError(2, problem)
		}
	}

	singbox := NewSingBoxProcess(e.basePath, e.statePath, e.handleSingBoxExit)
	if err := singbox.Start(prepared, socksAddr, vpnServerIP, enterpriseDNS); err != nil {
		releasePartial()
		return fmt.Errorf("sing-box 启动失败: %w", err)
	}

	e.mu.Lock()
	e.bridge = bridge
	e.singbox = singbox
	// 提交前在锁内复查取消信号：连接建立期间用户可能已点断开（Stop 持锁 cancel(ctx)
	// 并把 status 置 Disconnected）。若不复查就 setStatus(Connected)，会把状态踩回已连接，
	// 进而触发 monitorVPN 自动重连——表现为"用户断开后 VPN 自己又连上"。setStatus 也一并
	// 移进锁内，保证"复查 ctx + 写 Connected"相对 Stop 原子。
	if ctx.Err() != nil {
		e.cleanupLocked() // 清理刚建立的 bridge/singbox/socks，避免泄漏
		e.mu.Unlock()
		e.vpn.Disconnect()
		return ctx.Err()
	}
	e.setStatus(StatusConnected)
	// 接管系统 DNS。位置有两个约束：
	//  1. 必须在状态提交为 Connected 之后——此刻 tun 已在转发，指过去的查询能被
	//     hijack-dns 接住。"能不能接住"由 Takeover 内部的路由就绪探测再确认一遍
	//     （最多 3 秒，之后跳过接管），所以这里最坏会多持锁几秒，是有上限的；
	//  2. 必须仍在 e.mu 之内——放到锁外的话，正好在此刻点断开会让 Stop 的恢复先跑完，
	//     接管随后才落地，系统 DNS 就永久留在已消失的 tun 上。持锁让 Stop 必然排在
	//     接管之后，它的 cleanupLocked 一定能恢复。
	// 失败不是致命错：退回的正是接管前的现状（查询绕过 tun、结果可能被污染、按域名
	// 分流不准），连接必须保持，绝不能因此断开。
	e.takeoverDNSLocked()
	e.mu.Unlock()

	if closeCh != nil {
		go e.monitorVPN(closeCh)
	}
	return nil
}

// takeoverDNSLocked 在开关允许时接管系统 DNS。调用方必须持 e.mu（见 connectInternal
// 里那段关于"必须仍在锁内"的说明）。开关关闭时一条命令都不发。
func (e *Engine) takeoverDNSLocked() {
	if !e.allowDNSTakeover {
		return
	}
	if err := e.dns.Takeover(); err != nil {
		slog.Warn("system DNS takeover failed", "err", err)
		if e.callback != nil {
			e.callback.OnError(2, "系统 DNS 接管失败，按域名分流可能不准："+err.Error())
		}
	}
}

// handleSingBoxExit 处理 sing-box 子进程的非正常退出。`sing-box check` 只做
// box.New 不做 Start，抓不到启动期错误（典型：规则集首次下载失败会让 router
// 直接 FATAL）；不接管这里，engine 会停在"已连接"，用户看到的是"已连接但整机
// 没网"。
func (e *Engine) handleSingBoxExit(exitErr error) {
	e.mu.Lock()
	if e.status != StatusConnected && e.status != StatusConnecting && e.status != StatusReconnecting {
		e.mu.Unlock()
		return
	}
	slog.Error("sing-box exited unexpectedly", "err", exitErr)
	// 退出可能早于 connectInternal 提交状态，只改 status 会被随后的
	// setStatus(Connected) 覆盖回去；cancel 让它在提交前的 ctx 复查处退出。
	if e.cancel != nil {
		e.cancel()
	}
	e.cleanupLocked()
	e.vpn.Disconnect()
	e.setStatus(StatusDisconnected)
	callback := e.callback
	e.mu.Unlock()

	if callback != nil {
		callback.OnError(3, exitErr.Error())
	}
}

func (e *Engine) startSOCKS(bridge *VPNBridge) (string, error) {
	srv := socks5.NewServer(
		socks5.WithDial(func(ctx context.Context, network, addr string) (net.Conn, error) {
			if network == "tcp" {
				return bridge.DialTCP(ctx, addr)
			}
			return nil, fmt.Errorf("unsupported network: %s", network)
		}),
		socks5.WithLogger(socks5.NewLogger(log.Default())),
	)

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", err
	}

	e.socks = srv
	e.socksLn = ln

	go srv.Serve(ln)

	return ln.Addr().String(), nil
}

func (e *Engine) SOCKSAddr() string {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.socksLn != nil {
		return e.socksLn.Addr().String()
	}
	return ""
}

func (e *Engine) Stop() error {
	e.mu.Lock()
	defer e.mu.Unlock()

	if e.status != StatusConnected && e.status != StatusConnecting && e.status != StatusReconnecting {
		return nil
	}

	e.setStatus(StatusDisconnecting)

	if e.cancel != nil {
		e.cancel()
	}
	e.cleanupLocked()
	e.vpn.Disconnect()

	e.setStatus(StatusDisconnected)
	return nil
}

// cleanupLocked 是所有退出路径的共同收尾（用户断开、VPN 掉线重连、sing-box 崩溃、
// connect 中途被取消），所以恢复系统 DNS 只需接在这里一处。
func (e *Engine) cleanupLocked() {
	// 顺序是硬要求：先恢复系统 DNS，再停 sing-box。反序会留下一个「DNS 指向已经
	// 消失的 tun」的时间窗，那期间整机解析全灭。
	if err := e.dns.Restore(); err != nil {
		slog.Error("restore system DNS failed", "err", err)
		if e.callback != nil {
			e.callback.OnError(2, "恢复系统 DNS 失败："+err.Error())
		}
	}
	// 软失败（服务还在、只是当前被禁用）不算 Restore 的错误，但用户必须知道：重新启用
	// 那个服务时它的 DNS 还指着已消失的 tun。之后由周期自愈接手，不会重复上报。
	e.reportDNSPending()
	if e.singbox != nil {
		e.singbox.Stop()
		e.singbox = nil
	}
	if e.socksLn != nil {
		e.socksLn.Close()
		e.socksLn = nil
	}
	if e.bridge != nil {
		e.bridge.Close()
		e.bridge = nil
	}
}

func (e *Engine) Status() string {
	e.mu.Lock()
	defer e.mu.Unlock()
	msg := newStatusMessage(e.status)
	b, _ := json.Marshal(msg)
	return string(b)
}

func (e *Engine) monitorVPN(closeCh chan struct{}) {
	connectedAt := time.Now()
	<-closeCh

	e.mu.Lock()

	if e.status != StatusConnected {
		e.mu.Unlock()
		return
	}

	slog.Warn("VPN session lost unexpectedly, cleaning up")
	e.cleanupLocked()

	if time.Since(connectedAt) > stableConnectionThreshold {
		e.reconnectCount = 0
	}

	if e.reconnectCount >= maxReconnectAttempts {
		slog.Error("giving up reconnect", "attempts", e.reconnectCount)
		if e.callback != nil {
			e.callback.OnError(2, "AnyConnect 多次重连失败，已停止重试")
		}
		e.setStatus(StatusDisconnected)
		e.mu.Unlock()
		return
	}

	e.reconnectCount++
	attempt := e.reconnectCount
	e.setStatus(StatusReconnecting)

	ctx, cancel := context.WithCancel(context.Background())
	e.cancel = cancel
	profile := e.profile
	e.mu.Unlock()

	go e.reconnect(ctx, profile, attempt)
}

func (e *Engine) reconnect(ctx context.Context, profile *config.Profile, attempt int) {
	delay := time.Duration(1<<attempt) * time.Second
	slog.Info("reconnecting VPN", "attempt", attempt, "max", maxReconnectAttempts, "delay", delay)

	if e.callback != nil {
		e.callback.OnError(2, fmt.Sprintf("AnyConnect 断开，%d秒后重连 (%d/%d)", int(delay.Seconds()), attempt, maxReconnectAttempts))
	}

	select {
	case <-time.After(delay):
	case <-ctx.Done():
		e.mu.Lock()
		if e.status == StatusReconnecting {
			e.setStatus(StatusDisconnected)
		}
		e.mu.Unlock()
		return
	}

	e.mu.Lock()
	if e.status != StatusReconnecting {
		e.mu.Unlock()
		return
	}
	e.setStatus(StatusConnecting)
	e.mu.Unlock()

	if err := e.connectInternal(ctx, profile); err != nil {
		e.mu.Lock()
		if e.status == StatusConnecting {
			slog.Error("reconnect failed", "attempt", attempt, "err", err)
			if e.callback != nil {
				e.callback.OnError(2, "AnyConnect 重连失败："+err.Error())
			}
			e.setStatus(StatusDisconnected)
		}
		e.mu.Unlock()
	}
}

func (e *Engine) KillSession() {
	if cSess := session.Sess.CSess; cSess != nil {
		cSess.Close()
	}
}

func (e *Engine) setStatus(s Status) {
	e.status = s
	if e.callback != nil {
		msg := newStatusMessage(s)
		b, _ := json.Marshal(msg)
		e.callback.OnStatusChanged(string(b))
	}
}

func humanizeVPNError(err error, server string) string {
	s := err.Error()
	switch {
	case strings.Contains(s, "Login failed") ||
		strings.Contains(s, "login failed") ||
		strings.Contains(s, "401"):
		return "用户名或密码错误"
	case strings.Contains(s, "i/o timeout") ||
		strings.Contains(s, "deadline exceeded"):
		return fmt.Sprintf("连接 %s 超时，请检查地址和端口是否正确，或网络是否通畅", server)
	case strings.Contains(s, "no such host") ||
		strings.Contains(s, "DNS"):
		return fmt.Sprintf("无法解析服务器地址 %s，请检查域名是否正确", server)
	case strings.Contains(s, "connection refused"):
		return fmt.Sprintf("服务器 %s 拒绝连接，请检查端口是否正确", server)
	case strings.Contains(s, "no route to host"):
		return "网络不通，请检查网络连接"
	case strings.Contains(s, "certificate") ||
		strings.Contains(s, "x509"):
		return "服务器证书验证失败（若为自签证书，请在该 AnyConnect 线路里开启\"跳过证书验证\"）"
	default:
		return "AnyConnect 连接失败：" + s
	}
}

func (e *Engine) fail(msg string) {
	slog.Error("engine error", "msg", msg)
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.callback != nil {
		e.callback.OnError(1, msg)
	}
	e.setStatus(StatusDisconnected)
}
