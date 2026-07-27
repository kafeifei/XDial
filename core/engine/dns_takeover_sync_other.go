//go:build !darwin

package engine

import "os"

// fullSync 非 darwin 上就是普通 fsync：F_FULLFSYNC 是 macOS 独有的。
//
// 这条路径实际跑不到（DNS 接管只在 darwin 上 supported），但 engine 包会被编进
// Linux/Windows 的 CLI，writeState 必须在那里也能编译。
func fullSync(file *os.File) error {
	return file.Sync()
}
