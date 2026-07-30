package engine

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/kafeifei/xdial/core/config"
)

// fakeDNSRunner 替掉真正的 networksetup：单测绝不允许改动开发机的系统 DNS。
// 它是有状态的——-setdnsservers 的结果会被后续 -getdnsservers 读到，这样"上一次
// 没恢复干净"之类的时序场景才能真实复现。
type fakeDNSRunner struct {
	mu      sync.Mutex
	list    string
	listErr error
	current map[string]string
	readErr map[string]error
	setErr  map[string]error
	// setFailTimes 让同一个服务的前 N 次 -setdnsservers 失败、之后成功。恢复的两级
	// 兜底（原值 → 原值重试 → Empty）只能用这种"失败次数"的方式精确卡住。
	setFailTimes map[string]int
	// setHangs 里的服务会让 -setdnsservers 阻塞到 ctx 超时为止，复现 networksetup
	// 卡在 SystemConfiguration 提交上、被 deadline 杀掉、改动是否已生效不可知的场景。
	setHangs map[string]bool
	// setInlineError 里的服务会让 -setdnsservers 走 networksetup 的真实怪癖：退出码
	// 0，错误只写在 stdout 的 "** Error" 行里。
	setInlineError map[string]bool
	// route -n get 的伪造输出。默认就是真机上"已就绪"的样子：接管地址命中 auto_route
	// 装的 128.0.0.0/1 这条 sub-range，RTF_GATEWAY，下一跳是 tun 自己的地址。
	// routeGateway 为空 = 不打印 gateway 行，也就是命中了一条 link 路由。
	routeIface       string
	routeDestination string
	routeGateway     string
	routeErr         error

	calls           []string
	deadlineMissing []string
}

func newFakeDNSRunner(list string) *fakeDNSRunner {
	return &fakeDNSRunner{
		list:             list,
		current:          map[string]string{},
		readErr:          map[string]error{},
		setErr:           map[string]error{},
		setFailTimes:     map[string]int{},
		setHangs:         map[string]bool{},
		setInlineError:   map[string]bool{},
		routeIface:       "utun7",
		routeDestination: "128.0.0.0",
		routeGateway:     dnsTakeoverGateway,
	}
}

const dnsNotSetOutput = "There aren't any DNS Servers set on %s."

// unknownServiceOutput 复刻真机行为：服务名不存在时 networksetup 把错误写进
// stdout（"** Error: ..."），退出码并不总是非零。
const unknownServiceOutput = "NoSuchService is not a recognized network service.\n** Error: The parameters were not valid."

// knows 判定服务名是否被 networksetup 认识：以 -listallnetworkservices 的输出为准，
// 带 * 的禁用服务同样是"认识但禁用"。
func (f *fakeDNSRunner) knows(service string) bool {
	for _, line := range strings.Split(f.list, "\n") {
		if strings.TrimPrefix(strings.TrimSpace(line), "*") == service {
			return true
		}
	}
	return false
}

func (f *fakeDNSRunner) Run(ctx context.Context, name string, args ...string) (string, error) {
	f.mu.Lock()

	call := strings.TrimSpace(name + " " + strings.Join(args, " "))
	f.calls = append(f.calls, call)
	// 用户铁律：一切外部命令必须带超时。没有 deadline 就当调用方写错了。
	if _, ok := ctx.Deadline(); !ok {
		f.deadlineMissing = append(f.deadlineMissing, call)
		f.mu.Unlock()
		return "", errors.New("命令没有超时上限")
	}

	if name == routeBinary {
		iface, destination, gateway, err := f.routeIface, f.routeDestination, f.routeGateway, f.routeErr
		f.mu.Unlock()
		if err != nil {
			return "", err
		}
		out := fmt.Sprintf("   route to: %s\ndestination: %s\n       mask: 128.0.0.0\n", dnsTakeoverAddress, destination)
		if gateway != "" {
			// 真机上 gateway 行只在 RTF_GATEWAY 路由上出现；下层虚拟接口的 link
			// 路由不打印这一行。
			out += fmt.Sprintf("    gateway: %s\n", gateway)
		}
		return out + fmt.Sprintf("  interface: %s\n", iface), nil
	}
	if name != networksetupBinary {
		// dscacheutil / killall：缓存刷新是尽力而为，这里恒成功。
		f.mu.Unlock()
		return "", nil
	}

	switch args[0] {
	case "-listallnetworkservices":
		list, err := f.list, f.listErr
		f.mu.Unlock()
		return list, err
	case "-getdnsservers":
		service := args[1]
		if !f.knows(service) {
			f.mu.Unlock()
			return unknownServiceOutput, nil
		}
		if err := f.readErr[service]; err != nil {
			f.mu.Unlock()
			return "", err
		}
		value, ok := f.current[service]
		f.mu.Unlock()
		if !ok {
			return fmt.Sprintf(dnsNotSetOutput, service), nil
		}
		return value, nil
	case "-setdnsservers":
		service := args[1]
		if !f.knows(service) {
			f.mu.Unlock()
			return unknownServiceOutput, nil
		}
		if f.setInlineError[service] {
			f.mu.Unlock()
			return unknownServiceOutput, nil
		}
		if f.setHangs[service] {
			f.mu.Unlock()
			// 复刻 exec.CommandContext 的行为：ctx 到点把进程杀掉，返回的是那次 kill
			// 导致的错误，而"改动是否已经提交"无从得知。
			<-ctx.Done()
			return "", errors.New("signal: killed")
		}
		if remaining := f.setFailTimes[service]; remaining > 0 {
			f.setFailTimes[service] = remaining - 1
			f.mu.Unlock()
			return "", errors.New("exit status 1")
		}
		if err := f.setErr[service]; err != nil {
			f.mu.Unlock()
			return "", err
		}
		servers := args[2:]
		if len(servers) == 1 && servers[0] == "Empty" {
			delete(f.current, service)
		} else {
			f.current[service] = strings.Join(servers, "\n")
		}
		f.mu.Unlock()
		return "", nil
	}
	f.mu.Unlock()
	return "", fmt.Errorf("unexpected networksetup args: %v", args)
}

func (f *fakeDNSRunner) setCalls() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []string
	for _, call := range f.calls {
		if strings.Contains(call, "-setdnsservers") {
			out = append(out, strings.TrimPrefix(call, networksetupBinary+" -setdnsservers "))
		}
	}
	return out
}

func (f *fakeDNSRunner) callCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.calls)
}

func (f *fakeDNSRunner) called(substring string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, call := range f.calls {
		if strings.Contains(call, substring) {
			return true
		}
	}
	return false
}

func (f *fakeDNSRunner) currentOf(service string) string {
	f.mu.Lock()
	defer f.mu.Unlock()
	if value, ok := f.current[service]; ok {
		return value
	}
	return "dhcp"
}

// failSetTimes / clearSetErr 是给「后台重试」这类有并发 goroutine 的用例用的：直接
// 写 map 会和重试 goroutine 里的读撞成 data race。
func (f *fakeDNSRunner) failSetTimes(service string, times int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.setFailTimes[service] = times
}

func (f *fakeDNSRunner) clearSetErr() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.setErr = map[string]error{}
	f.setFailTimes = map[string]int{}
}

// setRoute 同理：有挂起的后台重试 goroutine 时直接写字段会撞 data race。
func (f *fakeDNSRunner) setRoute(iface, gateway string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.routeIface = iface
	f.routeGateway = gateway
}

func newTestTakeover(t *testing.T, runner commandRunner) *dnsTakeover {
	t.Helper()
	return newTestTakeoverIn(t, runner, t.TempDir())
}

// newTestTakeoverIn 指定 stateDir，用来模拟"同一台机器上换了一个进程"：残留状态文件
// 是唯一的跨进程载体。
func newTestTakeoverIn(t *testing.T, runner commandRunner, stateDir string) *dnsTakeover {
	t.Helper()
	takeover := &dnsTakeover{runner: runner, stateDir: stateDir, supported: true}
	// 恢复失败会留下一个后台重试 goroutine。测试结束前必须收掉，否则它会在测试之外
	// 继续操作 fake runner。
	t.Cleanup(takeover.Close)
	return takeover
}

func assertSetCalls(t *testing.T, runner *fakeDNSRunner, want ...string) {
	t.Helper()
	got := runner.setCalls()
	if len(got) != len(want) {
		t.Fatalf("set calls = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("set calls = %v, want %v", got, want)
		}
	}
}

func assertNoState(t *testing.T, takeover *dnsTakeover) {
	t.Helper()
	if _, err := os.Stat(takeover.statePath()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("state file must be gone, stat err = %v", err)
	}
}

func assertHasState(t *testing.T, takeover *dnsTakeover) dnsTakeoverState {
	t.Helper()
	data, err := os.ReadFile(takeover.statePath())
	if err != nil {
		t.Fatalf("state file must exist: %v", err)
	}
	var state dnsTakeoverState
	if err := json.Unmarshal(data, &state); err != nil {
		t.Fatalf("state file must be valid JSON: %v", err)
	}
	return state
}

// retryDoneChan 取后台重试 goroutine 的完成信号。必须持锁读：goroutine 自己也会动
// 这个字段。
func retryDoneChan(takeover *dnsTakeover) chan struct{} {
	takeover.mu.Lock()
	defer takeover.mu.Unlock()
	return takeover.retryDone
}

// takeoverFlags 快照几个受 t.mu 保护的判据字段。有挂起的后台重试 / 自愈 goroutine 时直接
// 读字段会和它们撞成 data race。
func takeoverFlags(takeover *dnsTakeover) (active bool, takenAddress string, unresolved bool) {
	takeover.mu.Lock()
	defer takeover.mu.Unlock()
	return takeover.active, takeover.takenAddress, takeover.unresolved
}

// waitFor 轮询等一个条件成立。一切等待都必须有上限：卡住要报告，不能无限等下去。
func waitFor(t *testing.T, within time.Duration, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(within)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("%s did not happen within %s", what, within)
		}
		time.Sleep(time.Millisecond)
	}
}

// recordingDNSCallback 收 OnError 上报，给"软失败只提醒一次"用。
type recordingDNSCallback struct {
	mu     sync.Mutex
	errors []string
}

func (c *recordingDNSCallback) OnStatusChanged(string) {}

func (c *recordingDNSCallback) OnError(code int, message string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.errors = append(c.errors, fmt.Sprintf("%d:%s", code, message))
}

func (c *recordingDNSCallback) snapshot() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]string(nil), c.errors...)
}

// blockingDNSCallback 把 OnError 卡住，用来把「自愈 tick 正在跑」这个状态拉长到可断言的
// 宽度。上报发生在 t.mu 之外，所以卡在这里能干净地隔离出「Close 到底有没有等 goroutine」。
type blockingDNSCallback struct {
	mu      sync.Mutex
	entered bool
	once    sync.Once
	release chan struct{}
}

func (c *blockingDNSCallback) OnStatusChanged(string) {}

func (c *blockingDNSCallback) OnError(int, string) {
	c.mu.Lock()
	c.entered = true
	c.mu.Unlock()
	<-c.release
}

func (c *blockingDNSCallback) hasEntered() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.entered
}

func (c *blockingDNSCallback) releaseAll() {
	c.once.Do(func() { close(c.release) })
}

func waitClosed(t *testing.T, done chan struct{}, within time.Duration) {
	t.Helper()
	if done == nil {
		t.Fatal("no background retry was scheduled")
	}
	select {
	case <-done:
	case <-time.After(within):
		t.Fatalf("background retry did not finish within %s", within)
	}
}

const twoServiceList = `An asterisk (*) denotes that a network service is disabled.
Wi-Fi
Thunderbolt Bridge`

