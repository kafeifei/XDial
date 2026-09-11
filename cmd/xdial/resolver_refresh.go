package main

import (
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Transparent Proxy 给每个被捕获的 UDP socket 只发一次 NEAppProxyUDPFlow：
// provider 关掉那个 flow 之后，macOS 不会再为同一个 socket 建新 flow，后续报文
// 被静默丢弃。mDNSResponder 每个 DNS 问题长期复用一个 querier socket 并无限重试，
// 所以 provider 停止（重装 / 退出 / 断开）时在途的查询会变成该域名对所有
// getaddrinfo 调用方的永久黑洞。XDial 的 NETransparentProxyNetworkSettings 不带
// dnsSettings，系统自己不会产生配置变更事件，只能由这个 root daemon 补一发
// SIGHUP：mDNSResponder 收到后重建 querier（新 socket → 新 flow）。
const (
	mdnsResponderProcessName = "mDNSResponder"
	pgrepBinary              = "/usr/bin/pgrep"
	// 一次切换在宿主侧会连着触发好几个点（事务提交、状态落定、启动就绪），
	// 一发 SIGHUP 就够；余下的在这里合并掉。
	resolverRefreshMinInterval = time.Second
)

type resolverRefresher struct {
	mu       sync.Mutex
	lastHUP  time.Time
	hasHUP   bool
	now      func() time.Time
	findPID  func() (int, error)
	sendHUP  func(pid int) error
	interval time.Duration
}

func newResolverRefresher() *resolverRefresher {
	return &resolverRefresher{
		now:      time.Now,
		findPID:  findMDNSResponderPID,
		sendHUP:  sendHangup,
		interval: resolverRefreshMinInterval,
	}
}

// refresh 发一次 SIGHUP，返回给客户端的 ok 与原因。失败只报错不改变任何状态：
// 这条路径是尽力而为的补救，不参与连接事务的成败。
// 只有真正发出去的 SIGHUP 才记时间戳，失败不会把后面一次也一起吞掉。
func (r *resolverRefresher) refresh(trigger string) (bool, string) {
	r.mu.Lock()
	defer r.mu.Unlock()

	now := r.now()
	if r.hasHUP && now.Sub(r.lastHUP) < r.interval {
		slog.Info("resolver refresh coalesced", "trigger", trigger)
		return true, "coalesced with recent refresh"
	}

	pid, err := r.findPID()
	if err != nil {
		slog.Warn("resolver refresh failed", "trigger", trigger, "err", err)
		return false, err.Error()
	}
	if err := r.sendHUP(pid); err != nil {
		message := fmt.Sprintf("signal %s (pid %d): %v", mdnsResponderProcessName, pid, err)
		slog.Warn("resolver refresh failed", "trigger", trigger, "err", message)
		return false, message
	}

	r.lastHUP = now
	r.hasHUP = true
	slog.Info("resolver refreshed", "trigger", trigger, "pid", pid)
	return true, ""
}

// pgrep -x 只匹配进程名全等，避免 HUP 到别的进程上。mDNSResponder 是单实例，
// 取第一行即可。
func findMDNSResponderPID() (int, error) {
	out, err := exec.Command(pgrepBinary, "-x", mdnsResponderProcessName).Output()
	if err != nil {
		return 0, fmt.Errorf("locate %s: %w", mdnsResponderProcessName, err)
	}
	for _, line := range strings.Split(string(out), "\n") {
		pid, convErr := strconv.Atoi(strings.TrimSpace(line))
		if convErr == nil && pid > 0 {
			return pid, nil
		}
	}
	return 0, fmt.Errorf("%s is not running", mdnsResponderProcessName)
}

func sendHangup(pid int) error {
	process, err := os.FindProcess(pid)
	if err != nil {
		return err
	}
	return process.Signal(syscall.SIGHUP)
}
