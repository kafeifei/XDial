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

	r, w, err := os.Pipe()
	if err != nil {
		return fmt.Errorf("create pipe: %w", err)
	}

	// 哨兵在后台监控 pipe 读端，helper 死时 OS 关闭写端，read 返回，杀 sing-box。
	// exec 3>&- 关掉 sing-box 继承的 fd 3，只有哨兵持有。
	// $$ 在解析时展开为 shell PID，exec 后该 PID 就是 sing-box。
	wrapper := fmt.Sprintf(
		`(read <&3; kill $$) & exec 3>&- '%s' run -c '%s' -D '%s'`,
		singboxBin, s.configPath, filepath.Dir(s.configPath),
	)

	s.cmd = exec.Command("sh", "-c", wrapper)
	s.cmd.ExtraFiles = []*os.File{r}
	s.cmd.Stdout = os.Stdout
	s.cmd.Stderr = os.Stderr

	if err := s.cmd.Start(); err != nil {
		r.Close()
		w.Close()
		return fmt.Errorf("start sing-box: %w", err)
	}

	r.Close()
	s.pipeW = w

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

func findSingBox() (string, error) {
	candidates := []string{
		"/opt/homebrew/bin/sing-box",
		"/usr/local/bin/sing-box",
	}
	for _, p := range candidates {
		if _, err := os.Stat(p); err == nil {
			return p, nil
		}
	}
	p, err := exec.LookPath("sing-box")
	if err != nil {
		return "", fmt.Errorf("sing-box not found; install with: brew install sing-box")
	}
	return p, nil
}
