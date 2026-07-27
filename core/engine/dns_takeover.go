package engine

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
)

// dnsTakeoverAddress 是 tun 接口地址 +1，不是 tun 接口地址本身。
//
// 必须是 +1 而不是 addr：tun 自己的 198.18.0.1（见 config.buildTUNInbound）在内核
// 路由表里那条是 RTF_LOCAL 的本机地址项，发往它的包被环回投递给本机协议栈，压根
// 不会写进 tun 设备，hijack-dns 永远接不住 —— 系统 DNS 查询原地超时，整机解析全
// 灭。198.18.0.2 不是接口地址，因此走的是 auto_route 装的那几条 sub-range 路由
// （见 dnsTakeoverGateway），下一跳是 tun 地址，包会真正进 tun，被
// {"protocol":"dns","action":"hijack-dns"} 接住并交给 sing-box 内部解析链应答。
// sing-box 官方 libbox 的 GetDNSServerAddress 用的就是 Addr().Next()，同款约定。
//
// 至于为什么非得接管系统 DNS：LAN 网关是 on-link 直达、官方 Tailscale 的
// 100.100.100.100 有自己的 host route，两者都天然绕过 tun 路由，应用拿到的是污染
// 结果，按域名分流随之失准。
const dnsTakeoverAddress = "198.18.0.2"

// dnsTakeoverGateway 是 tun 自己的 IPv4 地址，也就是接管地址的前一个地址（对齐
// config.buildTUNInbound，TestDNSTakeoverAddressIsTunAddressPlusOne 有防漂移断言）。
//
// 它是就绪探测的判据：sing-tun 在 darwin 上打开 auto_route 之后，装进内核的不是
// 198.18.0.0/15 这条接口路由，而是 8 条覆盖全 IPv4 的 sub-range（1.0.0.0/8、
// 2.0.0.0/7 … 128.0.0.0/1），每条都是 RTF_GATEWAY 且 gateway 就是这个 tun 地址。
// 接管地址 198.18.0.2 命中的是其中的 128.0.0.0/1。所以「路由已就绪」的充分判据是
// route -n get 打印的 gateway 行等于这个地址 —— 别的 utun（官方 Tailscale 客户端
// 装的 default link#43 utun13 之类）是 link 路由，route get 根本不打印 gateway 行，
// 天然被这条判据拒掉。
const dnsTakeoverGateway = "198.18.0.1"

// dnsTakeoverPrefix 是 tun 占的那一整段，用作「这个 DNS 地址是不是我们写进去的」的结构性
// 判据，补在"逐个比对记录过的地址"之后。
//
// 198.18.0.0/15 是 RFC 2544 专门留给网络设备基准测试的段，不会出现在任何真实的 DNS
// 配置里（既不是可路由的公网地址，也不在 RFC 1918 的私网段里，没有哪家路由器会往
// resolver 列表里下发它），所以「落在段内 ⇒ 是我们的残留」这条推断的误判率是零。
// 反过来漏认一个的代价是不可逆的：某个历史版本用过 198.18.0.7、而记着它的那份状态文件
// 已经随磁盘故障 / 用户手动清理一起没了，光靠地址列表就再也认不出它 —— 那个死地址从此
// 永久留在系统 DNS 里，整机解析全灭，没有任何路径会去救它。
//
// 常量与 config.GenerateSingBoxDesktop 生成的 tun 地址同源，防漂移断言见
// TestDNSTakeoverAddressIsTunAddressPlusOne。
var dnsTakeoverPrefix = netip.MustParsePrefix("198.18.0.0/15")

// isTakeoverAddress 判定 server 是不是「我们可能写进系统 DNS 的地址」：先认明确记录过的
// （地址列表，跨进程唯一的精确载体），再认整个 tun 网段（记录丢了之后唯一的兜底）。
// 解析不出来的字符串（networksetup 理论上只吐 IP，但输出格式不是契约）一律不认 ——
// 没有依据的"这是我们的"会让我们去清用户自己配的 DNS。
func isTakeoverAddress(addresses []string, server string) bool {
	if containsString(addresses, server) {
		return true
	}
	addr, err := netip.ParseAddr(server)
	if err != nil {
		return false
	}
	return dnsTakeoverPrefix.Contains(addr)
}

// containsAnyTakeoverAddress 判定一个服务当前的 DNS 列表里有没有我们的地址。
func containsAnyTakeoverAddress(servers, addresses []string) bool {
	for _, server := range servers {
		if isTakeoverAddress(addresses, server) {
			return true
		}
	}
	return false
}

// dnsTakeoverStateName 存「接管前各网络服务的原值」。这个文件的存在本身就是
// 信号：上一次没有恢复干净（进程被 SIGKILL / 掉电），此刻系统 DNS 还指着一个
// 已经消失的 tun，必须先自愈再干别的。
const dnsTakeoverStateName = "dns-takeover.json"

const (
	networksetupBinary = "/usr/sbin/networksetup"
	dscacheutilBinary  = "/usr/bin/dscacheutil"
	killallBinary      = "/usr/bin/killall"
	routeBinary        = "/sbin/route"
)

// networksetup 同步等 SystemConfiguration 提交，偶发卡死。断开路径要走这些调用，
// 一旦无上限阻塞就等于把用户永久留在「DNS 指向死 tun」的整机断网状态，所以每次
// 调用都必须自带超时。
const (
	networksetupTimeout = 5 * time.Second
	dnsFlushTimeout     = 5 * time.Second
	routeProbeTimeout   = 2 * time.Second
)

// dnsTakeoverBudget 是「一次 Takeover」或「一次 Restore」的总预算。单条命令各自
// 5 秒不够：十来个网络服务串起来最坏能堆到一分钟，而 Restore 是在持锁的断开路径
// 上跑的，用户会看着一个卡住的"正在断开"。预算耗尽按部分失败处理（保留状态文件，
// 交给后台重试 / 下次启动自愈），绝不无限往下发命令。
const dnsTakeoverBudget = 15 * time.Second

// tun 路由就绪探测：数据面刚起来那一小会儿路由还没装好，此刻把系统 DNS 指过去就是
// 整机解析黑洞。
const (
	dnsRouteProbeWindow   = 3 * time.Second
	dnsRouteProbeInterval = 250 * time.Millisecond
)

// 恢复失败后的后台有界重试。只靠"下次 daemon 启动时自愈"不够：用户可能几小时都不
// 重启，而这几小时里他的系统 DNS 指着已经消失的 tun，整机没网。
const (
	dnsRestoreRetryInterval = 30 * time.Second
	dnsRestoreRetryLimit    = 3
)

