//go:build !darwin

package engine

import (
	"context"
	"fmt"
)

func detectUnderlayInterface(context.Context) (string, error) {
	return "", fmt.Errorf("系统默认接口快照仅支持 macOS")
}
