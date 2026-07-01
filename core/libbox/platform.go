package libbox

import (
	"syscall"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/option"
	tun "github.com/sagernet/sing-tun"
	"github.com/sagernet/sing/common/control"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"
	"github.com/sagernet/sing/common/x/list"
	"net/netip"
)

// platform.go 把 XDial 的进程内 sing-box 接到 tvOS NetworkExtension 的 packetFlow。
//
// sing-box 通过 ctx 里的 adapter.PlatformInterface 决定 TUN inbound 怎么拿到底层
// 设备:当 UsePlatformInterface() 返回 true 时,它不会自己去 tun.New 打开一个新
// utun,而是回调 OpenInterface,让平台把 NE 已经建立好的 packetFlow 对应的文件
// 描述符交给 sing-box。macOS 版是外置进程 + 本地 TUN,不需要这条;tvOS 版扩展进程
// 内没有权限自己开 utun,只能复用 NE 给的 fd,所以必须实现这个接口。
//
// 这里刻意做成"最小可用":除 OpenInterface 外的方法几乎全部返回零值/false/nil,
// 因为 XDial 的出站流量走 vpnOutbound(sslcon + gVisor)而非依赖平台的接口监控/
// WiFi/连接归属等能力。唯一必须给出真实对象的是 CreateDefaultInterfaceMonitor:
// route.NetworkManager 在 platformInterface 非 nil 时会无条件调用它并立刻
// RegisterCallback(见 sing-box route/network.go),返回 nil 会直接 panic,所以这里
// 返回一个不会 panic、Start() 返回 nil 的 stub 监控器。

// TunOpener 是"打开 TUN 设备"这一步的可替换缝隙。
//
// 默认实现(defaultTunOpener)走真实路径:把 Swift 侧通过 Libbox.SetTunFD 传入的
// NE packetFlow 文件描述符 dup 一份,写进 options.FileDescriptor,再交给 tun.New。
// 之所以要 dup:tun.New/tun 对象拿到 fd 后会在 Close 时关掉它,而原始 fd 的所有权
// 属于 NEPacketTunnelProvider(packetFlow),不能被 sing-box 关掉;dup 出独立 fd 让
// 两边生命周期解耦。
//
// 离线 Go 测试(无 NE、无真实 fd)可以通过 Libbox.SetTunOpener 注入一个 fake:
// 比如返回一个基于 os.Pipe / socketpair 的假 tun.Tun,从而在桌面上跑通
// "sing-box 构建 + 启动 + 经 TUN inbound 收发包"的集成测试。这个 setter 参数是
// 函数类型,gomobile 绑定时会自动跳过它(不影响 tvOS 侧导出面),仅供包外测试代码用。
type TunOpener func(options *tun.Options, platformOptions option.TunPlatformOptions) (tun.Tun, error)

// xdPlatformInterface 是喂给 sing-box 的 adapter.PlatformInterface 精简实现。
// 有意保持 unexported:它的方法签名带 *tun.Options 等复杂类型,gomobile 无法绑定;
// 未导出后 gomobile 直接忽略整个类型,不会因此报错。
type xdPlatformInterface struct {
	// tunFD 是 Swift 侧传入的 NE packetFlow 文件描述符(见 Libbox.SetTunFD)。
	tunFD int
	// opener 是可替换的 TUN 打开器;nil 时用 defaultTunOpener(真实 dup+tun.New)。
	opener TunOpener
}

var _ adapter.PlatformInterface = (*xdPlatformInterface)(nil)

// UsePlatformInterface 返回 true,让 sing-box 走 OpenInterface 回调而不是自己开 utun。
func (p *xdPlatformInterface) UsePlatformInterface() bool { return true }

// OpenInterface 是本文件的核心:把 NE 的 fd 交给 sing-box 的 TUN inbound。
func (p *xdPlatformInterface) OpenInterface(options *tun.Options, platformOptions option.TunPlatformOptions) (tun.Tun, error) {
	opener := p.opener
	if opener == nil {
		opener = p.defaultTunOpener
	}
	return opener(options, platformOptions)
}

// defaultTunOpener 是真实路径:dup 传入的 NE fd 后交给 tun.New。
// 参照 sing-box 官方 experimental/libbox/service.go 的 OpenInterface(dup(fd) + tun.New)。
func (p *xdPlatformInterface) defaultTunOpener(options *tun.Options, _ option.TunPlatformOptions) (tun.Tun, error) {
	if p.tunFD <= 0 {
		return nil, E.New("platform: tun fd not set (call Libbox.SetTunFD with the NE packetFlow fd before Start)")
	}
	dupFd, err := syscall.Dup(p.tunFD)
	if err != nil {
		return nil, E.Cause(err, "dup tun file descriptor")
	}
	options.FileDescriptor = dupFd
	return tun.New(*options)
}

