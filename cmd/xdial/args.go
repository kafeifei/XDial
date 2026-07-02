package main

import (
	"flag"
	"fmt"
	"os"
	"strings"
)

// rejectLeftoverArgs 拦截多余的位置参数。历史上 daemon 曾用 `xdial daemon <sock>`
// 的位置参数约定；Go 的 flag 包会静默忽略残留位置参数（且遇首个非 flag 即停止解析，
// 其后的 flag 全部失效），极易踩坑——一律报错退出而非静默吞掉。
func rejectLeftoverArgs(fs *flag.FlagSet) {
	if fs.NArg() > 0 {
		fmt.Fprintf(os.Stderr, "unexpected argument: %q\n\n", fs.Arg(0))
		fs.Usage()
		os.Exit(2)
	}
}

// checkSocketPath 拦住 `--socket --foo` 这类把下一个 flag 当值吞掉的情况
// （Go flag 对非布尔 flag 无条件把下一 token 当值）。socket 路径不应以 - 开头，
// 也避免 daemon 以 root 运行时 os.Remove 误删相对路径下的同名文件。
func checkSocketPath(path string) {
	if path == "" || strings.HasPrefix(path, "-") {
		fmt.Fprintf(os.Stderr, "invalid socket path: %q\n", path)
		os.Exit(2)
	}
}
