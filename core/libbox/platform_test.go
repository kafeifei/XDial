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

func assertInterfaceUpdate(t *testing.T, updates <-chan *control.Interface, name string, index int) {
	t.Helper()
	value := <-updates
	if value == nil || value.Name != name || value.Index != index {
		t.Fatalf("unexpected interface update: %#v, want %s (%d)", value, name, index)
	}
}

var _ tun.DefaultInterfaceMonitor = (*platformInterfaceMonitor)(nil)
