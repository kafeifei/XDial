//go:build !mobile_no_tailscale

package engine

import (
	"context"
	"fmt"
	"log/slog"
	"net/netip"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/kafeifei/xdial/core/config"
	"github.com/sagernet/tailscale/client/local"
	"github.com/sagernet/tailscale/ipn/ipnstate"
	"github.com/sagernet/tailscale/tsnet"
)

type TailscaleSession struct {
	lineID   string
	server   *tsnet.Server
	client   *local.Client
	cancel   context.CancelFunc
	onAuth   func(string)
	onStatus func(TailscaleStatus)
}

func NewTailscaleSession(statePath string, identity config.TailscaleIdentity, lineID string, onAuth func(string), onStatus func(TailscaleStatus)) (*TailscaleSession, error) {
	if lineID == "" {
		return nil, fmt.Errorf("无效的 Tailscale 线路")
	}
	stateDirectory := config.TailscaleStateDirectory(statePath)
	if err := os.MkdirAll(stateDirectory, 0700); err != nil {
		return nil, fmt.Errorf("创建 Tailscale 状态目录: %w", err)
	}

	// 设备名由 Profile 持有并在首次登录时生成，这里不再回退到 os.Hostname()：
	// 每次启动重算会让用户改个机器名就变成一台新设备重新注册。
	hostname := strings.TrimSpace(identity.Hostname)
	if hostname == "" {
		hostname = config.GenerateTailscaleHostname()
	}

	server := &tsnet.Server{
		Dir:      stateDirectory,
		Hostname: hostname,
		// 常驻节点，不能用 Ephemeral：登录会话关闭后控制面会立刻回收
		// ephemeral 的 node key，随后 sing-box endpoint 复用同一份 state 时
		// 就被要求重新登录——「登录一次、连接复用」的两阶段模型直接失效。
		// 设备不堆积由全局唯一 state + 固定 hostname 保证；退出登录时通过
		// Logout 显式通知控制面删除设备记录。
		Logf: func(format string, args ...any) {
			slog.Debug("Tailscale", "message", fmt.Sprintf(format, args...))
		},
	}
	if err := server.Start(); err != nil {
		return nil, fmt.Errorf("启动 Tailscale 会话: %w", err)
	}
	client, err := server.LocalClient()
	if err != nil {
		server.Close()
		return nil, fmt.Errorf("连接 Tailscale 会话: %w", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	session := &TailscaleSession{
		lineID:   lineID,
		server:   server,
		client:   client,
		cancel:   cancel,
		onAuth:   onAuth,
		onStatus: onStatus,
	}
	go session.watch(ctx)
	return session, nil
}

func (s *TailscaleSession) LineID() string {
	return s.lineID
}

func (s *TailscaleSession) Status(ctx context.Context) (TailscaleStatus, error) {
	ticker := time.NewTicker(200 * time.Millisecond)
	defer ticker.Stop()
	for {
		status, err := s.client.Status(ctx)
		if err != nil {
			return TailscaleStatus{}, fmt.Errorf("读取 Tailscale 状态: %w", err)
		}
		switch status.BackendState {
		case "NeedsLogin", "NoState":
			// 未登录是正常状态，不是错误：UI 要据此显示登录入口。
			return TailscaleStatus{}, nil
		case "Running":
			return buildTailscaleStatus(status), nil
		}
		select {
		case <-ctx.Done():
			return TailscaleStatus{}, fmt.Errorf("等待 Tailscale 连接: %w", ctx.Err())
		case <-ticker.C:
		}
	}
}

func buildTailscaleStatus(status *ipnstate.Status) TailscaleStatus {
	return TailscaleStatus{
		LoggedIn:  true,
		Account:   tailscaleAccount(status),
		Hostname:  tailscaleSelfHostname(status),
		ExitNodes: tailscaleExitNodes(status),
	}
}

// tailscaleAccount 取登录邮箱。
func tailscaleAccount(status *ipnstate.Status) string {
	if status.Self == nil {
		return ""
	}
	if user, ok := status.User[status.Self.UserID]; ok {
		return user.LoginName
	}
	return ""
}

func tailscaleSelfHostname(status *ipnstate.Status) string {
	if status.Self == nil {
		return ""
	}
	return status.Self.HostName
}

// Logout 通知控制面注销本机节点，tailnet 里的设备记录随之删除。
func (s *TailscaleSession) Logout(ctx context.Context) error {
	if s.client == nil {
		return fmt.Errorf("Tailscale 会话不可用")
	}
	return s.client.Logout(ctx)
}

func (s *TailscaleSession) Close() error {
	if s.cancel != nil {
		s.cancel()
		s.cancel = nil
	}
	if s.server != nil {
		err := s.server.Close()
		s.server = nil
		return err
	}
	return nil
}

func (s *TailscaleSession) watch(ctx context.Context) {
	ticker := time.NewTicker(300 * time.Millisecond)
	defer ticker.Stop()
	var lastAuthURL string
	for {
		status, err := s.client.Status(ctx)
		if err == nil {
			if status.AuthURL != "" && status.AuthURL != lastAuthURL {
				lastAuthURL = status.AuthURL
				if s.onAuth != nil {
					s.onAuth(status.AuthURL)
				}
			}
			if status.BackendState == "Running" {
				if s.onStatus != nil {
					s.onStatus(buildTailscaleStatus(status))
				}
				return
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func tailscaleExitNodes(status *ipnstate.Status) []TailscaleExitNode {
	var nodes []TailscaleExitNode
	for _, peer := range status.Peer {
		if peer == nil || !peer.ExitNodeOption {
			continue
		}
		ip := preferredTailscaleIP(peer.TailscaleIPs)
		if ip == "" {
			continue
		}
		name := tailscalePeerName(peer, status.CurrentTailnet)
		nodes = append(nodes, TailscaleExitNode{
			ID:     string(peer.ID),
			Name:   name,
			IP:     ip,
			Online: peer.Online,
			OS:     peer.OS,
		})
	}
	sort.Slice(nodes, func(i, j int) bool {
		if nodes[i].Online != nodes[j].Online {
			return nodes[i].Online
		}
		return strings.ToLower(nodes[i].Name) < strings.ToLower(nodes[j].Name)
	})
	return nodes
}

func preferredTailscaleIP(addresses []netip.Addr) string {
	for _, address := range addresses {
		if address.Is4() {
			return address.String()
		}
	}
	if len(addresses) > 0 {
		return addresses[0].String()
	}
	return ""
}

func tailscalePeerName(peer *ipnstate.PeerStatus, tailnet *ipnstate.TailnetStatus) string {
	name := strings.TrimSuffix(peer.DNSName, ".")
	if tailnet != nil && tailnet.MagicDNSSuffix != "" {
		name = strings.TrimSuffix(name, "."+strings.TrimSuffix(tailnet.MagicDNSSuffix, "."))
	}
	if name == "" {
		name = peer.HostName
	}
	if name == "" {
		name = preferredTailscaleIP(peer.TailscaleIPs)
	}
	return name
}