// errDNSResultUnknown 标记「这条命令是否已经生效不可知」。networksetup 是同步等
// SystemConfiguration 提交的，被 ctx deadline 杀掉的那一刻提交可能已经发生，所以
// 超时绝不能当成"没改"——当成没改就会删掉状态文件，从此没人再去救那个被改坏的
// 服务。
var errDNSResultUnknown = errors.New("命令超时，是否已生效不可知")

// commandRunner 把外部命令抽出来，单测全部用 fake：真跑 networksetup 会改动开发
// 机的系统配置。
type commandRunner interface {
	Run(ctx context.Context, name string, args ...string) (string, error)
}

type execCommandRunner struct{}

func (execCommandRunner) Run(ctx context.Context, name string, args ...string) (string, error) {
	out, err := exec.CommandContext(ctx, name, args...).CombinedOutput()
	return string(out), err
}

// dnsServiceState 是单个网络服务接管前的 DNS。Servers 为空表示「没有手工设置」，
// 即用 DHCP 下发的地址，恢复时要写回 networksetup 的哨兵值 Empty 而不是任何具体
// 地址。
type dnsServiceState struct {
	Service string   `json:"service"`
	Servers []string `json:"servers"`
}

type dnsTakeoverState struct {
	Version int       `json:"version"`
	TakenAt time.Time `json:"taken_at"`

	// Addresses 是「可能被我们写进系统 DNS 的全部地址」的全集：当前常量 ∪ 本进程这次
	// 实际用的地址 ∪ 上一份状态文件记录过的地址。劫持识别和 DHCP 兜底都按这个列表来
	// 认「这个服务是我们改过的」——少认一个就等于把一个死地址永久留在系统里，而跨进程
	// （SIGKILL / 掉电后由下次 daemon 启动自愈）时这份列表是唯一的载体。
	Addresses []string `json:"addresses,omitempty"`

	// Address 是升级前的单值字段，只为读旧文件保留：老进程写下的状态文件里只有它。
	// 新文件一律写 Addresses，所以带 omitempty。读取一律走 recordedAddresses。
	Address string `json:"address,omitempty"`

	Services []dnsServiceState `json:"services"`
}

// recordedAddresses 把状态文件里记录过的接管地址摊成一个列表，同时认新的 Addresses
// 和旧的单值 Address —— 跨版本读到哪种都不许漏。
func (s dnsTakeoverState) recordedAddresses() []string {
	addresses := make([]string, 0, len(s.Addresses)+1)
	for _, address := range append(append([]string(nil), s.Addresses...), s.Address) {
		if address != "" && !containsString(addresses, address) {
			addresses = append(addresses, address)
		}
	}
	return addresses
}

type dnsTakeover struct {
	mu        sync.Mutex
	runner    commandRunner
	stateDir  string
	supported bool
	active    bool

	// takenAddress 是本进程这次实际写进系统的接管地址。恢复兜底靠它认出"这个服务
	// 是我们改过的"；升级换过常量时它和 dnsTakeoverAddress 可以不同。
	takenAddress string

	// unresolved 是「系统里存在已被改动、尚未证实解除的劫持」这个事实的粘性标记。
	//
	// 它和 takenAddress 是同一件事的两半，缺一不可：takenAddress 只在本进程亲手接管
	// 时才有值，而残留自愈（上一个进程被 SIGKILL / 掉电，本进程只是照着状态文件收拾）
	// 从头到尾不会给它赋值。此时若恢复失败、随后状态文件又被外部删掉（用户手动清理 /
	// 磁盘被抹），restoreTargets 的静默出口就会把"文件不存在"判成无事可做 —— 继承下来
	// 的那份劫持从此没有任何路径去救，系统 DNS 永久指着已消失的 tun。
	//
	// 所以置位的时机是 restoreLocked 拿到非空恢复目标那一刻（继承的残留与本进程亲手
	// 接管同权），清空只发生在全量恢复成功的那个出口、和 takenAddress 一起。软失败
	// 出口故意不清：那时条目还躺在文件里等服务被重新启用，劫持并没有解除。
	unresolved bool

	// pendingSoft 是上一次恢复里「服务还在、只是当前被禁用」的软失败条目；
	// pendingReported 记已经上报给用户过的，避免周期自愈每个 tick 弹一次同样的提示。
	pendingSoft     []string
	pendingReported map[string]bool

	// 后台有界恢复重试的句柄：重新接管 / 恢复成功 / 引擎关闭时取消。
	retryCancel context.CancelFunc
	retryDone   chan struct{}

	// 下面这几个时长可注入，零值表示用上面的常量。单测需要真实制造 ctx deadline
	// 超时（"改动是否已提交不可知"这条分支只能这样触发）、跑完探测窗口和重试循环，
	// 不可能真等 5 秒 / 30 秒。
	cmdTimeout    time.Duration
	budget        time.Duration
	probeWindow   time.Duration
	probeInterval time.Duration
	retryInterval time.Duration

	// syncFile 同理可注入，nil 表示用平台默认（darwin 上的 F_FULLFSYNC）。单测要真实
	// 制造"刷盘失败"这条分支：悄悄当成功是最坏的结果 —— 调用方以为恢复依据已经安全
	// 落盘，随后放心去改系统 DNS。
	syncFile func(*os.File) error
}

// newDNSTakeover 只在 macOS 上真正生效：networksetup 是 macOS 独有的，其它平台
// （engine 包也编进 iOS/tvOS 的 libbox）直接退化成 no-op。
func newDNSTakeover(stateDir string) *dnsTakeover {
	return &dnsTakeover{
		runner:    execCommandRunner{},
		stateDir:  stateDir,
		supported: runtime.GOOS == "darwin",
	}
}

func (t *dnsTakeover) statePath() string {
	return filepath.Join(t.stateDir, dnsTakeoverStateName)
}

func orDuration(value, fallback time.Duration) time.Duration {
	if value <= 0 {
		return fallback
	}
	return value
}

