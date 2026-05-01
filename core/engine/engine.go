package engine

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"log/slog"
	"net"
	"sync"

	"github.com/things-go/go-socks5"

	"github.com/kafeifei/xdial/core/config"
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
	vpnLine := profile.FindLine(config.LineIDCompanyVPN)
	if vpnLine == nil || vpnLine.Type != config.LineTypeCompanyVPN {
		e.fail("no company VPN line configured")
		return
	}

	slog.Info("connecting to VPN", "server", vpnLine.VPNServer)

	vpnInfo, err := e.vpn.Connect(VPNConfig{
		Server:   vpnLine.VPNServer,
		Username: vpnLine.VPNUsername,
		Password: vpnLine.VPNPassword,
	})
	if err != nil {
		e.fail(fmt.Sprintf("VPN connect failed: %v", err))
		return
	}

	slog.Info("VPN connected", "addr", vpnInfo.VPNAddress, "dns", vpnInfo.DNS)

	bridge, err := NewVPNBridge(vpnInfo.VPNAddress, vpnInfo.MTU)
	if err != nil {
		e.vpn.Disconnect()
		e.fail(fmt.Sprintf("bridge init failed: %v", err))
		return
	}

	cSess := e.vpn.Session()
	if cSess == nil {
		bridge.Close()
		e.vpn.Disconnect()
		e.fail("VPN session lost")
		return
	}
	bridge.Start(cSess)

	socksAddr, err := e.startSOCKS(bridge)
	if err != nil {
		bridge.Close()
		e.vpn.Disconnect()
		e.fail(fmt.Sprintf("SOCKS5 start failed: %v", err))
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

func (e *Engine) setStatus(s Status) {
	e.status = s
	if e.callback != nil {
		msg := newStatusMessage(s)
		b, _ := json.Marshal(msg)
		e.callback.OnStatusChanged(string(b))
	}
}

func (e *Engine) fail(msg string) {
	slog.Error("engine error", "msg", msg)
	e.mu.Lock()
	defer e.mu.Unlock()
	e.status = StatusDisconnected
	if e.callback != nil {
		e.callback.OnError(1, msg)
	}
}
