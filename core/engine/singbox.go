package engine

import (
	"fmt"
	"log/slog"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/kafeifei/xdial/core/config"
)

const singBoxStopTimeout = 2 * time.Second

type SingBoxProcess struct {
	cmd        *exec.Cmd
	pipeW      *os.File
	configPath string
	statePath  string
	onAuth     func(string)
}

func NewSingBoxProcess(basePath, statePath string, onAuth func(string)) *SingBoxProcess {
	return &SingBoxProcess{
		configPath: filepath.Join(basePath, "sing-box.json"),
		statePath:  statePath,
		onAuth:     onAuth,
	}
}

func (s *SingBoxProcess) Start(profile *config.Profile, socksAddr, vpnServerIP string) error {
	var port int
	if socksAddr != "" {
		_, portStr, ok := strings.Cut(socksAddr, ":")
		if !ok {
			return fmt.Errorf("invalid socks addr: %s", socksAddr)
		}
		port, _ = strconv.Atoi(portStr)
		if port == 0 {
			return fmt.Errorf("invalid socks addr: %s", socksAddr)
		}
	}
	if profile.ActiveVPNLine() != nil && port == 0 {
		return fmt.Errorf("active AnyConnect line requires a SOCKS address")
	}

	cfgData, err := config.GenerateSingBoxFor(profile, port, vpnServerIP, config.PlatformMacOS, s.statePath)
	if err != nil {
		return fmt.Errorf("generate config: %w", err)
	}
	return s.startConfig(cfgData)
}

func (s *SingBoxProcess) startConfig(cfgData []byte) error {
	// 0600：配置内含订阅节点的明文密码，且由同一 root 进程写入并启动 sing-box，
	// 无需他人可读
	if err := os.WriteFile(s.configPath, cfgData, 0600); err != nil {
		return fmt.Errorf("write config: %w", err)
	}

	slog.Info("sing-box config written", "path", s.configPath)

	singboxBin, err := findSingBox()
	if err != nil {
		return err
	}
	check := exec.Command(singboxBin, "check", "-c", s.configPath, "-D", filepath.Dir(s.configPath))
	if output, err := check.CombinedOutput(); err != nil {
		return fmt.Errorf("check config: %w: %s", err, strings.TrimSpace(string(output)))
	}

	logWriter := &singBoxLogWriter{onAuth: s.onAuth}
	cmd, pipeW, err := startSingBoxCmd(singboxBin, s.configPath, filepath.Dir(s.configPath), logWriter)
	if err != nil {
		return err
	}

	s.cmd = cmd
	s.pipeW = pipeW

	slog.Info("sing-box started", "pid", s.cmd.Process.Pid)
	return nil
}

func (s *SingBoxProcess) Stop() {
	s.stop(singBoxStopTimeout)
}

func (s *SingBoxProcess) stop(timeout time.Duration) {
	if s.pipeW != nil {
		s.pipeW.Close()
		s.pipeW = nil
	}
	if s.cmd != nil && s.cmd.Process != nil {
		_ = s.cmd.Process.Signal(os.Interrupt)
		done := make(chan error, 1)
		go func() { done <- s.cmd.Wait() }()
		select {
		case <-done:
		case <-time.After(timeout):
			slog.Warn("sing-box did not stop in time, killing it", "timeout", timeout)
			_ = s.cmd.Process.Kill()
			<-done
		}
		s.cmd = nil
	}
	os.Remove(s.configPath)
}

type singBoxLogWriter struct {
	mu      sync.Mutex
	pending string
	onAuth  func(string)
}

func (w *singBoxLogWriter) Write(p []byte) (int, error) {
	_, _ = os.Stdout.Write(p)

	w.mu.Lock()
	w.pending += string(p)
	var authURLs []string
	for {
		newline := strings.IndexByte(w.pending, '\n')
		if newline < 0 {
			break
		}
		line := w.pending[:newline]
		w.pending = w.pending[newline+1:]
		if authURL := parseTailscaleAuthURL(line); authURL != "" {
			authURLs = append(authURLs, authURL)
		}
	}
	w.mu.Unlock()

	if w.onAuth != nil {
		for _, authURL := range authURLs {
			w.onAuth(authURL)
		}
	}
	return len(p), nil
}

func parseTailscaleAuthURL(line string) string {
	const marker = "Waiting for authentication:"
	markerIndex := strings.Index(line, marker)
	if markerIndex < 0 {
		return ""
	}
	fields := strings.Fields(line[markerIndex+len(marker):])
	if len(fields) == 0 {
		return ""
	}
	candidate := strings.TrimSuffix(fields[0], "\x1b[0m")
	candidate = strings.TrimRight(candidate, ".,")
	parsed, err := url.Parse(candidate)
	if err != nil || parsed.Host == "" || (parsed.Scheme != "https" && parsed.Scheme != "http") {
		return ""
	}
	return parsed.String()
}
