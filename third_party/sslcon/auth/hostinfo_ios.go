//go:build ios

package auth

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"runtime"
)

// loadHostInfo 是 ios/tvos 下的纯 Go 实现,不依赖 go-sysinfo 的 cgo darwin
// provider(需要桌面 macOS SDK 才有的 libproc.h)。这些字段只用于
// AnyConnect 握手时的客户端标识,服务端不校验具体格式,降级为
// 标准库可得的信息不影响协议正确性。
func loadHostInfo() (computerName, deviceType, platformVersion, uniqueID string) {
	hostname, err := os.Hostname()
	if err != nil || hostname == "" {
		hostname = "xdial-appletv"
	}

	sum := sha256.Sum256([]byte(hostname + runtime.GOOS + runtime.GOARCH))
	return hostname, "Apple TV", runtime.GOOS, hex.EncodeToString(sum[:8])
}