// 接管地址必须是 tun 接口地址 +1，不能是接口地址本身：tun 自己的地址在内核路由表
// 里带 RTF_LOCAL，发往它的包被环回投递给本机协议栈，永远进不了 tun，hijack-dns 接
// 不住 → 系统 DNS 原地超时 → 整机解析全灭。这里直接和生成出来的 sing-box 配置对
// 齐：config 侧改了 tun 地址，这条会立刻炸出来。
func TestDNSTakeoverAddressIsTunAddressPlusOne(t *testing.T) {
	profile := &config.Profile{
		Lines:        []config.Line{{ID: "dir", Name: "直连", Type: config.LineTypeDirect, Enabled: true}},
		Modes:        []config.Mode{{ID: "m1", Name: "默认", DefaultLineID: "dir"}},
		ActiveModeID: "m1",
	}
	data, err := config.GenerateSingBoxDesktop(profile, 1080, "", t.TempDir(), nil, "en0")
	if err != nil {
		t.Fatalf("generate sing-box config: %v", err)
	}
	var parsed struct {
		Inbounds []struct {
			Type    string   `json:"type"`
			Address []string `json:"address"`
		} `json:"inbounds"`
	}
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatalf("parse sing-box config: %v", err)
	}

	var tunPrefix netip.Prefix
	for _, inbound := range parsed.Inbounds {
		if inbound.Type != "tun" {
			continue
		}
		for _, address := range inbound.Address {
			prefix, err := netip.ParsePrefix(address)
			if err == nil && prefix.Addr().Is4() {
				tunPrefix = prefix
			}
		}
	}
	if !tunPrefix.IsValid() {
		t.Fatal("no IPv4 tun address in generated config")
	}

	want := tunPrefix.Addr().Next()
	if dnsTakeoverAddress != want.String() {
		t.Fatalf("dnsTakeoverAddress = %s, want tun addr + 1 = %s (tun %s)", dnsTakeoverAddress, want, tunPrefix)
	}
	if !tunPrefix.Contains(want) {
		t.Fatalf("%s must fall inside the tun prefix %s", want, tunPrefix)
	}
	if want == tunPrefix.Addr() {
		t.Fatal("takeover address must not be the tun interface address itself (RTF_LOCAL loopback)")
	}

	// 就绪探测的判据是「gateway == tun 地址」，所以这个常量也必须跟着 config 走：
	// 它就是接管地址的前一个地址，即 tun 接口地址本身。任何一侧漂移都在这里炸出来。
	if dnsTakeoverGateway != tunPrefix.Addr().String() {
		t.Fatalf("dnsTakeoverGateway = %s, want the tun interface address %s", dnsTakeoverGateway, tunPrefix.Addr())
	}
	if prev := netip.MustParseAddr(dnsTakeoverAddress).Prev(); dnsTakeoverGateway != prev.String() {
		t.Fatalf("dnsTakeoverGateway = %s, want takeover addr - 1 = %s", dnsTakeoverGateway, prev)
	}

	// 结构性地址判据（isTakeoverAddress 的第二段）用的网段也必须与生成出来的 tun 网段
	// 同源。漂移的两个方向都致命：网段变窄会漏认历史接管地址，把死地址永久留在系统里；
	// 网段变宽会把用户自己配的 DNS 误判成我们的残留，去清一个我们从没碰过的服务。
	if masked := tunPrefix.Masked(); dnsTakeoverPrefix != masked {
		t.Fatalf("dnsTakeoverPrefix = %s, want the generated tun prefix %s", dnsTakeoverPrefix, masked)
	}
	if !dnsTakeoverPrefix.Contains(want) {
		t.Fatalf("takeover address %s must fall inside %s", want, dnsTakeoverPrefix)
	}
	if !dnsTakeoverPrefix.Contains(netip.MustParseAddr(dnsTakeoverGateway)) {
		t.Fatalf("gateway %s must fall inside %s", dnsTakeoverGateway, dnsTakeoverPrefix)
	}
}

// 主路径：手工设过 DNS 的服务按原列表恢复，DHCP 的服务恢复成 Empty。
func TestDNSTakeoverRoundTrip(t *testing.T) {
	runner := newFakeDNSRunner(twoServiceList)
	runner.current["Wi-Fi"] = "1.1.1.1\n8.8.8.8"
	takeover := newTestTakeover(t, runner)

	if err := takeover.Takeover(); err != nil {
		t.Fatalf("Takeover: %v", err)
	}
	assertSetCalls(t,
		runner,
		"Wi-Fi "+dnsTakeoverAddress,
		"Thunderbolt Bridge "+dnsTakeoverAddress,
	)
	state := assertHasState(t, takeover)
	if len(state.Services) != 2 ||
		strings.Join(state.Services[0].Servers, ",") != "1.1.1.1,8.8.8.8" ||
		len(state.Services[1].Servers) != 0 {
		t.Fatalf("state must record original values: %+v", state.Services)
	}
	if !runner.called("dscacheutil") || !runner.called("mDNSResponder") {
		t.Fatal("DNS cache must be flushed")
	}
	if !runner.called(routeBinary) {
		t.Fatal("tun route readiness must be probed before takeover")
	}

	if err := takeover.Restore(); err != nil {
		t.Fatalf("Restore: %v", err)
	}
	assertSetCalls(t,
		runner,
		"Wi-Fi "+dnsTakeoverAddress,
		"Thunderbolt Bridge "+dnsTakeoverAddress,
		"Wi-Fi 1.1.1.1 8.8.8.8",
		"Thunderbolt Bridge Empty",
	)
	if runner.currentOf("Wi-Fi") != "1.1.1.1\n8.8.8.8" || runner.currentOf("Thunderbolt Bridge") != "dhcp" {
		t.Fatalf("system DNS not restored: %q / %q", runner.currentOf("Wi-Fi"), runner.currentOf("Thunderbolt Bridge"))
	}
	assertNoState(t, takeover)
	if takeover.active {
		t.Fatal("takeover must not stay active after restore")
	}
}

// 说明首行与带 * 的禁用服务都不是可改 DNS 的目标。
func TestDNSTakeoverSkipsHeaderAndDisabledServices(t *testing.T) {
	runner := newFakeDNSRunner(`An asterisk (*) denotes that a network service is disabled.
*iPhone USB
Wi-Fi
`)
	takeover := newTestTakeover(t, runner)
	if err := takeover.Takeover(); err != nil {
		t.Fatalf("Takeover: %v", err)
	}
	assertSetCalls(t, runner, "Wi-Fi "+dnsTakeoverAddress)
}

// 单个服务失败不许中断整体：读不到原值的服务跳过（没有恢复依据不碰），设置失败的
// 服务照旧留在记录里（恢复时写回原值是无害的幂等操作）。
func TestDNSTakeoverContinuesAfterPerServiceFailure(t *testing.T) {
	runner := newFakeDNSRunner(`Wi-Fi
Thunderbolt Bridge
Surge`)
	runner.current["Wi-Fi"] = "1.1.1.1"
	runner.readErr["Thunderbolt Bridge"] = errors.New("exit status 4")
	runner.setErr["Surge"] = errors.New("exit status 1")
	takeover := newTestTakeover(t, runner)

	if err := takeover.Takeover(); err != nil {
		t.Fatalf("Takeover must survive per-service failures: %v", err)
	}
	if !takeover.active {
		t.Fatal("takeover must be active when at least one service applied")
	}
	assertSetCalls(t, runner, "Wi-Fi "+dnsTakeoverAddress, "Surge "+dnsTakeoverAddress)
	state := assertHasState(t, takeover)
	if len(state.Services) != 2 || state.Services[1].Service != "Surge" {
		t.Fatalf("unreadable service must be excluded, applied-failed service kept: %+v", state.Services)
	}
}

// 一个服务都没改成、且每一条失败都可证明未生效（退出码非零 / networksetup 自己报
// 错）：系统 DNS 还是原样，不许留状态文件（否则下次启动会拿它去"恢复"，把没碰过的
// 服务改掉），也不许进接管态。
func TestDNSTakeoverAllServicesProvablyFailed(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.setErr["Wi-Fi"] = errors.New("exit status 1")
	takeover := newTestTakeover(t, runner)

	if err := takeover.Takeover(); err == nil {
		t.Fatal("Takeover must fail when nothing was applied")
	}
	if takeover.active {
		t.Fatal("failed takeover must not be active")
	}
	assertNoState(t, takeover)
}

// 同上，但失败形态是 networksetup 的真实怪癖："** Error" 写在 stdout、退出码仍是
// 0。这同样算"可证明未生效"（参数根本没被接受），所以状态文件必须删掉。
func TestDNSTakeoverInlineErrorRemovesState(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = "1.1.1.1"
	runner.setInlineError["Wi-Fi"] = true
	takeover := newTestTakeover(t, runner)

	if err := takeover.Takeover(); err == nil {
		t.Fatal("an inline ** Error must fail the takeover")
	}
	if takeover.active {
		t.Fatal("provably-unapplied takeover must not be active")
	}
	assertNoState(t, takeover)
}

// 残留保护：本轮一个服务都没改成、且每一条失败都可证明未生效，但当前值里观测到了
// 接管地址 —— 系统里还躺着一次没解除干净的劫持。这时候删状态文件等于把唯一的恢复
// 依据连同"需要恢复"这个信号一起烧掉，用户永久断网。文件必须留着。
func TestDNSTakeoverKeepsStateWhenHijackObservedButNothingApplied(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = dnsTakeoverAddress
	runner.setErr["Wi-Fi"] = errors.New("exit status 1")
	takeover := newTestTakeover(t, runner)

	if err := takeover.Takeover(); err == nil {
		t.Fatal("Takeover must fail when nothing was applied")
	}
	if takeover.active {
		t.Fatal("provably-unapplied takeover must not be active")
	}
	assertHasState(t, takeover)
}

// 同上，另一条触发线：本轮当前值都是干净的，但进来时磁盘上本来就有状态文件（上一次
// 的接管没证实解除）。这份文件是别人的恢复依据，本轮的失败不构成删它的理由。
func TestDNSTakeoverKeepsExistingStateWhenNothingApplied(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = "1.1.1.1"
	runner.setErr["Wi-Fi"] = errors.New("exit status 1")
	takeover := newTestTakeover(t, runner)

	if err := takeover.writeState(dnsTakeoverState{
		Version:  1,
		Address:  dnsTakeoverAddress,
		Services: []dnsServiceState{{Service: "Wi-Fi", Servers: []string{"8.8.8.8"}}},
	}); err != nil {
		t.Fatalf("writeState: %v", err)
	}

	if err := takeover.Takeover(); err == nil {
		t.Fatal("Takeover must fail when nothing was applied")
	}
	assertHasState(t, takeover)
}

// 注定失败的接管尝试（就绪探测都没过，一条 set 都没发）不许解除别人排好的恢复重试：
// 那份重试是系统 DNS 还指着死 tun 时唯一的自愈手段。
func TestDNSTakeoverKeepsPendingRetryWhenProbeFails(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = "1.1.1.1"
	takeover := newTestTakeover(t, runner)
	takeover.retryInterval = time.Hour
	takeover.probeWindow = 30 * time.Millisecond
	takeover.probeInterval = 5 * time.Millisecond

	if err := takeover.Takeover(); err != nil {
		t.Fatalf("Takeover: %v", err)
	}
	runner.failSetTimes("Wi-Fi", 3)
	if err := takeover.Restore(); err == nil {
		t.Fatal("Restore must fail first, otherwise no retry is scheduled")
	}
	done := retryDoneChan(takeover)
	if done == nil {
		t.Fatal("no background retry was scheduled")
	}

	// 路由这次没就绪：接管必然被跳过，一条 set 都不会发。
	runner.setRoute("en0", "192.168.1.1")
	if err := takeover.Takeover(); err == nil {
		t.Fatal("takeover must be skipped when the route is not ready")
	}
	select {
	case <-done:
		t.Fatal("a takeover that never touched system DNS must not cancel the pending restore retry")
	default:
	}

	// 路由就绪、接管真的发生了：这时才该取消（否则重试醒来会把刚指好的 DNS 推翻）。
	runner.clearSetErr()
	runner.setRoute("utun7", dnsTakeoverGateway)
	if err := takeover.Takeover(); err != nil {
		t.Fatalf("re-Takeover: %v", err)
	}
	waitClosed(t, done, 2*time.Second)
}

