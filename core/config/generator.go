package config

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/netip"
	"path"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/google/uuid"
)

type SingBoxConfig struct {
	Log          map[string]interface{}   `json:"log"`
	DNS          map[string]interface{}   `json:"dns"`
	Endpoints    []map[string]interface{} `json:"endpoints,omitempty"`
	Inbounds     []map[string]interface{} `json:"inbounds"`
	Outbounds    []map[string]interface{} `json:"outbounds"`
	Route        map[string]interface{}   `json:"route"`
	Experimental map[string]interface{}   `json:"experimental,omitempty"`
}

// 桌面端“逐线路查公网地址”使用的域名；移动端不使用 Clash API/
// test-out，也不应该暗中改写这些域名的路由。
var testDomains = []string{"ip.sb", "ipinfo.io", "ip-api.com"}

const (
	testSelectorTag               = "test-out"
	clashAPIController            = "127.0.0.1:9090"
	connectivityDirectRuleSetID   = "xdial-connectivity-direct"
	connectivityOutboundRuleSetID = "xdial-connectivity-anyconnect"
	mobilePublicDNSTag            = "xdial-public-dns"
	mobileDispatcherDNSTag        = "xdial-mobile-dns"
	transparentSystemDNSTag       = "xdial-system-dns"
	transparentEnterpriseDNSTag   = "xdial-anyconnect-dns"
	tailnetSingleLabelDomainRegex = `^[^.]+$`
	minAnyTLSDurationSeconds      = 6
	maxAnyTLSDurationSeconds      = 3600
	maxAnyTLSMinIdleSession       = 64
	maxAnyTLSALPNProtocols        = 8
	maxAnyTLSALPNProtocolBytes    = 255
)

var anyTLSClientFingerprints = map[string]struct{}{
	"chrome_psk":                 {},
	"chrome_psk_shuffle":         {},
	"chrome_padding_psk_shuffle": {},
	"chrome_pq":                  {},
	"chrome_pq_psk":              {},
	"chrome":                     {},
	"firefox":                    {},
	"edge":                       {},
	"safari":                     {},
	"360":                        {},
	"qq":                         {},
	"ios":                        {},
	"android":                    {},
	"random":                     {},
	"randomized":                 {},
}

// Platform 决定 sing-box 配置生成的目标运行环境。
//
// PlatformMacOS(零值)= 桌面场景:sing-box 作为外部子进程运行,靠 tun +
// auto_route 抓包、route.default_interface 绑定到宿主在启动前从系统默认路由
// 读取的 Underlay，
// clash_api 暴露 controller、cache_file 用相对路径(子进程 cwd 下)。
//
// PlatformNE = tvOS/iOS 的 Packet Tunnel 场景:sing-box 作为库跑在扩展进程内,
// 无 root、无子进程、路由由 NEPacketTunnelNetworkSettings 在 Swift 侧接管,读包来源
// 是系统 packetFlow。因此 tun inbound 只保留最小字段(type/address/mtu),不生成
// auto_route/strict_route/stack/route_exclude_address,也不开
// clash_api;cache_file 必须用调用方传入的沙盒内绝对路径(basePath)。
//
// PlatformTransparentProxy = macOS Transparent Proxy 系统扩展：sing-box 同样作为库
// 跑在扩展进程内，但入口是只监听 loopback、带随机会话凭据的 SOCKS5 inbound。
// Swift 只把 NEAppProxyFlow 的字节搬到该入口；TCP/UDP/DNS 仍由同一份 sing-box
// 配置裁决。该平台把宿主在启动前从系统默认路由读取的接口写入
// route.default_interface；这让 Provider 进程里的出站 socket 延续既有 Underlay，
// 而不是依赖 Network Extension 进程可能退化到物理接口的默认视角。
type Platform int

const (
	PlatformMacOS Platform = iota
	PlatformNE
	PlatformTransparentProxy
)

func (p Platform) isNetworkExtension() bool {
	return p == PlatformNE || p == PlatformTransparentProxy
}

func (p Platform) isDesktop() bool {
	return p == PlatformMacOS
}

func (p Platform) isTransparentProxy() bool {
	return p == PlatformTransparentProxy
}

// GenerateSingBox 保留原有签名供配置单测与兼容调用。真实桌面连接必须走
// GenerateSingBoxDesktop，并传入启动前的系统默认接口快照。
func GenerateSingBox(profile *Profile, socksPort int, vpnServerIP string) ([]byte, error) {
	return GenerateSingBoxDesktop(profile, socksPort, vpnServerIP, "", nil, "en0")
}

// GenerateSingBoxDesktop 是桌面连接路径的入口：AnyConnect 隧道先建立、拿到
// 服务端下发的企业 DNS 后才生成配置，绑定到 VPN 线路的内网域名（如 oa.corp.example）
// 只在企业 DNS 有记录，必须经隧道向它查询，公共 DoH 上是 NXDOMAIN。
// underlayInterface 不是用户配置，也不是产品识别结果；它只能来自数据面启动前
// 操作系统默认路由的接口。空值必须报错，不能回落到 sing-tun 在 macOS 上会跳过
// 无网关 utun 的 auto_detect_interface。
func GenerateSingBoxDesktop(profile *Profile, socksPort int, vpnServerIP, basePath string, enterpriseDNS []string, underlayInterface string) ([]byte, error) {
	return generateSingBox(profile, socksPort, vpnServerIP, PlatformMacOS, basePath, enterpriseDNS, nil, underlayInterface, nil)
}

// GenerateSingBoxFor 生成 sing-box JSON 配置,platform 决定平台相关字段的取舍。
//
// basePath 是运行状态目录。NetworkExtension 用它生成 cache_file 的绝对路径；
// 两个平台的内置 Tailscale endpoint 都用它保存同一份持久身份。PlatformMacOS
// 的 cache_file 仍沿用相对路径 "cache.db"。
func GenerateSingBoxFor(profile *Profile, socksPort int, vpnServerIP string, platform Platform, basePath string, underlayInterfaces ...string) ([]byte, error) {
	if len(underlayInterfaces) > 1 {
		return nil, fmt.Errorf("expected at most one underlay interface snapshot")
	}
	var underlayInterface string
	if len(underlayInterfaces) == 1 {
		underlayInterface = underlayInterfaces[0]
	}
	return generateSingBox(profile, socksPort, vpnServerIP, platform, basePath, nil, nil, underlayInterface, nil)
}

type transparentProxyIngress struct {
	port     int
	username string
	password string
}

// GenerateSingBoxTransparentProxy 生成 macOS Transparent Proxy 扩展内的配置。
// 会话凭据只保护本机 loopback SOCKS 入口，不属于用户配置，不得持久化。
func GenerateSingBoxTransparentProxy(
	profile *Profile,
	listenPort int,
	username string,
	password string,
	basePath string,
	underlayInterface string,
	systemDNS []string,
) ([]byte, error) {
	if listenPort < 1 || listenPort > 65535 {
		return nil, fmt.Errorf("transparent proxy listen port is invalid")
	}
	username = strings.TrimSpace(username)
	password = strings.TrimSpace(password)
	if username == "" || password == "" || len(username) > 255 || len(password) > 255 {
		return nil, fmt.Errorf("transparent proxy session credentials are invalid")
	}
	return generateSingBox(
		profile,
		0,
		"",
		PlatformTransparentProxy,
		basePath,
		nil,
		systemDNS,
		underlayInterface,
		&transparentProxyIngress{
			port:     listenPort,
			username: username,
			password: password,
		},
	)
}

