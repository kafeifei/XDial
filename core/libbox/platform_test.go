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

func TestPlatformInterfaceMonitorRejectsMissingPhysicalInterface(t *testing.T) {
	platform := &xdPlatformInterface{}
	monitor := &platformInterfaceMonitor{platform: platform}
	if err := monitor.Start(); err == nil {
		t.Fatal("monitor started without a physical interface")
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

func TestPlatformNetworkInterfacesUsesDefaultPhysicalSnapshot(t *testing.T) {
	platform := &xdPlatformInterface{}
	platform.setDefaultInterface("en0", 7)

	interfaces, err := platform.NetworkInterfaces()
	if err != nil {
		t.Fatalf("read platform interfaces: %v", err)
	}
	if len(interfaces) != 1 ||
		interfaces[0].Name != "en0" ||
		interfaces[0].Index != 7 {
		t.Fatalf("unexpected platform interfaces: %#v", interfaces)
	}

	platform.setDefaultInterface("pdp_ip0", 12)
	interfaces, err = platform.NetworkInterfaces()
	if err != nil {
		t.Fatalf("read changed platform interfaces: %v", err)
	}
	if len(interfaces) != 1 ||
		interfaces[0].Name != "pdp_ip0" ||
		interfaces[0].Index != 12 {
		t.Fatalf("unexpected changed platform interfaces: %#v", interfaces)
	}
}

func TestPlatformNetworkInterfacesRejectsTunnelSnapshot(t *testing.T) {
	for _, name := range []string{"utun4", "ipsec0", "ppp0"} {
		t.Run(name, func(t *testing.T) {
			platform := &xdPlatformInterface{}
			platform.setDefaultInterface("en0", 7)
			platform.setDefaultInterface(name, 9)

			interfaces, err := platform.NetworkInterfaces()
			if err != nil {
				t.Fatalf("read platform interfaces: %v", err)
			}
			if len(interfaces) != 0 {
				t.Fatalf("tunnel interface was exposed: %#v", interfaces)
			}
			monitor := &platformInterfaceMonitor{platform: platform}
			if current := monitor.DefaultInterface(); current != nil {
				t.Fatalf("tunnel interface became default: %#v", current)
			}
		})
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