// 旧记录里本轮没记下的条目分两种命运，Takeover 的 carry-over 必须按服务三分类来判：
// 「被禁用但 networksetup 还认识」的服务随时可能被重新启用，它的 DNS 里可能还留着上一次
// 接管写进去的地址，而恢复依据只存在于那份旧记录里 —— 必须原样并入（本轮不许碰它）。
// 「networksetup 压根不认识」的服务已经被删掉，不会再回来，带着它只会让此后每一次恢复
// 都白发一条注定 "** Error" 的命令，并把整体永久钉在"还有待恢复项"上 —— 依据该弃用。
func TestDNSTakeoverCarriesOverDisabledButDropsDeletedServices(t *testing.T) {
	runner := newFakeDNSRunner(`An asterisk (*) denotes that a network service is disabled.
*iPhone USB
Wi-Fi`)
	runner.current["Wi-Fi"] = "1.1.1.1"
	takeover := newTestTakeover(t, runner)

	if err := takeover.writeState(dnsTakeoverState{
		Version:   1,
		Addresses: []string{dnsTakeoverAddress},
		Services: []dnsServiceState{
			{Service: "Wi-Fi", Servers: []string{"1.1.1.1"}},
			{Service: "iPhone USB", Servers: []string{"8.8.8.8"}},
			{Service: "Deleted Ethernet"},
		},
	}); err != nil {
		t.Fatalf("writeState: %v", err)
	}

	if err := takeover.Takeover(); err != nil {
		t.Fatalf("Takeover: %v", err)
	}
	// 只有本轮枚举到的 Wi-Fi 被改；禁用的 / 已删除的服务一条命令都不发。
	assertSetCalls(t, runner, "Wi-Fi "+dnsTakeoverAddress)

	state := assertHasState(t, takeover)
	byService := map[string][]string{}
	for _, entry := range state.Services {
		byService[entry.Service] = entry.Servers
	}
	if len(state.Services) != 2 {
		t.Fatalf("exactly Wi-Fi and the disabled iPhone USB must be recorded: %+v", state.Services)
	}
	if strings.Join(byService["iPhone USB"], ",") != "8.8.8.8" {
		t.Fatalf("recovery basis of the disabled service lost: %+v", state.Services)
	}
	if _, ok := byService["Deleted Ethernet"]; ok {
		t.Fatalf("recovery basis of a deleted service must be dropped: %+v", state.Services)
	}
}

// 同一个"别烧掉恢复依据"的要求，另一类触发：服务枚举得到但当前值读不出来，本轮按
// 「没有依据不许碰」跳过了它。writeState 是整份覆盖，旧记录里它的原值必须并入 ——
// 否则它可能永久指着已消失的 tun，而再没有任何路径知道该把它恢复成什么。
func TestDNSTakeoverCarriesOverUnreadableServiceFromPreviousState(t *testing.T) {
	runner := newFakeDNSRunner(twoServiceList)
	runner.current["Wi-Fi"] = "1.1.1.1"
	runner.readErr["Thunderbolt Bridge"] = errors.New("exit status 4")
	takeover := newTestTakeover(t, runner)

	if err := takeover.writeState(dnsTakeoverState{
		Version: 1,
		Address: dnsTakeoverAddress,
		Services: []dnsServiceState{
			{Service: "Thunderbolt Bridge", Servers: []string{"7.7.7.7"}},
		},
	}); err != nil {
		t.Fatalf("writeState: %v", err)
	}

	if err := takeover.Takeover(); err != nil {
		t.Fatalf("Takeover: %v", err)
	}
	assertSetCalls(t, runner, "Wi-Fi "+dnsTakeoverAddress)

	state := assertHasState(t, takeover)
	if len(state.Services) != 2 || state.Services[1].Service != "Thunderbolt Bridge" ||
		strings.Join(state.Services[1].Servers, ",") != "7.7.7.7" {
		t.Fatalf("recovery basis of the unreadable service lost: %+v", state.Services)
	}
}

func TestDNSTakeoverNoReadableService(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.readErr["Wi-Fi"] = errors.New("exit status 4")
	takeover := newTestTakeover(t, runner)

	if err := takeover.Takeover(); err == nil {
		t.Fatal("Takeover must fail when no original value could be read")
	}
	assertSetCalls(t, runner)
	assertNoState(t, takeover)
}

func TestDNSTakeoverListFailure(t *testing.T) {
	runner := newFakeDNSRunner("")
	runner.listErr = errors.New("exit status 1")
	takeover := newTestTakeover(t, runner)

	if err := takeover.Takeover(); err == nil {
		t.Fatal("Takeover must fail when services cannot be enumerated")
	}
	assertNoState(t, takeover)
}

// 设置超时 = networksetup 被 deadline 杀掉，改动可能已经提交到 SystemConfiguration。
// 必须按「已改」处理：保留状态文件 + 进接管态，否则以后没有任何路径会去救这个可能
// 已经指向 tun 的服务，用户就永久断网了。
func TestDNSTakeoverTimeoutKeepsStateAndGoesActive(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = "1.1.1.1"
	runner.setHangs["Wi-Fi"] = true
	takeover := newTestTakeover(t, runner)
	takeover.cmdTimeout = 30 * time.Millisecond

	err := takeover.Takeover()
	if err == nil {
		t.Fatal("Takeover must report the unknown outcome")
	}
	if !takeover.active {
		t.Fatal("timed-out takeover must be treated as active: the change may already be committed")
	}
	state := assertHasState(t, takeover)
	if len(state.Services) != 1 || strings.Join(state.Services[0].Servers, ",") != "1.1.1.1" {
		t.Fatalf("original value must survive an unknown-outcome takeover: %+v", state.Services)
	}
}

// 总预算耗尽：剩下的服务连命令都不该发（发了也只会立刻被 kill），整体按部分失败
// 处理 —— 保留状态文件、进接管态。
func TestDNSTakeoverBudgetExhaustedKeepsState(t *testing.T) {
	runner := newFakeDNSRunner(twoServiceList)
	runner.current["Wi-Fi"] = "1.1.1.1"
	runner.setHangs["Wi-Fi"] = true
	takeover := newTestTakeover(t, runner)
	// 预算和单条上限一样长：第一条卡死的 set 就把整个预算吃光，第二个服务只能进
	// "预算耗尽"分支。
	takeover.budget = 300 * time.Millisecond
	takeover.cmdTimeout = 300 * time.Millisecond

	if err := takeover.Takeover(); err == nil {
		t.Fatal("Takeover must report failure when the budget ran out")
	}
	if !takeover.active {
		t.Fatal("budget exhaustion is an unknown outcome: must be treated as active")
	}
	assertHasState(t, takeover)
	assertSetCalls(t, runner, "Wi-Fi "+dnsTakeoverAddress)
}

// 重复接管必须是空操作。若第二次重新读一遍当前值，读到的是我们自己写进去的接管
// 地址，原值就被永久覆盖了。
func TestDNSTakeoverIsIdempotent(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = "1.1.1.1"
	takeover := newTestTakeover(t, runner)

	if err := takeover.Takeover(); err != nil {
		t.Fatalf("Takeover: %v", err)
	}
	firstState := assertHasState(t, takeover)
	callsAfterFirst := runner.callCount()

	if err := takeover.Takeover(); err != nil {
		t.Fatalf("second Takeover: %v", err)
	}
	if runner.callCount() != callsAfterFirst {
		t.Fatalf("second takeover ran commands: %v", runner.calls)
	}
	secondState := assertHasState(t, takeover)
	if !secondState.TakenAt.Equal(firstState.TakenAt) ||
		strings.Join(secondState.Services[0].Servers, ",") != "1.1.1.1" {
		t.Fatalf("original value overwritten by second takeover: %+v", secondState)
	}
}

// 接管时读到的当前值已经是我们的地址、且磁盘上没有旧记录 = 原值彻底不可知。记成
// DHCP，绝不把这个死地址当"原值"写回去。
func TestDNSTakeoverTreatsOwnAddressAsUnknown(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = dnsTakeoverAddress
	takeover := newTestTakeover(t, runner)

	if err := takeover.Takeover(); err != nil {
		t.Fatalf("Takeover: %v", err)
	}
	if state := assertHasState(t, takeover); len(state.Services[0].Servers) != 0 {
		t.Fatalf("hijacked address must not be recorded as original: %+v", state.Services)
	}
	if err := takeover.Restore(); err != nil {
		t.Fatalf("Restore: %v", err)
	}
	assertSetCalls(t, runner, "Wi-Fi "+dnsTakeoverAddress, "Wi-Fi Empty")
}

// hijacked 但剔掉接管地址之后还剩别的服务器：那是用户（或别的 VPN 客户端的配置监视器）
// 在我们接管期间写进去的新值，它才是该恢复回去的真相。拿一份过时的磁盘旧记录盖掉它就是
// 破坏 —— 沿用旧记录只在"剔完什么都不剩、原值确实不可知"时才成立。
func TestDNSTakeoverPrefersObservedServersOverStaleRecord(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = dnsTakeoverAddress + "\n9.9.9.9"
	takeover := newTestTakeover(t, runner)

	if err := takeover.writeState(dnsTakeoverState{
		Version:   1,
		Addresses: []string{dnsTakeoverAddress},
		Services:  []dnsServiceState{{Service: "Wi-Fi", Servers: []string{"1.1.1.1"}}},
	}); err != nil {
		t.Fatalf("writeState: %v", err)
	}

	if err := takeover.Takeover(); err != nil {
		t.Fatalf("Takeover: %v", err)
	}
	state := assertHasState(t, takeover)
	if len(state.Services) != 1 || strings.Join(state.Services[0].Servers, ",") != "9.9.9.9" {
		t.Fatalf("the freshly observed value must win over the stale record: %+v", state.Services)
	}

	if err := takeover.Restore(); err != nil {
		t.Fatalf("Restore: %v", err)
	}
	if runner.currentOf("Wi-Fi") != "9.9.9.9" {
		t.Fatalf("restore must put the observed value back, got %q", runner.currentOf("Wi-Fi"))
	}
}

// 但磁盘旧记录里还留着原值时必须沿用它，不许被"当前值就是接管地址"覆盖成 DHCP。
// 这就是"上次崩了、这次又接管"的现实路径：原值只存在于那份旧记录里（当前值剔掉接管
// 地址之后什么都不剩）。
func TestDNSTakeoverReusesRecordedOriginalWhenAlreadyHijacked(t *testing.T) {
	runner := newFakeDNSRunner(twoServiceList)
	runner.current["Wi-Fi"] = dnsTakeoverAddress
	runner.current["Thunderbolt Bridge"] = dnsTakeoverAddress
	takeover := newTestTakeover(t, runner)

	// 上一次接管留下的残留记录：Wi-Fi 有原值，Thunderbolt 本来就是 DHCP。
	if err := takeover.writeState(dnsTakeoverState{
		Version: 1,
		Address: dnsTakeoverAddress,
		Services: []dnsServiceState{
			{Service: "Wi-Fi", Servers: []string{"192.168.1.1", "1.1.1.1"}},
			{Service: "Thunderbolt Bridge"},
		},
	}); err != nil {
		t.Fatalf("writeState: %v", err)
	}

	if err := takeover.Takeover(); err != nil {
		t.Fatalf("Takeover: %v", err)
	}
	state := assertHasState(t, takeover)
	if len(state.Services) != 2 ||
		strings.Join(state.Services[0].Servers, ",") != "192.168.1.1,1.1.1.1" ||
		len(state.Services[1].Servers) != 0 {
		t.Fatalf("recorded originals must be carried over: %+v", state.Services)
	}

	if err := takeover.Restore(); err != nil {
		t.Fatalf("Restore: %v", err)
	}
	if runner.currentOf("Wi-Fi") != "192.168.1.1\n1.1.1.1" {
		t.Fatalf("original DNS lost across a crash + re-takeover: %q", runner.currentOf("Wi-Fi"))
	}
}

// 状态文件必须把「可能被我们写进系统 DNS 的全部地址」记成列表：当前常量 ∪ 本进程实际
// 用的 ∪ 旧记录里的历史地址。少认一个就等于把一个死地址永久留在系统里，而跨进程
// （SIGKILL / 掉电后由下次 daemon 启动自愈）时这份列表是唯一的载体。这里的旧记录用的是
// 升级前的单值 address 字段，顺带锁住读取侧的向后兼容。
func TestDNSTakeoverStateRecordsAllTakeoverAddresses(t *testing.T) {
	const legacyAddress = "198.18.0.9"
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = "1.1.1.1"
	takeover := newTestTakeover(t, runner)

	if err := takeover.writeState(dnsTakeoverState{
		Version:  1,
		Address:  legacyAddress,
		Services: []dnsServiceState{{Service: "Wi-Fi", Servers: []string{"1.1.1.1"}}},
	}); err != nil {
		t.Fatalf("writeState: %v", err)
	}

	if err := takeover.Takeover(); err != nil {
		t.Fatalf("Takeover: %v", err)
	}
	state := assertHasState(t, takeover)
	if !containsString(state.Addresses, dnsTakeoverAddress) || !containsString(state.Addresses, legacyAddress) {
		t.Fatalf("state must record every address we may have written: %+v", state.Addresses)
	}
}