// Takeover 把所有已启用网络服务的 DNS 指向 tun。调用方必须在数据面真正就绪之后
// 才调用，否则会有一段「DNS 指向还没起来的 tun」的黑洞窗口。
func (t *dnsTakeover) Takeover() error {
	if !t.supported {
		return nil
	}
	t.mu.Lock()
	defer t.mu.Unlock()

	// 幂等：已接管就什么都不做，尤其不能重读一遍当前值——那时读到的是我们自己写
	// 进去的接管地址，会把真正的原值覆盖成不可恢复。
	if t.active {
		return nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), orDuration(t.budget, dnsTakeoverBudget))
	defer cancel()

	// 路由没就绪就不接管：指过去的查询会掉进黑洞。跳过接管只是退回"查询绕过 tun、
	// 结果可能被污染、分流不准"，比整机没网好得多。
	if err := t.waitTunRoute(ctx); err != nil {
		return err
	}

	// known 额外含被禁用的服务：下面并入旧条目时要靠它区分「服务还在（只是被禁用 / 读
	// 不出来）」和「服务已被彻底删掉」，后者的恢复依据没有继续携带的意义。
	services, known, err := t.listServices(ctx)
	if err != nil {
		return err
	}

	// 磁盘上的旧状态可能还留着真正的原值（上一次没恢复干净）。先读出来：下面遇到
	// 「当前值就是接管地址」的服务时沿用它，而不是把原值记成 DHCP。previousExists
	// 单独拿出来是因为「文件在」本身就是"系统里存在未证实解除的既有劫持"这个信号，
	// 和它里面有没有具体原值无关（内容坏掉也算）。
	previousState, previousExists := t.loadState()
	previous := recordedOriginals(previousState)
	addresses := t.takeoverAddresses(previousState.recordedAddresses()...)

	state := dnsTakeoverState{
		Version: 1,
		TakenAt: time.Now().UTC(),
		// 记全集而不是只记本轮用的那一个：恢复侧（很可能已经是下一个进程）要靠这份列表
		// 认出所有历史接管地址，漏一个就在系统里留一个死地址。
		Addresses: addresses,
	}
	hijackedSeen := false
	for _, service := range services {
		servers, hijacked, err := t.originalServers(ctx, service, addresses)
		if err != nil {
			// 读不到原值的服务干脆不碰：没有恢复依据的改动不许做。
			slog.Warn("read system DNS failed, leaving service untouched", "service", service, "err", err)
			continue
		}
		if hijacked {
			hijackedSeen = true
		}
		// 只有「剔掉接管地址之后什么都不剩」时才去沿用磁盘旧记录：那时真正的原值确实
		// 不可知。剔完还剩别的服务器就是另一回事 —— 那是用户或别的 VPN 客户端在我们接管
		// 期间写进去的新值，它才是该恢复回去的真相，拿一份过时的旧记录盖掉它就是破坏。
		if hijacked && len(servers) == 0 && len(previous[service]) > 0 {
			slog.Info("reusing recorded original DNS for already-hijacked service", "service", service)
			servers = previous[service]
		}
		state.Services = append(state.Services, dnsServiceState{Service: service, Servers: servers})
	}
	if len(state.Services) == 0 {
		return fmt.Errorf("读取系统 DNS 失败，未接管任何网络服务")
	}

	// 只对本轮真正读到原值的服务发 set；下面并入的旧条目不在其中。
	targets := state.Services

	// 旧记录里本轮没记下的服务条目原样并入。两类：
	//   1. 服务还在但本轮没进 targets（被禁用，或枚举到了却 -getdnsservers 读不出来、
	//      上面按"没有依据不许碰"跳过了）；
	//   2. networksetup 压根不认识这个名字了 —— 服务被彻底删掉。
	// 第 1 类必须并入：它们的 DNS 里可能还留着上一次接管写进去的地址，而恢复依据只存在
	// 于这份旧记录里 —— writeState 是整份覆盖，不并入就等于把依据烧掉，那个服务从此永久
	// 指着已消失的 tun，没有任何路径会去救它。本轮不碰它们，只是把依据继续带着往下传。
	// 第 2 类要弃用：服务不会再回来，带着它只会让此后每一次恢复都白发一条注定
	// "** Error" 的命令，并把整体永久钉在"还有待恢复项"上。
	recorded := make(map[string]bool, len(targets))
	for _, entry := range targets {
		recorded[entry.Service] = true
	}
	for _, entry := range previousState.Services {
		if recorded[entry.Service] {
			continue
		}
		if !containsString(known, entry.Service) {
			slog.Info("服务已不存在，恢复依据已弃用", "service", entry.Service)
			continue
		}
		slog.Info("carrying over recovery basis recorded by an earlier takeover", "service", entry.Service)
		state.Services = append(state.Services, entry)
	}

	// 先落盘再改。反序会留下「已改但恢复依据还没写下」的窗口，那一刻进程被杀就
	// 永远拿不回原值了。
	if err := t.writeState(state); err != nil {
		return err
	}

	// 到这里才取消上一轮恢复失败留下的后台重试：它要是在接管之后醒过来，会把刚指好
	// 的 DNS 又"恢复"回去，接管当场失效。位置卡在「就绪探测已通过、马上发第一条 set」
	// 这个点上是有意的 —— 前面那些注定失败的退出路径（路由没就绪、枚举不到服务、原值
	// 一个都读不到）根本没碰系统 DNS，凭什么把别人排好的恢复重试解除掉。
	t.cancelRetryLocked()

	applied, unknown := 0, 0
	for _, entry := range targets {
		if err := t.setServers(ctx, entry.Service, []string{dnsTakeoverAddress}); err != nil {
			if errors.Is(err, errDNSResultUnknown) {
				unknown++
			}
			slog.Warn("set system DNS failed, continuing with other services", "service", entry.Service, "err", err)
			continue
		}
		applied++
	}
	switch {
	case applied == 0 && unknown == 0:
		// 全部失败且每一条都可证明未生效（networksetup 自己报错 / 正常退出但退出码
		// 非零）：本轮没碰动任何服务，不进接管态。
		//
		// 状态文件能不能删要另外判：只有在"系统里确实没有未证实解除的劫持"时才敢删
		// （留着的话下次启动会拿它去"恢复"，把我们从没碰过的服务改掉）。反过来，只要
		// 本轮观测到任何服务当前值里含接管地址，或者进来时磁盘上本来就有状态文件，
		// 就说明系统里还躺着上一次没解除干净的劫持 —— 这时删文件等于把唯一的恢复
		// 依据连同"需要恢复"这个信号一起烧掉，用户永久留在指向死 tun 的断网状态。
		if hijackedSeen || previousExists {
			slog.Error("takeover applied nothing but an unresolved hijack exists, keeping state file",
				"path", t.statePath(), "hijacked_observed", hijackedSeen, "previous_state", previousExists)
			return fmt.Errorf("设置系统 DNS 失败，全部网络服务均未生效（检测到未解除的既有劫持，恢复依据已保留）")
		}
		_ = t.removeState()
		return fmt.Errorf("设置系统 DNS 失败，全部网络服务均未生效")
	case applied == 0:
		// 至少一次失败是 ctx deadline 超时：networksetup 被 kill 时改动可能已经提交
		// 到 SystemConfiguration，必须按「已改」处理——保留状态文件并进接管态，否则
		// 恢复路径永远不会去救那个可能已经指向 tun 的服务。
		t.active = true
		t.takenAddress = dnsTakeoverAddress
		t.flushCache(ctx)
		return fmt.Errorf("设置系统 DNS 超时，是否已生效不可知，已按已接管处理")
	}

	t.active = true
	t.takenAddress = dnsTakeoverAddress
	t.flushCache(ctx)
	slog.Info("system DNS taken over", "address", dnsTakeoverAddress, "services", applied)
	return nil
}