func generateSingBox(
	profile *Profile,
	socksPort int,
	vpnServerIP string,
	platform Platform,
	basePath string,
	enterpriseDNS []string,
	systemDNS []string,
	underlayInterface string,
	transparentIngress *transparentProxyIngress,
) ([]byte, error) {
	mode := profile.ActiveMode()
	if mode == nil {
		return nil, fmt.Errorf("no active mode")
	}
	// INV6a：悬空引用（模式指向不存在的规则/线路/订阅）在这里就拒绝，
	// 绝不让它变成"整条规则蒸发、流量静默落到 final"。存在但被禁用的对象
	// （INV6b）只产生 warning，由 CollectProfileWarnings 供 daemon/UI 读取。
	if _, err := inspectModeReferences(profile, mode); err != nil {
		return nil, err
	}
	activeApplicationIdentities := activeApplicationRuleSetIdentities(profile, mode)
	if len(activeApplicationIdentities) > 0 && !platform.isTransparentProxy() {
		// 只有 macOS Transparent Proxy 能取得系统交付的 source app 归因。
		// 其他入口若跳过规则会让受约束应用静默落到 Mode 默认出口，必须拒绝。
		return nil, fmt.Errorf("active application rule sets require the macOS transparent proxy ingress")
	}
	if platform.isTransparentProxy() && transparentIngress == nil {
		return nil, fmt.Errorf("transparent proxy ingress is unavailable")
	}
	if len(activeApplicationIdentities) > 0 &&
		len(transparentIngress.username)+1+sha256.Size*2 > 255 {
		return nil, fmt.Errorf("transparent proxy session username is too long for application rules")
	}
	activeLineIDs, activeSubscriptionIDs := effectiveActiveTargetIDs(profile, mode)
	activeVPNIDs := effectiveActiveVPNLineIDs(profile, mode)
	activeTailscaleIDs := effectiveActiveTailscaleLineIDs(profile, mode)
	activeMagicDNSTags := effectiveActiveMagicDNSEndpointTags(profile, mode)
	// D30：sslcon 是包级单例，一个进程只能维持一条 AnyConnect 隧道，而所有 VPN
	// 线路共享 "vpn" 这一个 outbound tag。两条不同的 active VPN 线路会让第二条的
	// 流量静默钻进第一条的隧道（违反 Line 隔离）。所有平台一律硬校验报错，
	// 不区分桌面/NE —— 桌面同样只有一份 VPNBridge。
	if len(activeVPNIDs) > 1 {
		return nil, fmt.Errorf("only one active AnyConnect line is supported: %d active lines would share one tunnel", len(activeVPNIDs))
	}
	// D33：所有 Tailscale Line 共享一份 node key/state，不能同时创建两个 endpoint
	// 实例。未被 active Mode 引用的 Line 不计入，也绝不能为了登录或探测进入数据面。
	if len(activeTailscaleIDs) > 1 {
		return nil, fmt.Errorf("only one active Tailscale line is supported: %d active lines would share one identity", len(activeTailscaleIDs))
	}

	outbounds := []map[string]interface{}{{"type": "direct", "tag": "direct"}}
	if len(activeVPNIDs) > 0 {
		vpnOutbound := map[string]interface{}{
			"type":        "socks",
			"tag":         "vpn",
			"server":      "127.0.0.1",
			"server_port": socksPort,
		}
		if platform.isNetworkExtension() {
			// NE 模式下 sing-box 是库,跑在同一进程里,"vpn" 出口是
			// core/libbox/vpn_outbound.go 注册的自研 outbound(直接拨
			// VPNBridge,不经本地 SOCKS5 中转);macOS 模式下 sing-box 是
			// 外部子进程,只能通过 127.0.0.1 socks 中转回 app 进程里的 VPNBridge。
			vpnOutbound = map[string]interface{}{
				"type": "vpn",
				"tag":  "vpn",
			}
		}
		outbounds = append(outbounds, vpnOutbound)
	}

	var endpoints []map[string]interface{}
	var activeTailscaleTags []string
	if len(activeTailscaleIDs) > 0 && (basePath == "" || !path.IsAbs(basePath)) {
		return nil, fmt.Errorf("Tailscale state directory is unavailable")
	}
	for index := range profile.Lines {
		line := &profile.Lines[index]
		if !activeTailscaleIDs[line.ID] {
			continue
		}
		// 旧移动端 Profile 仍可携带 Auth Key；桌面 D33 明确禁止把持久 Profile
		// 中的秘密带入日常运行配置。桌面首次注册只走 helper 的瞬时 setup 请求。
		authKey := ""
		if platform == PlatformNE {
			authKey = line.TailscaleAuthKey
		}
		endpoint, err := buildTailscaleEndpoint(line, profile.Tailscale, basePath, authKey)
		if err != nil {
			return nil, err
		}
		endpoints = append(endpoints, endpoint)
		activeTailscaleTags = append(activeTailscaleTags, tailscaleEndpointTag(line))
	}

	for _, line := range profile.Lines {
		if !activeLineIDs[line.ID] || !line.Enabled || line.Type == LineTypeDirect || line.Type == LineTypeVPN || line.Type == LineTypeTailscale {
			continue
		}
		ob := buildProxyOutbound(&line)
		if ob == nil {
			// inspectModeReferences 使用同一能力判据，正常情况下会更早返回错误。
			// 这里仍保留生成器自身的最后防线，避免未来两处判据漂移后又把 active
			// Line 静默丢掉，让绑定或默认出口落到 direct。
			return nil, fmt.Errorf(
				"active enabled line %q (type %q) cannot generate an outbound",
				line.ID,
				line.Type,
			)
		}
		outbounds = append(outbounds, ob)
	}

	// 订阅 outbound：节点 + 策略组（或默认 urltest/selector）
	subTagMap := make(map[string]string)
	subGroupTagMap := make(map[string]map[string]string) // subID -> groupName -> tag
	for _, sub := range profile.Subscriptions {
		if !activeSubscriptionIDs[sub.ID] || !sub.Enabled || len(sub.Lines) == 0 {
			continue
		}
		obs, mainTag, groupTags := buildSubscriptionOutbounds(&sub, platform)
		if mainTag != "" {
			outbounds = append(outbounds, obs...)
			subTagMap[sub.ID] = mainTag
			subGroupTagMap[sub.ID] = groupTags
		}
	}

	// 代理服务器域名属于 Line 的启动端点，不是用户流量的目标域名。Transparent
	// Proxy 的全局 resolver 必须继续保持启动前 Underlay 的系统 DNS 视角；但把代理
	// 端点也交给它，会让一个对公网域名返回 SERVFAIL 的下层 resolver 阻断整条 Line。
	// 这里只覆盖 active Mode 实际生成的域名型代理 outbound，并使用盒内、IP 直连的
	// public-dns 做唯一的启动解析主路径。它不参与 Mode DNS 分域，也绝不能 detour
	// 回正在启动的代理（否则形成 resolver → outbound → resolver 自循环）。
	needsProxyEndpointBootstrap := false
	if platform.isTransparentProxy() {
		needsProxyEndpointBootstrap = configureTransparentProxyEndpointBootstrap(outbounds)
	}

	if platform == PlatformMacOS {
		// 桌面端通过 Clash API 临时切换 selector 做逐线路地址探测。
		// NetworkExtension 不启 Clash API，不生成这个诊断专用出口。
		selectorMembers := []string{"direct"}
		for _, ob := range outbounds {
			tag, _ := ob["tag"].(string)
			if tag == "direct" {
				continue
			}
			selectorMembers = append(selectorMembers, tag)
		}
		selectorMembers = append(selectorMembers, activeTailscaleTags...)
		outbounds = append(outbounds, map[string]interface{}{
			"type":      "selector",
			"tag":       testSelectorTag,
			"outbounds": selectorMembers,
			"default":   "direct",
		})
	}

	// 收集所有已生成的 outbound tag，规则引用前要校验，避免引用不存在 tag 导致 sing-box 启动失败。
	// 顺带做唯一性断言：重复 tag 会让 sing-box 在解析阶段直接拒绝启动（而 helper 只确认
	// 进程 spawn 成功，用户看到"已连接但流量全断"的假连接），故在生成阶段就 fail-fast。
	validTags := map[string]bool{}
	for _, ob := range outbounds {
		if tag, _ := ob["tag"].(string); tag != "" {
			if validTags[tag] {
				return nil, fmt.Errorf("duplicate outbound tag: %q", tag)
			}
			validTags[tag] = true
		}
	}
	for _, endpoint := range endpoints {
		if tag, _ := endpoint["tag"].(string); tag != "" {
			if validTags[tag] {
				return nil, fmt.Errorf("duplicate outbound tag: %q", tag)
			}
			validTags[tag] = true
		}
	}

	// 两个平台的系统 DNS 包都走 hijack-dns：桌面交给 buildDNS 的解析链，
	// NE 交给 xdial-mobile dispatcher。
	routeRules := buildSystemRouteRules(platform == PlatformMacOS)
	if platform.isNetworkExtension() {
		routeRules = buildNESystemRouteRules()
	}
	ruleSetResources := sbCollectRuleSets(profile, mode, subTagMap, validTags)
	acceptanceModeRules, ordinaryModeRules := buildModeRouteRules(
		profile,
		mode,
		subTagMap,
		validTags,
	)
	if platform.isTransparentProxy() {
		// Transparent Proxy 必须逐条保留 Mode 顺序：域名条件先用目标 Line
		// 的解析视角，只有轮到 IP 条件时才用启动前系统 DNS。不能再在所有
		// Mode 规则之前做一次固定 resolver 的全局 resolve。
		acceptanceModeRules = nil
		ordinaryModeRules = buildTransparentProxyModeRouteRules(
			profile,
			mode,
			subTagMap,
			validTags,
			transparentIngress.username,
		)
	}

	// 两条锁定验收规则来自用户可见 profile，不是生成器暗中注入；但它们必须
	// 先于订阅规则匹配，否则订阅里的大网段（如 1.0.0.0/8）会吞掉 /32，
	// 让路由验收测到订阅语义而不是两条显式绑定。
	routeRules = append(routeRules, acceptanceModeRules...)
	// 模式的普通规则排在订阅自带规则之前。
	//
	// 架构约束：Mode 是唯一裁决者，订阅只是"自带规则的供给源"（D28）。订阅那几百条
	// 宽匹配（GEOIP,CN→DIRECT 之类）一旦排在前面，就会把用户在模式里显式绑定的
	// 规则整个遮蔽掉 —— 用户明明把 example.com 绑到了某条线路，流量却被订阅的
	// 兜底规则抢走，这正是"隐式抢注"。改为：用户显式绑定优先，订阅规则退为兜底。
	routeRules = append(routeRules, ordinaryModeRules...)

	// 用户在 active Tailscale Line 上勾选 MagicDNS 后，才加入
	// endpoint 根据当前 NetMap 动态申报的 peer 路由归属。这里只是
	// route 优先级：Mode 显式绑定仍在前，MagicDNS 路由在订阅供给
	// 规则之前。DNS 快照的最高优先级由 buildTransparentProxyDNS
	// 独立表达，不得从本段 route 顺序反推。
	routeRules = append(routeRules, buildMagicDNSRouteRules(
		activeMagicDNSTags,
		platform.isTransparentProxy(),
	)...)

	// 订阅自带规则：以一等公民身份进入裁决，但排在用户显式绑定之后。
	for _, sub := range profile.Subscriptions {
		if !activeSubscriptionIDs[sub.ID] || !sub.Enabled {
			continue
		}
		groupTags := subGroupTagMap[sub.ID]
		if groupTags == nil {
			continue
		}
		subRules, subSets := buildSubscriptionRules(&sub, groupTags)
		if platform.isTransparentProxy() {
			subRules, subSets = buildTransparentProxySubscriptionRules(&sub, groupTags)
		}
		routeRules = append(routeRules, subRules...)
		for _, s := range subSets {
			tag := s["tag"].(string)
			dup := false
			for _, existing := range ruleSetResources {
				if existing["tag"].(string) == tag {
					dup = true
					break
				}
			}
			if !dup {
				ruleSetResources = append(ruleSetResources, s)
			}
		}
	}

	// 默认出口。悬空引用和 enabled 但生成不出 outbound 的线路已在
	// inspectModeReferences 里报错拒绝；这里能走到 direct 的只剩用户显式禁用
	// 对象的 INV6b 语义，并且已经产生对应 ProfileWarning。
	defaultTag := "direct"
	if mode.DefaultSubscriptionID != "" {
		if tag, ok := subTagMap[mode.DefaultSubscriptionID]; ok && validTags[tag] {
			defaultTag = tag
		}
	} else if mode.DefaultLineID != "" {
		if l := profile.FindLine(mode.DefaultLineID); l != nil && l.Enabled {
			candidate := resolveOutboundTag(l)
			if validTags[candidate] {
				defaultTag = candidate
			}
		}
	}

	// 未被更具体规则接管的域名与未被更具体规则接管的流量，都归 Mode 的
	// 默认线路。IP 规则仍可在前面用启动时系统 DNS 做保守判断；如果没有命中，
	// 这里再从默认线路的解析视角求值，避免把 Underlay DNS 的地址带到另一个
	// 出口。direct 的默认 resolver 本来就是 Underlay 系统 DNS。
	if platform.isTransparentProxy() {
		routeRules = append(routeRules, map[string]interface{}{
			"action": "resolve",
			"server": transparentProxyResolverForOutbound(defaultTag),
		})
	}

	route := map[string]interface{}{
		"rules": routeRules,
		"final": defaultTag,
	}
	if platform == PlatformTransparentProxy {
		route["default_domain_resolver"] = transparentSystemDNSTag
	} else if platform.isNetworkExtension() {
		// 节点域名和 Tailscale 控制面必须能在首次登录前解析，不能递归进入
		// 尚未就绪的企业或 Tailscale 分域 resolver。
		route["default_domain_resolver"] = mobilePublicDNSTag
	} else {
		// 桌面出站域名统一交给盒内公共解析器，避免依赖 XDial 启动前的
		// 系统 resolver 状态。
		route["default_domain_resolver"] = desktopPublicDNSTag
	}
	// Underlay 选择仍属于操作系统与 sing-box 数据面。桌面宿主只把启动前系统
	// 默认路由已经选定的接口原样转交给 sing-box；它不识别 Wi-Fi、网线或任何
	// VPN 产品。不能在桌面回落 auto_detect_interface：sing-tun 0.8.9 的 darwin
	// 实现会跳过没有 RTF_GATEWAY 的 utun 默认路由，破坏自然叠加。
	if platform == PlatformMacOS || platform == PlatformTransparentProxy {
		underlayInterface = strings.TrimSpace(underlayInterface)
		if underlayInterface == "" {
			return nil, fmt.Errorf("desktop underlay interface snapshot is unavailable")
		}
		route["default_interface"] = underlayInterface
	} else if platform == PlatformNE {
		// Apple 移动端由 NWPathMonitor 经 PlatformInterface 提供系统网络变化。
		route["auto_detect_interface"] = true
	}
	if len(ruleSetResources) > 0 {
		route["rule_set"] = ruleSetResources
	}
	dnsConfig := buildNEDNS(activeMagicDNSTags)
	if platform.isTransparentProxy() {
		var dnsErr error
		dnsConfig, dnsErr = buildTransparentProxyDNS(
			profile,
			mode,
			subTagMap,
			subGroupTagMap,
			validTags,
			activeMagicDNSTags,
			systemDNS,
			defaultTag,
			needsProxyEndpointBootstrap,
		)
		if dnsErr != nil {
			return nil, dnsErr
		}
	} else if !platform.isNetworkExtension() {
		dnsConfig = buildDNS(
			enterpriseDNS,
			collectVPNBoundDomains(profile, mode),
			collectProxyBoundDNSTargets(profile, mode, subTagMap, validTags),
			activeMagicDNSTags,
		)
	}

	inbound := buildTUNInbound(vpnServerIP, platform)
	if platform.isTransparentProxy() {
		var inboundErr error
		inbound, inboundErr = buildTransparentProxyInbound(*transparentIngress, activeApplicationIdentities)
		if inboundErr != nil {
			return nil, inboundErr
		}
	}

	cfg := SingBoxConfig{
		Log: map[string]interface{}{
			"level": "info",
		},
		DNS:          dnsConfig,
		Endpoints:    endpoints,
		Inbounds:     []map[string]interface{}{inbound},
		Outbounds:    outbounds,
		Route:        route,
		Experimental: buildExperimental(platform, basePath),
	}

	return json.MarshalIndent(cfg, "", "  ")
}