// 跨进程：另一个进程写下的 Addresses 列表是唯一载体。Services 为空 → 走 DHCP 兜底，
// 列表里的历史地址必须一样被认成"我们改过的"，否则那个服务永久指着已消失的 tun。
func TestDNSRestoreRecognizesAddressListFromAnotherProcess(t *testing.T) {
	const legacyAddress = "198.18.0.9"
	runner := newFakeDNSRunner(twoServiceList)
	runner.current["Wi-Fi"] = legacyAddress
	runner.current["Thunderbolt Bridge"] = "192.168.1.1"
	takeover := newTestTakeover(t, runner)

	// Services 为空 → restoreTargets 走兜底，但 Addresses 仍然可用。
	if err := takeover.writeState(dnsTakeoverState{
		Version:   1,
		Addresses: []string{dnsTakeoverAddress, legacyAddress},
	}); err != nil {
		t.Fatalf("writeState: %v", err)
	}

	if err := takeover.Restore(); err != nil {
		t.Fatalf("Restore: %v", err)
	}
	assertSetCalls(t, runner, "Wi-Fi Empty")
	if runner.currentOf("Thunderbolt Bridge") != "192.168.1.1" {
		t.Fatalf("untouched service must keep its value, got %q", runner.currentOf("Thunderbolt Bridge"))
	}
	assertNoState(t, takeover)
}

// 旧版本用过别的接管地址（198.18.0.1 是 tun 自己的地址，那一版是错的）。状态文件
// 不可用时的兜底必须把升级前的单值 address 字段也认成"我们改过的"，只认当前常量会把
// 那个死地址留在系统里。
func TestDNSRestoreRecognizesLegacyTakeoverAddress(t *testing.T) {
	const legacyAddress = "198.18.0.1"
	runner := newFakeDNSRunner(twoServiceList)
	runner.current["Wi-Fi"] = legacyAddress
	runner.current["Thunderbolt Bridge"] = "192.168.1.1"
	takeover := newTestTakeover(t, runner)

	// Services 为空 → restoreTargets 走兜底，但 Address 仍然可用。
	if err := takeover.writeState(dnsTakeoverState{Version: 1, Address: legacyAddress}); err != nil {
		t.Fatalf("writeState: %v", err)
	}

	if err := takeover.Restore(); err != nil {
		t.Fatalf("Restore: %v", err)
	}
	assertSetCalls(t, runner, "Wi-Fi Empty")
	if runner.currentOf("Thunderbolt Bridge") != "192.168.1.1" {
		t.Fatalf("untouched service must keep its value, got %q", runner.currentOf("Thunderbolt Bridge"))
	}
	assertNoState(t, takeover)
}

// 状态文件损坏 = 所有原值不可知。此时唯一安全的动作是把「当前正指着我们地址」的
// 服务清回 DHCP：宁可退回可能被污染的 DHCP DNS，也绝不留下指向已消失 tun 的死
// 地址。从没被我们改成功的服务（这里的 Surge 仍是 9.9.9.9）不许误伤。
func TestDNSRestoreCorruptStateFallsBackToDHCP(t *testing.T) {
	runner := newFakeDNSRunner(`Wi-Fi
Surge`)
	runner.current["Wi-Fi"] = "1.1.1.1"
	runner.current["Surge"] = "9.9.9.9"
	runner.setErr["Surge"] = errors.New("exit status 1")
	takeover := newTestTakeover(t, runner)

	if err := takeover.Takeover(); err != nil {
		t.Fatalf("Takeover: %v", err)
	}
	if err := os.WriteFile(takeover.statePath(), []byte("{ truncated"), 0o600); err != nil {
		t.Fatalf("corrupt state file: %v", err)
	}
	runner.clearSetErr()

	if err := takeover.Restore(); err != nil {
		t.Fatalf("Restore must succeed on the DHCP fallback path: %v", err)
	}
	assertSetCalls(t, runner,
		"Wi-Fi "+dnsTakeoverAddress,
		"Surge "+dnsTakeoverAddress,
		"Wi-Fi Empty",
	)
	if runner.currentOf("Surge") != "9.9.9.9" {
		t.Fatalf("untouched service must keep its value, got %q", runner.currentOf("Surge"))
	}
	assertNoState(t, takeover)
}

// 状态文件被外部删掉但我们仍持有接管：同样走 DHCP 兜底，绝不留死地址。
func TestDNSRestoreMissingStateWhileActiveFallsBackToDHCP(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = "1.1.1.1"
	takeover := newTestTakeover(t, runner)

	if err := takeover.Takeover(); err != nil {
		t.Fatalf("Takeover: %v", err)
	}
	if err := os.Remove(takeover.statePath()); err != nil {
		t.Fatalf("remove state file: %v", err)
	}
	if err := takeover.Restore(); err != nil {
		t.Fatalf("Restore: %v", err)
	}
	assertSetCalls(t, runner, "Wi-Fi "+dnsTakeoverAddress, "Wi-Fi Empty")
}

// 重试路径的闸门：接管过 → 恢复全失败 → 状态文件被外部删掉（用户手动清理 / 磁盘被抹）。
// 此时 active 已经在上一轮恢复末尾被清掉了，光看 !active 会把"文件不见了"判成无事可做，
// 系统 DNS 从此永久指着已消失的 tun。takenAddress 只在全量恢复成功处清空，所以它非空
// 恰好等于"本进程接管过且尚未证实解除"，必须一起进闸门 —— 走 hijackedServices 的 DHCP
// 兜底，而不是静默成功。
//
// 时序是自证的：setFailTimes 到 clearSetErr 之前一直失败，而 clearSetErr 排在 os.Remove
// 之后，所以任何一次"恢复成功"都必然发生在文件已被删掉之后，也就必然走了兜底路径 ——
// 断言 Wi-Fi 落到 DHCP（而不是原值 1.1.1.1）就锁死了这一点。
func TestDNSRestoreRetryFallsBackWhenStateFileVanishes(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = "1.1.1.1"
	takeover := newTestTakeover(t, runner)
	takeover.retryInterval = 50 * time.Millisecond

	if err := takeover.Takeover(); err != nil {
		t.Fatalf("Takeover: %v", err)
	}
	runner.failSetTimes("Wi-Fi", 99)
	if err := takeover.Restore(); err == nil {
		t.Fatal("Restore must fail first, otherwise no retry is scheduled")
	}
	done := retryDoneChan(takeover)
	if takeover.active {
		t.Fatal("a finished restore attempt always clears active, that is why the gate needs takenAddress")
	}
	if runner.currentOf("Wi-Fi") != dnsTakeoverAddress {
		t.Fatalf("a fully failed restore must leave the takeover address in place, got %q", runner.currentOf("Wi-Fi"))
	}

	// 外部把唯一的恢复依据删掉，随后故障消失。
	if err := os.Remove(takeover.statePath()); err != nil {
		t.Fatalf("remove state file: %v", err)
	}
	runner.clearSetErr()

	waitClosed(t, done, 5*time.Second)
	if runner.currentOf("Wi-Fi") != "dhcp" {
		t.Fatalf("background retry must clear the takeover address via the DHCP fallback, got %q", runner.currentOf("Wi-Fi"))
	}
	assertNoState(t, takeover)
}

// 同一个闸门的另一半，也是更常见的那一半：本进程从没亲手接管过，只是照着上一个进程留下
// 的残留文件收拾（daemon 被 SIGKILL / 掉电后由 launchd KeepAlive 拉起来的那条路径）。这条
// 路上 takenAddress 恒为空，active 又在每轮恢复末尾被清掉 —— 只有粘性的 unresolved 记得
// "手上有一份继承来的、尚未解除的劫持"。少了它，恢复失败之后状态文件再被外部删掉（用户
// 手动清理 / 磁盘被抹），后台重试就把"文件不存在"判成无事可做，Wi-Fi 从此永久指着已消失
// 的 tun，整机解析全灭。
//
// 时序自证同上：setFailTimes 到 clearSetErr 之前一直失败，而 clearSetErr 排在 os.Remove
// 之后，所以任何一次"恢复成功"都必然发生在文件已被删掉之后，也就必然走了兜底路径 ——
// 断言 Wi-Fi 落到 DHCP（而不是原值 1.1.1.1）就锁死了这一点。
func TestDNSRestoreRetryFallsBackWhenInheritedStateVanishes(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = dnsTakeoverAddress
	takeover := newTestTakeover(t, runner)
	takeover.retryInterval = 50 * time.Millisecond

	// 上一个进程留下的残留：Wi-Fi 的原值只存在于这份文件里，本进程一次 Takeover 都没做。
	if err := takeover.writeState(dnsTakeoverState{
		Version:   1,
		Addresses: []string{dnsTakeoverAddress},
		Services:  []dnsServiceState{{Service: "Wi-Fi", Servers: []string{"1.1.1.1"}}},
	}); err != nil {
		t.Fatalf("writeState: %v", err)
	}
	runner.failSetTimes("Wi-Fi", 99)

	if err := takeover.RestoreLeftover(); err == nil {
		t.Fatal("RestoreLeftover must fail first, otherwise no retry is scheduled")
	}
	done := retryDoneChan(takeover)
	active, takenAddress, unresolved := takeoverFlags(takeover)
	if takenAddress != "" {
		t.Fatal("inheriting leftover state never sets takenAddress, that is exactly why the gate needs unresolved")
	}
	if active {
		t.Fatal("a finished restore attempt always clears active")
	}
	if !unresolved {
		t.Fatal("a non-empty restore target set must mark the hijack unresolved")
	}
	if runner.currentOf("Wi-Fi") != dnsTakeoverAddress {
		t.Fatalf("a fully failed restore must leave the takeover address in place, got %q", runner.currentOf("Wi-Fi"))
	}

	// 外部把唯一的恢复依据删掉，随后故障消失。
	if err := os.Remove(takeover.statePath()); err != nil {
		t.Fatalf("remove state file: %v", err)
	}
	runner.clearSetErr()

	waitClosed(t, done, 5*time.Second)
	if runner.currentOf("Wi-Fi") != "dhcp" {
		t.Fatalf("background retry must clear the takeover address via the DHCP fallback, got %q", runner.currentOf("Wi-Fi"))
	}
	assertNoState(t, takeover)
}

// 没接管过的引擎（连接中途取消、连接失败）走恢复路径必须完全不碰系统 DNS。
func TestDNSRestoreWithoutTakeoverIsNoop(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	takeover := newTestTakeover(t, runner)

	if err := takeover.Restore(); err != nil {
		t.Fatalf("Restore: %v", err)
	}
	if runner.callCount() != 0 {
		t.Fatalf("restore without takeover must run nothing, got %v", runner.calls)
	}
}

// 写回原值第一次失败 → 原值重试一次就好。别急着退回 DHCP：原值能写回去才是最好的
// 结果。
func TestDNSRestoreRetriesOriginalValueOnce(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = "1.1.1.1"
	takeover := newTestTakeover(t, runner)
	if err := takeover.Takeover(); err != nil {
		t.Fatalf("Takeover: %v", err)
	}
	runner.failSetTimes("Wi-Fi", 1)

	if err := takeover.Restore(); err != nil {
		t.Fatalf("Restore must succeed on the second attempt: %v", err)
	}
	assertSetCalls(t, runner,
		"Wi-Fi "+dnsTakeoverAddress,
		"Wi-Fi 1.1.1.1",
		"Wi-Fi 1.1.1.1",
	)
	if runner.currentOf("Wi-Fi") != "1.1.1.1" {
		t.Fatalf("original DNS must be back, got %q", runner.currentOf("Wi-Fi"))
	}
	assertNoState(t, takeover)
}

