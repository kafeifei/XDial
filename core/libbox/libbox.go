//go:build !windows

// Package libbox 是 XDial tvOS 自研引擎的进程内门面:
// sslcon(AnyConnect) + gVisor 用户态栈 + sing-box(库,非外置进程)整合成
// 单个 gomobile 可绑定的 API,供 NEPacketTunnelProvider(Swift)调用。
//
// 对照 macOS 版 core/engine.Engine:那边 sing-box 是 exec 出去的外置二进制,
// "vpn" 出口经本地 SOCKS5 中转;这里 sing-box 作为库直接跑在同一进程,
// "vpn" 出口(vpn_outbound.go)直接拨 VPNBridge,省掉中转那一跳。
//
// Phase 0 范围:验证 sslcon+gVisor+sing-box 这条依赖链能否被 gomobile 绑定到 tvOS,
// 并跑通到 AnyConnect 服务端的真实连接。TUN inbound 与 NE packetFlow 的对接
// (adapter.PlatformInterface)留到 Phase 2 —— 那需要真实的 NEPacketTunnelProvider
// 才能验证,在没有 Xcode/真机的情况下无法有意义地测试。
package libbox

import (
	"context"
	"fmt"
	"sync"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json"
	"github.com/sagernet/sing/service"

	"github.com/kafeifei/xdial/core/engine"
)

// Callback 镜像 core/engine.StatusCallback 的形状,保持 gomobile 可绑定
// (方法参数只用 string/int 等基础类型)。
type Callback interface {
	OnStatusChanged(statusJSON string)
	OnError(code int, message string)
}

// 错误分类码:通过 Callback.OnError 传给 Swift 侧,让上层能按大类做区分处理
// (比如"配置错" vs "网络错"给不同的用户提示),而不必解析 Go error 字符串。
// 刻意只分几大类,不做细粒度设计。
const (
	// ErrCodeState 引擎状态非法(如已在运行时又调 Start)。
	ErrCodeState = 1
	// ErrCodeNetwork AnyConnect 拨号/网桥建立等网络层失败。
	ErrCodeNetwork = 2
	// ErrCodeConfig sing-box 配置解析失败。
	ErrCodeConfig = 3
	// ErrCodeEngine sing-box 实例构建/启动失败。
	ErrCodeEngine = 4
)

type Libbox struct {
	mu       sync.Mutex
	cb       Callback
	vpn      *engine.VPNClient
	bridge   *engine.VPNBridge
	box      *box.Box
	running  bool
	platform *xdPlatformInterface
}

func New(cb Callback) *Libbox {
	return &Libbox{
		cb:       cb,
		vpn:      engine.NewVPNClient(),
		platform: &xdPlatformInterface{},
	}
}

// SetTunFD 记录 NE packetFlow 对应的文件描述符,供 sing-box 的 TUN inbound 复用。
//
// 调用时机:Swift 的 NEPacketTunnelProvider.startTunnel 里,在拿到 packetFlow 的
// fd(通过 packetFlow.value(forKeyPath: "socket.fileDescriptor") 之类的方式取得)
// 之后、调用 Start 之前调用一次。Start 内部会把这个 fd dup 一份交给 sing-box
// (见 platform.go 的 OpenInterface),原始 fd 的所有权仍归 NE。
//
// 若引擎跑的是不含 tun inbound 的配置(如桌面手测用 socks inbound),不设置也没关系。
func (l *Libbox) SetTunFD(fd int) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.platform.tunFD = fd
}

// SetTunOpener 替换 TUN 打开器(默认走 dup(tunFD)+tun.New 的真实路径)。
//
// 这是刻意留给离线集成测试的缝隙:测试代码可从包外注入一个返回 fake tun.Tun 的
// opener,从而在没有 NE/真实 fd 的桌面环境跑通 sing-box 启动链路。参数是函数类型,
// gomobile 绑定时会自动跳过本方法,不影响 tvOS 导出面。生产代码无需调用。
func (l *Libbox) SetTunOpener(opener TunOpener) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.platform.opener = opener
}

