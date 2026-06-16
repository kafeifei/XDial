package engine

import (
	"fmt"
	"os"
	"os/exec"
)

func findSingBox() (string, error) {
	for _, p := range platformSingBoxCandidates() {
		if _, err := os.Stat(p); err == nil {
			return p, nil
		}
	}
	p, err := exec.LookPath("sing-box")
	if err != nil {
		return "", fmt.Errorf("sing-box not found in PATH")
	}
	return p, nil
}