// 原值两次都写不回去 → 第二级兜底改写 Empty。回 DHCP 拿到的可能是被污染的解析结
// 果，但永远好过把系统留在指向已消失 tun 的死地址上。
func TestDNSRestoreFallsBackToDHCPAfterOriginalKeepsFailing(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = "1.1.1.1"
	takeover := newTestTakeover(t, runner)
	if err := takeover.Takeover(); err != nil {
		t.Fatalf("Takeover: %v", err)
	}
	runner.failSetTimes("Wi-Fi", 2)

	if err := takeover.Restore(); err != nil {
		t.Fatalf("Restore must succeed via the DHCP fallback: %v", err)
	}
	assertSetCalls(t, runner,
		"Wi-Fi "+dnsTakeoverAddress,
		"Wi-Fi 1.1.1.1",
		"Wi-Fi 1.1.1.1",
		"Wi-Fi Empty",
	)
	if runner.currentOf("Wi-Fi") != "dhcp" {
		t.Fatalf("service must be back on DHCP, got %q", runner.currentOf("Wi-Fi"))
	}
	assertNoState(t, takeover)
}

// 恢复目标本来就是 Empty（原值是 DHCP）时，两级兜底的第三条命令和前两条完全一样，
// 不许多发一次没有新信息的命令。
func TestDNSRestoreDoesNotRepeatEmptyFallback(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	takeover := newTestTakeover(t, runner)
	if err := takeover.Takeover(); err != nil {
		t.Fatalf("Takeover: %v", err)
	}
	runner.failSetTimes("Wi-Fi", 99)

	if err := takeover.Restore(); err == nil {
		t.Fatal("Restore must report the failure")
	}
	assertSetCalls(t, runner,
		"Wi-Fi "+dnsTakeoverAddress,
		"Wi-Fi Empty",
		"Wi-Fi Empty",
	)
	assertHasState(t, takeover)
}

// 两级兜底全挂：状态文件必须留着，后台重试和下次 daemon 启动都要靠它。
func TestDNSRestorePartialFailureKeepsState(t *testing.T) {
	runner := newFakeDNSRunner(twoServiceList)
	runner.current["Wi-Fi"] = "1.1.1.1"
	takeover := newTestTakeover(t, runner)

	if err := takeover.Takeover(); err != nil {
		t.Fatalf("Takeover: %v", err)
	}
	runner.failSetTimes("Wi-Fi", 99)

	err := takeover.Restore()
	if err == nil || !strings.Contains(err.Error(), "Wi-Fi") {
		t.Fatalf("partial restore failure must be reported, got %v", err)
	}
	assertSetCalls(t, runner,
		"Wi-Fi "+dnsTakeoverAddress,
		"Thunderbolt Bridge "+dnsTakeoverAddress,
		"Wi-Fi 1.1.1.1",
		"Wi-Fi 1.1.1.1",
		"Wi-Fi Empty",
		"Thunderbolt Bridge Empty",
	)
	assertHasState(t, takeover)
	if runner.currentOf("Thunderbolt Bridge") != "dhcp" {
		t.Fatal("the other service must still be restored")
	}
}

// 子预算逐轮重算 = 防饿死。前一半服务全都卡在 SystemConfiguration 提交上（networksetup
// 同步等，偶发卡死），后一半是用户真正在用的网卡。没有子预算的话第一个卡死的服务就把
// 总预算一口吃光，后面的服务连一条命令都发不出去 —— 主网卡永久指着已消失的 tun，整机
// 没网。逐轮重算（share = 剩余总预算 / 剩余目标数）保证每个卡死服务只吃掉自己那一份，
// 且健康服务省下的预算自动摊给后面的目标。
func TestDNSRestoreNeverStarvesLaterServices(t *testing.T) {
	const count = 10
	var names []string
	var services []dnsServiceState
	for i := 0; i < count; i++ {
		name := fmt.Sprintf("Svc%02d", i)
		names = append(names, name)
		services = append(services, dnsServiceState{Service: name, Servers: []string{fmt.Sprintf("10.0.0.%d", i+1)}})
	}
	runner := newFakeDNSRunner(strings.Join(names, "\n"))
	for i, name := range names {
		runner.current[name] = dnsTakeoverAddress
		if i < count/2 {
			runner.setHangs[name] = true
		}
	}
	takeover := newTestTakeover(t, runner)
	// 单条命令上限故意等于总预算：唯一能拦住卡死服务的就是逐轮重算的子预算。
	takeover.budget = time.Second
	takeover.cmdTimeout = time.Second
	takeover.retryInterval = time.Hour

	if err := takeover.writeState(dnsTakeoverState{
		Version:   1,
		Addresses: []string{dnsTakeoverAddress},
		Services:  services,
	}); err != nil {
		t.Fatalf("writeState: %v", err)
	}

	if err := takeover.RestoreLeftover(); err == nil {
		t.Fatal("the hung services must be reported as failed")
	}
	for i, name := range names {
		if !runner.called("-setdnsservers " + name) {
			t.Fatalf("%s never got a command, it was starved by the services before it: %v", name, runner.setCalls())
		}
		if i < count/2 {
			continue
		}
		if want := fmt.Sprintf("10.0.0.%d", i+1); runner.currentOf(name) != want {
			t.Fatalf("%s must be restored even though earlier services hung: got %q, want %q",
				name, runner.currentOf(name), want)
		}
	}
}

// 进度持久化：每恢复成功一个服务就立刻把它从状态文件里剔掉。恢复途中进程被 SIGKILL
// （launchd 宽限期到点 / 掉电）后，下次启动只会去救真正还没救回来的那些，不会拿旧记录
// 把已经恢复好的服务再改一遍。
func TestDNSRestorePersistsProgressPerService(t *testing.T) {
	stateDir := t.TempDir()
	runner := newFakeDNSRunner("Wi-Fi\nSurge")
	runner.current["Wi-Fi"] = dnsTakeoverAddress
	runner.current["Surge"] = dnsTakeoverAddress
	takeover := newTestTakeoverIn(t, runner, stateDir)
	takeover.retryInterval = time.Hour

	if err := takeover.writeState(dnsTakeoverState{
		Version: 1,
		Address: dnsTakeoverAddress,
		Services: []dnsServiceState{
			{Service: "Wi-Fi", Servers: []string{"1.1.1.1"}},
			{Service: "Surge", Servers: []string{"9.9.9.9"}},
		},
	}); err != nil {
		t.Fatalf("writeState: %v", err)
	}
	// Wi-Fi 能恢复，Surge 两级兜底全挂。
	runner.failSetTimes("Surge", 99)

	if err := takeover.RestoreLeftover(); err == nil {
		t.Fatal("Restore must report the failed service")
	}
	state := assertHasState(t, takeover)
	if len(state.Services) != 1 || state.Services[0].Service != "Surge" ||
		strings.Join(state.Services[0].Servers, ",") != "9.9.9.9" {
		t.Fatalf("state file must only keep the services still to be restored: %+v", state.Services)
	}

	// 换一个进程接着救（残留文件是唯一载体）：只有尾部那个服务该被碰。
	nextRunner := newFakeDNSRunner("Wi-Fi\nSurge")
	nextRunner.current["Wi-Fi"] = "1.1.1.1"
	nextRunner.current["Surge"] = dnsTakeoverAddress
	next := newTestTakeoverIn(t, nextRunner, stateDir)

	if err := next.RestoreLeftover(); err != nil {
		t.Fatalf("second-process RestoreLeftover: %v", err)
	}
	assertSetCalls(t, nextRunner, "Surge 9.9.9.9")
	if nextRunner.currentOf("Wi-Fi") != "1.1.1.1" {
		t.Fatalf("already-restored service must not be touched again, got %q", nextRunner.currentOf("Wi-Fi"))
	}
	assertNoState(t, next)
}

// 服务三分类之二：「networksetup 还认识但当前被禁用」的服务是软失败 —— 只试一次（不走
// 两级兜底，不烧预算），不计入 failed（不触发重试风暴），条目留在状态文件里等它被重新
// 启用。状态文件仍用升级前的单值 address 字段写，顺带证明读取侧的兼容。
func TestDNSRestoreDisabledServiceIsSoftFailure(t *testing.T) {
	runner := newFakeDNSRunner(`An asterisk (*) denotes that a network service is disabled.
*iPhone USB
Wi-Fi`)
	runner.current["Wi-Fi"] = dnsTakeoverAddress
	// 禁用服务的 -setdnsservers 真实返回未实机验证，这里按"写不进去"模拟。
	runner.setErr["iPhone USB"] = errors.New("exit status 1")
	takeover := newTestTakeover(t, runner)
	takeover.retryInterval = time.Hour

	if err := takeover.writeState(dnsTakeoverState{
		Version: 1,
		Address: dnsTakeoverAddress,
		Services: []dnsServiceState{
			{Service: "Wi-Fi", Servers: []string{"1.1.1.1"}},
			{Service: "iPhone USB", Servers: []string{"8.8.8.8"}},
		},
	}); err != nil {
		t.Fatalf("writeState: %v", err)
	}

	if err := takeover.RestoreLeftover(); err != nil {
		t.Fatalf("a currently disabled service must not fail the restore: %v", err)
	}
	// 关键：iPhone USB 只有一次尝试，没有"原值 ×2 + Empty"那三条。
	assertSetCalls(t, runner, "Wi-Fi 1.1.1.1", "iPhone USB 8.8.8.8")
	if done := retryDoneChan(takeover); done != nil {
		t.Fatal("a soft failure must not schedule a background retry storm")
	}
	state := assertHasState(t, takeover)
	if len(state.Services) != 1 || state.Services[0].Service != "iPhone USB" {
		t.Fatalf("the disabled entry must stay in the file waiting for the service to be re-enabled: %+v", state.Services)
	}
}

// 服务三分类之三：状态文件里的服务名 networksetup 压根不认识了（用户在系统设置里删掉了
// 它 / 那块网卡对应的服务被移除）。它不会再回来 —— 一条命令都不许发，条目直接从文件里
// 剔掉，整体返回 nil。同一份文件里带 * 的禁用服务是另一类：随时可能被重新启用，依据
// 必须留着。混成一类的话，要么把不会回来的服务永久钉在待恢复列表上（每次自愈白发一条
// 注定 "** Error" 的命令），要么把只是暂时禁用的服务的唯一恢复依据丢掉。
func TestDNSRestoreDropsDeletedServiceButKeepsDisabledOne(t *testing.T) {
	runner := newFakeDNSRunner(`An asterisk (*) denotes that a network service is disabled.
*iPhone USB
Wi-Fi`)
	runner.current["Wi-Fi"] = dnsTakeoverAddress
	runner.setErr["iPhone USB"] = errors.New("exit status 1")
	takeover := newTestTakeover(t, runner)
	takeover.retryInterval = time.Hour

	if err := takeover.writeState(dnsTakeoverState{
		Version:   1,
		Addresses: []string{dnsTakeoverAddress},
		Services: []dnsServiceState{
			{Service: "Wi-Fi", Servers: []string{"1.1.1.1"}},
			{Service: "iPhone USB", Servers: []string{"8.8.8.8"}},
			{Service: "Deleted Ethernet", Servers: []string{"7.7.7.7"}},
		},
	}); err != nil {
		t.Fatalf("writeState: %v", err)
	}

	if err := takeover.RestoreLeftover(); err != nil {
		t.Fatalf("a deleted service must not fail the restore: %v", err)
	}
	// Deleted Ethernet 一条命令都不发。
	assertSetCalls(t, runner, "Wi-Fi 1.1.1.1", "iPhone USB 8.8.8.8")
	if done := retryDoneChan(takeover); done != nil {
		t.Fatal("dropping a deleted service must not schedule a background retry")
	}
	state := assertHasState(t, takeover)
	if len(state.Services) != 1 || state.Services[0].Service != "iPhone USB" {
		t.Fatalf("only the disabled service may keep its recovery basis: %+v", state.Services)
	}
}