func buildTransparentProxyInbound(
	ingress transparentProxyIngress,
	applicationIdentities []string,
) (map[string]interface{}, error) {
	users := []map[string]interface{}{{
		"username": ingress.username,
		"password": ingress.password,
	}}
	seen := map[string]bool{ingress.username: true}
	for _, identity := range applicationIdentities {
		username := ApplicationSOCKSUsername(ingress.username, identity)
		if len(username) > 255 {
			return nil, fmt.Errorf("transparent proxy session username is too long for application rules")
		}
		if seen[username] {
			continue
		}
		seen[username] = true
		users = append(users, map[string]interface{}{
			"username": username,
			"password": ingress.password,
		})
	}
	return map[string]interface{}{
		"type":                "socks",
		"tag":                 "transparent-proxy-in",
		"listen":              "127.0.0.1",
		"listen_port":         ingress.port,
		"xdial_flow_metadata": true,
		"users":               users,
	}, nil
}

// ApplicationSOCKSUsername derives a per-flow SOCKS username from the session
// credential and the OS-supplied signing identity. The raw identity never
// enters the data-plane config, while SOCKS authentication and route matching
// can join on this deterministic value.
func ApplicationSOCKSUsername(baseUsername, identity string) string {
	sum := sha256.Sum256([]byte(identity))
	return baseUsername + "." + hex.EncodeToString(sum[:])
}

// effectiveActiveTargetIDs 只返回活动模式真正引用的线路和订阅。未使用但 enabled 的
// 半成品节点不应进入 sing-box：否则它们即使永远不会承载流量，也可能在 box.New 时
// 让整个活动模式启动失败。
func effectiveActiveTargetIDs(profile *Profile, mode *Mode) (map[string]bool, map[string]bool) {
	lineIDs := make(map[string]bool)
	subscriptionIDs := make(map[string]bool)
	addTarget := func(lineID, subscriptionID string) {
		if lineID != "" {
			lineIDs[lineID] = true
		}
		if subscriptionID != "" {
			subscriptionIDs[subscriptionID] = true
		}
	}

	addTarget(mode.DefaultLineID, mode.DefaultSubscriptionID)
	for _, binding := range mode.Bindings {
		ruleSet := profile.FindRuleSet(binding.RuleSetID)
		if ruleSet == nil || !ruleSet.Enabled {
			continue
		}
		addTarget(binding.LineID, binding.SubscriptionID)
	}
	return lineIDs, subscriptionIDs
}

// activeApplicationRuleSetIdentities returns only identities that are both
// enabled and bound by the active Mode. Unbound rules must create neither
// route entries nor additional accepted SOCKS credentials.
func activeApplicationRuleSetIdentities(profile *Profile, mode *Mode) []string {
	seen := make(map[string]struct{})
	var identities []string
	for _, binding := range mode.Bindings {
		ruleSet := profile.FindRuleSet(binding.RuleSetID)
		if ruleSet == nil || !ruleSet.Enabled || ruleSet.Type != RuleSetTypeApplication {
			continue
		}
		for _, identity := range applicationRuleSetIdentities(ruleSet) {
			if _, exists := seen[identity]; exists {
				continue
			}
			seen[identity] = struct{}{}
			identities = append(identities, identity)
		}
	}
	return identities
}

// ActiveApplicationSOCKSCredentials exposes the active Mode's identity →
// derived SOCKS username map to the macOS session envelope. It follows the
// exact same Mode boundary and derivation used by the generated inbound and
// route rules, so Swift never has to reproduce the hash algorithm.
func ActiveApplicationSOCKSCredentials(profile *Profile, baseUsername string) (map[string]string, error) {
	if profile == nil {
		return nil, fmt.Errorf("profile is nil")
	}
	mode := profile.ActiveMode()
	if mode == nil {
		return nil, fmt.Errorf("no active mode")
	}
	if _, err := inspectModeReferences(profile, mode); err != nil {
		return nil, err
	}
	baseUsername = strings.TrimSpace(baseUsername)
	if baseUsername == "" {
		return nil, fmt.Errorf("transparent proxy session username is invalid for application rules")
	}
	identities := activeApplicationRuleSetIdentities(profile, mode)
	if len(identities) > 0 && len(baseUsername)+1+sha256.Size*2 > 255 {
		return nil, fmt.Errorf("transparent proxy session username is too long for application rules")
	}
	credentials := make(map[string]string)
	for _, identity := range identities {
		credentials[identity] = ApplicationSOCKSUsername(baseUsername, identity)
	}
	return credentials, nil
}

func effectiveActiveVPNLineIDs(profile *Profile, mode *Mode) map[string]bool {
	activeLineIDs, _ := effectiveActiveTargetIDs(profile, mode)
	ids := make(map[string]bool)
	for lineID := range activeLineIDs {
		line := profile.FindLine(lineID)
		if line != nil && line.Enabled && line.Type == LineTypeVPN {
			ids[line.ID] = true
		}
	}
	return ids
}

func effectiveActiveTailscaleLineIDs(profile *Profile, mode *Mode) map[string]bool {
	activeLineIDs, _ := effectiveActiveTargetIDs(profile, mode)
	ids := make(map[string]bool)
	for lineID := range activeLineIDs {
		line := profile.FindLine(lineID)
		if line != nil && line.Enabled && line.Type == LineTypeTailscale {
			ids[line.ID] = true
		}
	}
	return ids
}

// effectiveActiveMagicDNSEndpointTags 只返回 active Mode 实际引用，
// 且用户在 Line 上显式勾选 MagicDNS 的 Tailscale endpoint。单纯声明、
// 启用或勾选一条未被 active Mode 引用的 Line 仍然是零副作用。
func effectiveActiveMagicDNSEndpointTags(profile *Profile, mode *Mode) []string {
	var tags []string
	activeLineIDs := effectiveActiveTailscaleLineIDs(profile, mode)
	for index := range profile.Lines {
		line := &profile.Lines[index]
		if !activeLineIDs[line.ID] || !line.TailscaleMagicDNS {
			continue
		}
		tags = append(tags, tailscaleEndpointTag(line))
	}
	return tags
}

// ActiveTailscaleLine returns the one enabled Tailscale Line referenced by the active
// Mode. The desktop helper uses this same decision boundary for login/exit-node
// preflight before it starts the external sing-box data plane.
func ActiveTailscaleLine(profile *Profile) (*Line, error) {
	if profile == nil {
		return nil, fmt.Errorf("profile is nil")
	}
	mode := profile.ActiveMode()
	if mode == nil {
		return nil, fmt.Errorf("no active mode")
	}
	if _, err := inspectModeReferences(profile, mode); err != nil {
		return nil, err
	}
	ids := effectiveActiveTailscaleLineIDs(profile, mode)
	if len(ids) > 1 {
		return nil, fmt.Errorf("only one active Tailscale line is supported: %d active lines would share one identity", len(ids))
	}
	for index := range profile.Lines {
		if ids[profile.Lines[index].ID] {
			return &profile.Lines[index], nil
		}
	}
	return nil, nil
}

// buildExperimental 组装 experimental 块。
//
// macOS 模式:clash_api(TCP controller)+ cache_file(相对路径,子进程 cwd 下)。
// NE 模式:扩展进程内存预算极紧(~15MB),不开 clash_api;cache_file 用沙盒内绝对
// 路径,库内运行没有子进程 cwd,相对路径会落到只读的 app bundle 目录。
func buildExperimental(platform Platform, basePath string) map[string]interface{} {
	cachePath := "cache.db"
	if platform.isNetworkExtension() {
		cachePath = path.Join(basePath, "cache.db")
	}
	exp := map[string]interface{}{
		"cache_file": map[string]interface{}{
			"enabled": true,
			"path":    cachePath,
		},
	}
	if platform == PlatformMacOS {
		exp["clash_api"] = map[string]interface{}{
			"external_controller": clashAPIController,
		}
	}
	return exp
}

func buildTUNInbound(vpnServerIP string, platform Platform) map[string]interface{} {
	// IPv4 与 IPv6 地址都必须给：
	// NE 端决定哪些族的包进 packetFlow；桌面端 sing-tun 的 auto_route 把整段
	// IPv6 路由构造包在 len(Inet6Address) > 0 里，没有 v6 地址就一条 v6 路由都
	// 不装，IPv6 流量会整体绕过 XDial，Mode 里的 IPv6 规则永不求值，DNS 经指定
	// 出口得到的 AAAA 也可能被系统 Happy Eyeballs 从盒外连接。AnyConnect bridge
	// 当前仅支持 IPv4，纯 IPv6 目标会在 vpn outbound 明确失败；关键是不能绕过
	// 数据面直出。
	addresses := []string{"198.18.0.1/15", "fd00::1/126"}
	inbound := map[string]interface{}{
		"type":    "tun",
		"tag":     "tun-in",
		"address": addresses,
		"mtu":     9000,
	}
	// NE 模式由 gVisor 在进程内终止来自 packetFlow 的连接。明确指定 stack，确保
	// 发布包若漏掉 with_gvisor 构建标签会在启动阶段直接失败，而不是静默退回到
	// 依赖系统接口名称的 system stack 后假连接。
	if platform.isNetworkExtension() {
		inbound["stack"] = "gvisor"
		return inbound
	}
	inbound["auto_route"] = true
	inbound["strict_route"] = false
	inbound["stack"] = "system"
	if vpnServerIP != "" {
		inbound["route_exclude_address"] = []string{vpnServerIP + "/32"}
	}
	return inbound
}

// desktopPublicDNSTag 是桌面端的默认解析器：IP 直连的 DoH（阿里 223.5.5.5）。
// 不能用 type:local（系统 DNS）当默认——启动前 Underlay 的 resolver 可能只在
// 下层虚拟接口中可达，XDial 接管路由后再把原始查询强制直出会形成解析黑洞。
// DoH 使用 IP 地址，不需要 bootstrap 解析；其 detour 仍由 sing-box 按当前
// Underlay 选择，不由 XDial 绑定接口。
const desktopPublicDNSTag = "public-dns"
const desktopEnterpriseDNSTag = "enterprise-dns"