// Restore 把系统 DNS 恢复成接管前的值。调用方必须在停 tun / sing-box 之前调用：
// 反序会留下一个「DNS 指向已经消失的 tun」的时间窗，那期间整机解析全灭。
func (t *dnsTakeover) Restore() error {
	if !t.supported {
		return nil
	}
	t.mu.Lock()
	defer t.mu.Unlock()

	err := t.restoreLocked()
	if err != nil {
		t.scheduleRestoreRetryLocked()
	}
	return err
}

// RestoreLeftover 自愈上一次没恢复干净的残留：daemon 被 SIGKILL 或整机掉电后
// dns-takeover.json 还在，系统 DNS 仍指着死 tun。launchd KeepAlive 把 daemon 拉
// 起来后由这里收拾。没有残留文件时绝不碰系统 DNS——没有依据的"恢复"就是破坏。
func (t *dnsTakeover) RestoreLeftover() error {
	if !t.supported {
		return nil
	}
	t.mu.Lock()
	defer t.mu.Unlock()

	if _, err := os.Stat(t.statePath()); err != nil {
		return nil
	}
	slog.Warn("found leftover DNS takeover state, restoring", "path", t.statePath())
	err := t.restoreLocked()
	if err != nil {
		t.scheduleRestoreRetryLocked()
	}
	return err
}

// SelfHealLeftover 是周期自愈（见 Engine.StartDNSSelfHeal）的入口。和 RestoreLeftover
// 的差别只有一条：多一道 !active 的闸门，而且这道闸门必须在 t.mu 之内、和 restoreLocked
// 原子完成。
//
// 原因是调用方那边的"引擎已断开"随时可能过期：它读完 status、还没走到这里的这一瞬间，
// 用户完全可能点了连接并接管成功。那时状态文件里躺的是刚写下的、正在生效的接管记录，
// 照着它"恢复"就是把用户刚指好的 DNS 当场推翻。active 判定放进锁内之后，Takeover 与
// 这里被 t.mu 串成前后关系，中间不存在可插入的窗口。
//
// 没有残留文件时只花一次 stat，所以 tick 再密也不产生外部命令。
func (t *dnsTakeover) SelfHealLeftover() error {
	if !t.supported {
		return nil
	}
	t.mu.Lock()
	defer t.mu.Unlock()

	if t.active {
		return nil
	}
	if _, err := os.Stat(t.statePath()); err != nil {
		return nil
	}
	slog.Warn("periodic self-heal found leftover DNS takeover state, restoring", "path", t.statePath())
	err := t.restoreLocked()
	if err != nil {
		t.scheduleRestoreRetryLocked()
	}
	return err
}

// takeNewPendingSoftFailures 取「本次之后新出现的软失败服务名」并标记为已上报。周期自愈
// 每 5 分钟醒一次，同一批禁用服务不该每次都弹一遍提示；而条目一旦真的恢复掉（全量成功
// 出口会清空 pendingReported），下次再出现时又该重新提醒一次。
func (t *dnsTakeover) takeNewPendingSoftFailures() []string {
	t.mu.Lock()
	defer t.mu.Unlock()

	var fresh []string
	for _, service := range t.pendingSoft {
		if t.pendingReported[service] {
			continue
		}
		if t.pendingReported == nil {
			t.pendingReported = map[string]bool{}
		}
		t.pendingReported[service] = true
		fresh = append(fresh, service)
	}
	return fresh
}

// notePendingSoftLocked 记下本轮的软失败条目，并把已经不在其中的服务从"已上报"里剔掉 ——
// 它下一次再变成软失败时该重新提醒。
func (t *dnsTakeover) notePendingSoftLocked(stale []string) {
	t.pendingSoft = stale
	for service := range t.pendingReported {
		if !containsString(stale, service) {
			delete(t.pendingReported, service)
		}
	}
}

// Close 收掉后台恢复重试。进程退出前调用：此刻要么已经恢复成功，要么状态文件还
// 在（下次 daemon 启动会再自愈），后台重试没有继续存在的意义。
func (t *dnsTakeover) Close() {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.cancelRetryLocked()
}