// 全部条目都是已删除服务时，状态文件必须整份消失：不变式「文件内容 == 尚未恢复的条目」
// 要求 remaining 空掉的那一刻就把文件删掉，而不是留着一份所有条目都已处置完的旧记录 ——
// 那一刻进程被杀，下次启动会照着它再折腾一遍。
func TestDNSRestoreDeletedOnlyEntryClearsStateFile(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = "1.1.1.1"
	takeover := newTestTakeover(t, runner)
	takeover.retryInterval = time.Hour

	if err := takeover.writeState(dnsTakeoverState{
		Version:   1,
		Addresses: []string{dnsTakeoverAddress},
		Services:  []dnsServiceState{{Service: "Deleted Ethernet", Servers: []string{"7.7.7.7"}}},
	}); err != nil {
		t.Fatalf("writeState: %v", err)
	}

	if err := takeover.RestoreLeftover(); err != nil {
		t.Fatalf("RestoreLeftover: %v", err)
	}
	assertSetCalls(t, runner)
	assertNoState(t, takeover)
	if runner.currentOf("Wi-Fi") != "1.1.1.1" {
		t.Fatalf("no other service may be touched, got %q", runner.currentOf("Wi-Fi"))
	}
}

// 恢复整体失败必须起一个有界后台重试：只等"下次 daemon 启动"不够，用户可能几小时
// 都不重启，而这几小时里他的系统 DNS 指着已消失的 tun，整机没网。
func TestDNSRestoreBackgroundRetryEventuallySucceeds(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = "1.1.1.1"
	takeover := newTestTakeover(t, runner)
	takeover.retryInterval = 5 * time.Millisecond
	if err := takeover.Takeover(); err != nil {
		t.Fatalf("Takeover: %v", err)
	}
	// 原值 ×2 + Empty ×1 全部失败 → 这一轮彻底失败，之后恢复正常。
	runner.failSetTimes("Wi-Fi", 3)

	if err := takeover.Restore(); err == nil {
		t.Fatal("Restore must fail first, otherwise no retry is scheduled")
	}
	done := retryDoneChan(takeover)
	assertHasState(t, takeover)

	waitClosed(t, done, 5*time.Second)
	if runner.currentOf("Wi-Fi") != "1.1.1.1" {
		t.Fatalf("background retry must put the original DNS back, got %q", runner.currentOf("Wi-Fi"))
	}
	assertNoState(t, takeover)
}

// 重新接管必须取消挂起的后台重试：它要是在接管之后醒过来，会把刚指好的 DNS 又
// "恢复"回去，接管当场失效。
func TestDNSRestoreBackgroundRetryCancelledByTakeover(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = "1.1.1.1"
	takeover := newTestTakeover(t, runner)
	// 间隔故意留长：重试 goroutine 会一直卡在等待里，只能被取消唤醒。
	takeover.retryInterval = time.Hour
	if err := takeover.Takeover(); err != nil {
		t.Fatalf("Takeover: %v", err)
	}
	runner.failSetTimes("Wi-Fi", 3)
	if err := takeover.Restore(); err == nil {
		t.Fatal("Restore must fail first, otherwise no retry is scheduled")
	}
	done := retryDoneChan(takeover)

	// 再次接管：此时 Wi-Fi 的当前值还是接管地址（恢复全失败了），原值只能从磁盘
	// 旧记录里沿用。
	if err := takeover.Takeover(); err != nil {
		t.Fatalf("re-Takeover: %v", err)
	}
	waitClosed(t, done, 2*time.Second)

	state := assertHasState(t, takeover)
	if len(state.Services) != 1 || strings.Join(state.Services[0].Servers, ",") != "1.1.1.1" {
		t.Fatalf("re-takeover must carry the recorded original over: %+v", state.Services)
	}
	if runner.currentOf("Wi-Fi") != dnsTakeoverAddress {
		t.Fatalf("cancelled retry must not undo the fresh takeover, got %q", runner.currentOf("Wi-Fi"))
	}
}

// Close 收掉挂起的后台重试（进程退出前的收尾）。
func TestDNSTakeoverCloseCancelsBackgroundRetry(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	takeover := newTestTakeover(t, runner)
	takeover.retryInterval = time.Hour
	if err := takeover.Takeover(); err != nil {
		t.Fatalf("Takeover: %v", err)
	}
	runner.failSetTimes("Wi-Fi", 99)
	if err := takeover.Restore(); err == nil {
		t.Fatal("Restore must fail first, otherwise no retry is scheduled")
	}
	done := retryDoneChan(takeover)

	takeover.Close()
	waitClosed(t, done, 2*time.Second)
}

// daemon 启动自愈：残留文件按记录精确恢复并删除。
func TestDNSRestoreLeftoverOnStartup(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = dnsTakeoverAddress
	takeover := newTestTakeover(t, runner)

	state := dnsTakeoverState{
		Version:  1,
		Address:  dnsTakeoverAddress,
		Services: []dnsServiceState{{Service: "Wi-Fi", Servers: []string{"1.1.1.1"}}},
	}
	if err := takeover.writeState(state); err != nil {
		t.Fatalf("writeState: %v", err)
	}

	if err := takeover.RestoreLeftover(); err != nil {
		t.Fatalf("RestoreLeftover: %v", err)
	}
	assertSetCalls(t, runner, "Wi-Fi 1.1.1.1")
	assertNoState(t, takeover)
}

func TestDNSRestoreLeftoverWithoutStateFileIsNoop(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	takeover := newTestTakeover(t, runner)

	if err := takeover.RestoreLeftover(); err != nil {
		t.Fatalf("RestoreLeftover: %v", err)
	}
	if runner.callCount() != 0 {
		t.Fatalf("no leftover state must mean no commands, got %v", runner.calls)
	}
}

// 残留文件损坏时，启动自愈同样只能走 DHCP 兜底。
func TestDNSRestoreLeftoverCorruptState(t *testing.T) {
	runner := newFakeDNSRunner(twoServiceList)
	runner.current["Wi-Fi"] = dnsTakeoverAddress
	runner.current["Thunderbolt Bridge"] = "192.168.1.1"
	takeover := newTestTakeover(t, runner)
	if err := os.WriteFile(takeover.statePath(), []byte("not json"), 0o600); err != nil {
		t.Fatalf("write corrupt state: %v", err)
	}

	if err := takeover.RestoreLeftover(); err != nil {
		t.Fatalf("RestoreLeftover: %v", err)
	}
	assertSetCalls(t, runner, "Wi-Fi Empty")
	assertNoState(t, takeover)
}

// 就绪探测：出接口不是 utun 说明 tun 路由还没装上，此刻把系统 DNS 指过去就是整机
// 解析黑洞。探测超时必须跳过接管，一条 -setdnsservers 都不许发，也不许留状态文件。
func TestDNSTakeoverSkippedWhenRouteNotOnTun(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = "1.1.1.1"
	runner.routeIface = "en0"
	takeover := newTestTakeover(t, runner)
	takeover.probeWindow = 30 * time.Millisecond
	takeover.probeInterval = 5 * time.Millisecond

	err := takeover.Takeover()
	if err == nil || !strings.Contains(err.Error(), "tun 路由未就绪") {
		t.Fatalf("takeover must be skipped when the route is not on a tun, got %v", err)
	}
	if takeover.active {
		t.Fatal("skipped takeover must not be active")
	}
	assertSetCalls(t, runner)
	assertNoState(t, takeover)
	if !runner.called(routeBinary) {
		t.Fatal("route probe must actually run")
	}
}

// 就绪判据三态之二：出接口是 utun，但 route get 没有 gateway 行 —— 命中的是一条
// 下层 link 路由。光看"出接口是不是 utun"会把它误判成我们的 tun 已就绪，接管过去
// 就是整机解析黑洞。
func TestDNSTakeoverSkippedWhenRouteHasNoGateway(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = "1.1.1.1"
	runner.routeIface = "utun13"
	runner.routeDestination = "default"
	runner.routeGateway = "" // link 路由不打印 gateway 行
	takeover := newTestTakeover(t, runner)
	takeover.probeWindow = 30 * time.Millisecond
	takeover.probeInterval = 5 * time.Millisecond

	err := takeover.Takeover()
	if err == nil || !strings.Contains(err.Error(), "link 路由") {
		t.Fatalf("a link route on some other utun must not count as tun readiness, got %v", err)
	}
	assertSetCalls(t, runner)
	assertNoState(t, takeover)
}

// 就绪判据三态之三：有 gateway 行但下一跳不是我们的 tun 地址（别的隧道自己的网关）。
func TestDNSTakeoverSkippedWhenGatewayIsNotTunAddress(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = "1.1.1.1"
	runner.routeIface = "utun13"
	runner.routeGateway = "100.100.100.100"
	takeover := newTestTakeover(t, runner)
	takeover.probeWindow = 30 * time.Millisecond
	takeover.probeInterval = 5 * time.Millisecond

	err := takeover.Takeover()
	if err == nil || !strings.Contains(err.Error(), "不是 tun 地址") {
		t.Fatalf("a foreign gateway must not count as tun readiness, got %v", err)
	}
	assertSetCalls(t, runner)
	assertNoState(t, takeover)
}

// 就绪判据三态之一（放行）：gateway 正是 tun 地址 —— 这就是 auto_route 装好的
// sub-range 路由（128.0.0.0/1 → 198.18.0.1），此时接管才安全。
func TestDNSTakeoverProceedsWhenGatewayIsTunAddress(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = "1.1.1.1"
	runner.routeIface = "utun7"
	runner.routeDestination = "128.0.0.0"
	runner.routeGateway = dnsTakeoverGateway
	takeover := newTestTakeover(t, runner)
	takeover.probeWindow = 30 * time.Millisecond
	takeover.probeInterval = 5 * time.Millisecond

	if err := takeover.Takeover(); err != nil {
		t.Fatalf("a sub-range route via the tun address must count as ready: %v", err)
	}
	assertSetCalls(t, runner, "Wi-Fi "+dnsTakeoverAddress)
}

// route 命令自身失败（数据面还没起、路由表里根本没这条）同样是"未就绪"。
func TestDNSTakeoverSkippedWhenRouteProbeFails(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.routeErr = errors.New("exit status 1")
	takeover := newTestTakeover(t, runner)
	takeover.probeWindow = 30 * time.Millisecond
	takeover.probeInterval = 5 * time.Millisecond

	if err := takeover.Takeover(); err == nil {
		t.Fatal("a failing route probe must skip the takeover")
	}
	assertSetCalls(t, runner)
	assertNoState(t, takeover)
}

// networksetup 的部分错误只写在 stdout 里，退出码仍是 0：必须把它当失败。
func TestNetworksetupInlineErrorIsFailure(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	takeover := newTestTakeover(t, runner)
	ctx := context.Background()

	if _, err := takeover.readServers(ctx, "Wi-Fi"); err != nil {
		t.Fatalf("existing service must read fine: %v", err)
	}
	_, err := takeover.readServers(ctx, "NoSuchService")
	if err == nil {
		t.Fatal(`"** Error" in output must be treated as failure`)
	}
	// 而且必须是"可证明未生效"，不能被当成超时那种不可知的失败。
	if errors.Is(err, errDNSResultUnknown) {
		t.Fatal(`"** Error" is provably not applied, it must not be marked unknown`)
	}
}

// 所有外部命令都必须带超时上限，否则断开路径可能挂死在 networksetup 上，把用户留
// 在 DNS 指向死 tun 的整机断网状态。
func TestDNSTakeoverAlwaysSetsCommandDeadline(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	takeover := newTestTakeover(t, runner)

	_ = takeover.Takeover()
	_ = takeover.Restore()
	if len(runner.deadlineMissing) > 0 {
		t.Fatalf("commands without timeout: %v", runner.deadlineMissing)
	}
	if runner.callCount() == 0 {
		t.Fatal("no command ran, the deadline assertion proves nothing")
	}
	if !runner.called(routeBinary) {
		t.Fatal("route probe must be covered by the deadline assertion too")
	}
}

// 非 macOS 构建（engine 包也编进 iOS/tvOS 的 libbox）不许执行任何命令。
func TestDNSTakeoverUnsupportedPlatformIsNoop(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	takeover := &dnsTakeover{runner: runner, stateDir: t.TempDir(), supported: false}

	if err := takeover.Takeover(); err != nil {
		t.Fatalf("Takeover: %v", err)
	}
	if err := takeover.Restore(); err != nil {
		t.Fatalf("Restore: %v", err)
	}
	if err := takeover.RestoreLeftover(); err != nil {
		t.Fatalf("RestoreLeftover: %v", err)
	}
	if err := takeover.SelfHealLeftover(); err != nil {
		t.Fatalf("SelfHealLeftover: %v", err)
	}
	if runner.callCount() != 0 {
		t.Fatalf("unsupported platform must run nothing, got %v", runner.calls)
	}
}

