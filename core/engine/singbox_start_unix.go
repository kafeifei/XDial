//go:build darwin || linux

package engine

import (
	"fmt"
	"os"
	"os/exec"
)

// startSingBoxCmd launches sing-box with a pipe sentinel that kills it if the parent dies.
func startSingBoxCmd(singboxBin, configPath, workDir string) (*exec.Cmd, *os.File, error) {
	r, w, err := os.Pipe()
	if err != nil {
		return nil, nil, fmt.Errorf("create pipe: %w", err)
	}

	wrapper := fmt.Sprintf(
		`(read <&3; kill $$) & exec 3>&- '%s' run -c '%s' -D '%s'`,
		singboxBin, configPath, workDir,
	)

	cmd := exec.Command("sh", "-c", wrapper)
	cmd.ExtraFiles = []*os.File{r}
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Start(); err != nil {
		r.Close()
		w.Close()
		return nil, nil, fmt.Errorf("start sing-box: %w", err)
	}

	r.Close()
	return cmd, w, nil
}