// desktopProxyDNSTag 给"经某条代理线路解析"的 DoH server 命名，一条线路一个。
func desktopProxyDNSTag(lineTag string) string {
	return "proxy-dns-" + lineTag
}

// proxyDNSTarget 描述"这些域名的解析要经 lineTag 这条线路出去"。
// domains 与 ruleSetTag 二选一：手动规则集直接内联域名后缀，URL 规则集复用
// route.rule_set 里已有的同一份资源，不重复下载。
type proxyDNSTarget struct {
	lineTag    string
	domains    []string
	ruleSetTag string
	invert     bool
}

// collectProxyBoundDNSTargets 收集活动模式里"解析必须经该线路出去"的规则集。
// 在本地用境内公共 DNS 解析拿到的是污染结果，再从隧道那头连过去，分流等于白做。
//
// direct 不在此列：它本就要本地视角。vpn 按规则集语义二分——手动规则集是内网名，
// 归 enterprise-dns（企业 DNS 才有记录，见 collectVPNBoundDomains）；URL 规则集
// （gfwlist 之类）是公网名，企业 DNS 对它没有特殊记录，走和代理线路同一套经隧道
// 的公共 DoH。少了这一支，"URL 规则集绑 VPN 线路"（预设模式"国内"就是）两边都
// 不管，域名落到 final 的境内解析器上被污染。
func collectProxyBoundDNSTargets(
	profile *Profile,
	mode *Mode,
	subTagMap map[string]string,
	validTags map[string]bool,
) []proxyDNSTarget {
	var targets []proxyDNSTarget
	for _, binding := range mode.Bindings {
		ruleSet := profile.FindRuleSet(binding.RuleSetID)
		if ruleSet == nil || !ruleSet.Enabled {
			continue
		}

		var lineTag string
		if binding.SubscriptionID != "" {
			lineTag = subTagMap[binding.SubscriptionID]
		} else {
			line := profile.FindLine(binding.LineID)
			if line == nil || !line.Enabled {
				continue
			}
			lineTag = resolveOutboundTag(line)
		}
		if lineTag == "" || lineTag == "direct" || !validTags[lineTag] {
			continue
		}
		if lineTag == "vpn" && ruleSet.Type != RuleSetTypeURL {
			continue
		}

		switch ruleSet.Type {
		case RuleSetTypeManual:
			var domains []string
			for _, domain := range ruleSet.Domains {
				if domain = strings.TrimSpace(domain); domain != "" {
					domains = append(domains, domain)
				}
			}
			if len(domains) == 0 {
				continue
			}
			targets = append(targets, proxyDNSTarget{lineTag: lineTag, domains: domains})
		case RuleSetTypeURL:
			if ruleSet.URL == "" {
				continue
			}
			targets = append(targets, proxyDNSTarget{
				lineTag:    lineTag,
				ruleSetTag: sbRuleSetTag(ruleSet),
				invert:     ruleSet.Invert,
			})
		}
	}
	return targets
}

// collectVPNBoundDomains 收集活动模式里绑定到 AnyConnect 线路的手动规则集域名。
// 这些域名的解析必须交给企业 DNS：真正的内网名（如 oa.corp.example）只在企业 DNS 有记录。
func collectVPNBoundDomains(profile *Profile, mode *Mode) []string {
	var domains []string
	seen := map[string]bool{}
	for _, binding := range mode.Bindings {
		line := profile.FindLine(binding.LineID)
		if line == nil || line.Type != LineTypeVPN || !line.Enabled {
			continue
		}
		ruleSet := profile.FindRuleSet(binding.RuleSetID)
		if ruleSet == nil || !ruleSet.Enabled || ruleSet.Type != RuleSetTypeManual {
			continue
		}
		for _, domain := range ruleSet.Domains {
			domain = strings.TrimSpace(domain)
			if domain == "" || seen[domain] {
				continue
			}
			seen[domain] = true
			domains = append(domains, domain)
		}
	}
	return domains
}

func buildDNS(
	enterpriseDNS []string,
	enterpriseDomains []string,
	proxyTargets []proxyDNSTarget,
	magicDNSEndpointTags []string,
) map[string]interface{} {
	servers := []map[string]interface{}{
		// system 仍保留：个别场景（无网络策略偏好）可作诊断对照，但不再当默认。
		{"tag": "system", "type": "local"},
		{
			"tag":    desktopPublicDNSTag,
			"type":   "https",
			"server": "223.5.5.5",
		},
	}
	var rules []map[string]interface{}

	// 企业域名 → 企业 DNS（查询本身经 AnyConnect 隧道出去）。放在最前，
	// 绝不落到公共 DoH（那里是 NXDOMAIN）。
	if len(enterpriseDNS) > 0 && len(enterpriseDomains) > 0 {
		servers = append(servers, map[string]interface{}{
			"tag": desktopEnterpriseDNSTag,
			// 必须 TCP：桌面的 vpn outbound 是本地 go-socks5 桥，只实现了
			// CONNECT。UDP ASSOCIATE 会"成功"建立却静默丢包，而带 server 的
			// DNS 规则命中后不回落 final，结果是每个内网域名卡满超时再 SERVFAIL。
			"type":   "tcp",
			"server": enterpriseDNS[0],
			"detour": "vpn",
		})
		rules = append(rules, map[string]interface{}{
			"domain_suffix": enterpriseDomains,
			"server":        desktopEnterpriseDNSTag,
		})
	}

	// 承载线路上的域名 → 经该线路的 DoH 解析。排在企业规则之后：
	// 内网名的归属已定。
	// 统一用 DoH（TCP/443 CONNECT）而非 UDP：detour 可能是 "vpn"，桌面那头是只
	// 实现了 CONNECT 的本地 go-socks5 桥（同 enterprise-dns 的 tcp 理由）。
	seenProxyServer := map[string]bool{}
	for _, target := range proxyTargets {
		serverTag := desktopProxyDNSTag(target.lineTag)
		if !seenProxyServer[serverTag] {
			seenProxyServer[serverTag] = true
			servers = append(servers, map[string]interface{}{
				"tag":    serverTag,
				"type":   "https",
				"server": "1.1.1.1",
				"detour": target.lineTag,
			})
		}
		rule := map[string]interface{}{"server": serverTag}
		if target.ruleSetTag != "" {
			rule["rule_set"] = target.ruleSetTag
			if target.invert {
				rule["invert"] = true
			}
		} else {
			rule["domain_suffix"] = target.domains
		}
		rules = append(rules, rule)
	}

	// 历史外部进程路径没有 Provider Prepare 阶段的内存快照注入接口，
	// 暂保留 endpoint 原生 DNS；新的 hosts 密封语义只在 Transparent Proxy 生效。
	for _, endpointTag := range magicDNSEndpointTags {
		serverTag := mobileTailscaleDNSTag(endpointTag)
		servers = append(servers, buildTailnetDNSServer(endpointTag))
		rules = append(rules, buildTailnetDNSRules(serverTag)...)
	}

	config := map[string]interface{}{
		"servers": servers,
		"final":   desktopPublicDNSTag,
		// 按 (域名, server) 分别缓存，避免不同线路的解析视角互相污染。
		"independent_cache": true,
	}
	if len(rules) > 0 {
		config["rules"] = rules
	}
	return config
}

func buildNEDNS(tailscaleTags []string) map[string]interface{} {
	servers := []map[string]interface{}{
		{
			"type":        "udp",
			"tag":         mobilePublicDNSTag,
			"server":      "1.1.1.1",
			"server_port": 53,
		},
	}
	bindings := make([]map[string]interface{}, 0, len(tailscaleTags))
	for _, endpointTag := range tailscaleTags {
		serverTag := mobileTailscaleDNSTag(endpointTag)
		servers = append(servers, buildTailnetDNSServer(endpointTag))
		bindings = append(bindings, map[string]interface{}{
			"endpoint": endpointTag,
			"server":   serverTag,
		})
	}
	servers = append(servers, map[string]interface{}{
		"type":            "xdial-mobile",
		"tag":             mobileDispatcherDNSTag,
		"public_fallback": mobilePublicDNSTag,
		"tailscale":       bindings,
	})
	config := map[string]interface{}{
		"servers": servers,
		"final":   mobileDispatcherDNSTag,
	}
	var rules []map[string]interface{}
	for _, endpointTag := range tailscaleTags {
		rules = append(rules, buildTailnetDNSRules(mobileTailscaleDNSTag(endpointTag))...)
	}
	if len(rules) > 0 {
		config["rules"] = rules
	}
	return config
}

func buildTransparentProxyDNS(
	profile *Profile,
	mode *Mode,
	subTagMap map[string]string,
	subGroupTagMap map[string]map[string]string,
	validTags map[string]bool,
	magicDNSEndpointTags []string,
	systemDNS []string,
	defaultOutboundTag string,
	needsProxyEndpointBootstrap bool,
) (map[string]interface{}, error) {
	primarySystemDNS, err := validateTransparentProxySystemDNS(systemDNS)
	if err != nil {
		return nil, err
	}
	servers := []map[string]interface{}{{
		"type":        "udp",
		"tag":         transparentSystemDNSTag,
		"server":      primarySystemDNS,
		"server_port": 53,
	}}
	if needsProxyEndpointBootstrap {
		servers = append(servers, map[string]interface{}{
			"type":   "https",
			"tag":    desktopPublicDNSTag,
			"server": "223.5.5.5",
		})
	}
	var rules []map[string]interface{}
	seenResolver := map[string]bool{
		transparentSystemDNSTag: true,
		desktopPublicDNSTag:     needsProxyEndpointBootstrap,
	}
	// 运行期快照归属必须先于 Mode 中的普通 DNS 分域求值。
	// 这里只安装空的纯内存 hosts transport 与静态 preferred_by
	// 规则；精确记录和 owned suffix 由 Provider 在 sing-box instance
	// Start 之后、系统网络 Commit 之前注入。
	for _, endpointTag := range magicDNSEndpointTags {
		serverTag := TailscaleMagicDNSDNSServerTag(endpointTag)
		servers = append(servers, buildTailnetHostsDNSServer(endpointTag))
		seenResolver[serverTag] = true
		rules = append(rules, buildTailnetHostsDNSRules(serverTag)...)
	}

	ensureResolver := func(resolverTag, outTag string) {
		if seenResolver[resolverTag] {
			return
		}
		seenResolver[resolverTag] = true
		switch resolverTag {
		case transparentEnterpriseDNSTag:
			servers = append(servers, map[string]interface{}{
				"type": "xdial-anyconnect",
				"tag":  resolverTag,
			})
		default:
			servers = append(servers, map[string]interface{}{
				"type":   "https",
				"tag":    resolverTag,
				"server": "1.1.1.1",
				"detour": outTag,
			})
		}
	}

	// DNS 与 route 使用同一个可见顺序。DNS 查询本身还没有目标 IP，因此遇到
	// 第一条 IP / 混合规则后，后续域名规则不能越过它抢先选择 resolver；从该点
	// 开始由启动前系统 DNS 处理。仍继续扫描后续域名 binding 只为注册 route
	// action:resolve 会引用的 resolver，不再把它们加入 DNS 查询规则链。
	dnsRulesOpen := true
	for index := range mode.Bindings {
		binding := &mode.Bindings[index]
		ruleSet := profile.FindRuleSet(binding.RuleSetID)
		if ruleSet == nil || !ruleSet.Enabled {
			continue
		}
		outTag := bindingOutboundTag(profile, binding, subTagMap, validTags)
		if outTag == "" {
			continue
		}
		resolverTag := transparentProxyResolverTag(ruleSet, outTag)
		switch ruleSet.Type {
		case RuleSetTypeManual:
			if len(ruleSet.Domains) > 0 {
				ensureResolver(resolverTag, outTag)
				if dnsRulesOpen {
					rules = append(rules, map[string]interface{}{
						"domain_suffix": ruleSet.Domains,
						"server":        resolverTag,
					})
				}
			}
			if len(ruleSet.CIDRs) > 0 {
				dnsRulesOpen = false
			}
		case RuleSetTypeURL:
			if ruleSet.RuntimeMatchKind != RuleSetMatchDomain {
				// IP 与无法安全拆分的混合规则走系统 DNS；这是用户指定的
				// 保守路径，不猜测远程规则集里的域名归属，也不允许后续
				// 域名规则越过它抢先选择 resolver。
				dnsRulesOpen = false
				continue
			}
			ensureResolver(resolverTag, outTag)
			if dnsRulesOpen {
				rule := map[string]interface{}{
					"rule_set": sbRuleSetTag(ruleSet),
					"server":   resolverTag,
				}
				applyURLRuleSetInvert(rule, ruleSet)
				rules = append(rules, rule)
			}
		}
	}

	for _, sub := range profile.Subscriptions {
		groupTags := subGroupTagMap[sub.ID]
		if groupTags == nil {
			continue
		}
		compiled, _ := collectSubscriptionRules(&sub, groupTags)
		for _, rule := range compiled {
			if !rule.domain {
				dnsRulesOpen = false
				continue
			}
			if rule.outTag == rejectTag {
				if dnsRulesOpen {
					rules = append(rules, map[string]interface{}{
						rule.matchKey: rule.values,
						"action":      "reject",
					})
				}
				continue
			}
			resolverTag := transparentProxyResolverForOutbound(rule.outTag)
			ensureResolver(resolverTag, rule.outTag)
			if dnsRulesOpen {
				rules = append(rules, map[string]interface{}{
					rule.matchKey: rule.values,
					"server":      resolverTag,
				})
			}
		}
	}

	defaultResolverTag := transparentProxyResolverForOutbound(defaultOutboundTag)
	ensureResolver(defaultResolverTag, defaultOutboundTag)
	dnsConfig := map[string]interface{}{
		"servers":           servers,
		"final":             defaultResolverTag,
		"independent_cache": true,
	}
	if len(rules) > 0 {
		dnsConfig["rules"] = rules
	}
	return dnsConfig, nil
}

