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

	"github.com/things-go/go-socks5"

	"github.com/kafeifei/xdial/core/config"
	"sslcon/session"
)

type Engine struct {
	mu       sync.Mutex
	status   Status
	vpn      *VPNClient
	bridge   *VPNBridge
	socks    *socks5.Server
	socksLn  net.Listener
	singbox  *SingBoxProcess
	callback StatusCallback
	cancel   context.CancelFunc
	basePath string
}

func New(basePath string, cb StatusCallback) *Engine {
	return &Engine{
		vpn:      NewVPNClient(),
		callback: cb,
		basePath: basePath,
	}
}

func (e *Engine) Start(profileJSON string) error {
	e.mu.Lock()
	defer e.mu.Unlock()

	if e.status == StatusConnected || e.status == StatusConnecting {
		return fmt.Errorf("already %s", e.status)
	}

	var profile config.Profile
	if err := json.Unmarshal([]byte(profileJSON), &profile); err != nil {
		return fmt.Errorf("parse profile: %w", err)
	}

	e.setStatus(StatusConnecting)

	ctx, cancel := context.WithCancel(context.Background())
	e.cancel = cancel

	go e.connect(ctx, &profile)
	return nil
}

func (e *Engine) connect(ctx context.Context, profile *config.Profile) {
	vpnPort := profile.VPNPort()
	if vpnPort == nil {
		e.fail("没有配置 VPN 港口")
		return
	}
	if vpnPort.VPNServer == "" {
		e.fail("VPN 服务器地址未填写")
		return
	}
	if vpnPort.VPNUsername == "" || vpnPort.VPNPassword == "" {
		e.fail("VPN 用户名或密码未填写")
		return
	}

	slog.Info("connecting to VPN", "server", vpnPort.VPNServer)

	vpnInfo, err := e.vpn.Connect(VPNConfig{
		Server:   vpnPort.VPNServer,
		Username: vpnPort.VPNUsername,
		Password: vpnPort.VPNPassword,
	})
	if err != nil {
		e.fail(humanizeVPNError(err, vpnPort.VPNServer))
		return
	}

	slog.Info("VPN connected", "addr", vpnInfo.VPNAddress, "dns", vpnInfo.DNS)

	bridge, err := NewVPNBridge(vpnInfo.VPNAddress, vpnInfo.MTU)
	if err != nil {
		e.vpn.Disconnect()
		e.fail("VPN 隧道初始化失败")
		return
	}

	cSess := e.vpn.Session()
	if cSess == nil {
		bridge.Close()
		e.vpn.Disconnect()
		e.fail("VPN 会话已断开")
		return
	}
	bridge.Start(cSess)

	socksAddr, err := e.startSOCKS(bridge)
	if err != nil {
		bridge.Close()
		e.vpn.Disconnect()
		e.fail("本地代理启动失败")
		return
	}

	slog.Info("SOCKS5 proxy ready", "addr", socksAddr)

	singbox := NewSingBoxProcess(e.basePath)
	if err := singbox.Start(profile, socksAddr, vpnInfo.ServerAddr); err != nil {
		slog.Warn("sing-box not started (TUN routing unavailable)", "err", err)
	}

	e.mu.Lock()
	e.bridge = bridge
	e.singbox = singbox
	e.mu.Unlock()

	e.setStatus(StatusConnected)

	closeCh := session.Sess.CloseChan
	go e.monitorVPN(closeCh)
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

	if e.status != StatusConnected && e.status != StatusConnecting {
		return nil
	}

	e.setStatus(StatusDisconnecting)

	if e.cancel != nil {
		e.cancel()
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
	e.vpn.Disconnect()

	e.setStatus(StatusDisconnected)
	return nil
}

func (e *Engine) Status() string {
	e.mu.Lock()
	defer e.mu.Unlock()
	msg := newStatusMessage(e.status)
	b, _ := json.Marshal(msg)
	return string(b)
}

func (e *Engine) monitorVPN(closeCh chan struct{}) {
	<-closeCh

	e.mu.Lock()
	defer e.mu.Unlock()

	if e.status != StatusConnected {
		return
	}

	slog.Warn("VPN session lost unexpectedly, cleaning up")

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

	if e.callback != nil {
		e.callback.OnError(2, "VPN 连接意外断开")
	}
	e.setStatus(StatusDisconnected)
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

// humanizeVPNError 把底层错误翻译成给人看的提示
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
		return "服务器证书验证失败"
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
	// 广播状态变化，让 UI 知道连接失败、可以重试
	e.setStatus(StatusDisconnected)
}
