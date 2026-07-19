//go:build darwin

package libbox

import "golang.org/x/sys/unix"

// tunnelNameFromFileDescriptor mirrors sing-box experimental/libbox on Apple
// platforms. The name must be known before tun.New copies its options.
func tunnelNameFromFileDescriptor(fd int) (string, error) {
	return unix.GetsockoptString(
		fd,
		2, // SYSPROTO_CONTROL
		2, // UTUN_OPT_IFNAME
	)
}
