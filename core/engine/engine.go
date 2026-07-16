package engine

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"log/slog"
	"net"
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

type Engine struct {
	mu             sync.Mutex
	status         Status
	vpn            *VPNClient
	bridge         *VPNBridge
	socks          *socks5.Server
	socksLn        net.Listener
	singbox        *SingBoxProcess
	tailscaleAuth  *TailscaleSession
	callback       StatusCallback
	cancel         context.CancelFunc
	basePath       string
	statePath      string
	profile        *config.Profile
	reconnectCount int
}

func New(basePath, statePath string, cb StatusCallback) *Engine {
	return &Engine{
		vpn:       NewVPNClient(),
		callback:  cb,
		basePath:  basePath,
		statePath: statePath,
	}
}

func (e *Engine) Start(profile *config.Profile) error {
	e.mu.Lock()
	defer e.mu.Unlock()

	if e.status == StatusConnected || e.status == StatusConnecting || e.status == StatusReconnecting {
		return fmt.Errorf("already %s", e.status)
	}
	if e.tailscaleAuth != nil {
		e.tailscaleAuth.Close()
		e.tailscaleAuth = nil
	}

	e.profile = profile
	e.reconnectCount = 0
	e.setStatus(StatusConnecting)

	ctx, cancel := context.WithCancel(context.Background())
	e.cancel = cancel

	go e.connect(ctx, profile)
	return nil
}

func (e *Engine) StartTailscaleAuth(line *config.Line) error {
	e.mu.Lock()
	defer e.mu.Unlock()

	if e.status != StatusDisconnected {
		return fmt.Errorf("请先断开 XDial，再登录 Tailscale")
	}
	if e.tailscaleAuth != nil {
		e.tailscaleAuth.Close()
	}

	lineID := line.ID
	authSession, err := NewTailscaleSession(e.statePath, line, e.notifyAuthRequired, func(nodes []TailscaleExitNode) {
		e.notifyTailscaleExitNodes(lineID, nodes)
	})
	if err != nil {
		e.tailscaleAuth = nil
		return err
	}
	e.tailscaleAuth = authSession
	return nil
}

func (e *Engine) TailscaleExitNodes(line *config.Line) ([]TailscaleExitNode, error) {
	e.mu.Lock()
	defer e.mu.Unlock()

	if e.status != StatusDisconnected {
		return nil, fmt.Errorf("请先断开 XDial，再刷新出口节点")
	}
	if e.tailscaleAuth == nil || e.tailscaleAuth.LineID() != line.ID {
		if e.tailscaleAuth != nil {
			e.tailscaleAuth.Close()
		}
		lineID := line.ID
		session, err := NewTailscaleSession(e.statePath, line, e.notifyAuthRequired, func(nodes []TailscaleExitNode) {
			e.notifyTailscaleExitNodes(lineID, nodes)
		})
		if err != nil {
			e.tailscaleAuth = nil
			return nil, err
		}
		e.tailscaleAuth = session
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return e.tailscaleAuth.ExitNodes(ctx)
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
	var closeCh chan struct{}

	if vpnLine != nil {
		if vpnLine.VPNServer == "" {
			return fmt.Errorf("VPN 服务器地址未填写")
		}
		if vpnLine.VPNUsername == "" || vpnLine.VPNPassword == "" {
			return fmt.Errorf("VPN 用户名或密码未填写")
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
			return fmt.Errorf("VPN 隧道初始化失败")
		}
		cSess := e.vpn.Session()
		if cSess == nil {
			bridge.Close()
			e.vpn.Disconnect()
			return fmt.Errorf("VPN 会话已断开")
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
		slog.Info("SOCKS5 proxy ready", "addr", socksAddr)
	}

	singbox := NewSingBoxProcess(e.basePath, e.statePath, e.notifyAuthRequired)
	if err := singbox.Start(profile, socksAddr, vpnServerIP); err != nil {
		if e.socksLn != nil {
			e.socksLn.Close()
			e.socksLn = nil
		}
		if bridge != nil {
			bridge.Close()
			e.vpn.Disconnect()
		}
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
	e.mu.Unlock()

	if closeCh != nil {
		go e.monitorVPN(closeCh)
	}
	return nil
}

func (e *Engine) notifyAuthRequired(authURL string) {
	if callback, ok := e.callback.(AuthCallback); ok {
		callback.OnAuthRequired(authURL)
	}
}

func (e *Engine) notifyTailscaleExitNodes(lineID string, nodes []TailscaleExitNode) {
	if callback, ok := e.callback.(TailscaleExitNodesCallback); ok {
		callback.OnTailscaleExitNodes(lineID, nodes)
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
		if e.tailscaleAuth != nil {
			e.tailscaleAuth.Close()
			e.tailscaleAuth = nil
		}
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

func (e *Engine) cleanupLocked() {
	if e.tailscaleAuth != nil {
		e.tailscaleAuth.Close()
		e.tailscaleAuth = nil
	}
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
			e.callback.OnError(2, "VPN 多次重连失败，已停止重试")
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
		e.callback.OnError(2, fmt.Sprintf("VPN 断开，%d秒后重连 (%d/%d)", int(delay.Seconds()), attempt, maxReconnectAttempts))
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
				e.callback.OnError(2, "VPN 重连失败："+err.Error())
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
		return "服务器证书验证失败（若为自签证书，请在该 VPN 线路里开启\"跳过证书验证\"）"
	default:
		return "VPN 连接失败：" + s
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
