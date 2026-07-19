//go:build darwin

package libbox

import "golang.org/x/sys/unix"

const utunControlName = "com.apple.net.utun_control"

// GetTunnelFileDescriptor 查找当前扩展进程持有的 utun 文件描述符。
// Swift 侧直接采用这条与 sing-box Apple 客户端一致的路径，不读取私有 KVC 属性。
func GetTunnelFileDescriptor() int32 {
	controlInfo := &unix.CtlInfo{}
	copy(controlInfo.Name[:], utunControlName)
	for fd := 0; fd < 1024; fd++ {
		peer, err := unix.Getpeername(fd)
		if err != nil {
			continue
		}
		controlAddress, ok := peer.(*unix.SockaddrCtl)
		if !ok {
			continue
		}
		if controlInfo.Id == 0 {
			if err := unix.IoctlCtlInfo(fd, controlInfo); err != nil {
				continue
			}
		}
		if controlAddress.ID == controlInfo.Id {
			return int32(fd)
		}
	}
	return -1
}
