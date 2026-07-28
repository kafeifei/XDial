//go:build !windows

package libbox

import (
	"net/netip"
	"sync"
	"sync/atomic"
	"syscall"

	"github.com/sagernet/sing-box/adapter"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
	tun "github.com/sagernet/sing-tun"
	"github.com/sagernet/sing/common/control"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"
	"github.com/sagernet/sing/common/x/list"
)

// platform.go 把 XDial 的进程内 sing-box 接到 Apple NetworkExtension 的 packetFlow。
//
// sing-box 通过 ctx 里的 adapter.PlatformInterface 决定 TUN inbound 怎么拿到底层
// 设备:当 UsePlatformInterface() 返回 true 时,它不会自己去 tun.New 打开一个新
// utun,而是回调 OpenInterface,让平台把 NE 已经建立好的 packetFlow 对应的文件
// 描述符交给 sing-box。iOS/tvOS/macOS 扩展进程都复用 NE 给的 fd。
//
// 除 OpenInterface 外，默认接口和全部候选接口也必须来自 NWPath。这里不能把
// utun/ipsec/ppp 一概当成“隧道”删掉：它们可能是 XDial 启动前已经存在的 Underlay。
// 唯一应排除的是当前会话自己创建、由 RegisterMyInterface 明确登记的接口。

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

	mu                sync.Mutex
	networkManager    adapter.NetworkManager
	defaultInterface  *control.Interface
	networkInterfaces []adapter.NetworkInterface
	ownInterfaceName  string
	monitor           *platformInterfaceMonitor
	tunInPackets      atomic.Uint64
	tunInBytes        atomic.Uint64
	tunOutPackets     atomic.Uint64
	tunOutBytes       atomic.Uint64
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
	// sing-tun 会按值复制 options。真实接口名必须在 tun.New 之前写入，否则其内部
	// 会一直保留占位名 "utun"，Start 时再把接口监控器覆盖成错误名称。
	name, err := tunnelNameFromFileDescriptor(p.tunFD)
	if err != nil {
		return nil, E.Cause(err, "query tun name")
	}
	if name != "" {
		options.Name = name
		if options.InterfaceMonitor != nil {
			options.InterfaceMonitor.RegisterMyInterface(name)
		}
	}
	dupFd, err := syscall.Dup(p.tunFD)
	if err != nil {
		return nil, E.Cause(err, "dup tun file descriptor")
	}
	options.FileDescriptor = dupFd
	device, err := tun.New(*options)
	if err != nil {
		_ = syscall.Close(dupFd)
		return nil, err
	}
	// 非 Darwin 平台没有通用的 fd→名称查询；保留原来的创建后读取作为回退。
	if name == "" {
		name, err = device.Name()
		if err != nil {
			_ = device.Close()
			return nil, E.Cause(err, "read tun interface name")
		}
		options.Name = name
		if options.InterfaceMonitor != nil {
			options.InterfaceMonitor.RegisterMyInterface(name)
		}
	}
	return wrapTunWithDiagnostics(device, p), nil
}

// UnderNetworkExtension 返回 true:XDial Apple 数据面始终跑在 NEPacketTunnelProvider 里。
// sing-box 据此把 MTU 默认收敛到 4064 等 NE 友好参数。
func (p *xdPlatformInterface) UnderNetworkExtension() bool { return true }

// 默认接口/接口列表用于 direct 与 DNS 出站；其余 Wi-Fi 详情、进程归属、通知等
// 非数据面能力暂不提供，让 sing-box 回退到通用逻辑。

func (p *xdPlatformInterface) Initialize(networkManager adapter.NetworkManager) error {
	p.mu.Lock()
	p.networkManager = networkManager
	p.mu.Unlock()
	return nil
}

func (p *xdPlatformInterface) UsePlatformAutoDetectInterfaceControl() bool { return false }

func (p *xdPlatformInterface) AutoDetectInterfaceControl(fd int) error { return nil }

func (p *xdPlatformInterface) UsePlatformDefaultInterfaceMonitor() bool { return true }

// CreateDefaultInterfaceMonitor 必须返回非 nil:NetworkManager 会在返回值上注册
// 回调。monitor 的初始值及后续更新来自 Swift NWPathMonitor。
func (p *xdPlatformInterface) CreateDefaultInterfaceMonitor(logger logger.Logger) tun.DefaultInterfaceMonitor {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.monitor == nil {
		p.monitor = &platformInterfaceMonitor{platform: p, logger: logger}
	}
	return p.monitor
}

