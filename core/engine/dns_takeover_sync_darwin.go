//go:build darwin

package engine

import (
	"os"

	"golang.org/x/sys/unix"
)

// fullSync 在 macOS 上要用 F_FULLFSYNC，不是 fsync(2)。
//
// Apple 文档写得很直白：fsync 只保证把数据交给磁盘，不等磁盘把自己的写缓存刷到介质，
// 所以掉电（本模块存在的理由之一）之后照样可能丢。F_FULLFSYNC 才是"真的落到介质"的
// 那一条。代价是慢，但状态文件一次几百字节、一次接管/恢复只写十几次，完全吃得下。
//
// 不是所有文件系统都实现它（网络卷 / 某些外挂卷返回 ENOTSUP、ENOTTY 之类），此时退回
// 普通 Sync —— 拿到弱一点的保证，好过直接把落盘判成失败。
func fullSync(file *os.File) error {
	if _, err := unix.FcntlInt(file.Fd(), unix.F_FULLFSYNC, 0); err == nil {
		return nil
	}
	return file.Sync()
}
