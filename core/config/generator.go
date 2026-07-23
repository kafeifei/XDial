package config

import (
	"encoding/json"
	"fmt"
	"path"
	"strings"

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
)

// Platform 决定 sing-box 配置生成的目标运行环境。
//
// PlatformMacOS(零值)= 现有桌面场景:sing-box 作为外部子进程运行,靠 tun +
// auto_route 抓包、auto_detect_interface 选物理网卡、clash_api 暴露 controller、
// cache_file 用相对路径(子进程 cwd 下)。
//
// PlatformNE = tvOS/iOS 的 NetworkExtension 场景:sing-box 作为库跑在扩展进程内,
// 无 root、无子进程、路由由 NEPacketTunnelNetworkSettings 在 Swift 侧接管,读包来源
// 是系统 packetFlow。因此 tun inbound 只保留最小字段(type/address/mtu),不生成
// auto_route/strict_route/stack/route_exclude_address,也不开
// clash_api;cache_file 必须用调用方传入的沙盒内绝对路径(basePath)。
type Platform int

const (
	PlatformMacOS Platform = iota
	PlatformNE
)

// GenerateSingBox 保留原有签名作为 macOS 模式的包装函数,现有调用方(如
// core/engine.SingBoxProcess.Start)无需改动。
func GenerateSingBox(profile *Profile, socksPort int, vpnServerIP string) ([]byte, error) {
	return GenerateSingBoxFor(profile, socksPort, vpnServerIP, PlatformMacOS, "")
}

