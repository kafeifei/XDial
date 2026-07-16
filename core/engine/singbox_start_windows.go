//go:build windows

package engine

import (
	"fmt"
	"io"
	"os"
	"os/exec"
)

func startSingBoxCmd(singboxBin, configPath, workDir string, output io.Writer) (*exec.Cmd, *os.File, error) {
	return nil, nil, fmt.Errorf("sing-box launch not yet implemented on Windows")
}