func (p *xdPlatformInterface) UsePlatformNetworkInterfaces() bool { return true }

func (p *xdPlatformInterface) NetworkInterfaces() ([]adapter.NetworkInterface, error) {
	p.mu.Lock()
	defaultInterface := cloneInterface(p.defaultInterface)
	ownInterfaceName := p.ownInterfaceName
	networkInterfaces := append([]adapter.NetworkInterface(nil), p.networkInterfaces...)
	p.mu.Unlock()

	if len(networkInterfaces) > 0 {
		filtered := networkInterfaces[:0]
		for _, networkInterface := range networkInterfaces {
			if networkInterface.Name == ownInterfaceName {
				continue
			}
			filtered = append(filtered, networkInterface)
		}
		return filtered, nil
	}
	if defaultInterface == nil || defaultInterface.Name == ownInterfaceName {
		return nil, nil
	}
	return []adapter.NetworkInterface{{Interface: *defaultInterface}}, nil
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

// platformInterfaceMonitor 把 Swift NWPathMonitor 报告的默认 Underlay 接口桥接给
// sing-box。它必须在 Start 时先刷新全部接口列表，再发布初始接口，否则
// auto_detect_interface 会看到 "no available network interface"。
type platformInterfaceMonitor struct {
	platform    *xdPlatformInterface
	logger      logger.Logger
	mu          sync.Mutex
	callbacks   list.List[tun.DefaultInterfaceUpdateCallback]
	myInterface string
}

var _ tun.DefaultInterfaceMonitor = (*platformInterfaceMonitor)(nil)

func (m *platformInterfaceMonitor) Start() error {
	m.platform.mu.Lock()
	networkManager := m.platform.networkManager
	defaultInterface := cloneInterface(m.platform.defaultInterface)
	m.platform.mu.Unlock()
	if networkManager != nil {
		if err := networkManager.UpdateInterfaces(); err != nil {
			return E.Cause(err, "update platform interfaces")
		}
	}
	if defaultInterface == nil {
		return E.New("platform: default interface not set")
	}
	m.notify(defaultInterface)
	return nil
}

func (m *platformInterfaceMonitor) Close() error { return nil }

func (m *platformInterfaceMonitor) DefaultInterface() *control.Interface {
	m.platform.mu.Lock()
	defer m.platform.mu.Unlock()
	return cloneInterface(m.platform.defaultInterface)
}

func (m *platformInterfaceMonitor) OverrideAndroidVPN() bool { return false }

func (m *platformInterfaceMonitor) AndroidVPNEnabled() bool { return false }

func (m *platformInterfaceMonitor) RegisterCallback(callback tun.DefaultInterfaceUpdateCallback) *list.Element[tun.DefaultInterfaceUpdateCallback] {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.callbacks.PushBack(callback)
}

func (m *platformInterfaceMonitor) UnregisterCallback(element *list.Element[tun.DefaultInterfaceUpdateCallback]) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.callbacks.Remove(element)
}

func (m *platformInterfaceMonitor) RegisterMyInterface(interfaceName string) {
	m.mu.Lock()
	m.myInterface = interfaceName
	m.mu.Unlock()
	m.platform.setOwnInterface(interfaceName)
}

func (m *platformInterfaceMonitor) MyInterface() string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.myInterface
}

func (m *platformInterfaceMonitor) notify(defaultInterface *control.Interface) {
	m.mu.Lock()
	callbacks := m.callbacks.Array()
	m.mu.Unlock()
	for _, callback := range callbacks {
		callback(defaultInterface, 0)
	}
}

func (p *xdPlatformInterface) setDefaultInterface(name string, index int) {
	p.mu.Lock()
	var updated *control.Interface
	if name != "" && index > 0 {
		if name == p.ownInterfaceName {
			updated = p.firstUsableInterfaceLocked()
		} else {
			updated = &control.Interface{Name: name, Index: index}
		}
	}
	old := p.defaultInterface
	if old != nil && updated != nil && old.Name == updated.Name && old.Index == updated.Index {
		p.mu.Unlock()
		return
	}
	p.defaultInterface = updated
	networkManager := p.networkManager
	monitor := p.monitor
	p.mu.Unlock()

	if networkManager != nil {
		if err := networkManager.UpdateInterfaces(); err != nil && monitor != nil && monitor.logger != nil {
			monitor.logger.Error(E.Cause(err, "update platform interfaces"))
		}
	}
	if monitor != nil {
		monitor.notify(cloneInterface(updated))
	}
}

