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

// singBoxLogTailBytes 是异常退出时随错误带出的日志尾部长度。sing-box 的致命错误
// （如 "initial rule-set: ..."）就在最后几行，够定位又不至于把整段日志塞进 UI。
const singBoxLogTailBytes = 2048

type SingBoxProcess struct {
	mu         sync.Mutex
	cmd        *exec.Cmd
	pipeW      *os.File
	exited     chan struct{}
	stopping   bool
	configPath string
	statePath  string
	onAuth     func(string)
	onExit     func(error)
}

// onExit 在 sing-box 子进程非正常退出（不是我们主动 Stop）时被调用。
// 必需而非可选：sing-box 的启动期错误（规则集首次下载失败、路由构造失败等）
// 都发生在 spawn 之后，check 阶段查不出来；没人盯着退出码，调用方会一直停在
// "已连接"，用户看到的是"已连接但整机没网"。
func NewSingBoxProcess(basePath, statePath string, onAuth func(string), onExit func(error)) *SingBoxProcess {
	return &SingBoxProcess{
		configPath: filepath.Join(basePath, "sing-box.json"),
		statePath:  statePath,
		onAuth:     onAuth,
		onExit:     onExit,
	}
}

func (s *SingBoxProcess) Start(profile *config.Profile, socksAddr, vpnServerIP string, enterpriseDNS []string) error {
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

	cfgData, err := config.GenerateSingBoxDesktop(profile, port, vpnServerIP, s.statePath, enterpriseDNS)
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

	exited := make(chan struct{})
	s.mu.Lock()
	s.cmd = cmd
	s.pipeW = pipeW
	s.exited = exited
	s.mu.Unlock()

	go s.watch(cmd, exited, logWriter)

	slog.Info("sing-box started", "pid", cmd.Process.Pid)
	return nil
}

// watch 独占 cmd.Wait()：先关 exited 让 stop() 能同步等到回收，再判断这次退出
// 是不是我们主动要的，不是就把 sing-box 自己打印的错误尾部交给 onExit。
func (s *SingBoxProcess) watch(cmd *exec.Cmd, exited chan struct{}, logWriter *singBoxLogWriter) {
	waitErr := cmd.Wait()
	close(exited)

	s.mu.Lock()
	expected := s.stopping || s.cmd != cmd
	onExit := s.onExit
	s.mu.Unlock()
	if expected || onExit == nil {
		return
	}

	reason := "exit status 0"
	if waitErr != nil {
		reason = waitErr.Error()
	}
	if tail := logWriter.Tail(); tail != "" {
		reason += ": " + tail
	}
	onExit(fmt.Errorf("sing-box 异常退出: %s", reason))
}

func (s *SingBoxProcess) Stop() {
	s.stop(singBoxStopTimeout)
}

func (s *SingBoxProcess) stop(timeout time.Duration) {
	s.mu.Lock()
	s.stopping = true
	cmd := s.cmd
	pipeW := s.pipeW
	exited := s.exited
	s.cmd = nil
	s.pipeW = nil
	s.exited = nil
	s.mu.Unlock()

	if pipeW != nil {
		pipeW.Close()
	}
	if cmd != nil && cmd.Process != nil {
		_ = cmd.Process.Signal(os.Interrupt)
		if exited == nil {
			// 没有 watch goroutine（未经 startConfig 构造的实例）时自己回收。
			done := make(chan struct{})
			exited = done
			go func() { _ = cmd.Wait(); close(done) }()
		}
		select {
		case <-exited:
		case <-time.After(timeout):
			slog.Warn("sing-box did not stop in time, killing it", "timeout", timeout)
			_ = cmd.Process.Kill()
			<-exited
		}
	}
	os.Remove(s.configPath)
}

type singBoxLogWriter struct {
	mu      sync.Mutex
	pending string
	tail    []byte
	onAuth  func(string)
}

// Tail 返回最近 singBoxLogTailBytes 字节的输出，供异常退出时定位原因。
func (w *singBoxLogWriter) Tail() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return strings.TrimSpace(string(w.tail))
}

func (w *singBoxLogWriter) Write(p []byte) (int, error) {
	_, _ = os.Stdout.Write(p)

	w.mu.Lock()
	w.tail = append(w.tail, p...)
	if len(w.tail) > singBoxLogTailBytes {
		w.tail = append(w.tail[:0], w.tail[len(w.tail)-singBoxLogTailBytes:]...)
	}
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