func (t *dnsTakeover) restoreLocked() error {
	total := orDuration(t.budget, dnsTakeoverBudget)
	ctx, cancel := context.WithTimeout(context.Background(), total)
	defer cancel()

	// 服务枚举懒加载：没有恢复目标时（最常见的"没接管过就断开"）一条命令都不该发。
	// 两处要用它：兜底路径挑「当前指着我们地址」的已启用服务，主路径把旧条目分成
	// 已启用 / 被禁用 / 已删除三类。枚举失败在主路径上不致命，退化成"无法判断"。
	var (
		liveDone    bool
		liveEnabled []string
		liveKnown   []string
		liveErr     error
	)
	liveServices := func() ([]string, []string, error) {
		if !liveDone {
			liveDone = true
			liveEnabled, liveKnown, liveErr = t.listServices(ctx)
		}
		return liveEnabled, liveKnown, liveErr
	}

	state, err := t.restoreTargets(ctx, liveServices)
	if err != nil {
		return err
	}
	targets := state.Services
	if len(targets) == 0 {
		t.active = false
		t.cancelRetryLocked()
		return nil
	}
	// 有非空恢复目标 = 系统里确实存在「已被改动、尚未证实解除」的劫持，不论它是本进程
	// 亲手接管的还是从状态文件里继承来的。粘性置位，只在全量恢复成功的出口清掉，理由见
	// unresolved 字段注释。
	t.unresolved = true

	enabled, known, listErr := liveServices()
	if listErr != nil {
		// 枚举不了就无法区分三类，一律按普通已启用服务处理：宁可多试几次，也不要把真正
		// 的失败误判成软失败而不再重试，更不要把还在的服务当成"已删除"、把它唯一的恢复
		// 依据一起丢掉。
		enabled, known = nil, nil
	}

	deadline, hasDeadline := ctx.Deadline()
	remaining := append([]dnsServiceState(nil), targets...)
	var failed, stale []string
	for i, entry := range targets {
		// enabled == nil 表示枚举失败，此时一律按已启用服务处理（见上）。
		listed := enabled == nil || containsString(enabled, entry.Service)
		if !listed && !containsString(known, entry.Service) {
			// networksetup 压根不认识这个服务名了：用户在系统设置里删掉了它 / 那块网卡
			// 对应的服务被移除。它不会再回来，恢复依据留着只会让此后每一次自愈都白发一条
			// 注定 "** Error" 的命令，并把整体永久钉在"还有待恢复项"上。
			slog.Info("服务已不存在，恢复依据已弃用", "service", entry.Service)
			remaining = dropService(remaining, entry.Service)
			t.persistProgress(state, remaining)
			continue
		}

		// 子预算逐轮重算：share = 剩余总预算 / 剩余目标数。健康服务几乎不花时间，它省下
		// 的那份自动摊给后面的目标；卡死在 SystemConfiguration 提交上的服务只能吃掉自己
		// 这一份，绝不会把排在它后面的服务（很可能正是用户唯一在用的 Wi-Fi）饿死。单条
		// 命令的实际 deadline 于是是 min(单命令上限, 本轮子预算, 总预算剩余)。
		share := total
		if hasDeadline {
			share = 0
			if left := time.Until(deadline); left > 0 {
				share = left / time.Duration(len(targets)-i)
			}
		}

		// 「服务还在但被禁用」只试一次就收手：它本来就大概率写不进去，走完两级兜底只是
		// 白烧预算，还会把整体判成失败、引来一轮又一轮重试风暴。条目留在文件里等它被
		// 重新启用。
		// 注：-setdnsservers 对「已存在但被禁用」的服务的真实返回未实机验证（未知服务名是
		// "** Error"，禁用服务是否同样报错没验过），判定一律从宽 —— 宁可当软失败把条目留
		// 在文件里，也不要把它当硬失败拖着整体不停重试。
		serviceCtx, cancelService := context.WithTimeout(ctx, share)
		if listed {
			err = t.restoreService(serviceCtx, entry)
		} else {
			err = t.setServers(serviceCtx, entry.Service, entry.Servers)
		}
		cancelService()

		if err != nil {
			if listed {
				failed = append(failed, entry.Service)
			} else {
				slog.Warn("service is disabled, keeping its recovery basis for later",
					"service", entry.Service, "err", err)
				stale = append(stale, entry.Service)
			}
			continue
		}
		// 恢复成功就立刻把这条从状态文件里剔掉并原子落盘。恢复过程中被 SIGKILL
		// （launchd 宽限期到点 / 掉电）时，已经救回来的服务不会被下次启动照着旧记录
		// 再改一遍，没救回来的依据一条不少。
		remaining = dropService(remaining, entry.Service)
		t.persistProgress(state, remaining)
	}
	t.active = false
	t.notePendingSoftLocked(stale)

	if len(failed) == 0 && len(remaining) == 0 {
		// 全部收拾干净了。清状态文件必须排在 flushCache 之前：flushCache 是尽力而为的
		// 收尾，两条命令都可能一路卡到预算耗尽，把清文件排在它后面就留下一个「已经全部
		// 恢复完、恢复依据却还躺在盘上」的时间窗 —— 那一刻进程被杀，下次启动会照着这份
		// 过时记录把已经好了的服务再改一遍。
		// （正常情况下 persistProgress 已经在最后一条成功时删掉了它，这里是收口兜底。）
		//
		// 这是唯一有资格清 unresolved 的出口：走到这里才证明系统里再没有我们改过、
		// 却还没写回去的服务。
		t.takenAddress = ""
		t.unresolved = false
		t.pendingReported = nil
		t.cancelRetryLocked()
		removeErr := t.removeState()
		t.flushCache(ctx)
		if removeErr != nil {
			return removeErr
		}
		slog.Info("system DNS restored", "services", len(targets))
		return nil
	}

	t.flushCache(ctx)
	if len(failed) > 0 {
		// 状态文件故意留着：后台重试和下次 daemon 启动（RestoreLeftover）都要靠它。
		return fmt.Errorf("恢复系统 DNS 失败：%s", strings.Join(failed, ", "))
	}
	// 只剩软失败条目：不报错（不触发重试风暴），条目留在文件里等服务被重新启用，
	// 由下次 daemon 启动的 RestoreLeftover 再试。
	slog.Warn("system DNS restored except for services that are currently disabled",
		"pending", strings.Join(stale, ", "), "path", t.statePath())
	return nil
}

// persistProgress 把「还没恢复成功的服务」原子写回状态文件，一条都不剩时直接删掉文件。
// 不许在 remaining 为空时"什么都不做"：那会让盘上留着一份所有条目都已恢复的旧记录，
// 此刻进程被杀，下次启动就照着它把已经好了的服务再改一遍。删掉之后不变式在每一步都
// 成立 —— 文件内容恒等于"尚未恢复的条目"，文件不存在恒等于"没有待恢复项"。
func (t *dnsTakeover) persistProgress(base dnsTakeoverState, remaining []dnsServiceState) {
	if len(remaining) == 0 {
		if err := t.removeState(); err != nil {
			slog.Warn("clear DNS restore state failed", "err", err)
		}
		return
	}
	base.Services = remaining
	if err := t.writeState(base); err != nil {
		slog.Warn("persist DNS restore progress failed", "err", err)
	}
}

func dropService(entries []dnsServiceState, service string) []dnsServiceState {
	out := entries[:0]
	for _, entry := range entries {
		if entry.Service != service {
			out = append(out, entry)
		}
	}
	return out
}

// restoreService 单个服务的两级兜底：原值 → 原值重试一次 → Empty（回 DHCP）。
// networksetup 的失败多是 SystemConfiguration 一时忙，重试一次就好；真的写不回原
// 值时，回 DHCP 得到的可能是被污染的解析结果，但永远好过把系统留在指向已消失 tun
// 的死地址上。两级都失败才算这个服务没救回来。
func (t *dnsTakeover) restoreService(ctx context.Context, entry dnsServiceState) error {
	var lastErr error
	for attempt := 1; attempt <= 2; attempt++ {
		err := t.setServers(ctx, entry.Service, entry.Servers)
		if err == nil {
			return nil
		}
		lastErr = err
		slog.Error("restore system DNS failed", "service", entry.Service, "attempt", attempt, "err", err)
	}
	if len(entry.Servers) == 0 {
		// 目标本来就是 Empty，第三次发同一条命令没有任何新信息。
		return lastErr
	}
	if err := t.setServers(ctx, entry.Service, nil); err != nil {
		slog.Error("fallback to DHCP failed too", "service", entry.Service, "err", err)
		return err
	}
	slog.Warn("original DNS unwritable, service reset to DHCP", "service", entry.Service, "err", lastErr)
	return nil
}

