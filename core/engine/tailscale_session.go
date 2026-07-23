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
	lineID      string
	server      *tsnet.Server
	client      *local.Client
	cancel      context.CancelFunc
	onAuth      func(string)
	onExitNodes func([]TailscaleExitNode)
}

func NewTailscaleSession(statePath string, line *config.Line, onAuth func(string), onExitNodes func([]TailscaleExitNode)) (*TailscaleSession, error) {
	if line == nil || line.Type != config.LineTypeTailscale || line.ID == "" {
		return nil, fmt.Errorf("无效的 Tailscale 线路")
	}
	stateDirectory := config.TailscaleStateDirectory(statePath, line.ID)
	if err := os.MkdirAll(stateDirectory, 0700); err != nil {
		return nil, fmt.Errorf("创建 Tailscale 状态目录: %w", err)
	}

	hostname := strings.TrimSpace(line.TailscaleHostname)
	if hostname == "" {
		hostname, _ = os.Hostname()
	}
	if hostname == "" {
		hostname = "xdial"
	}

	server := &tsnet.Server{
		Dir:      stateDirectory,
		Hostname: hostname,
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
		lineID:      line.ID,
		server:      server,
		client:      client,
		cancel:      cancel,
		onAuth:      onAuth,
		onExitNodes: onExitNodes,
	}
	go session.watch(ctx)
	return session, nil
}

func (s *TailscaleSession) LineID() string {
	return s.lineID
}

func (s *TailscaleSession) ExitNodes(ctx context.Context) ([]TailscaleExitNode, error) {
	ticker := time.NewTicker(200 * time.Millisecond)
	defer ticker.Stop()
	for {
		status, err := s.client.Status(ctx)
		if err != nil {
			return nil, fmt.Errorf("读取 Tailscale 状态: %w", err)
		}
		switch status.BackendState {
		case "NeedsLogin", "NoState":
			return nil, fmt.Errorf("Tailscale 尚未登录")
		case "Running":
			return tailscaleExitNodes(status), nil
		}
		select {
		case <-ctx.Done():
			return nil, fmt.Errorf("等待 Tailscale 连接: %w", ctx.Err())
		case <-ticker.C:
		}
	}
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
				if s.onExitNodes != nil {
					s.onExitNodes(tailscaleExitNodes(status))
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
