//go:build !ios

package auth

import (
	"runtime"
	"strings"

	"github.com/elastic/go-sysinfo"
)

// loadHostInfo 收集发给 AnyConnect 服务端握手用的主机信息(桌面平台)。
//
// gomobile 给 ios/tvos 交叉编译时启用 cgo,而 go-sysinfo 的 darwin cgo
// 实现依赖 libproc.h(仅完整 macOS SDK 有,tvOS SDK 没有),所以这个实现
// 限定在桌面平台(!ios),tvOS/iOS 走 hostinfo_ios.go 的纯 Go 实现。
func loadHostInfo() (computerName, deviceType, platformVersion, uniqueID string) {
	host, err := sysinfo.Host()
	if err != nil {
		return "", runtime.GOOS, "", ""
	}
	info := host.Info()

	osInfo := info.OS
	version := osInfo.Version
	if runtime.GOOS == "windows" {
		version = osInfo.Build
	} else if idx := strings.IndexByte(version, ' '); idx >= 0 {
		version = version[:idx]
	}

	return info.Hostname, osInfo.Name, version, info.UniqueID
}