// IsRunning 返回引擎当前是否处于已启动状态。
func (l *Libbox) IsRunning() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.running
}

// Status 返回一个 JSON 字符串描述当前状态,形如 {"running":true}。
// 与 OnStatusChanged 推送的语义一致,但供 Swift 侧主动轮询用。
func (l *Libbox) Status() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.running {
		return `{"running":true}`
	}
	return `{"running":false}`
}

// fail 在返回 error 前把结构化错误(分类码 + 文本)推给 Swift 侧,
// 再原样返回同一个 error 给 Go 调用方。集中一处,避免每条错误路径重复两行。
func (l *Libbox) fail(code int, err error) error {
	if l.cb != nil {
		l.cb.OnError(code, err.Error())
	}
	return err
}

// Start 连接 AnyConnect 服务端,起 gVisor 网桥,再用 configJSON 启动进程内 sing-box。
//
// configJSON 是标准 sing-box 配置(由 core/config.GenerateSingBox 产出,
// inbound 段在 Phase 2 改为 NE 模式),outbounds 里 "vpn" 类型的条目会
// 路由到本次连接建立的 VPNBridge。
func (l *Libbox) Start(server, username, password, configJSON string) error {
	l.mu.Lock()
	defer l.mu.Unlock()

	if l.running {
		return l.fail(ErrCodeState, fmt.Errorf("already running"))
	}

	vpnInfo, err := l.vpn.Connect(engine.VPNConfig{
		Server:   server,
		Username: username,
		Password: password,
	})
	if err != nil {
		return l.fail(ErrCodeNetwork, fmt.Errorf("anyconnect dial: %w", err))
	}

	bridge, err := engine.NewVPNBridge(vpnInfo.VPNAddress, vpnInfo.MTU)
	if err != nil {
		l.vpn.Disconnect()
		return l.fail(ErrCodeNetwork, fmt.Errorf("vpn bridge: %w", err))
	}
	cSess := l.vpn.Session()
	if cSess == nil {
		bridge.Close()
		l.vpn.Disconnect()
		return l.fail(ErrCodeNetwork, fmt.Errorf("vpn session lost right after connect"))
	}
	bridge.Start(cSess)

	ctx := boxContext(context.Background())
	ctx = service.ContextWith[*engine.VPNBridge](ctx, bridge)
	// 注入 PlatformInterface:sing-box 的 TUN inbound 靠它拿到 NE packetFlow 的 fd。
	// 与上面注入 VPNBridge 同一套 service.ContextWith 机制。
	ctx = service.ContextWith[adapter.PlatformInterface](ctx, adapter.PlatformInterface(l.platform))

	opts, err := json.UnmarshalExtendedContext[option.Options](ctx, []byte(configJSON))
	if err != nil {
		bridge.Close()
		l.vpn.Disconnect()
		return l.fail(ErrCodeConfig, fmt.Errorf("parse sing-box config: %w", err))
	}

	instance, err := box.New(box.Options{Options: opts, Context: ctx})
	if err != nil {
		bridge.Close()
		l.vpn.Disconnect()
		return l.fail(ErrCodeEngine, fmt.Errorf("construct sing-box: %w", err))
	}

	if err := instance.Start(); err != nil {
		bridge.Close()
		l.vpn.Disconnect()
		return l.fail(ErrCodeEngine, fmt.Errorf("start sing-box: %w", err))
	}

	l.bridge = bridge
	l.box = instance
	l.running = true

	if l.cb != nil {
		l.cb.OnStatusChanged(`{"status":"connected"}`)
	}
	return nil
}

func (l *Libbox) Stop() error {
	l.mu.Lock()
	defer l.mu.Unlock()

	if !l.running {
		return nil
	}

	if l.box != nil {
		l.box.Close()
		l.box = nil
	}
	if l.bridge != nil {
		l.bridge.Close()
		l.bridge = nil
	}
	l.vpn.Disconnect()
	l.running = false

	if l.cb != nil {
		l.cb.OnStatusChanged(`{"status":"disconnected"}`)
	}
	return nil
}