type platformNetworkInterfaceSnapshot struct {
	Name  string `json:"name"`
	Index int    `json:"index"`
	Type  string `json:"type"`
}

func (p *xdPlatformInterface) setNetworkInterfaces(snapshots []platformNetworkInterfaceSnapshot) error {
	seen := make(map[string]struct{}, len(snapshots))
	interfaces := make([]adapter.NetworkInterface, 0, len(snapshots))
	for _, snapshot := range snapshots {
		if snapshot.Name == "" || snapshot.Index <= 0 {
			return E.New("platform: invalid network interface snapshot")
		}
		if _, exists := seen[snapshot.Name]; exists {
			return E.New("platform: duplicate network interface: ", snapshot.Name)
		}
		seen[snapshot.Name] = struct{}{}
		interfaceType, loaded := C.StringToInterfaceType[snapshot.Type]
		if !loaded {
			return E.New("platform: unsupported network interface type: ", snapshot.Type)
		}
		interfaces = append(interfaces, adapter.NetworkInterface{
			Interface: control.Interface{
				Name:  snapshot.Name,
				Index: snapshot.Index,
			},
			Type: interfaceType,
		})
	}

	p.mu.Lock()
	p.networkInterfaces = interfaces
	networkManager := p.networkManager
	monitor := p.monitor
	p.mu.Unlock()
	if networkManager != nil {
		if err := networkManager.UpdateInterfaces(); err != nil {
			return E.Cause(err, "update platform interfaces")
		}
	}
	if monitor != nil && monitor.logger != nil {
		monitor.logger.Debug("updated platform network interfaces: ", len(interfaces))
	}
	return nil
}

func (p *xdPlatformInterface) setOwnInterface(name string) {
	p.mu.Lock()
	if p.ownInterfaceName == name {
		p.mu.Unlock()
		return
	}
	p.ownInterfaceName = name
	if p.defaultInterface != nil && p.defaultInterface.Name == name {
		p.defaultInterface = p.firstUsableInterfaceLocked()
	}
	networkManager := p.networkManager
	monitor := p.monitor
	defaultInterface := cloneInterface(p.defaultInterface)
	p.mu.Unlock()

	if networkManager != nil {
		if err := networkManager.UpdateInterfaces(); err != nil && monitor != nil && monitor.logger != nil {
			monitor.logger.Error(E.Cause(err, "remove own interface from platform interfaces"))
		}
	}
	if monitor != nil {
		monitor.notify(defaultInterface)
	}
}

// firstUsableInterfaceLocked 返回 NWPath 顺序中的第一个下层接口。
// 调用方必须持有 p.mu。只跳过当前 XDial 会话自己的接口，不按名字猜测产品或协议。
func (p *xdPlatformInterface) firstUsableInterfaceLocked() *control.Interface {
	for _, networkInterface := range p.networkInterfaces {
		if networkInterface.Name == p.ownInterfaceName {
			continue
		}
		return cloneInterface(&networkInterface.Interface)
	}
	return nil
}

func cloneInterface(value *control.Interface) *control.Interface {
	if value == nil {
		return nil
	}
	copy := *value
	return &copy
}

type platformDiagnostics struct {
	TunFD                 int
	TunName               string
	DefaultInterfaceName  string
	DefaultInterfaceIndex int
	TunInPackets          uint64
	TunInBytes            uint64
	TunOutPackets         uint64
	TunOutBytes           uint64
}

func (p *xdPlatformInterface) diagnostics() platformDiagnostics {
	p.mu.Lock()
	defaultInterface := cloneInterface(p.defaultInterface)
	monitor := p.monitor
	p.mu.Unlock()

	result := platformDiagnostics{
		TunFD:         p.tunFD,
		TunInPackets:  p.tunInPackets.Load(),
		TunInBytes:    p.tunInBytes.Load(),
		TunOutPackets: p.tunOutPackets.Load(),
		TunOutBytes:   p.tunOutBytes.Load(),
	}
	if defaultInterface != nil {
		result.DefaultInterfaceName = defaultInterface.Name
		result.DefaultInterfaceIndex = defaultInterface.Index
	}
	if monitor != nil {
		result.TunName = monitor.MyInterface()
	}
	return result
}