func validateTransparentProxySystemDNS(systemDNS []string) (string, error) {
	seen := make(map[netip.Addr]bool)
	var primary string
	for _, raw := range systemDNS {
		raw = strings.TrimSpace(raw)
		address, err := netip.ParseAddr(raw)
		if err != nil || address.IsUnspecified() || address.IsMulticast() {
			return "", fmt.Errorf("system DNS snapshot contains an invalid resolver")
		}
		address = address.Unmap()
		if seen[address] {
			continue
		}
		seen[address] = true
		if primary == "" {
			primary = address.String()
		}
	}
	if primary == "" {
		return "", fmt.Errorf("system DNS snapshot is unavailable")
	}
	return primary, nil
}

// TailscaleMagicDNSDNSServerTag exposes the exact DNS transport tag generated
// for an active Tailscale endpoint. Platform consumers must use this exported
// value instead of reimplementing the tag rule.
func TailscaleMagicDNSDNSServerTag(endpointTag string) string {
	return "xdial-dns-" + endpointTag
}

func mobileTailscaleDNSTag(endpointTag string) string {
	return TailscaleMagicDNSDNSServerTag(endpointTag)
}

func buildTailnetDNSServer(endpointTag string) map[string]interface{} {
	return map[string]interface{}{
		"type":                     "tailscale",
		"tag":                      mobileTailscaleDNSTag(endpointTag),
		"endpoint":                 endpointTag,
		"accept_default_resolvers": false,
		"accept_search_domain":     true,
	}
}

func buildTailnetHostsDNSServer(endpointTag string) map[string]interface{} {
	return map[string]interface{}{
		"type": "hosts",
		"tag":  TailscaleMagicDNSDNSServerTag(endpointTag),
		// upstream hosts 在 path 为空时会默认读取系统 hosts 文件。
		// patched memory_only 是一个显式、跨平台的密封开关：禁止
		// 任何文件输入，只接受本次会话在内存中注入的快照。
		"memory_only": true,
		"predefined":  map[string][]string{},
	}
}

func buildTailnetDNSRules(serverTag string) []map[string]interface{} {
	return []map[string]interface{}{
		{
			"preferred_by": serverTag,
			"server":       serverTag,
		},
		{
			"domain_regex": []string{tailnetSingleLabelDomainRegex},
			"server":       serverTag,
		},
	}
}

func buildTailnetHostsDNSRules(serverTag string) []map[string]interface{} {
	return []map[string]interface{}{
		{
			"preferred_by":  serverTag,
			"server":        serverTag,
			"disable_cache": true,
		},
	}
}

func buildMagicDNSRouteRules(
	endpointTags []string,
	resolveBeforeRoute bool,
) (rules []map[string]interface{}) {
	for _, endpointTag := range endpointTags {
		if resolveBeforeRoute {
			resolverTag := TailscaleMagicDNSDNSServerTag(endpointTag)
			rules = append(rules, map[string]interface{}{
				"preferred_by":  resolverTag,
				"action":        "resolve",
				"server":        resolverTag,
				"disable_cache": true,
			})
		}
		rules = append(rules, map[string]interface{}{
			"preferred_by": endpointTag,
			"outbound":     endpointTag,
		})
	}
	return rules
}

func buildSystemRouteRules(includeDesktopDiagnostics bool) []map[string]interface{} {
	rules := []map[string]interface{}{
		{"action": "sniff"},
		// DNS 由 sing-box 拦截并自己应答（与 NE 端同款），绝不把原始 DNS 包
		// 强制直出——启动前 Underlay 的 resolver 可能只在下层虚拟接口中可达，
		// 错误选择接口会形成解析黑洞。
		{"protocol": "dns", "action": "hijack-dns"},
	}
	if includeDesktopDiagnostics {
		rules = append(rules, map[string]interface{}{
			"domain_suffix": testDomains,
			"outbound":      testSelectorTag,
		})
	}
	return rules
}

func buildNESystemRouteRules() []map[string]interface{} {
	return []map[string]interface{}{
		{"action": "sniff"},
		{"protocol": "dns", "action": "hijack-dns"},
	}
}

// buildTransparentProxyModeRouteRules 把每个 Mode binding 编译成一段连续的
// “解析 + 裁决”动作，并严格保留 binding 的相对顺序。
//
// - 手动域名：目标 Line 的 DNS → 域名 route；
// - 手动 IP：启动前系统 DNS → IP route；
// - 已检查为纯域名/纯 IP 的本地规则集分别走同样两条路径；
// - 混合或无法安全分类的规则集按用户约定走保守的系统 DNS。
// - 应用身份：原生 SOCKS auth_user → route，不参与 DNS。
func buildTransparentProxyModeRouteRules(
	profile *Profile,
	mode *Mode,
	subTagMap map[string]string,
	validTags map[string]bool,
	baseUsername string,
) (rules []map[string]interface{}) {
	for _, binding := range mode.Bindings {
		ruleSet := profile.FindRuleSet(binding.RuleSetID)
		if ruleSet == nil || !ruleSet.Enabled {
			continue
		}
		outTag := bindingOutboundTag(profile, &binding, subTagMap, validTags)
		if outTag == "" {
			continue
		}
		rules = append(rules, compileTransparentProxyRuleSet(ruleSet, outTag, baseUsername)...)
	}
	return
}

func bindingOutboundTag(
	profile *Profile,
	binding *RuleBinding,
	subTagMap map[string]string,
	validTags map[string]bool,
) string {
	var outTag string
	if binding.SubscriptionID != "" {
		outTag = subTagMap[binding.SubscriptionID]
	} else {
		line := profile.FindLine(binding.LineID)
		switch {
		case line == nil:
			if binding.LineID != builtinDirectLineID {
				return ""
			}
			outTag = "direct"
		case !line.Enabled:
			return ""
		default:
			outTag = resolveOutboundTag(line)
		}
	}
	if outTag == "" || !validTags[outTag] {
		return ""
	}
	return outTag
}

func compileTransparentProxyRuleSet(ruleSet *RuleSet, outTag, baseUsername string) []map[string]interface{} {
	switch ruleSet.Type {
	case RuleSetTypeApplication:
		identities := applicationRuleSetIdentities(ruleSet)
		if len(identities) == 0 {
			return nil
		}
		users := make([]string, 0, len(identities))
		for _, identity := range identities {
			users = append(users, ApplicationSOCKSUsername(baseUsername, identity))
		}
		return []map[string]interface{}{{
			"auth_user": users,
			"outbound":  outTag,
		}}
	case RuleSetTypeManual:
		var rules []map[string]interface{}
		if len(ruleSet.Domains) > 0 {
			resolver := transparentProxyResolverTag(ruleSet, outTag)
			rules = append(rules,
				map[string]interface{}{
					"domain_suffix": ruleSet.Domains,
					"action":        "resolve",
					"server":        resolver,
				},
				map[string]interface{}{
					"domain_suffix": ruleSet.Domains,
					"outbound":      outTag,
				},
			)
		}
		if len(ruleSet.CIDRs) > 0 {
			rules = append(rules,
				transparentProxySystemResolveRule(),
				map[string]interface{}{
					"ip_cidr":  ruleSet.CIDRs,
					"outbound": outTag,
				},
			)
		}
		return rules
	case RuleSetTypeURL:
		if ruleSet.URL == "" {
			return nil
		}
		match := map[string]interface{}{"rule_set": sbRuleSetTag(ruleSet)}
		route := map[string]interface{}{
			"rule_set": sbRuleSetTag(ruleSet),
			"outbound": outTag,
		}
		applyURLRuleSetInvert(match, ruleSet)
		applyURLRuleSetInvert(route, ruleSet)
		switch ruleSet.RuntimeMatchKind {
		case RuleSetMatchDomain:
			match["action"] = "resolve"
			match["server"] = transparentProxyResolverTag(ruleSet, outTag)
			return []map[string]interface{}{match, route}
		case RuleSetMatchIP, RuleSetMatchMixed, RuleSetMatchUnknown:
			return []map[string]interface{}{transparentProxySystemResolveRule(), route}
		}
	}
	return nil
}

func transparentProxySystemResolveRule() map[string]interface{} {
	return map[string]interface{}{
		"action": "resolve",
		"server": transparentSystemDNSTag,
	}
}

func transparentProxyResolverTag(ruleSet *RuleSet, outTag string) string {
	if outTag == "direct" {
		return transparentSystemDNSTag
	}
	if outTag == "vpn" && ruleSet.Type == RuleSetTypeManual {
		return transparentEnterpriseDNSTag
	}
	return desktopProxyDNSTag(outTag)
}

