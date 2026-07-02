//go:build darwin

package main

import (
	"net"
	"os"
	"syscall"

	"golang.org/x/sys/unix"
)

// consoleUID 返回当前登录（console）用户的 uid。macOS 上 loginwindow 会把 /dev/console
// 的属主设为登录用户。取不到时返回 false。
func consoleUID() (int, bool) {
	fi, err := os.Stat("/dev/console")
	if err != nil {
		return 0, false
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, false
	}
	return int(st.Uid), true
}

// peerAllowed 用 LOCAL_PEERCRED 取对端 uid，只放行 root 和当前登录（console）用户。
// 在每个连接发生时判断，避开"开机 daemon 先于登录启动时拿不到 console 用户"的时序问题。
func peerAllowed(conn net.Conn) bool {
	uc, ok := conn.(*net.UnixConn)
	if !ok {
		return false
	}
	raw, err := uc.SyscallConn()
	if err != nil {
		return false
	}
	var uid int
	var cerr error
	if e := raw.Control(func(fd uintptr) {
		cred, err := unix.GetsockoptXucred(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERCRED)
		if err != nil {
			cerr = err
			return
		}
		uid = int(cred.Uid)
	}); e != nil || cerr != nil {
		return false
	}
	if uid == 0 {
		return true // root
	}
	if cu, ok := consoleUID(); ok && cu > 0 && uid == cu {
		return true // 当前登录用户（运行 GUI 的人）
	}
	return false
}