// scheduleRestoreRetryLocked 起一个有界后台重试（间隔 30s，最多 3 次）。恢复失败
// 意味着系统 DNS 还指着即将消失的 tun，整机解析全灭；只靠 daemon 下次启动自愈不
// 够——用户可能几小时都不重启。重新接管 / 恢复成功 / 引擎关闭都会取消它。
func (t *dnsTakeover) scheduleRestoreRetryLocked() {
	t.cancelRetryLocked()

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	t.retryCancel = cancel
	t.retryDone = done
	interval := orDuration(t.retryInterval, dnsRestoreRetryInterval)

	go func() {
		defer close(done)
		for attempt := 1; attempt <= dnsRestoreRetryLimit; attempt++ {
			select {
			case <-ctx.Done():
				return
			case <-time.After(interval):
			}

			t.mu.Lock()
			// 等锁期间可能已经重新接管或引擎关闭：那时再"恢复"就是把刚指好的 DNS
			// 推翻，比不恢复更糟。
			if ctx.Err() != nil {
				t.mu.Unlock()
				return
			}
			err := t.restoreLocked()
			t.mu.Unlock()

			if err == nil {
				slog.Info("system DNS restored by background retry", "attempt", attempt)
				return
			}
			slog.Error("background DNS restore retry failed", "attempt", attempt, "max", dnsRestoreRetryLimit, "err", err)
		}
		slog.Error("giving up background DNS restore, state file kept for next daemon start", "path", t.statePath())
	}()
}

func (t *dnsTakeover) cancelRetryLocked() {
	if t.retryCancel != nil {
		t.retryCancel()
		t.retryCancel = nil
	}
	t.retryDone = nil
}

// restoreTargets 决定「恢复成什么」。正常路径读状态文件按原值恢复；文件不见了或
// 内容坏了就进兜底：原值不可知时，把「当前 DNS 正指着我们那个地址」的服务清成
// Empty（回到 DHCP 下发）。宁可退回可能被污染的 DHCP DNS，也绝不把系统留在指向
// 已消失 tun 的整机断网状态。只挑「指着我们地址」的服务是为了不误伤用户自己手
// 工配过、我们从没碰过的服务。
//
// 「文件不存在就当没事」这个静默出口的闸门要同时满足三条：!active、takenAddress == ""、
// !unresolved。三条各挡一类漏救：
//   - active 在每一次恢复尝试末尾就被清掉，光看它会把「接管过 → 恢复失败 → 状态文件被
//     外部删掉」判成无事可做；
//   - takenAddress 只在全量恢复成功处清空，非空恰好等于"本进程亲手接管过、而且还没证实
//     解除"；
//   - unresolved 覆盖 takenAddress 覆盖不到的那一半：残留自愈（上一个进程接管、本进程
//     只是照着文件收拾）从头到尾不会给 takenAddress 赋值，只有它记得"手上有一份继承来的、
//     尚未解除的劫持"。
//
// 三条任一为真就走兜底（hijackedServices → Empty → DHCP），而不是静默成功。
func (t *dnsTakeover) restoreTargets(ctx context.Context, liveServices func() ([]string, []string, error)) (dnsTakeoverState, error) {
	fallback := func(recorded []string) (dnsTakeoverState, error) {
		// recorded 即使在这条路上也要用上：旧版本用过别的接管地址（198.18.0.1），
		// 只认当前常量会漏掉它，把死地址留在系统里。
		services, _, err := liveServices()
		if err != nil {
			return dnsTakeoverState{}, err
		}
		addresses := t.takeoverAddresses(recorded...)
		return dnsTakeoverState{
			Version:   1,
			TakenAt:   time.Now().UTC(),
			Addresses: addresses,
			Services:  t.hijackedServices(ctx, services, addresses),
		}, nil
	}

	data, err := os.ReadFile(t.statePath())
	if err != nil {
		if errors.Is(err, os.ErrNotExist) && !t.active && t.takenAddress == "" && !t.unresolved {
			return dnsTakeoverState{}, nil
		}
		slog.Error("read DNS takeover state failed, falling back to DHCP", "err", err)
		return fallback(nil)
	}
	var state dnsTakeoverState
	if err := json.Unmarshal(data, &state); err != nil || len(state.Services) == 0 {
		slog.Error("DNS takeover state unusable, falling back to DHCP", "path", t.statePath(), "err", err)
		return fallback(state.recordedAddresses())
	}
	if state.Version == 0 {
		state.Version = 1
	}
	return state, nil
}

// takeoverAddresses 列出「可能被我们写进系统 DNS」的地址：当前常量、本进程这次接
// 管实际用的地址、以及磁盘旧状态记录的地址。少认一个就等于把死地址留在系统里。
func (t *dnsTakeover) takeoverAddresses(extra ...string) []string {
	addresses := []string{dnsTakeoverAddress}
	for _, address := range append([]string{t.takenAddress}, extra...) {
		if address != "" && !containsString(addresses, address) {
			addresses = append(addresses, address)
		}
	}
	return addresses
}

// hijackedServices 列出当前 DNS 里含任一接管地址的已启用服务，恢复目标一律为空
// （Empty → DHCP）。读不出当前值的服务也算进来：读失败通常意味着这台机器的
// networksetup 整体有问题，此时"多清一个"远好过"漏掉一个死地址"。
func (t *dnsTakeover) hijackedServices(ctx context.Context, services []string, addresses []string) []dnsServiceState {
	var targets []dnsServiceState
	for _, service := range services {
		servers, err := t.readServers(ctx, service)
		if err == nil && !containsAnyTakeoverAddress(servers, addresses) {
			continue
		}
		targets = append(targets, dnsServiceState{Service: service})
	}
	return targets
}

// waitTunRoute 等到接管地址真的经 tun 出去为止。sing-box 起来到 auto_route 把路由
// 装好之间有一小段空档，那时把系统 DNS 指过去就是整机解析黑洞。探测超时就跳过接
// 管（由调用链上报 OnError(2)）。
//
// 判据是「route -n get 打印的 gateway 行 == tun 自己的 IPv4 地址」，理由见
// dnsTakeoverGateway：auto_route 装的 sub-range 路由都是 RTF_GATEWAY 且下一跳就是
// 这个地址，而本机上和它竞争的其它 utun 路由（官方 Tailscale 客户端的
// default link#43 utun13）是 link 路由，route get 不打印 gateway 行，天然被拒。
// 出接口仍要求是 utun：gateway 对上而接口不是 tun 只能是路由表处于半装状态。
func (t *dnsTakeover) waitTunRoute(budget context.Context) error {
	deadline := time.Now().Add(orDuration(t.probeWindow, dnsRouteProbeWindow))
	interval := orDuration(t.probeInterval, dnsRouteProbeInterval)

	var detail string
	for {
		iface, gateway, err := t.routeTarget(budget)
		switch {
		case err != nil:
			detail = err.Error()
		case gateway == "":
			// 没有 gateway 行 = 命中的是某条 link 路由（典型就是官方 Tailscale 那条
			// default link#43 utun13），不是我们 tun 的 sub-range 路由。
			detail = fmt.Sprintf("命中的是 %s 上的 link 路由，不是 tun 的 sub-range 路由", iface)
		case gateway != dnsTakeoverGateway:
			detail = fmt.Sprintf("下一跳 %s 不是 tun 地址 %s", gateway, dnsTakeoverGateway)
		case !strings.HasPrefix(iface, "utun"):
			detail = fmt.Sprintf("出接口 %s 不是 tun", iface)
		default:
			return nil
		}

		if time.Now().After(deadline) || budget.Err() != nil {
			return fmt.Errorf("tun 路由未就绪，跳过接管系统 DNS（%s）", detail)
		}
		select {
		case <-time.After(interval):
		case <-budget.Done():
			return fmt.Errorf("tun 路由未就绪，跳过接管系统 DNS（%s）", detail)
		}
	}
}

