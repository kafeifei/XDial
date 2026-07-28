//go:build !windows

package libbox

import (
	"encoding/json"
	"testing"

	tun "github.com/sagernet/sing-tun"
	"github.com/sagernet/sing/common/control"
)

func TestDiagnosticsReportsCompiledStackAndInterfaces(t *testing.T) {
	library := New(nil)
	library.SetTunFD(42)
	library.SetDefaultInterface("en0", 7)
	monitor := &platformInterfaceMonitor{platform: library.platform}
	monitor.RegisterMyInterface("utun9")
	library.platform.mu.Lock()
	library.platform.monitor = monitor
	library.platform.mu.Unlock()

	var got map[string]any
	if err := json.Unmarshal([]byte(library.Diagnostics()), &got); err != nil {
		t.Fatalf("decode diagnostics: %v", err)
	}
	if got["gvisor_compiled"] != tun.WithGVisor || got["selected_stack"] != "gvisor" {
		t.Fatalf("unexpected stack diagnostics: %#v", got)
	}
	if got["tun_fd_ready"] != true || got["tun_name"] != "utun9" || got["default_interface_name"] != "en0" {
		t.Fatalf("unexpected interface diagnostics: %#v", got)
	}
}

func TestPlatformInterfaceMonitorRejectsMissingDefaultInterface(t *testing.T) {
	platform := &xdPlatformInterface{}
	monitor := &platformInterfaceMonitor{platform: platform}
	if err := monitor.Start(); err == nil {
		t.Fatal("monitor started without a default interface")
	}
}

func TestPlatformInterfaceMonitorPublishesInitialAndChangedInterface(t *testing.T) {
	platform := &xdPlatformInterface{}
	monitor := &platformInterfaceMonitor{platform: platform}
	platform.monitor = monitor

	updates := make(chan *control.Interface, 2)
	monitor.RegisterCallback(func(value *control.Interface, _ int) {
		updates <- value
	})

	platform.setDefaultInterface("en0", 7)
	assertInterfaceUpdate(t, updates, "en0", 7)
	if err := monitor.Start(); err != nil {
		t.Fatalf("start monitor: %v", err)
	}
	assertInterfaceUpdate(t, updates, "en0", 7)

	platform.setDefaultInterface("pdp_ip0", 12)
	assertInterfaceUpdate(t, updates, "pdp_ip0", 12)
	if current := monitor.DefaultInterface(); current == nil || current.Name != "pdp_ip0" || current.Index != 12 {
		t.Fatalf("unexpected current interface: %#v", current)
	}
}

func TestPlatformNetworkInterfacesPublishesCompleteNWPathSnapshot(t *testing.T) {
	platform := &xdPlatformInterface{}
	if err := platform.setNetworkInterfaces([]platformNetworkInterfaceSnapshot{
		{Name: "utun13", Index: 21, Type: "other"},
		{Name: "en0", Index: 7, Type: "wifi"},
	}); err != nil {
		t.Fatalf("set platform interfaces: %v", err)
	}
	platform.setDefaultInterface("utun13", 21)

	interfaces, err := platform.NetworkInterfaces()
	if err != nil {
		t.Fatalf("read platform interfaces: %v", err)
	}
	if len(interfaces) != 2 ||
		interfaces[0].Name != "utun13" ||
		interfaces[0].Index != 21 ||
		interfaces[1].Name != "en0" ||
		interfaces[1].Index != 7 {
		t.Fatalf("unexpected platform interfaces: %#v", interfaces)
	}
	monitor := &platformInterfaceMonitor{platform: platform}
	if current := monitor.DefaultInterface(); current == nil || current.Name != "utun13" || current.Index != 21 {
		t.Fatalf("lower VPN was not accepted as the default Underlay: %#v", current)
	}
}

func TestPlatformNetworkInterfacesAcceptsLowerVirtualInterfaces(t *testing.T) {
	for _, name := range []string{"utun4", "ipsec0", "ppp0"} {
		t.Run(name, func(t *testing.T) {
			platform := &xdPlatformInterface{}
			platform.setDefaultInterface(name, 9)

			interfaces, err := platform.NetworkInterfaces()
			if err != nil {
				t.Fatalf("read platform interfaces: %v", err)
			}
			if len(interfaces) != 1 || interfaces[0].Name != name || interfaces[0].Index != 9 {
				t.Fatalf("lower virtual interface was not exposed: %#v", interfaces)
			}
			monitor := &platformInterfaceMonitor{platform: platform}
			if current := monitor.DefaultInterface(); current == nil || current.Name != name || current.Index != 9 {
				t.Fatalf("lower virtual interface was not accepted as default: %#v", current)
			}
		})
	}
}

func TestPlatformNetworkInterfacesRejectsOnlyOwnTunnel(t *testing.T) {
	platform := &xdPlatformInterface{}
	monitor := &platformInterfaceMonitor{platform: platform}
	platform.monitor = monitor
	if err := platform.setNetworkInterfaces([]platformNetworkInterfaceSnapshot{
		{Name: "utun13", Index: 21, Type: "other"},
		{Name: "utun14", Index: 22, Type: "other"},
		{Name: "en0", Index: 7, Type: "wifi"},
	}); err != nil {
		t.Fatalf("set platform interfaces: %v", err)
	}
	platform.setDefaultInterface("utun14", 22)
	monitor.RegisterMyInterface("utun14")

	interfaces, err := platform.NetworkInterfaces()
	if err != nil {
		t.Fatalf("read platform interfaces: %v", err)
	}
	if len(interfaces) != 2 || interfaces[0].Name != "utun13" || interfaces[1].Name != "en0" {
		t.Fatalf("own interface filtering removed the wrong candidates: %#v", interfaces)
	}
	if current := monitor.DefaultInterface(); current == nil || current.Name != "utun13" || current.Index != 21 {
		t.Fatalf("default Underlay did not fall back to the next lower interface: %#v", current)
	}

	// 后续 NWPath 更新即使仍把当前 XDial utun 排在第一位，也必须继续选择
	// 下一层；不能出现默认 Underlay 短暂为空的窗口。
	platform.setDefaultInterface("utun14", 22)
	if current := monitor.DefaultInterface(); current == nil || current.Name != "utun13" {
		t.Fatalf("own tunnel update displaced the lower Underlay: %#v", current)
	}
}

func TestSetNetworkInterfacesRejectsMalformedSnapshot(t *testing.T) {
	library := New(nil)
	if err := library.SetNetworkInterfaces(`[{"name":"en0","index":7,"type":"wifi"}]`); err != nil {
		t.Fatalf("valid snapshot rejected: %v", err)
	}
	for _, value := range []string{
		`not-json`,
		`[{"name":"","index":7,"type":"wifi"}]`,
		`[{"name":"en0","index":7,"type":"unknown"}]`,
		`[{"name":"en0","index":7,"type":"wifi"},{"name":"en0","index":8,"type":"other"}]`,
	} {
		if err := library.SetNetworkInterfaces(value); err == nil {
			t.Fatalf("malformed snapshot accepted: %s", value)
		}
	}
}

func assertInterfaceUpdate(t *testing.T, updates <-chan *control.Interface, name string, index int) {
	t.Helper()
	value := <-updates
	if value == nil || value.Name != name || value.Index != index {
		t.Fatalf("unexpected interface update: %#v, want %s (%d)", value, name, index)
	}
}

var _ tun.DefaultInterfaceMonitor = (*platformInterfaceMonitor)(nil)
