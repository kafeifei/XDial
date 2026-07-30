package engine

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/kafeifei/xdial/core/config"
)

func TestParseDefaultRouteInterface(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		output string
		want   string
	}{
		{
			name: "physical",
			output: `   route to: default
destination: default
  interface: en0
      flags: <UP,DONE,CLONING,STATIC,PRCLONING>
`,
			want: "en0",
		},
		{
			name: "virtual_without_gateway",
			output: `   route to: default
destination: default
  interface: utun13
      flags: <UP,DONE,STATIC>
`,
			want: "utun13",
		},
	}

	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			got, err := parseDefaultRouteInterface(test.output)
			if err != nil {
				t.Fatalf("parseDefaultRouteInterface: %v", err)
			}
			if got != test.want {
				t.Fatalf("got %q, want %q", got, test.want)
			}
		})
	}
}

func TestParseDefaultRouteInterfaceRejectsMissingOrInvalid(t *testing.T) {
	t.Parallel()

	for _, output := range []string{
		"route to: default\n",
		"interface:\n",
		"interface: utun13 extra\n",
	} {
		if got, err := parseDefaultRouteInterface(output); err == nil {
			t.Fatalf("accepted %q as %q", output, got)
		}
	}
}

func TestParseDefaultRouteIsGlobal(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		output string
		want   bool
	}{
		{
			name:   "network extension global route",
			output: "flags: <UP,DONE,CLONING,STATIC,GLOBAL>\n",
			want:   true,
		},
		{
			name:   "ordinary default route",
			output: "flags: <UP,GATEWAY,DONE,STATIC,PRCLONING>\n",
			want:   false,
		},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			got, err := parseDefaultRouteIsGlobal(test.output)
			if err != nil {
				t.Fatalf("parseDefaultRouteIsGlobal: %v", err)
			}
			if got != test.want {
				t.Fatalf("got %v, want %v", got, test.want)
			}
		})
	}
}

func TestParseDefaultRouteIsGlobalRejectsMissingOrInvalid(t *testing.T) {
	t.Parallel()

	for _, output := range []string{
		"interface: en0\n",
		"flags: UP,GATEWAY\n",
	} {
		if got, err := parseDefaultRouteIsGlobal(output); err == nil {
			t.Fatalf("accepted %q as %v", output, got)
		}
	}
}

func TestEngineRejectsUnsupportedUnderlayBeforeStartingLines(t *testing.T) {
	t.Parallel()

	profile := &config.Profile{
		Lines: []config.Line{{
			ID:      "vpn",
			Type:    config.LineTypeVPN,
			Enabled: true,
			// 故意不填服务器和凭据：若 Line 校验先执行，错误会变成“服务器未填写”。
		}},
		Modes: []config.Mode{{
			ID:            "mode",
			DefaultLineID: "vpn",
		}},
		ActiveModeID: "mode",
	}
	engine := New(t.TempDir(), t.TempDir(), nil)
	engine.detectDataPlaneUnderlay = func(context.Context) (string, error) {
		return "", errors.New("global route is unsupported")
	}

	err := engine.connectInternal(context.Background(), profile)
	if err == nil {
		t.Fatal("expected unsupported Underlay error")
	}
	if !strings.Contains(err.Error(), "global route is unsupported") {
		t.Fatalf("unexpected error: %v", err)
	}
	if strings.Contains(err.Error(), "服务器地址未填写") {
		t.Fatalf("Line validation ran before Underlay preflight: %v", err)
	}
}