// routeTarget 解析 route -n get 的 interface / gateway 两行。gateway 行只在命中
// RTF_GATEWAY 路由时才有，缺失本身就是有效信息（命中的是 link 路由），所以它为空
// 不算错误，交给 waitTunRoute 判。
func (t *dnsTakeover) routeTarget(budget context.Context) (string, string, error) {
	out, err := t.runCommand(budget, orDuration(t.cmdTimeout, routeProbeTimeout), routeBinary, "-n", "get", "-inet", dnsTakeoverAddress)
	if err != nil {
		return "", "", err
	}
	var iface, gateway string
	for _, line := range strings.Split(out, "\n") {
		key, value, ok := strings.Cut(strings.TrimSpace(line), ":")
		if !ok {
			continue
		}
		switch strings.TrimSpace(key) {
		case "interface":
			iface = strings.TrimSpace(value)
		case "gateway":
			gateway = strings.TrimSpace(value)
		}
	}
	if iface == "" {
		return "", "", fmt.Errorf("route 输出里没有 interface 行")
	}
	return iface, gateway, nil
}

// listServices 解析 -listallnetworkservices 的完整输出，一次给出两个集合：
//   - enabled：可改 DNS 的已启用服务（输出里没有 * 前缀的那些）；
//   - known：enabled 再加上带 * 的被禁用服务（前缀已剥掉），也就是 networksetup 认识的
//     全部服务名。
//
// 两个集合都要，是因为恢复侧必须把状态文件里的旧条目分成三类，处置完全不同：已启用走
// 正常两级兜底；被禁用是软失败（只试一次，依据留着等它被重新启用）；networksetup 压根
// 不认识的是已被删除，依据该弃用 —— 混成一类的话，要么把不会再回来的服务永久钉在待恢复
// 列表里（每次自愈白发一条注定报错的命令），要么把只是暂时被禁用的服务的唯一恢复依据
// 丢掉，那个服务从此永久指着已消失的 tun。
//
// 带 * 前缀的服务改 DNS 没有意义（networksetup 也会报错），所以不进 enabled。
//
// 故意不做任何设备过滤：Wi-Fi / 有线之外，Surge、Tailscale、各家 VPN 客户端装的那些
// 虚拟网络服务也全都要接管。这是有意决定，不是漏筛 —— SystemConfiguration 的
// resolver 顺序是按服务序（ServiceOrder）来的，只改物理网卡的话，任何一个排在前面的
// 虚拟服务都会继续把查询接走，接管等于没做，按域名分流照旧失准。
//
// 代价是知情接受的：每条 -setdnsservers 都是一次 SystemConfiguration 提交，会唤醒
// 其它 VPN 客户端的配置监视器；它们要是在我们接管期间自己回写 DNS，我们恢复时会拿
// 接管前记下的旧值把它们的新值覆盖掉。用"少改一个就等于没接管"来换这点冲突风险。
func (t *dnsTakeover) listServices(ctx context.Context) ([]string, []string, error) {
	out, err := t.runNetworksetup(ctx, "-listallnetworkservices")
	if err != nil {
		return nil, nil, err
	}
	var enabled, known []string
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.Contains(line, "denotes that a network service is disabled") {
			continue
		}
		if name := strings.TrimPrefix(line, "*"); name != line {
			if name != "" {
				known = append(known, name)
			}
			continue
		}
		enabled = append(enabled, line)
		known = append(known, line)
	}
	if len(enabled) == 0 {
		return nil, nil, fmt.Errorf("没有已启用的网络服务")
	}
	return enabled, known, nil
}

// readServers 读单个服务当前的 DNS，原样返回（含可能存在的接管地址，恢复兜底要靠
// 它认出"这个服务是我们改过的"）。返回空切片表示"没有手工设置"，即用 DHCP 下发的
// 地址。
func (t *dnsTakeover) readServers(ctx context.Context, service string) ([]string, error) {
	out, err := t.runNetworksetup(ctx, "-getdnsservers", service)
	if err != nil {
		return nil, err
	}
	// "There aren't any DNS Servers set on X." 是 networksetup 表达"用 DHCP 下发"
	// 的方式，不是错误。
	if strings.Contains(out, "aren't any DNS Servers") {
		return nil, nil
	}
	var servers []string
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		servers = append(servers, line)
	}
	return servers, nil
}

// originalServers 给"记录原值"用：把我们自己写进去的接管地址剔掉。hijacked 为 true
// 表示当前值里含接管地址——上一次没恢复干净，真正的原值已经不可知，剔完剩下的通
// 常是空（看着像 DHCP），调用方要优先沿用磁盘旧记录里的原值。
func (t *dnsTakeover) originalServers(ctx context.Context, service string, addresses []string) ([]string, bool, error) {
	servers, err := t.readServers(ctx, service)
	if err != nil {
		return nil, false, err
	}
	var filtered []string
	hijacked := false
	for _, server := range servers {
		if isTakeoverAddress(addresses, server) {
			hijacked = true
			continue
		}
		filtered = append(filtered, server)
	}
	return filtered, hijacked, nil
}

func (t *dnsTakeover) setServers(ctx context.Context, service string, servers []string) error {
	args := append([]string{"-setdnsservers", service}, servers...)
	if len(servers) == 0 {
		args = append(args, "Empty")
	}
	_, err := t.runNetworksetup(ctx, args...)
	return err
}

// loadState 读磁盘上的旧状态，只当"参考资料"用：解析失败不是错误，退化成「内容不可
// 用」即可。第二个返回值只表示文件在不在 —— 它本身就是「上一次没恢复干净、系统里还
// 躺着未证实解除的劫持」这个信号，和里面能不能解析出原值无关。
func (t *dnsTakeover) loadState() (dnsTakeoverState, bool) {
	data, err := os.ReadFile(t.statePath())
	if err != nil {
		return dnsTakeoverState{}, false
	}
	var state dnsTakeoverState
	if err := json.Unmarshal(data, &state); err != nil {
		slog.Warn("previous DNS takeover state unusable, ignoring recorded originals", "path", t.statePath(), "err", err)
		return dnsTakeoverState{}, true
	}
	return state, true
}