// UnderNetworkExtension 返回 true:XDial tvOS 引擎始终跑在 NEPacketTunnelProvider 里。
// sing-box 据此把 MTU 默认收敛到 4064 等 NE 友好参数。
func (p *xdPlatformInterface) UnderNetworkExtension() bool { return true }

// 以下方法对 XDial 均无实际意义(出站走 vpnOutbound,不依赖平台的接口/WiFi/进程归属
// 能力),统一返回"平台不提供该能力"的零值,让 sing-box 回退到其内置的通用逻辑。

func (p *xdPlatformInterface) Initialize(networkManager adapter.NetworkManager) error { return nil }

func (p *xdPlatformInterface) UsePlatformAutoDetectInterfaceControl() bool { return false }

func (p *xdPlatformInterface) AutoDetectInterfaceControl(fd int) error { return nil }

func (p *xdPlatformInterface) UsePlatformDefaultInterfaceMonitor() bool { return true }

// CreateDefaultInterfaceMonitor 必须返回非 nil:见文件头注释,NetworkManager 会
// 无条件在返回值上调 RegisterCallback。返回一个纯 stub。
func (p *xdPlatformInterface) CreateDefaultInterfaceMonitor(logger logger.Logger) tun.DefaultInterfaceMonitor {
	return &stubInterfaceMonitor{}
}

func (p *xdPlatformInterface) UsePlatformNetworkInterfaces() bool { return false }

func (p *xdPlatformInterface) NetworkInterfaces() ([]adapter.NetworkInterface, error) {
	return nil, nil
}

func (p *xdPlatformInterface) NetworkExtensionIncludeAllNetworks() bool { return false }

func (p *xdPlatformInterface) ClearDNSCache() {}

func (p *xdPlatformInterface) RequestPermissionForWIFIState() error { return nil }

func (p *xdPlatformInterface) ReadWIFIState() adapter.WIFIState { return adapter.WIFIState{} }

func (p *xdPlatformInterface) SystemCertificates() []string { return nil }

func (p *xdPlatformInterface) UsePlatformConnectionOwnerFinder() bool { return false }

func (p *xdPlatformInterface) FindConnectionOwner(request *adapter.FindConnectionOwnerRequest) (*adapter.ConnectionOwner, error) {
	return nil, nil
}

func (p *xdPlatformInterface) UsePlatformWIFIMonitor() bool { return false }

func (p *xdPlatformInterface) UsePlatformNotification() bool { return false }

func (p *xdPlatformInterface) SendNotification(notification *adapter.Notification) error { return nil }

func (p *xdPlatformInterface) MyInterfaceAddress() []netip.Addr { return nil }

// stubInterfaceMonitor 满足 tun.DefaultInterfaceMonitor,但不做任何真实监控:
// NE 场景下默认接口固定为隧道自身,不需要监听系统网络变化。所有回调注册都进一个
// 本地 list(保证 RegisterCallback/UnregisterCallback 不 panic),Start/Close 返回 nil
// (返回 error 会让 NetworkManager 启动失败)。
type stubInterfaceMonitor struct {
	callbacks list.List[tun.DefaultInterfaceUpdateCallback]
}

var _ tun.DefaultInterfaceMonitor = (*stubInterfaceMonitor)(nil)

func (m *stubInterfaceMonitor) Start() error { return nil }

func (m *stubInterfaceMonitor) Close() error { return nil }

func (m *stubInterfaceMonitor) DefaultInterface() *control.Interface { return nil }

func (m *stubInterfaceMonitor) OverrideAndroidVPN() bool { return false }

func (m *stubInterfaceMonitor) AndroidVPNEnabled() bool { return false }

func (m *stubInterfaceMonitor) RegisterCallback(callback tun.DefaultInterfaceUpdateCallback) *list.Element[tun.DefaultInterfaceUpdateCallback] {
	return m.callbacks.PushBack(callback)
}

func (m *stubInterfaceMonitor) UnregisterCallback(element *list.Element[tun.DefaultInterfaceUpdateCallback]) {
	m.callbacks.Remove(element)
}

func (m *stubInterfaceMonitor) RegisterMyInterface(interfaceName string) {}

func (m *stubInterfaceMonitor) MyInterface() string { return "" }