// CLI（xdial start）关掉接管开关：一条命令都不许发。它不受 launchd 托管，被 kill -9
// 之后没人会把系统 DNS 从已消失的 tun 上救回来。
func TestEngineDoesNotTakeoverDNSWhenDisallowed(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = "1.1.1.1"
	takeover := newTestTakeover(t, runner)

	eng := &Engine{status: StatusConnected, dns: takeover}
	if err := eng.takeoverDNSLocked(); err != nil {
		t.Fatalf("disabled takeover must be a no-op: %v", err)
	}

	if runner.callCount() != 0 {
		t.Fatalf("disallowed takeover must run nothing, got %v", runner.calls)
	}
	if takeover.active {
		t.Fatal("disallowed takeover must not be active")
	}
	assertNoState(t, takeover)
}

// daemon 打开开关：接管照常发生，恢复依据落盘。
func TestEngineTakesOverDNSWhenAllowed(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = "1.1.1.1"
	takeover := newTestTakeover(t, runner)

	eng := &Engine{status: StatusConnected, dns: takeover}
	eng.AllowSystemDNSTakeover(true)
	if err := eng.takeoverDNSLocked(); err != nil {
		t.Fatalf("enabled takeover: %v", err)
	}

	assertSetCalls(t, runner, "Wi-Fi "+dnsTakeoverAddress)
	if !takeover.active {
		t.Fatal("allowed takeover must be active")
	}
	assertHasState(t, takeover)
}

// daemon 承诺的是完整密封的数据面。路由优先级被下层全局 VPN 抢走时，DNS 查询无法
// 进入 sing-box；此时继续显示 Connected 会让所有域名规则看似存在、实际不生效。
func TestEngineRejectsConnectionReadinessWhenDNSTakeoverFails(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = "1.1.1.1"
	runner.routeIface = "utun13"
	runner.routeDestination = "default"
	runner.routeGateway = ""
	takeover := newTestTakeover(t, runner)
	takeover.probeWindow = 30 * time.Millisecond
	takeover.probeInterval = 5 * time.Millisecond

	eng := &Engine{status: StatusConnecting, dns: takeover}
	eng.AllowSystemDNSTakeover(true)
	err := eng.takeoverDNSLocked()
	if err == nil || !strings.Contains(err.Error(), "已取消连接以避免错误分流") {
		t.Fatalf("DNS outside the tun must reject readiness, got %v", err)
	}
	if takeover.active {
		t.Fatal("failed readiness must not leave DNS takeover active")
	}
	assertSetCalls(t, runner)
	assertNoState(t, takeover)
}

// 顺序断言：cleanupLocked 必须在停 sing-box 之前恢复系统 DNS，否则会留下一个
// 「DNS 指向已经消失的 tun」的窗口，那期间整机解析全灭。以 sing-box 配置文件是否
// 还在为标尺——SingBoxProcess.stop 的收尾动作就是删掉它。
func TestCleanupRestoresDNSBeforeStoppingSingBox(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "sing-box.json")
	if err := os.WriteFile(configPath, []byte("{}"), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}

	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = "1.1.1.1"
	takeover := newTestTakeover(t, runner)
	if err := takeover.Takeover(); err != nil {
		t.Fatalf("Takeover: %v", err)
	}

	observer := &orderObserver{inner: runner, configPath: configPath}
	takeover.runner = observer

	eng := &Engine{status: StatusConnected, dns: takeover, singbox: &SingBoxProcess{configPath: configPath}}
	eng.cleanupLocked()

	if !observer.sawRestore {
		t.Fatal("cleanup must restore system DNS")
	}
	if !observer.singBoxAliveOnRestore {
		t.Fatal("system DNS was restored after sing-box had already been stopped")
	}
	if _, err := os.Stat(configPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("sing-box must still be stopped afterwards, stat err = %v", err)
	}
	assertNoState(t, takeover)
}

// 用户点"断开"走的是 Stop → cleanupLocked。锁定这条最常走的路径不被将来的改动绕过：
// 漏了恢复就是整机 DNS 死在已消失的 tun 上。
func TestStopRestoresSystemDNS(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = "1.1.1.1"
	takeover := newTestTakeover(t, runner)
	if err := takeover.Takeover(); err != nil {
		t.Fatalf("Takeover: %v", err)
	}

	eng := &Engine{status: StatusConnected, dns: takeover, vpn: NewVPNClient()}
	if err := eng.Stop(); err != nil {
		t.Fatalf("Stop: %v", err)
	}
	assertSetCalls(t, runner, "Wi-Fi "+dnsTakeoverAddress, "Wi-Fi 1.1.1.1")
	assertNoState(t, takeover)
}

// 顺序断言：状态文件必须在刷缓存之前就被清掉。flushCache 是尽力而为的收尾，两条命令都
// 可能一路卡到预算耗尽，把清文件排在它后面就留下一个「已经全部恢复完、恢复依据却还躺在
// 盘上」的时间窗 —— 那一刻进程被杀（launchd 宽限期到点 / 掉电），下次启动会照着这份过时
// 记录把已经好了的服务再改一遍。
func TestDNSRestoreClearsStateBeforeFlushingCache(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = "1.1.1.1"
	takeover := newTestTakeover(t, runner)
	if err := takeover.Takeover(); err != nil {
		t.Fatalf("Takeover: %v", err)
	}

	// 观察者只在恢复这一程装上：Takeover 自己也会刷缓存，那时状态文件本该还在。
	observer := &flushOrderObserver{inner: runner, statePath: takeover.statePath()}
	takeover.runner = observer

	if err := takeover.Restore(); err != nil {
		t.Fatalf("Restore: %v", err)
	}
	if !observer.sawFlush {
		t.Fatal("restore must flush the DNS cache")
	}
	if observer.stateAliveOnFlush {
		t.Fatal("state file was still on disk when the cache flush started")
	}
	assertNoState(t, takeover)
}

type flushOrderObserver struct {
	inner             commandRunner
	statePath         string
	sawFlush          bool
	stateAliveOnFlush bool
}

func (o *flushOrderObserver) Run(ctx context.Context, name string, args ...string) (string, error) {
	if name == dscacheutilBinary || name == killallBinary {
		o.sawFlush = true
		if _, err := os.Stat(o.statePath); err == nil {
			o.stateAliveOnFlush = true
		}
	}
	return o.inner.Run(ctx, name, args...)
}

// 结构性地址判据（接管侧）：某个历史版本用过 198.18.0.7，而记着它的那份状态文件已经没了
// （磁盘故障 / 用户手动清理 / 换过 stateDir），光靠地址列表再也认不出它。198.18.0.0/15 是
// RFC 2544 给基准测试保留的段，不可能是用户真实的 DNS，所以整段一概认成我们的残留。
// 认不出的后果是把死地址当"原值"记下来，恢复时原样写回去 —— 那台机器的解析永久停在一个
// 早就不存在的 tun 上，而且此后每一次恢复都会热情地把它再写一遍。
func TestDNSTakeoverRecognizesAnyAddressInTunPrefix(t *testing.T) {
	const forgottenAddress = "198.18.0.7"
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = forgottenAddress
	takeover := newTestTakeover(t, runner)

	if err := takeover.Takeover(); err != nil {
		t.Fatalf("Takeover: %v", err)
	}
	state := assertHasState(t, takeover)
	if len(state.Services) != 1 || len(state.Services[0].Servers) != 0 {
		t.Fatalf("an address inside the tun prefix must never be recorded as an original: %+v", state.Services)
	}

	if err := takeover.Restore(); err != nil {
		t.Fatalf("Restore: %v", err)
	}
	assertSetCalls(t, runner, "Wi-Fi "+dnsTakeoverAddress, "Wi-Fi Empty")
	if runner.currentOf("Wi-Fi") != "dhcp" {
		t.Fatalf("the forgotten takeover address must be gone, got %q", runner.currentOf("Wi-Fi"))
	}
}

// 同一条判据在恢复兜底侧：状态文件里 Services 为空（原值全不可知），地址列表里也没有
// 198.18.0.7 —— 只有 tun 网段判据能认出它该被清回 DHCP。同时锁住"不许误伤"：Thunderbolt
// 上那个 192.168.1.1 是用户自己配的，不在网段内，一条命令都不许发给它。
func TestDNSRestoreFallbackRecognizesAnyAddressInTunPrefix(t *testing.T) {
	const forgottenAddress = "198.18.0.7"
	runner := newFakeDNSRunner(twoServiceList)
	runner.current["Wi-Fi"] = forgottenAddress
	runner.current["Thunderbolt Bridge"] = "192.168.1.1"
	takeover := newTestTakeover(t, runner)

	if err := takeover.writeState(dnsTakeoverState{
		Version:   1,
		Addresses: []string{dnsTakeoverAddress},
	}); err != nil {
		t.Fatalf("writeState: %v", err)
	}

	if err := takeover.RestoreLeftover(); err != nil {
		t.Fatalf("RestoreLeftover: %v", err)
	}
	assertSetCalls(t, runner, "Wi-Fi Empty")
	if runner.currentOf("Thunderbolt Bridge") != "192.168.1.1" {
		t.Fatalf("a user-configured DNS must never be touched, got %q", runner.currentOf("Thunderbolt Bridge"))
	}
	assertNoState(t, takeover)
}

// 落盘必须真的刷过盘：刷盘失败要让整个 writeState 失败，而且不许把半截 tmp 留在盘上，也
// 不许把旧的状态文件换成新的。悄悄当成功是最坏的结果 —— Takeover 以为恢复依据已经安全落盘
// （writeState 成功是它继续往下发 set 的前提），随后放心去改系统 DNS；掉电之后那份依据其实
// 只在页缓存里，从没到过介质，用户醒来面对的是指向已消失 tun 的系统 DNS 和一个空目录。
func TestDNSTakeoverStateWriteFailsWhenFlushFails(t *testing.T) {
	takeover := newTestTakeover(t, newFakeDNSRunner("Wi-Fi"))

	// 先写一份好的，证明失败的那次不会把它破坏掉。
	good := dnsTakeoverState{
		Version:   1,
		Addresses: []string{dnsTakeoverAddress},
		Services:  []dnsServiceState{{Service: "Wi-Fi", Servers: []string{"1.1.1.1"}}},
	}
	if err := takeover.writeState(good); err != nil {
		t.Fatalf("writeState: %v", err)
	}

	takeover.syncFile = func(*os.File) error { return errors.New("刷盘失败") }
	err := takeover.writeState(dnsTakeoverState{
		Version:  1,
		Services: []dnsServiceState{{Service: "Thunderbolt Bridge", Servers: []string{"9.9.9.9"}}},
	})
	if err == nil {
		t.Fatal("a failed flush must fail the whole write")
	}
	if _, statErr := os.Stat(takeover.statePath() + ".tmp"); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("the temp file must be cleaned up after a failed flush, stat err = %v", statErr)
	}
	state := assertHasState(t, takeover)
	if len(state.Services) != 1 || state.Services[0].Service != "Wi-Fi" {
		t.Fatalf("a failed write must leave the previous state intact: %+v", state.Services)
	}

	// 刷盘恢复正常之后照常提交，tmp 也照常消失。
	takeover.syncFile = nil
	if err := takeover.writeState(good); err != nil {
		t.Fatalf("writeState after recovery: %v", err)
	}
	if _, statErr := os.Stat(takeover.statePath() + ".tmp"); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("the temp file must not survive a commit, stat err = %v", statErr)
	}
}

// 一次真实的接管必须走过刷盘。writeState 是 Takeover 继续往下发 set 的前提，这条断言把
// 「状态文件确实经过了 fsync/F_FULLFSYNC 那一步」钉在最常走的那条路径上 —— 把刷盘整段
// 摘掉（或换成 no-op）时这里立刻炸。
func TestDNSTakeoverFlushesStateToDisk(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = "1.1.1.1"
	takeover := newTestTakeover(t, runner)

	synced := 0
	takeover.syncFile = func(file *os.File) error {
		synced++
		return fullSync(file)
	}

	if err := takeover.Takeover(); err != nil {
		t.Fatalf("Takeover: %v", err)
	}
	if synced == 0 {
		t.Fatal("the state file was committed without ever being flushed to disk")
	}
	assertHasState(t, takeover)
}

