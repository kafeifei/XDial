//go:build windows

package engine

import (
	"fmt"
	"os"
	"os/exec"
)

func startSingBoxCmd(singboxBin, configPath, workDir string) (*exec.Cmd, *os.File, error) {
	return nil, nil, fmt.Errorf("sing-box launch not yet implemented on Windows")
}
