//go:build !darwin

package main

import "net"

// 非 darwin（linux/windows 只是跨平台脚手架，daemon 实际投产在 macOS）暂不做对端凭据校验。
func peerAllowed(net.Conn) bool { return true }
