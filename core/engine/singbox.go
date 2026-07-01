package engine

import (
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/kafeifei/xdial/core/config"
)

type SingBoxProcess struct {
	cmd        *exec.Cmd
	pipeW      *os.File
	configPath string
}

func NewSingBoxProcess(basePath string) *SingBoxProcess {
	return &SingBoxProcess{
		configPath: filepath.Join(basePath, "sing-box.json"),
	}
}

func (s *SingBoxProcess) Start(profile *config.Profile, socksAddr, vpnServerIP string) error {
	_, portStr, _ := strings.Cut(socksAddr, ":")
	port, _ := strconv.Atoi(portStr)
	if port == 0 {
		return fmt.Errorf("invalid socks addr: %s", socksAddr)
	}

	cfgData, err := config.GenerateSingBox(profile, port, vpnServerIP)
	if err != nil {
		return fmt.Errorf("generate config: %w", err)
	}

	if err := os.WriteFile(s.configPath, cfgData, 0644); err != nil {
		return fmt.Errorf("write config: %w", err)
	}

	slog.Info("sing-box config written", "path", s.configPath)

	singboxBin, err := findSingBox()
	if err != nil {
		return err
	}

	cmd, pipeW, err := startSingBoxCmd(singboxBin, s.configPath, filepath.Dir(s.configPath))
	if err != nil {
		return err
	}

	s.cmd = cmd
	s.pipeW = pipeW

	slog.Info("sing-box started", "pid", s.cmd.Process.Pid)
	return nil
}

func (s *SingBoxProcess) Stop() {
	if s.cmd != nil && s.cmd.Process != nil {
		s.cmd.Process.Signal(os.Interrupt)
		s.cmd.Wait()
		s.cmd = nil
	}
	if s.pipeW != nil {
		s.pipeW.Close()
		s.pipeW = nil
	}
	os.Remove(s.configPath)
}
