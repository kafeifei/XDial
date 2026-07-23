//go:build !windows && with_gvisor && !mobile_no_tailscale

package libbox

import (
	"context"
	"encoding/json"
	"fmt"
	"net/netip"
	"sort"
	"strings"
	"time"

	boxTailscale "github.com/sagernet/sing-box/protocol/tailscale"
	"github.com/sagernet/tailscale/ipn/ipnstate"
)

const tailscaleStatusTimeout = 5 * time.Second

type tailscaleStatusPayload struct {
	BackendState string                    `json:"backend_state"`
	AuthURL      string                    `json:"auth_url"`
	ExitNodes    []tailscaleStatusExitNode `json:"exit_nodes"`
}

type tailscaleStatusExitNode struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	IP     string `json:"ip"`
	Online bool   `json:"online"`
	OS     string `json:"os"`
}

// TailscaleStatus 返回指定 sing-box endpoint 的脱敏状态。JSON 只包含登录所需
// 的状态、授权地址和可选出口节点，不暴露 tailnet、用户、健康详情或节点密钥。
func (l *Libbox) TailscaleStatus(endpointTag string) (string, error) {
	l.mu.Lock()
	if !l.running || l.box == nil || l.runtimeCtx == nil {
		l.mu.Unlock()
		return "", fmt.Errorf("connection is not running")
	}
	endpoint, found := l.box.Endpoint().Get(strings.TrimSpace(endpointTag))
	runtimeCtx := l.runtimeCtx
	l.mu.Unlock()

	tailscaleEndpoint, ok := endpoint.(*boxTailscale.Endpoint)
	if !found || !ok {
		return "", fmt.Errorf("Tailscale endpoint is unavailable")
	}
	client, err := tailscaleEndpoint.Server().LocalClient()
	if err != nil {
		return "", fmt.Errorf("Tailscale status is unavailable")
	}
	ctx, cancel := context.WithTimeout(runtimeCtx, tailscaleStatusTimeout)
	defer cancel()
	status, err := client.Status(ctx)
	if err != nil {
		return "", fmt.Errorf("Tailscale status is unavailable")
	}
	return encodeTailscaleStatus(status)
}

func encodeTailscaleStatus(status *ipnstate.Status) (string, error) {
	if status == nil {
		return "", fmt.Errorf("Tailscale status is unavailable")
	}
	payload := tailscaleStatusPayload{
		BackendState: status.BackendState,
		AuthURL:      status.AuthURL,
		ExitNodes:    make([]tailscaleStatusExitNode, 0),
	}
	for _, peer := range status.Peer {
		if peer == nil || !peer.ExitNodeOption {
			continue
		}
		ip := preferredTailscaleStatusIP(peer.TailscaleIPs)
		if ip == "" {
			continue
		}
		payload.ExitNodes = append(payload.ExitNodes, tailscaleStatusExitNode{
			ID:     string(peer.ID),
			Name:   tailscaleStatusPeerName(peer, status.CurrentTailnet),
			IP:     ip,
			Online: peer.Online,
			OS:     peer.OS,
		})
	}
	sort.Slice(payload.ExitNodes, func(i, j int) bool {
		if payload.ExitNodes[i].Online != payload.ExitNodes[j].Online {
			return payload.ExitNodes[i].Online
		}
		leftName := strings.ToLower(payload.ExitNodes[i].Name)
		rightName := strings.ToLower(payload.ExitNodes[j].Name)
		if leftName != rightName {
			return leftName < rightName
		}
		return payload.ExitNodes[i].ID < payload.ExitNodes[j].ID
	})
	data, err := json.Marshal(payload)
	if err != nil {
		return "", fmt.Errorf("Tailscale status encoding failed")
	}
	return string(data), nil
}

func preferredTailscaleStatusIP(addresses []netip.Addr) string {
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

func tailscaleStatusPeerName(peer *ipnstate.PeerStatus, tailnet *ipnstate.TailnetStatus) string {
	name := strings.TrimSuffix(peer.DNSName, ".")
	if tailnet != nil && tailnet.MagicDNSSuffix != "" {
		name = strings.TrimSuffix(name, "."+strings.TrimSuffix(tailnet.MagicDNSSuffix, "."))
	}
	if name == "" {
		name = peer.HostName
	}
	if name == "" {
		name = preferredTailscaleStatusIP(peer.TailscaleIPs)
	}
	return name
}