func buildModeRouteRules(
	profile *Profile,
	mode *Mode,
	subTagMap map[string]string,
	validTags map[string]bool,
) (acceptanceRules []map[string]interface{}, ordinaryRules []map[string]interface{}) {

	for _, binding := range mode.Bindings {
		ruleSet := profile.FindRuleSet(binding.RuleSetID)
		if ruleSet == nil || !ruleSet.Enabled {
			continue
		}

		var outTag string
		if binding.SubscriptionID != "" {
			outTag = subTagMap[binding.SubscriptionID]
		} else {
			line := profile.FindLine(binding.LineID)
			switch {
			case line == nil:
				// 悬空引用已由 inspectModeReferences 在生成入口拒绝，能到这里
				// 的只有内建 direct（profile 里没有显式直连线路时的保留 ID）。
				if binding.LineID != builtinDirectLineID {
					continue
				}
				outTag = "direct"
			case !line.Enabled:
				// 被禁用的线路必须显式跳过：direct/vpn 这类固定 tag 恒在
				// validTags 里，不查 Enabled 就会让"已禁用的线路"悄悄把流量
				// 塞进 direct 或别人的 VPN 隧道（对应 WarningDisabledLine）。
				continue
			default:
				outTag = resolveOutboundTag(line)
			}
		}
		if outTag == "" || !validTags[outTag] {
			continue
		}

		routeRule := buildRouteRule(ruleSet, outTag)
		if routeRule != nil {
			if isConnectivityAcceptanceRuleSetID(ruleSet.ID) {
				acceptanceRules = append(acceptanceRules, routeRule)
			} else {
				ordinaryRules = append(ordinaryRules, routeRule)
			}
		}
	}

	return acceptanceRules, ordinaryRules
}

func isConnectivityAcceptanceRuleSetID(id string) bool {
	return id == connectivityDirectRuleSetID || id == connectivityOutboundRuleSetID
}

func buildRouteRule(c *RuleSet, outTag string) map[string]interface{} {
	switch c.Type {
	case RuleSetTypeURL:
		if c.URL == "" {
			return nil
		}
		rule := map[string]interface{}{
			"rule_set": sbRuleSetTag(c),
			"outbound": outTag,
		}
		applyURLRuleSetInvert(rule, c)
		return rule
	case RuleSetTypeManual:
		rule := map[string]interface{}{
			"outbound": outTag,
		}
		if len(c.Domains) > 0 {
			rule["domain_suffix"] = c.Domains
		}
		if len(c.CIDRs) > 0 {
			rule["ip_cidr"] = c.CIDRs
		}
		if len(c.Domains) == 0 && len(c.CIDRs) == 0 {
			return nil
		}
		return rule
	}
	return nil
}

// applicationRuleSetIdentities flattens the user-visible application entries
// into the sing-box match list. The order stays stable for readable generated
// config, while duplicates across an app bundle and its helpers cannot alter
// matching semantics.
func applicationRuleSetIdentities(ruleSet *RuleSet) []string {
	if ruleSet == nil {
		return nil
	}
	seen := make(map[string]struct{})
	var identities []string
	for _, application := range ruleSet.Applications {
		for _, identity := range application.Identities {
			if _, exists := seen[identity]; exists {
				continue
			}
			seen[identity] = struct{}{}
			identities = append(identities, identity)
		}
	}
	return identities
}

func applyURLRuleSetInvert(rule map[string]interface{}, ruleSet *RuleSet) {
	if ruleSet != nil && ruleSet.Type == RuleSetTypeURL && ruleSet.Invert {
		rule["invert"] = true
	}
}

// sbCollectRuleSets 收集 sing-box 配置层的 rule_set 资源块（route.rule_set 数组里
// 的 remote 规则集下载条目）。
//
// 命名前缀 sb 用来把这一层（sing-box 配置里的 rule_set，处理远程 .srs/.json
// 下载资源）与新的数据模型层 RuleSet（本仓库自己的“规则”概念）区分开：二者
// 语义不同，前者是 sing-box 协议字段，后者是我们的持久化数据类型。本函数遍历
// 数据模型的 RuleSet（URL 类型），为每个生成一个 sing-box rule_set 资源。
func sbCollectRuleSets(
	profile *Profile,
	mode *Mode,
	subTagMap map[string]string,
	validTags map[string]bool,
) []map[string]interface{} {
	seen := map[string]bool{}
	var sets []map[string]interface{}

	for _, binding := range mode.Bindings {
		c := profile.FindRuleSet(binding.RuleSetID)
		if c == nil || !c.Enabled || c.Type != RuleSetTypeURL || c.URL == "" {
			continue
		}
		tag := sbRuleSetTag(c)
		if seen[tag] {
			continue
		}
		seen[tag] = true

		format := sbResolveRuleSetFormat(c)
		if strings.HasPrefix(c.URL, "file://") {
			sets = append(sets, map[string]interface{}{
				"type":   "local",
				"tag":    tag,
				"format": format,
				"path":   strings.TrimPrefix(c.URL, "file://"),
			})
		} else {
			sets = append(sets, map[string]interface{}{
				"type":            "remote",
				"tag":             tag,
				"format":          format,
				"url":             c.URL,
				"download_detour": sbDownloadDetour(profile, &binding, subTagMap, validTags),
			})
		}
	}
	return sets
}

// sbDownloadDetour 选 remote 规则集的下载出口。
//
// 不能一律 direct：规则集描述的往往正是走不通的那批域名（gfwlist 的 .srs 就托管
// 在 raw.githubusercontent.com），从它自己描述的被墙路径上下载必然失败。而首次
// 下载失败是硬失败不是降级 —— sing-box 的 router 在启动阶段直接 FATAL 退出。
//
// 但绑定线路不是都能用，能当 detour 的只有订阅节点/策略组和代理线路：
//   - 移动端 Tailscale endpoint 的 tsnet server 在 StartStatePostStart 才 Start，而
//     rule_set 首次下载发生在更早的 StartStateStart（box.preStart → Router.Start），
//     那时 endpoint 还没有 tailnet 地址和 netstack，拿它当 detour 必然失败。
//   - vpn 出口在桌面是本地 go-socks5 桥：sing-box 把域名原样 CONNECT 过去，桥用
//     启动前系统 resolver 解析，其视角可能与隧道不一致，还可能解出 IPv6 而
//     VPNBridge.DialTCP 只收 IPv4。不可靠，同样退回 direct。
//
// 桌面的 vpn/direct 绑定不会真的走到这里下载：daemon 已在启动 sing-box 前把它们
// 抓成本地文件（engine.prepareRuleSets），生成的是 type:local。这个 direct 兜底
// 主要覆盖移动端和测试调用方。
func sbDownloadDetour(
	profile *Profile,
	binding *RuleBinding,
	subTagMap map[string]string,
	validTags map[string]bool,
) string {
	var tag string
	if binding.SubscriptionID != "" {
		tag = subTagMap[binding.SubscriptionID]
	} else {
		line := profile.FindLine(binding.LineID)
		if line == nil || !line.Enabled || line.Type == LineTypeTailscale {
			return "direct"
		}
		tag = resolveOutboundTag(line)
	}
	if tag == "" || tag == "direct" || tag == "vpn" || !validTags[tag] {
		return "direct"
	}
	return tag
}

// sbRuleSetTag 生成 sing-box rule_set 资源块（及引用它的 route rule）用的 tag。
// sb 前缀表明这是 sing-box 配置层的 tag，不是数据模型 RuleSet 的字段。
func sbRuleSetTag(c *RuleSet) string {
	return "ruleset-" + c.ID
}

// sbResolveRuleSetFormat 推断 sing-box rule_set 资源的 format（binary/source）。
// sb 前缀同上：处理的是 sing-box 配置层的 rule_set 下载格式。
func sbResolveRuleSetFormat(c *RuleSet) string {
	if c.Format != "" && c.Format != "auto" {
		switch c.Format {
		case "srs", "binary":
			return "binary"
		case "json", "source":
			return "source"
		}
	}
	ext := strings.ToLower(path.Ext(c.URL))
	switch ext {
	case ".srs":
		return "binary"
	case ".json":
		return "source"
	default:
		return "binary"
	}
}

func resolveOutboundTag(line *Line) string {
	switch line.Type {
	case LineTypeDirect:
		return "direct"
	case LineTypeVPN:
		return "vpn"
	case LineTypeTailscale:
		return tailscaleEndpointTag(line)
	default:
		return "proxy-" + line.ID
	}
}

func tailscaleEndpointTag(line *Line) string {
	return "tailscale-" + line.ID
}

func firstString(values []string) string {
	if len(values) == 0 {
		return ""
	}
	return values[0]
}

// rejectTag 是 groupTags 里的哨兵值：不是真实 outbound tag（含 NUL 保证永不与
// slugify 产物撞车），表示"指向该组/规则应生成 action:reject 而非 outbound 引用"。
const rejectTag = "\x00reject"

// isRejectName 判断订阅规则/组成员里的名字是否为拦截策略（Clash/Surge 内置）。
func isRejectName(name string) bool {
	switch strings.ToUpper(name) {
	case "REJECT", "REJECT-DROP", "REJECT-TINYGIF", "BLOCK":
		return true
	}
	return false
}

