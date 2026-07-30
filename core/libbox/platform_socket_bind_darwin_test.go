//go:build darwin

package libbox

import (
	"net"
	"testing"

	"golang.org/x/sys/unix"
)

func TestAutoDetectInterfaceControlBindsIPv4Socket(t *testing.T) {
	loopback, err := net.InterfaceByName("lo0")
	if err != nil {
		t.Skipf("loopback interface is unavailable: %v", err)
	}
	fd, err := unix.Socket(unix.AF_INET, unix.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer unix.Close(fd)

	platform := &xdPlatformInterface{}
	platform.setDefaultInterface(loopback.Name, loopback.Index)
	platform.setUnderlayInterfaceBinding(true)
	if err := platform.AutoDetectInterfaceControl(fd); err != nil {
		t.Fatalf("bind socket: %v", err)
	}
	index, err := unix.GetsockoptInt(fd, unix.IPPROTO_IP, unix.IP_BOUND_IF)
	if err != nil {
		t.Fatalf("read bound interface: %v", err)
	}
	if index != loopback.Index {
		t.Fatalf("bound interface = %d, want %d", index, loopback.Index)
	}
}
