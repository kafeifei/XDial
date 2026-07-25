//go:build !windows

package libbox

import "testing"

func TestStartupStageFromStack(t *testing.T) {
	tests := []struct {
		name  string
		stack string
		want  string
	}{
		{
			name:  "tailscale backend has priority over generic box",
			stack: "github.com/sagernet/sing-box/protocol/tailscale.(*Endpoint).postStart\ngithub.com/sagernet/sing-box.(*Box).start",
			want:  "tailscale_backend_starting",
		},
		{
			name:  "tailscale endpoint",
			stack: "github.com/sagernet/sing-box/protocol/tailscale.(*Endpoint).start",
			want:  "tailscale_endpoint_starting",
		},
		{
			name:  "tun",
			stack: "github.com/sagernet/sing-box/protocol/tun.(*Inbound).Start",
			want:  "tun_starting",
		},
		{
			name:  "network interfaces",
			stack: "github.com/sagernet/sing-box/route.(*NetworkManager).UpdateInterfaces",
			want:  "interfaces_updating",
		},
		{
			name:  "generic box",
			stack: "github.com/sagernet/sing-box.(*Box).start",
			want:  "singbox_starting",
		},
		{
			name:  "unknown",
			stack: "runtime.goexit",
			want:  "unknown_starting",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := startupStageFromStack(test.stack); got != test.want {
				t.Fatalf("startupStageFromStack() = %q, want %q", got, test.want)
			}
		})
	}
}