// buildSubscriptionOutbounds 返回所有 outbound、主 tag、以及组名→tag 映射
func buildSubscriptionOutbounds(sub *Subscription, platform Platform) ([]map[string]interface{}, string, map[string]string) {
	prefix := sub.ID + "-"

	// 1. 生成所有节点 outbound，建立 name→tag 映射
	var nodeObs []map[string]interface{}
	nameToTag := map[string]string{}
	for _, line := range sub.Lines {
		if !line.Enabled {
			continue
		}
		lineCopy := line
		lineCopy.ID = prefix + line.ID
		ob := buildProxyOutbound(&lineCopy)
		if ob != nil {
			tag := ob["tag"].(string)
			nodeObs = append(nodeObs, ob)
			nameToTag[line.Name] = tag
		}
	}
	if len(nodeObs) == 0 {
		return nil, "", nil
	}

	groupTags := map[string]string{} // groupName → tag
	var groupObs []map[string]interface{}

	if len(sub.ProxyGroups) > 0 {
		// 2a. 有策略组：先按真实可达成员做 fixpoint。不能先把所有组都当成有效
		// outbound，否则“有效节点 + 空子组”会把不存在的 tag 塞进 selector，
		// 直到 sing-box 启动时才失败。
		nameToTag["DIRECT"] = "direct"
		nameToTag["Direct"] = "direct"
		const (
			groupUnavailable = iota
			groupRejectOnly
			groupOutbound
		)
		groupDefinitions := make(map[string]ProxyGroup, len(sub.ProxyGroups))
		for _, group := range sub.ProxyGroups {
			if _, exists := groupDefinitions[group.Name]; !exists {
				groupDefinitions[group.Name] = group
			}
		}
		groupStates := make(map[string]int, len(groupDefinitions))
		for changed := true; changed; {
			changed = false
			for name, group := range groupDefinitions {
				next := groupUnavailable
				for _, member := range group.Proxies {
					if isRejectName(member) || groupStates[member] == groupRejectOnly {
						if next < groupRejectOnly {
							next = groupRejectOnly
						}
						continue
					}
					if _, ok := nameToTag[member]; ok || groupStates[member] == groupOutbound {
						next = groupOutbound
						break
					}
				}
				if next > groupStates[name] {
					groupStates[name] = next
					changed = true
				}
			}
		}

		// 为最终确实存在的 outbound 分配唯一 tag；纯拦截组映射到哨兵，
		// 完全不可用的组不进入映射。
		// slugify 把非 ASCII 全映射为 '-'，中文组名（香港节点/台湾节点→"----"）会
		// 撞成同一 tag，导致 sing-box 因 duplicate outbound tag 拒绝启动（表现为假连接）。
		// 去重：首个组保留无后缀 base（Swift NetworkInfo 只按第一个组算 tag，保持兼容），
		// 撞车/同名组追加 -N。
		usedTags := map[string]bool{}
		for _, g := range sub.ProxyGroups {
			if _, exists := groupTags[g.Name]; exists {
				continue // 同名组只保留第一个
			}
			if groupStates[g.Name] == groupRejectOnly {
				groupTags[g.Name] = rejectTag
				continue
			}
			if groupStates[g.Name] != groupOutbound {
				continue
			}
			base := "sub-" + prefix + slugify(g.Name)
			tag := base
			for i := 2; usedTags[tag]; i++ {
				tag = fmt.Sprintf("%s-%d", base, i)
			}
			usedTags[tag] = true
			groupTags[g.Name] = tag
		}
		processedGroups := map[string]bool{}
		for _, g := range sub.ProxyGroups {
			if processedGroups[g.Name] || groupStates[g.Name] != groupOutbound {
				continue
			}
			processedGroups[g.Name] = true
			var memberTags []string
			selectedTag := ""
			for _, name := range g.Proxies {
				if isRejectName(name) {
					continue
				}
				if tag, ok := nameToTag[name]; ok {
					memberTags = append(memberTags, tag)
					if name == g.Selected {
						selectedTag = tag
					}
				} else if tag, ok := groupTags[name]; ok && tag != rejectTag {
					memberTags = append(memberTags, tag)
					if name == g.Selected {
						selectedTag = tag
					}
				}
			}
			if len(memberTags) == 0 {
				delete(groupTags, g.Name)
				continue
			}

			ob := map[string]interface{}{
				"tag":       groupTags[g.Name],
				"outbounds": memberTags,
			}
			switch g.Type {
			case "url-test", "urltest":
				ob["type"] = "urltest"
				url := ""
				if !platform.isNetworkExtension() {
					url = g.URL
				}
				if url == "" {
					url = "https://www.gstatic.com/generate_204"
				}
				ob["url"] = url
				interval := g.Interval
				if interval <= 0 {
					interval = 300
				}
				if interval > 1800 {
					interval = 1800
				}
				ob["interval"] = fmt.Sprintf("%ds", interval)
			default:
				ob["type"] = "selector"
				if selectedTag != "" {
					ob["default"] = selectedTag
				}
			}
			groupObs = append(groupObs, ob)
		}
	} else {
		// 2b. 无策略组：生成一个默认 group
		var allTags []string
		for _, ob := range nodeObs {
			allTags = append(allTags, ob["tag"].(string))
		}
		groupTag := "sub-" + sub.ID
		group := map[string]interface{}{
			"tag":       groupTag,
			"outbounds": allTags,
		}
		switch sub.Strategy {
		case "selector":
			group["type"] = "selector"
			if selectedTag := nameToTag[sub.Selected]; selectedTag != "" {
				group["default"] = selectedTag
			}
		default:
			group["type"] = "urltest"
			url := ""
			if !platform.isNetworkExtension() {
				url = sub.TestURL
			}
			if url == "" {
				url = "https://www.gstatic.com/generate_204"
			}
			group["url"] = url
			interval := sub.TestInterval
			if interval <= 0 {
				interval = 300
			}
			if interval > 1800 {
				interval = 1800
			}
			group["interval"] = fmt.Sprintf("%ds", interval)
		}
		groupObs = append(groupObs, group)
		groupTags["__default__"] = groupTag
	}

	// 主 tag：第一个真正生成了 outbound 的策略组（按原顺序找），或默认组
	mainTag := ""
	if len(sub.ProxyGroups) > 0 {
		for _, g := range sub.ProxyGroups {
			if tag, ok := groupTags[g.Name]; ok && tag != rejectTag {
				mainTag = tag
				break
			}
		}
	} else {
		mainTag = groupTags["__default__"]
	}

	all := append(nodeObs, groupObs...)
	return all, mainTag, groupTags
}

// RuntimeSubscriptionCatalog exposes the exact tags generated for subscription
// nodes and groups. Mobile clients use this catalog for live selector changes and
// latency probes instead of reimplementing slug/collision rules in Swift.
type RuntimeSubscriptionCatalog struct {
	Subscriptions []RuntimeSubscription `json:"subscriptions"`
}

type RuntimeSubscription struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Strategy string `json:"strategy"`
	// MainTag is the exact primary outbound selected by
	// buildSubscriptionOutbounds, not a tag reconstructed by a consumer.
	MainTag string `json:"main_tag"`
	// ReadinessTags contains only generated proxy groups that can affect the
	// active subscription: its primary group and groups referenced by its own
	// compiled rules. Direct/reject targets and unused declared groups are
	// intentionally excluded.
	ReadinessTags []string        `json:"readiness_tags"`
	Nodes         []RuntimeMember `json:"nodes"`
	Groups        []RuntimeGroup  `json:"groups"`
}

type RuntimeGroup struct {
	Name     string          `json:"name"`
	Tag      string          `json:"tag"`
	Type     string          `json:"type"`
	Selected string          `json:"selected,omitempty"`
	Members  []RuntimeMember `json:"members"`
}

type RuntimeMember struct {
	ID   string `json:"id,omitempty"`
	Name string `json:"name"`
	Tag  string `json:"tag"`
}

type RuntimeLineCatalog struct {
	Lines []RuntimeMember `json:"lines"`
}

// BuildLineRuntimeCatalog exports the exact Line tags generated by Go. Desktop
// diagnostics consume this instead of extending Swift's legacy tag reimplementation.
func BuildLineRuntimeCatalog(profile *Profile) RuntimeLineCatalog {
	catalog := RuntimeLineCatalog{Lines: []RuntimeMember{}}
	if profile == nil {
		return catalog
	}
	for index := range profile.Lines {
		line := &profile.Lines[index]
		if !line.Enabled {
			continue
		}
		catalog.Lines = append(catalog.Lines, RuntimeMember{
			ID:   line.ID,
			Name: line.Name,
			Tag:  resolveOutboundTag(line),
		})
	}
	return catalog
}

func BuildSubscriptionRuntimeCatalog(profile *Profile, platform Platform) RuntimeSubscriptionCatalog {
	catalog := RuntimeSubscriptionCatalog{Subscriptions: []RuntimeSubscription{}}
	for index := range profile.Subscriptions {
		subscription := &profile.Subscriptions[index]
		if !subscription.Enabled {
			continue
		}
		generated, mainTag, groupTags := buildSubscriptionOutbounds(subscription, platform)
		if len(generated) == 0 {
			continue
		}
		generatedTags := make(map[string]bool, len(generated))
		for _, outbound := range generated {
			if tag, ok := outbound["tag"].(string); ok {
				generatedTags[tag] = true
			}
		}

		entry := RuntimeSubscription{
			ID: subscription.ID, Name: subscription.Name, Strategy: subscription.Strategy,
			MainTag: mainTag,
			ReadinessTags: subscriptionReadinessTags(
				subscription,
				mainTag,
				groupTags,
				generatedTags,
			),
			Nodes:  []RuntimeMember{},
			Groups: []RuntimeGroup{},
		}
		memberTags := make(map[string]string)
		for _, line := range subscription.Lines {
			if !line.Enabled {
				continue
			}
			lineCopy := line
			lineCopy.ID = subscription.ID + "-" + line.ID
			outbound := buildProxyOutbound(&lineCopy)
			if outbound == nil {
				continue
			}
			tag, _ := outbound["tag"].(string)
			if tag == "" || !generatedTags[tag] {
				continue
			}
			memberTags[line.Name] = tag
			entry.Nodes = append(entry.Nodes, RuntimeMember{ID: line.ID, Name: line.Name, Tag: tag})
		}
		memberTags["DIRECT"] = "direct"
		memberTags["Direct"] = "direct"
		for name, tag := range groupTags {
			if name != "__default__" && tag != rejectTag {
				memberTags[name] = tag
			}
		}

		if len(subscription.ProxyGroups) == 0 {
			if tag := groupTags["__default__"]; tag != "" {
				members := append([]RuntimeMember(nil), entry.Nodes...)
				entry.Groups = append(entry.Groups, RuntimeGroup{
					Name: "__default__", Tag: tag, Type: subscription.Strategy,
					Selected: subscription.Selected, Members: members,
				})
			}
		} else {
			seenGroups := make(map[string]bool)
			for _, group := range subscription.ProxyGroups {
				if seenGroups[group.Name] {
					continue
				}
				seenGroups[group.Name] = true
				tag := groupTags[group.Name]
				if tag == "" || tag == rejectTag || !generatedTags[tag] {
					continue
				}
				members := []RuntimeMember{}
				for _, memberName := range group.Proxies {
					memberTag := memberTags[memberName]
					if memberTag == "" || memberTag == rejectTag {
						continue
					}
					members = append(members, RuntimeMember{Name: memberName, Tag: memberTag})
				}
				entry.Groups = append(entry.Groups, RuntimeGroup{
					Name: group.Name, Tag: tag, Type: group.Type, Selected: group.Selected, Members: members,
				})
			}
		}
		catalog.Subscriptions = append(catalog.Subscriptions, entry)
	}
	return catalog
}

func subscriptionReadinessTags(
	subscription *Subscription,
	mainTag string,
	groupTags map[string]string,
	generatedTags map[string]bool,
) []string {
	tags := make([]string, 0, len(groupTags))
	seen := make(map[string]bool, len(groupTags))
	appendTag := func(tag string) {
		tag = strings.TrimSpace(tag)
		if tag == "" ||
			tag == "direct" ||
			tag == rejectTag ||
			!generatedTags[tag] ||
			seen[tag] {
			return
		}
		seen[tag] = true
		tags = append(tags, tag)
	}

	appendTag(mainTag)
	compiled, _ := collectSubscriptionRules(subscription, groupTags)
	for _, rule := range compiled {
		appendTag(rule.outTag)
	}
	return tags
}

type subscriptionCompiledRule struct {
	matchKey string
	values   interface{}
	outTag   string
	domain   bool
}

