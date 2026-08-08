//go:build darwin || ios

package libbox

import (
	"fmt"

	"golang.org/x/sys/unix"
)

// bindSocketToInterface seals protocol-owned sockets to the Underlay chosen
// before XDial starts. The socket family decides which Apple-specific option
// applies; trying both options would turn an expected ENOPROTOOPT into a false
// startup failure.
func bindSocketToInterface(fd int, interfaceIndex int) error {
	if fd < 0 || interfaceIndex <= 0 {
		return fmt.Errorf("platform: invalid socket or interface index")
	}
	address, err := unix.Getsockname(fd)
	if err != nil {
		return fmt.Errorf("platform: inspect socket family: %w", err)
	}
	switch address.(type) {
	case *unix.SockaddrInet4:
		err = unix.SetsockoptInt(
			fd,
			unix.IPPROTO_IP,
			unix.IP_BOUND_IF,
			interfaceIndex,
		)
	case *unix.SockaddrInet6:
		err = unix.SetsockoptInt(
			fd,
			unix.IPPROTO_IPV6,
			unix.IPV6_BOUND_IF,
			interfaceIndex,
		)
	default:
		return fmt.Errorf("platform: unsupported socket family %T", address)
	}
	if err != nil {
		return fmt.Errorf(
			"platform: bind socket to interface %d: %w",
			interfaceIndex,
			err,
		)
	}
	return nil
}