// persistProgress 复用同一个刷盘路径，所以「逐服务的恢复进度」享有同一份掉电保证。它正是
// 最需要保证的那一份：恢复途中掉电时，盘上那份必须精确等于"还没救回来的条目"，多一条会让
// 下次启动把已经好了的服务再改一遍，少一条会让还没救的服务永久指着已消失的 tun。
func TestDNSRestoreProgressIsFlushedToDisk(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi\nSurge")
	runner.current["Wi-Fi"] = dnsTakeoverAddress
	runner.current["Surge"] = dnsTakeoverAddress
	takeover := newTestTakeover(t, runner)
	takeover.retryInterval = time.Hour

	if err := takeover.writeState(dnsTakeoverState{
		Version:   1,
		Addresses: []string{dnsTakeoverAddress},
		Services: []dnsServiceState{
			{Service: "Wi-Fi", Servers: []string{"1.1.1.1"}},
			{Service: "Surge", Servers: []string{"9.9.9.9"}},
		},
	}); err != nil {
		t.Fatalf("writeState: %v", err)
	}

	// Wi-Fi 恢复成功（触发 persistProgress 重写文件），Surge 两级兜底全挂（所以文件不会
	// 被整份删掉，重写的那一次必须刷过盘）。
	runner.failSetTimes("Surge", 99)
	synced := 0
	takeover.syncFile = func(file *os.File) error {
		synced++
		return fullSync(file)
	}

	if err := takeover.RestoreLeftover(); err == nil {
		t.Fatal("Restore must report the failed service")
	}
	if synced == 0 {
		t.Fatal("restore progress was written without ever being flushed to disk")
	}
	state := assertHasState(t, takeover)
	if len(state.Services) != 1 || state.Services[0].Service != "Surge" {
		t.Fatalf("state file must only keep the services still to be restored: %+v", state.Services)
	}
}

// 周期自愈：启动自愈跑完之后才出现的待恢复项（软失败条目留在文件里，用户随后把那个服务
// 重新启用）必须被后续 tick 收拾掉。只等"下次 daemon 启动"不够 —— daemon 由 launchd
// KeepAlive 托管，可能几星期都不重启一次。
func TestEngineDNSSelfHealPicksUpLeftoverState(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = dnsTakeoverAddress
	takeover := newTestTakeover(t, runner)
	eng := &Engine{status: StatusDisconnected, dns: takeover, dnsSelfHealEvery: time.Millisecond}
	t.Cleanup(eng.Close)

	if err := takeover.writeState(dnsTakeoverState{
		Version:   1,
		Addresses: []string{dnsTakeoverAddress},
		Services:  []dnsServiceState{{Service: "Wi-Fi", Servers: []string{"1.1.1.1"}}},
	}); err != nil {
		t.Fatalf("writeState: %v", err)
	}

	eng.StartDNSSelfHeal()
	waitFor(t, 5*time.Second, "periodic self-heal", func() bool {
		return runner.currentOf("Wi-Fi") == "1.1.1.1"
	})
	assertNoState(t, takeover)
}

// 没有残留文件时一个 tick 只花一次 stat：一条外部命令都不许发，否则"5 分钟一次"就成了
// 每 5 分钟往 SystemConfiguration 上敲一遍，还会唤醒其它 VPN 客户端的配置监视器。
func TestEngineDNSSelfHealWithoutStateRunsNoCommand(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	takeover := newTestTakeover(t, runner)
	eng := &Engine{status: StatusDisconnected, dns: takeover, dnsSelfHealEvery: time.Millisecond}
	t.Cleanup(eng.Close)

	eng.StartDNSSelfHeal()
	time.Sleep(50 * time.Millisecond) // 约 50 个 tick
	if runner.callCount() != 0 {
		t.Fatalf("no leftover state must mean no commands, got %v", runner.calls)
	}
}

// 连接态下状态文件里躺的是当前生效的接管记录，不是残留：自愈一条命令都不许发。
func TestEngineDNSSelfHealSkipsWhileConnected(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = dnsTakeoverAddress
	takeover := newTestTakeover(t, runner)
	eng := &Engine{status: StatusConnected, dns: takeover, dnsSelfHealEvery: time.Millisecond}
	t.Cleanup(eng.Close)

	if err := takeover.writeState(dnsTakeoverState{
		Version:   1,
		Addresses: []string{dnsTakeoverAddress},
		Services:  []dnsServiceState{{Service: "Wi-Fi", Servers: []string{"1.1.1.1"}}},
	}); err != nil {
		t.Fatalf("writeState: %v", err)
	}

	eng.StartDNSSelfHeal()
	time.Sleep(50 * time.Millisecond)
	if runner.callCount() != 0 {
		t.Fatalf("self-heal must stay idle while connected, got %v", runner.calls)
	}
	assertHasState(t, takeover)
}

// 自愈绝不许推翻一个生效中的接管。引擎状态那道粗筛是在锁外读的，随时可能过期（读完的下一
// 瞬间用户点了连接并接管成功）；真正防住的是 SelfHealLeftover 锁内的 !active 闸门。这里
// 直接把引擎摆成断开、而 takeover 处于 active，模拟那个过期瞬间。
func TestEngineDNSSelfHealNeverUndoesLiveTakeover(t *testing.T) {
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = "1.1.1.1"
	takeover := newTestTakeover(t, runner)
	if err := takeover.Takeover(); err != nil {
		t.Fatalf("Takeover: %v", err)
	}
	callsAfterTakeover := runner.callCount()

	eng := &Engine{status: StatusDisconnected, dns: takeover, dnsSelfHealEvery: time.Millisecond}
	t.Cleanup(eng.Close)

	eng.StartDNSSelfHeal()
	time.Sleep(50 * time.Millisecond)

	if runner.callCount() != callsAfterTakeover {
		t.Fatalf("self-heal must not touch a live takeover: %v", runner.setCalls())
	}
	if runner.currentOf("Wi-Fi") != dnsTakeoverAddress {
		t.Fatalf("the live takeover was undone by self-heal, got %q", runner.currentOf("Wi-Fi"))
	}
}

// Close 必须等在跑的那个 tick 真正结束再返回：tick 里发的是 networksetup，让它继续跑在
// 进程退出之后等于把系统 DNS 的改动扔进一个没人再观测的窗口 —— 最后一条改动的结果既没人
// 记进状态文件，也没人上报。顺带锁住 StartDNSSelfHeal 的幂等（起两个 goroutine 就是两路
// 命令互相踩）和 Close 的可重入（daemon 退出路径和 t.Cleanup 都会调）。
//
// 卡点故意选在 OnError 上报里，不是选在 networksetup 上：tick 卡在 networksetup 时它还
// 持着 t.mu，Close 末尾的 e.dns.Close() 会顺带被那把锁挡住，于是"Close 等到了"看起来成立
// 但完全是巧合 —— 一旦以后有人调整 Close 的顺序就悄悄失效。上报发生在锁外，只有真正的
// `<-done` 能挡住它。
func TestEngineDNSSelfHealCloseWaitsForInFlightTick(t *testing.T) {
	runner := newFakeDNSRunner(`An asterisk (*) denotes that a network service is disabled.
*iPhone USB
Wi-Fi`)
	runner.current["Wi-Fi"] = dnsTakeoverAddress
	// 禁用服务写不进去 → 软失败 → tick 末尾会走一次 OnError 上报。
	runner.setErr["iPhone USB"] = errors.New("exit status 1")
	takeover := newTestTakeover(t, runner)
	takeover.retryInterval = time.Hour

	if err := takeover.writeState(dnsTakeoverState{
		Version:   1,
		Addresses: []string{dnsTakeoverAddress},
		Services: []dnsServiceState{
			{Service: "Wi-Fi", Servers: []string{"1.1.1.1"}},
			{Service: "iPhone USB", Servers: []string{"8.8.8.8"}},
		},
	}); err != nil {
		t.Fatalf("writeState: %v", err)
	}

	callback := &blockingDNSCallback{release: make(chan struct{})}
	eng := &Engine{
		status:           StatusDisconnected,
		dns:              takeover,
		callback:         callback,
		dnsSelfHealEvery: time.Millisecond,
	}
	// Cleanup 是 LIFO：放行必须排在 eng.Close 之前跑，否则任何一条 t.Fatal 路径都会让
	// Close 永远等在 <-done 上，测试从超时里出来而不是从断言里出来。
	t.Cleanup(eng.Close)
	t.Cleanup(callback.releaseAll)

	eng.StartDNSSelfHeal()
	eng.StartDNSSelfHeal() // 幂等：不许起第二个 goroutine

	// 等到 tick 真的跑进上报里：此刻它已经放开 t.mu，只剩 <-done 能挡住 Close。
	waitFor(t, 2*time.Second, "the pending-soft-failure report", callback.hasEntered)

	eng.mu.Lock()
	done := eng.dnsSelfHealDone
	eng.mu.Unlock()
	if done == nil {
		t.Fatal("self-heal goroutine was never started")
	}

	const hold = 100 * time.Millisecond
	go func() {
		time.Sleep(hold)
		callback.releaseAll()
	}()

	start := time.Now()
	eng.Close()
	if elapsed := time.Since(start); elapsed < hold {
		t.Fatalf("Close returned after %s, it did not wait for the in-flight self-heal tick", elapsed)
	}
	select {
	case <-done:
	default:
		t.Fatal("Close returned while the self-heal goroutine was still alive")
	}
	eng.Close() // 可重入
}

// 软失败（服务还在、只是当前被禁用）必须提醒用户一次：他重新启用那块网卡的瞬间，它的 DNS
// 还指着已消失的 tun。但只提醒一次 —— 周期自愈每 5 分钟醒一次，同一批条目弹十几遍提示就
// 是噪音，用户会学会忽略它，真正要紧的那条也一起被忽略。
func TestEngineDNSPendingSoftFailureReportedOnce(t *testing.T) {
	runner := newFakeDNSRunner(`An asterisk (*) denotes that a network service is disabled.
*iPhone USB
Wi-Fi`)
	runner.current["Wi-Fi"] = dnsTakeoverAddress
	// 禁用服务的 -setdnsservers 真实返回未实机验证，这里按"写不进去"模拟。
	runner.setErr["iPhone USB"] = errors.New("exit status 1")
	takeover := newTestTakeover(t, runner)
	takeover.retryInterval = time.Hour

	if err := takeover.writeState(dnsTakeoverState{
		Version:   1,
		Addresses: []string{dnsTakeoverAddress},
		Services: []dnsServiceState{
			{Service: "Wi-Fi", Servers: []string{"1.1.1.1"}},
			{Service: "iPhone USB", Servers: []string{"8.8.8.8"}},
		},
	}); err != nil {
		t.Fatalf("writeState: %v", err)
	}

	callback := &recordingDNSCallback{}
	eng := &Engine{status: StatusDisconnected, dns: takeover, callback: callback}
	t.Cleanup(eng.Close)

	eng.RestoreLeftoverDNS()
	first := callback.snapshot()
	if len(first) != 1 || !strings.Contains(first[0], "iPhone USB") {
		t.Fatalf("a pending soft failure must be reported exactly once: %v", first)
	}
	if !strings.HasPrefix(first[0], "2:") {
		t.Fatalf("a pending soft failure is a warning, not a fatal error: %v", first)
	}

	// 后续每个 tick 都会再跑一遍恢复，但同一批条目不许重复上报。
	eng.selfHealDNSOnce()
	eng.selfHealDNSOnce()
	if got := callback.snapshot(); len(got) != 1 {
		t.Fatalf("the same pending entry must not be reported on every tick: %v", got)
	}
	if state := assertHasState(t, takeover); len(state.Services) != 1 || state.Services[0].Service != "iPhone USB" {
		t.Fatalf("the disabled entry must stay in the file: %+v", state.Services)
	}
}

type orderObserver struct {
	inner                 commandRunner
	configPath            string
	sawRestore            bool
	singBoxAliveOnRestore bool
}

func (o *orderObserver) Run(ctx context.Context, name string, args ...string) (string, error) {
	if len(args) > 0 && args[0] == "-setdnsservers" {
		o.sawRestore = true
		if _, err := os.Stat(o.configPath); err == nil {
			o.singBoxAliveOnRestore = true
		}
	}
	return o.inner.Run(ctx, name, args...)
}