// collectSubscriptionRules 把订阅语法规范化成有序 matcher；桌面旧路径与
// Transparent Proxy 的分阶段 DNS 编译共享这一份顺序事实。
func collectSubscriptionRules(
	sub *Subscription,
	groupTags map[string]string,
) ([]subscriptionCompiledRule, []map[string]interface{}) {
	var rules []subscriptionCompiledRule
	var sets []map[string]interface{}
	seenGeoIP := map[string]bool{}

	for _, r := range sub.Rules {
		outTag := groupTags[r.Group]
		if outTag == "" {
			// 组名解析不到时：DIRECT→直连，REJECT 系→拦截哨兵，其余（含引用了被删的
			// 空组）才丢弃。此前 REJECT 走 else 分支被静默丢弃，广告/追踪拦截规则整体失效。
			switch strings.ToUpper(r.Group) {
			case "DIRECT":
				outTag = "direct"
			case "REJECT", "REJECT-DROP", "REJECT-TINYGIF", "BLOCK":
				outTag = rejectTag
			default:
				continue
			}
		}

		switch r.Type {
		case "RULE-SET":
			// 原始未展开的 RULE-SET 占位（真正的展开在 subscription.ExpandRulesets
			// 解析期就地完成）。这里出现的都是残留占位，跳过。
			continue
		case "DOMAIN-SUFFIX":
			rules = append(rules, subscriptionCompiledRule{
				matchKey: "domain_suffix", values: []string{r.Value}, outTag: outTag, domain: true,
			})
		case "DOMAIN":
			rules = append(rules, subscriptionCompiledRule{
				matchKey: "domain", values: []string{r.Value}, outTag: outTag, domain: true,
			})
		case "DOMAIN-KEYWORD":
			rules = append(rules, subscriptionCompiledRule{
				matchKey: "domain_keyword", values: []string{r.Value}, outTag: outTag, domain: true,
			})
		case "IP-CIDR", "IP-CIDR6":
			rules = append(rules, subscriptionCompiledRule{
				matchKey: "ip_cidr", values: []string{r.Value}, outTag: outTag,
			})
		case "GEOIP":
			// sing-box 1.12 移除了内置 geoip，转换为远程 rule-set
			code := strings.ToLower(r.Value)
			if code == "private" || code == "lan" {
				// Clash 常用 GEOIP,LAN 表达私有地址；sing-box 对应原生
				// ip_is_private，不应为它构造一个不存在的远程国家规则集。
				rules = append(rules, subscriptionCompiledRule{
					matchKey: "ip_is_private", values: true, outTag: outTag,
				})
				continue
			}
			setTag := "sub-geoip-" + sub.ID + "-" + code
			if !seenGeoIP[setTag] {
				seenGeoIP[setTag] = true
				sets = append(sets, map[string]interface{}{
					"type":            "remote",
					"tag":             setTag,
					"format":          "binary",
					"url":             "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-" + code + ".srs",
					"download_detour": "direct",
				})
			}
			rules = append(rules, subscriptionCompiledRule{
				matchKey: "rule_set", values: setTag, outTag: outTag,
			})
		case "FINAL":
			// FINAL 不生成 route rule，由 sing-box 的 "final" 字段处理
			continue
		}
	}
	return rules, sets
}

// buildSubscriptionRules 将订阅的规则转换为 sing-box route rules 和 rule_sets。
func buildSubscriptionRules(sub *Subscription, groupTags map[string]string) ([]map[string]interface{}, []map[string]interface{}) {
	compiled, sets := collectSubscriptionRules(sub, groupTags)
	rules := make([]map[string]interface{}, 0, len(compiled))
	for _, rule := range compiled {
		rules = append(rules, subRouteRule(rule.matchKey, rule.values, rule.outTag))
	}
	return rules, sets
}

func buildTransparentProxySubscriptionRules(
	sub *Subscription,
	groupTags map[string]string,
) ([]map[string]interface{}, []map[string]interface{}) {
	compiled, sets := collectSubscriptionRules(sub, groupTags)
	var rules []map[string]interface{}
	for _, rule := range compiled {
		route := subRouteRule(rule.matchKey, rule.values, rule.outTag)
		if rule.domain {
			// 域名拦截不需要解析；其余目标先从目标订阅组/Line 的出口视角解析。
			if rule.outTag != rejectTag {
				rules = append(rules, map[string]interface{}{
					rule.matchKey: rule.values,
					"action":      "resolve",
					"server":      transparentProxyResolverForOutbound(rule.outTag),
				})
			}
			rules = append(rules, route)
			continue
		}
		rules = append(rules, transparentProxySystemResolveRule(), route)
	}
	return rules, sets
}

func transparentProxyResolverForOutbound(outTag string) string {
	if outTag == "direct" {
		return transparentSystemDNSTag
	}
	return desktopProxyDNSTag(outTag)
}

// subRouteRule 组装单条订阅 route rule。outTag 为拦截哨兵时生成 action:reject
// （sing-box 1.11+ 的现代拦截做法），否则生成常规 outbound 引用。
func subRouteRule(matchKey string, values interface{}, outTag string) map[string]interface{} {
	rule := map[string]interface{}{matchKey: values}
	if outTag == rejectTag {
		rule["action"] = "reject"
	} else {
		rule["outbound"] = outTag
	}
	return rule
}

func slugify(s string) string {
	// 简单 slug：取前 16 字符，替换非字母数字为 -
	r := strings.Map(func(c rune) rune {
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') {
			return c
		}
		return '-'
	}, s)
	if len(r) > 16 {
		r = r[:16]
	}
	return strings.ToLower(r)
}

func applyTransport(ob map[string]interface{}, line *Line) {
	if line.TFO {
		ob["tcp_fast_open"] = true
	}
	if line.UDP {
		ob["udp_over_tcp"] = true
	}
}

func validAnyTLSOptions(line *Line) bool {
	if (line.AnyTLSIdleSessionCheckInterval != 0 &&
		(line.AnyTLSIdleSessionCheckInterval < minAnyTLSDurationSeconds ||
			line.AnyTLSIdleSessionCheckInterval > maxAnyTLSDurationSeconds)) ||
		(line.AnyTLSIdleSessionTimeout != 0 &&
			(line.AnyTLSIdleSessionTimeout < minAnyTLSDurationSeconds ||
				line.AnyTLSIdleSessionTimeout > maxAnyTLSDurationSeconds)) ||
		line.AnyTLSMinIdleSession < 0 ||
		line.AnyTLSMinIdleSession > maxAnyTLSMinIdleSession {
		return false
	}
	if line.AnyTLSClientFingerprint != "" {
		if _, exists := anyTLSClientFingerprints[line.AnyTLSClientFingerprint]; !exists {
			return false
		}
	}
	if len(line.AnyTLSALPN) > maxAnyTLSALPNProtocols {
		return false
	}
	seenALPN := make(map[string]struct{}, len(line.AnyTLSALPN))
	for _, protocol := range line.AnyTLSALPN {
		if protocol == "" ||
			len(protocol) > maxAnyTLSALPNProtocolBytes ||
			!utf8.ValidString(protocol) ||
			strings.IndexFunc(protocol, unicode.IsControl) >= 0 {
			return false
		}
		if _, duplicate := seenALPN[protocol]; duplicate {
			return false
		}
		seenALPN[protocol] = struct{}{}
	}
	return true
}

// configureTransparentProxyEndpointBootstrap isolates proxy endpoint lookup from
// user-traffic DNS ownership. Only concrete proxy outbounds generated from the
// active Mode are present here; selectors and infrastructure outbounds have no
// server field and must never acquire this resolver implicitly.
func configureTransparentProxyEndpointBootstrap(outbounds []map[string]interface{}) bool {
	needed := false
	for _, outbound := range outbounds {
		outboundType, _ := outbound["type"].(string)
		switch outboundType {
		case "trojan", "shadowsocks", "vmess", "anytls":
		default:
			continue
		}
		server, _ := outbound["server"].(string)
		server = strings.TrimSpace(server)
		if server == "" {
			continue
		}
		if _, err := netip.ParseAddr(server); err == nil {
			continue
		}
		outbound["domain_resolver"] = desktopPublicDNSTag
		needed = true
	}
	return needed
}

func buildProxyOutbound(line *Line) map[string]interface{} {
	switch line.Type {
	case LineTypeTrojan:
		if line.TrojanServer == "" || line.TrojanPort <= 0 || line.TrojanPort > 65535 || line.TrojanPassword == "" {
			return nil
		}
		tls := map[string]interface{}{
			"enabled":     true,
			"server_name": line.TrojanSNI,
		}
		// sing-box 用 server_name(SNI) 做证书校验，SNI 与连接地址不同是正常场景，
		// 不该据此关闭校验。仅在用户/订阅显式 opt-in（自签节点）时才跳过。
		if line.AllowInsecure {
			tls["insecure"] = true
		}
		ob := map[string]interface{}{
			"type":        "trojan",
			"tag":         "proxy-" + line.ID,
			"server":      line.TrojanServer,
			"server_port": line.TrojanPort,
			"password":    line.TrojanPassword,
			"tls":         tls,
		}
		applyTransport(ob, line)
		return ob
	case LineTypeShadowsocks:
		if line.SSServer == "" || line.SSPort <= 0 || line.SSPort > 65535 || line.SSMethod == "" || line.SSPass == "" {
			return nil
		}
		ob := map[string]interface{}{
			"type":        "shadowsocks",
			"tag":         "proxy-" + line.ID,
			"server":      line.SSServer,
			"server_port": line.SSPort,
			"method":      line.SSMethod,
			"password":    line.SSPass,
		}
		applyTransport(ob, line)
		return ob
	case LineTypeVMess:
		if line.VMessServer == "" || line.VMessPort <= 0 || line.VMessPort > 65535 {
			return nil
		}
		if _, err := uuid.Parse(line.VMessUUID); err != nil {
			return nil
		}
		ob := map[string]interface{}{
			"type":        "vmess",
			"tag":         "proxy-" + line.ID,
			"server":      line.VMessServer,
			"server_port": line.VMessPort,
			"uuid":        line.VMessUUID,
			"alter_id":    line.VMessAltID,
		}
		applyTransport(ob, line)
		return ob
	case LineTypeAnyTLS:
		// AnyTLS 会在握手期间读取已经建立连接的远端地址，而 TCP Fast Open
		// 返回的是延迟建立连接。sing-box 明确拒绝这个组合；在配置编译阶段就把
		// 线路判为不可用，避免数据面启动时崩溃或才暴露错误。
		if line.TFO ||
			line.AnyTLSServer == "" ||
			line.AnyTLSPort <= 0 ||
			line.AnyTLSPort > 65535 ||
			line.AnyTLSPassword == "" ||
			!validAnyTLSOptions(line) {
			return nil
		}
		serverName := line.AnyTLSSNI
		if serverName == "" {
			serverName = line.AnyTLSServer
		}
		tls := map[string]interface{}{
			"enabled":     true,
			"server_name": serverName,
		}
		if line.AllowInsecure {
			tls["insecure"] = true
		}
		if len(line.AnyTLSALPN) > 0 {
			tls["alpn"] = line.AnyTLSALPN
		}
		if line.AnyTLSClientFingerprint != "" {
			tls["utls"] = map[string]interface{}{
				"enabled":     true,
				"fingerprint": line.AnyTLSClientFingerprint,
			}
		}
		ob := map[string]interface{}{
			"type":        "anytls",
			"tag":         "proxy-" + line.ID,
			"server":      line.AnyTLSServer,
			"server_port": line.AnyTLSPort,
			"password":    line.AnyTLSPassword,
			"tls":         tls,
		}
		if line.AnyTLSIdleSessionCheckInterval > 0 {
			ob["idle_session_check_interval"] = fmt.Sprintf(
				"%ds",
				line.AnyTLSIdleSessionCheckInterval,
			)
		}
		if line.AnyTLSIdleSessionTimeout > 0 {
			ob["idle_session_timeout"] = fmt.Sprintf("%ds", line.AnyTLSIdleSessionTimeout)
		}
		if line.AnyTLSMinIdleSession > 0 {
			ob["min_idle_session"] = line.AnyTLSMinIdleSession
		}
		// AnyTLS 原生用 UoT 承载 UDP；不能套用通用 udp_over_tcp 字段。
		return ob
	}
	return nil
}