// GenerateSingBoxFor 生成 sing-box JSON 配置,platform 决定平台相关字段的取舍。
//
// basePath 仅在 PlatformNE 下使用,作为沙盒内绝对目录,用来拼出 cache_file 的绝对
// 路径(basePath/cache.db)。PlatformMacOS 下 basePath 被忽略,cache_file 沿用现有
// 相对路径 "cache.db"。
func GenerateSingBoxFor(profile *Profile, socksPort int, vpnServerIP string, platform Platform, basePath string) ([]byte, error) {
	mode := profile.ActiveMode()
	if mode == nil {
		return nil, fmt.Errorf("no active mode")
	}
	activeLineIDs, activeSubscriptionIDs := effectiveActiveTargetIDs(profile, mode)
	activeVPNIDs := effectiveActiveVPNLineIDs(profile, mode)
	if platform == PlatformNE && len(activeVPNIDs) > 1 {
		return nil, fmt.Errorf("network extension mode supports only one active AnyConnect line")
	}

	outbounds := []map[string]interface{}{{"type": "direct", "tag": "direct"}}
	if len(activeVPNIDs) > 0 {
		vpnOutbound := map[string]interface{}{
			"type":        "socks",
			"tag":         "vpn",
			"server":      "127.0.0.1",
			"server_port": socksPort,
		}
		if platform == PlatformNE {
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
	var tailscaleTags []string
	for _, line := range profile.Lines {
		// Tailscale endpoint 的 preferred_by / accept_routes 是全局路由能力，
		// 不要求模式显式引用；移动端与桌面端保持相同语义。
		if !line.Enabled || line.Type != LineTypeTailscale {
			continue
		}
		if platform == PlatformNE && (basePath == "" || !path.IsAbs(basePath)) {
			return nil, fmt.Errorf("network extension Tailscale state directory is unavailable")
		}
		endpoint, err := buildTailscaleEndpoint(&line, basePath)
		if err != nil {
			return nil, err
		}
		endpoints = append(endpoints, endpoint)
		tailscaleTags = append(tailscaleTags, tailscaleEndpointTag(&line))
	}

	for _, line := range profile.Lines {
		if !activeLineIDs[line.ID] || !line.Enabled || line.Type == LineTypeDirect || line.Type == LineTypeVPN || line.Type == LineTypeTailscale {
			continue
		}
		ob := buildProxyOutbound(&line)
		if ob != nil {
			outbounds = append(outbounds, ob)
		}
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
		selectorMembers = append(selectorMembers, tailscaleTags...)
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

	dnsOutbound := "direct"
	if platform == PlatformNE && len(activeVPNIDs) == 1 {
		// 保留旧变量的出口语义供桌面生成路径使用；NE 的系统 DNS 包会由
		// hijack-dns 交给 xdial-mobile dispatcher，再按域名选择 Tailscale、
		// AnyConnect 企业 DNS 或 standalone 公共 DNS。
		dnsOutbound = "vpn"
	}
	routeRules := buildSystemRouteRules(dnsOutbound, platform == PlatformMacOS)
	if platform == PlatformNE {
		routeRules = buildNESystemRouteRules()
	}
	ruleSetResources := sbCollectRuleSets(profile, mode)
	acceptanceModeRules, ordinaryModeRules := buildModeRouteRules(
		profile,
		mode,
		subTagMap,
		validTags,
	)

	// 两条锁定验收规则来自用户可见 profile，不是生成器暗中注入；但它们必须
	// 先于订阅规则匹配，否则订阅里的大网段（如 1.0.0.0/8）会吞掉 /32，
	// 让路由验收测到订阅语义而不是两条显式绑定。
	routeRules = append(routeRules, acceptanceModeRules...)

	// 订阅自带规则仍优先于普通模式规则（让订阅的分组规则优先匹配）。
	for _, sub := range profile.Subscriptions {
		if !activeSubscriptionIDs[sub.ID] || !sub.Enabled {
			continue
		}
		groupTags := subGroupTagMap[sub.ID]
		if groupTags == nil {
			continue
		}
		subRules, subSets := buildSubscriptionRules(&sub, groupTags)
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

	// 普通模式规则作为兜底（引用不存在的 outbound 时跳过）。
	routeRules = append(routeRules, ordinaryModeRules...)

	// Tailscale 的 preferred_by 会包含出口节点发布的默认路由。它必须排在
	// 用户显式配置的订阅/模式规则之后，否则 0.0.0.0/0 会抢走所有流量，
	// 例如本应命中企业域名 → VPN 的请求会提前走 Tailscale 出口。
	routeRules = append(routeRules, buildTailscalePreferredRouteRules(tailscaleTags)...)

	defaultTag := "direct"
	if mode.DefaultSubscriptionID != "" {
		if tag, ok := subTagMap[mode.DefaultSubscriptionID]; ok && validTags[tag] {
			defaultTag = tag
		}
	} else if mode.DefaultLineID != "" {
		if l := profile.FindLine(mode.DefaultLineID); l != nil {
			candidate := resolveOutboundTag(l)
			if validTags[candidate] {
				defaultTag = candidate
			}
		}
	}

	route := map[string]interface{}{
		"rules": routeRules,
		"final": defaultTag,
	}
	if platform == PlatformNE {
		// 节点域名和 Tailscale 控制面必须能在首次登录前解析，不能递归进入
		// 尚未就绪的企业或 Tailscale 分域 resolver。
		route["default_domain_resolver"] = mobilePublicDNSTag
	} else if len(tailscaleTags) > 0 {
		route["default_domain_resolver"] = "system"
	}
	// 两个平台都必须选择真实物理出口。NE 只接管“哪些设备流量进 utun”，并不会
	// 替 sing-box 的 direct/DNS 出站选择 Wi-Fi/蜂窝接口；移动端由 NWPathMonitor
	// 经 PlatformInterface 提供接口信息。
	route["auto_detect_interface"] = true
	if len(ruleSetResources) > 0 {
		route["rule_set"] = ruleSetResources
	}
	tailscaleDNSTag := firstString(tailscaleTags)
	dnsConfig := buildDNS(tailscaleDNSTag)
	if platform == PlatformNE {
		dnsConfig = buildNEDNS(tailscaleTags)
	}

	cfg := SingBoxConfig{
		Log: map[string]interface{}{
			"level": "info",
		},
		DNS:       dnsConfig,
		Endpoints: endpoints,
		Inbounds: []map[string]interface{}{
			buildTUNInbound(vpnServerIP, platform),
		},
		Outbounds:    outbounds,
		Route:        route,
		Experimental: buildExperimental(platform, basePath),
	}

	return json.MarshalIndent(cfg, "", "  ")
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

// buildExperimental 组装 experimental 块。
//
// macOS 模式:clash_api(TCP controller)+ cache_file(相对路径,子进程 cwd 下)。
// NE 模式:扩展进程内存预算极紧(~15MB),不开 clash_api;cache_file 用沙盒内绝对
// 路径,库内运行没有子进程 cwd,相对路径会落到只读的 app bundle 目录。
func buildExperimental(platform Platform, basePath string) map[string]interface{} {
	cachePath := "cache.db"
	if platform == PlatformNE {
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
	addresses := []string{"198.18.0.1/15"}
	if platform == PlatformNE {
		// 把 IPv6 一并接入 packetFlow。AnyConnect bridge 当前仅支持 IPv4，
		// 因而纯 IPv6 目标会在 vpn outbound 明确失败；关键是不能绕过隧道直出。
		addresses = append(addresses, "fd00::1/126")
	}
	inbound := map[string]interface{}{
		"type":    "tun",
		"tag":     "tun-in",
		"address": addresses,
		"mtu":     9000,
	}
	// NE 模式由 gVisor 在进程内终止来自 packetFlow 的连接。明确指定 stack，确保
	// 发布包若漏掉 with_gvisor 构建标签会在启动阶段直接失败，而不是静默退回到
	// 依赖系统接口名称的 system stack 后假连接。
	if platform == PlatformNE {
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

func buildDNS(tailscaleTag string) map[string]interface{} {
	servers := []map[string]interface{}{{"tag": "system", "type": "local"}}
	if tailscaleTag == "" {
		return map[string]interface{}{"servers": servers}
	}
	servers = append(servers, map[string]interface{}{
		"type":     "tailscale",
		"tag":      "tailscale-dns",
		"endpoint": tailscaleTag,
	})
	return map[string]interface{}{
		"servers": servers,
		"rules": []map[string]interface{}{
			{"ip_accept_any": true, "server": "tailscale-dns"},
		},
	}
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
		servers = append(servers, map[string]interface{}{
			"type":                     "tailscale",
			"tag":                      serverTag,
			"endpoint":                 endpointTag,
			"accept_default_resolvers": false,
		})
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
	return map[string]interface{}{
		"servers": servers,
		"final":   mobileDispatcherDNSTag,
	}
}

func mobileTailscaleDNSTag(endpointTag string) string {
	return "xdial-dns-" + endpointTag
}

func buildSystemRouteRules(dnsOutbound string, includeDesktopDiagnostics bool) []map[string]interface{} {
	rules := []map[string]interface{}{
		{"action": "sniff"},
		{"protocol": "dns", "action": "route", "outbound": dnsOutbound},
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

func buildTailscalePreferredRouteRules(tailscaleTags []string) []map[string]interface{} {
	var rules []map[string]interface{}
	for _, tag := range tailscaleTags {
		rules = append(rules, map[string]interface{}{
			"preferred_by": tag,
			"action":       "route",
			"outbound":     tag,
		})
	}
	return rules
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
			if line == nil {
				continue
			}
			outTag = resolveOutboundTag(line)
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
		return map[string]interface{}{
			"rule_set": sbRuleSetTag(c),
			"outbound": outTag,
		}
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

// sbCollectRuleSets 收集 sing-box 配置层的 rule_set 资源块（route.rule_set 数组里
// 的 remote 规则集下载条目）。
//
// 命名前缀 sb 用来把这一层（sing-box 配置里的 rule_set，处理远程 .srs/.json
// 下载资源）与新的数据模型层 RuleSet（本仓库自己的“规则”概念）区分开：二者
// 语义不同，前者是 sing-box 协议字段，后者是我们的持久化数据类型。本函数遍历
// 数据模型的 RuleSet（URL 类型），为每个生成一个 sing-box rule_set 资源。
func sbCollectRuleSets(profile *Profile, mode *Mode) []map[string]interface{} {
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
				"download_detour": "direct",
			})
		}
	}
	return sets
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
				if platform != PlatformNE {
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
			if platform != PlatformNE {
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
	ID       string          `json:"id"`
	Name     string          `json:"name"`
	Strategy string          `json:"strategy"`
	Nodes    []RuntimeMember `json:"nodes"`
	Groups   []RuntimeGroup  `json:"groups"`
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

func BuildSubscriptionRuntimeCatalog(profile *Profile, platform Platform) RuntimeSubscriptionCatalog {
	catalog := RuntimeSubscriptionCatalog{Subscriptions: []RuntimeSubscription{}}
	for index := range profile.Subscriptions {
		subscription := &profile.Subscriptions[index]
		if !subscription.Enabled {
			continue
		}
		generated, _, groupTags := buildSubscriptionOutbounds(subscription, platform)
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
			Nodes: []RuntimeMember{}, Groups: []RuntimeGroup{},
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

// buildSubscriptionRules 将订阅的规则转换为 sing-box route rules 和 rule_sets
func buildSubscriptionRules(sub *Subscription, groupTags map[string]string) ([]map[string]interface{}, []map[string]interface{}) {
	var rules []map[string]interface{}
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
			rules = append(rules, subRouteRule("domain_suffix", []string{r.Value}, outTag))
		case "DOMAIN":
			rules = append(rules, subRouteRule("domain", []string{r.Value}, outTag))
		case "DOMAIN-KEYWORD":
			rules = append(rules, subRouteRule("domain_keyword", []string{r.Value}, outTag))
		case "IP-CIDR", "IP-CIDR6":
			rules = append(rules, subRouteRule("ip_cidr", []string{r.Value}, outTag))
		case "GEOIP":
			// sing-box 1.12 移除了内置 geoip，转换为远程 rule-set
			code := strings.ToLower(r.Value)
			if code == "private" || code == "lan" {
				// Clash 常用 GEOIP,LAN 表达私有地址；sing-box 对应原生
				// ip_is_private，不应为它构造一个不存在的远程国家规则集。
				rules = append(rules, subRouteRule("ip_is_private", true, outTag))
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
			rules = append(rules, subRouteRule("rule_set", setTag, outTag))
		case "FINAL":
			// FINAL 不生成 route rule，由 sing-box 的 "final" 字段处理
			continue
		}
	}
	return rules, sets
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
	}
	return nil
}
