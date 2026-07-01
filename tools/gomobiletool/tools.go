//go:build tools

// Package gomobiletool 仅用于固定 gomobile/gobind 的构建依赖,
// 防止 `go mod tidy` 把它当未使用依赖清掉(gobind 生成的代码需要这个包)。
package gomobiletool

import (
	_ "github.com/sagernet/gomobile/bind"
)