// recordedOriginals 把旧状态摊成 service → 原值。只收有原值的服务：记着 DHCP 的条目
// 和默认兜底完全等价，收进来只会让沿用逻辑更难读。
func recordedOriginals(state dnsTakeoverState) map[string][]string {
	previous := make(map[string][]string, len(state.Services))
	for _, entry := range state.Services {
		if len(entry.Servers) > 0 {
			previous[entry.Service] = entry.Servers
		}
	}
	return previous
}

// runNetworksetup 走共享预算跑一条 networksetup。networksetup 在部分错误下仍返回
// exit 0，只把 "** Error" 写进 stdout，所以退出码之外还得看输出——这类失败是可证明
// 未生效的（参数根本没被接受），故意不带 errDNSResultUnknown。
func (t *dnsTakeover) runNetworksetup(ctx context.Context, args ...string) (string, error) {
	out, err := t.runCommand(ctx, orDuration(t.cmdTimeout, networksetupTimeout), networksetupBinary, args...)
	if err != nil {
		return out, err
	}
	if strings.Contains(out, "** Error") {
		return out, fmt.Errorf("networksetup %s: %s", strings.Join(args, " "), firstLine(out))
	}
	return out, nil
}

// runCommand 在共享总预算 budget 之内跑一条外部命令，单条上限 limit —— 实际
// deadline 是 min(limit, 预算剩余)，因为 WithTimeout 会继承父 ctx 更早的那个。
// 「结果不可知」的失败（预算耗尽 / deadline 把进程杀了）一律包上
// errDNSResultUnknown，让调用方能把它和"可证明未生效"区分开。
func (t *dnsTakeover) runCommand(budget context.Context, limit time.Duration, name string, args ...string) (string, error) {
	label := strings.TrimSpace(name + " " + strings.Join(args, " "))
	if budget.Err() != nil {
		// 预算已经被前面的超时吃光：继续发命令只会立刻被 kill，结果照样落在"不可知"
		// 一侧，不如直接停手并如实上报不可知。
		return "", fmt.Errorf("%s: %w", label, errDNSResultUnknown)
	}

	ctx, cancel := context.WithTimeout(budget, limit)
	defer cancel()

	out, err := t.runner.Run(ctx, name, args...)
	out = strings.TrimSpace(out)
	if err != nil {
		if ctx.Err() != nil {
			return out, fmt.Errorf("%s: %w: %s", label, errDNSResultUnknown, firstLine(out))
		}
		return out, fmt.Errorf("%s: %w: %s", label, err, firstLine(out))
	}
	return out, nil
}

// flushCache 让已缓存的旧结果立刻失效——接管/恢复的瞬间解析链变了，缓存里还留着
// 上一条链的答案。两条命令都是尽力而为：失败只是旧缓存多活一会儿，不影响 DNS
// 指向本身，所以只告警。
func (t *dnsTakeover) flushCache(ctx context.Context) {
	commands := [][]string{
		{dscacheutilBinary, "-flushcache"},
		{killallBinary, "-HUP", "mDNSResponder"},
	}
	for _, command := range commands {
		out, err := t.runCommand(ctx, orDuration(t.cmdTimeout, dnsFlushTimeout), command[0], command[1:]...)
		if err != nil {
			slog.Warn("flush DNS cache failed", "cmd", command[0], "err", err, "out", out)
		}
	}
}

// writeState 原子且持久地落盘：写 tmp → 刷 tmp 的数据 → 关 → rename → 刷目录项。
// persistProgress 复用它，所以逐服务的恢复进度享有同一份保证。
//
// 光有 tmp + rename 只挡住"半截 JSON 被恢复路径判成损坏"，挡不住掉电 —— 而掉电正是
// 这个模块存在的理由之一（状态文件的语义就是"上一次没恢复干净"）。rename 只保证目录项
// 要么指向旧文件要么指向新文件，不保证新文件的内容已经到介质上：崩在中间会留下一个长度
// 对、内容却是一段零的文件（被判成损坏，精确原值丢失，退化成 DHCP 兜底），或者目录项
// 压根没落地、状态文件凭空消失（系统 DNS 指着已消失的 tun，而唯一的恢复依据没了）。
// 所以两次 sync 都是必需的：数据一次，目录项一次。
func (t *dnsTakeover) writeState(state dnsTakeoverState) error {
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return fmt.Errorf("序列化 DNS 接管状态: %w", err)
	}
	path := t.statePath()
	tmpPath := path + ".tmp"
	if err := t.writeFileSynced(tmpPath, data); err != nil {
		os.Remove(tmpPath)
		return err
	}
	if err := os.Rename(tmpPath, path); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("提交 DNS 接管状态: %w", err)
	}
	// 目录项自己也要落地。失败只告警：文件内容此刻已经在盘上，rename 也已在内存里生效，
	// 唯一的残余风险是"紧接着掉电"，为它把整个接管判成失败反而更糟。
	if err := syncDir(t.stateDir); err != nil {
		slog.Warn("fsync state directory failed", "dir", t.stateDir, "err", err)
	}
	return nil
}

// writeFileSynced 写一个新文件并确保内容真的落到介质上再返回。刷盘失败必须让整个写入
// 失败：谎报成功之后调用方就会放心去改系统 DNS，而唯一的恢复依据其实还只在页缓存里。
//
// O_TRUNC 在当前调用点是冗余的（tmp 每次都被 rename 移走，不会预先存在），保留它是为了
// 让这个函数对"文件已存在"也成立 —— 否则将来任何一个复用它的调用点都会静默继承上一份
// 内容的尾巴。
func (t *dnsTakeover) writeFileSynced(path string, data []byte) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return fmt.Errorf("写入 DNS 接管状态: %w", err)
	}
	if _, err := file.Write(data); err != nil {
		file.Close()
		return fmt.Errorf("写入 DNS 接管状态: %w", err)
	}
	sync := t.syncFile
	if sync == nil {
		sync = fullSync
	}
	if err := sync(file); err != nil {
		file.Close()
		return fmt.Errorf("刷盘 DNS 接管状态: %w", err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("关闭 DNS 接管状态: %w", err)
	}
	return nil
}

// syncDir 刷目录项，让 rename 的结果本身也持久化。
func syncDir(dir string) error {
	handle, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer handle.Close()
	return handle.Sync()
}

func (t *dnsTakeover) removeState() error {
	if err := os.Remove(t.statePath()); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("清除 DNS 接管状态: %w", err)
	}
	return nil
}

func firstLine(s string) string {
	if index := strings.IndexByte(s, '\n'); index >= 0 {
		return strings.TrimSpace(s[:index])
	}
	return s
}

func containsString(list []string, target string) bool {
	for _, item := range list {
		if item == target {
			return true
		}
	}
	return false
}
