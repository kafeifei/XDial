package config

import (
	"encoding/json"
	"fmt"
	"path"
	"strings"
)

type SingBoxConfig struct {
	Log          map[string]interface{}   `json:"log"`
	DNS          map[string]interface{}   `json:"dns"`
	Inbounds     []map[string]interface{} `json:"inbounds"`
	Outbounds    []map[string]interface{} `json:"outbounds"`
	Route        map[string]interface{}   `json:"route"`
	Experimental map[string]interface{}   `json:"experimental,omitempty"`
}

// 测试 IP 信息的域名（流量走 selector 出口组）
var testDomains = []string{"ip.sb", "ipinfo.io", "ip-api.com"}

const (
	testSelectorTag    = "test-out"
	clashAPIController = "127.0.0.1:9090"
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
// auto_route/strict_route/stack/route_exclude_address/auto_detect_interface,也不开
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

	outbounds := []map[string]interface{}{
		{"type": "direct", "tag": "direct"},
		vpnOutbound,
	}

	for _, line := range profile.Lines {
		if !line.Enabled || line.Type == LineTypeDirect || line.Type == LineTypeVPN {
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
		if !sub.Enabled || len(sub.Lines) == 0 {
			continue
		}
		obs, mainTag, groupTags := buildSubscriptionOutbounds(&sub)
		if mainTag != "" {
			outbounds = append(outbounds, obs...)
			subTagMap[sub.ID] = mainTag
			subGroupTagMap[sub.ID] = groupTags
		}
	}

	// selector 出口组：包含所有有效线路和订阅组
	selectorMembers := []string{"direct", "vpn"}
	for _, ob := range outbounds {
		tag, _ := ob["tag"].(string)
		if tag == "direct" || tag == "vpn" {
			continue
		}
		selectorMembers = append(selectorMembers, tag)
	}
	outbounds = append(outbounds, map[string]interface{}{
		"type":      "selector",
		"tag":       testSelectorTag,
		"outbounds": selectorMembers,
		"default":   "direct",
	})

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

	routeRules := buildSystemRouteRules()
	ruleSetResources := sbCollectRuleSets(profile, mode)

	// 订阅自带规则在模式规则之前（让订阅的分组规则优先匹配）
	for _, sub := range profile.Subscriptions {
		if !sub.Enabled {
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

	// 模式规则作为兜底（引用不存在的 outbound 时跳过）
	modeRules := buildModeRouteRules(profile, mode, subTagMap, validTags)
	routeRules = append(routeRules, modeRules...)

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
	// auto_detect_interface 是桌面专属:选物理网卡。NE 模式下路由由平台层
	// (NEPacketTunnelNetworkSettings)接管,不生成此字段。
	if platform == PlatformMacOS {
		route["auto_detect_interface"] = true
	}
	if len(ruleSetResources) > 0 {
		route["rule_set"] = ruleSetResources
	}

	cfg := SingBoxConfig{
		Log: map[string]interface{}{
			"level": "info",
		},
		DNS: buildDNS(),
		Inbounds: []map[string]interface{}{
			buildTUNInbound(vpnServerIP, platform),
		},
		Outbounds:    outbounds,
		Route:        route,
		Experimental: buildExperimental(platform, basePath),
	}

	return json.MarshalIndent(cfg, "", "  ")
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
	inbound := map[string]interface{}{
		"type":    "tun",
		"tag":     "tun-in",
		"address": []string{"198.18.0.1/15"},
		"mtu":     9000,
	}
	// NE 模式只保留最小 tun inbound(type/address/mtu);auto_route/strict_route/
	// stack/route_exclude_address 都是桌面自建 tun 抓包才需要的,NE 下读包来源是
	// 系统 packetFlow,路由控制交给平台层,不是这个函数的职责。
	if platform == PlatformNE {
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

func buildDNS() map[string]interface{} {
	return map[string]interface{}{
		"servers": []map[string]interface{}{
			{
				"tag":  "system",
				"type": "local",
			},
		},
	}
}

func buildSystemRouteRules() []map[string]interface{} {
	return []map[string]interface{}{
		{"action": "sniff"},
		{"protocol": "dns", "action": "route", "outbound": "direct"},
		{"domain_suffix": testDomains, "outbound": testSelectorTag},
	}
}

func buildModeRouteRules(profile *Profile, mode *Mode, subTagMap map[string]string, validTags map[string]bool) []map[string]interface{} {
	var rules []map[string]interface{}

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
			rules = append(rules, routeRule)
		}
	}

	return rules
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
		sets = append(sets, map[string]interface{}{
			"type":            "remote",
			"tag":             tag,
			"format":          format,
			"url":             c.URL,
			"download_detour": "direct",
		})
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
		case "srs":
			return "binary"
		case "json":
			return "source"
		default:
			return c.Format
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
	default:
		return "proxy-" + line.ID
	}
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
func buildSubscriptionOutbounds(sub *Subscription) ([]map[string]interface{}, string, map[string]string) {
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
		// 2a. 有策略组：每个策略组生成一个 outbound
		// 先注册所有组名 tag，以便组间互相引用。
		// slugify 把非 ASCII 全映射为 '-'，中文组名（香港节点/台湾节点→"----"）会
		// 撞成同一 tag，导致 sing-box 因 duplicate outbound tag 拒绝启动（表现为假连接）。
		// 去重：首个组保留无后缀 base（Swift NetworkInfo 只按第一个组算 tag，保持兼容），
		// 撞车/同名组追加 -N。
		usedTags := map[string]bool{}
		for _, g := range sub.ProxyGroups {
			if _, exists := groupTags[g.Name]; exists {
				continue // 同名组只保留第一个
			}
			base := "sub-" + prefix + slugify(g.Name)
			tag := base
			for i := 2; usedTags[tag]; i++ {
				tag = fmt.Sprintf("%s-%d", base, i)
			}
			usedTags[tag] = true
			groupTags[g.Name] = tag
		}
		// "DIRECT" / "Direct" 映射到内置 direct
		nameToTag["DIRECT"] = "direct"
		nameToTag["Direct"] = "direct"

		for _, g := range sub.ProxyGroups {
			var memberTags []string
			hasReject := false
			for _, name := range g.Proxies {
				if isRejectName(name) {
					// REJECT 是拦截策略，不是 outbound，不能作 selector 成员；
					// 记下拦截意图，供纯拦截组保留 rejectTag 哨兵用
					hasReject = true
					continue
				}
				if tag, ok := nameToTag[name]; ok {
					memberTags = append(memberTags, tag)
				} else if tag, ok := groupTags[name]; ok && tag != rejectTag {
					memberTags = append(memberTags, tag)
				}
			}
			if len(memberTags) == 0 {
				if hasReject {
					// 纯拦截组（如广告组 proxies:[REJECT]）：不生成 outbound，但保留
					// 组名→哨兵映射，让指向它的订阅规则翻译成 action:reject 而非被丢弃
					groupTags[g.Name] = rejectTag
				} else {
					// 没有任何有效成员就不生成 outbound，同时从 groupTags 移除，
					// 避免 mainTag / subscription rules 后续引用一个不存在的 tag
					delete(groupTags, g.Name)
				}
				continue
			}

			ob := map[string]interface{}{
				"tag":       groupTags[g.Name],
				"outbounds": memberTags,
			}
			switch g.Type {
			case "url-test", "urltest":
				ob["type"] = "urltest"
				url := g.URL
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
		default:
			group["type"] = "urltest"
			url := sub.TestURL
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
			setTag := "sub-geoip-" + sub.ID + "-" + code
			if !seenGeoIP[setTag] {
				seenGeoIP[setTag] = true
				sets = append(sets, map[string]interface{}{
					"type":            "remote",
					"tag":             setTag,
					"format":          "binary",
					"url":             "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-" + code + ".srs",
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
		if line.TrojanServer == "" {
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
		if line.SSServer == "" {
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
		if line.VMessServer == "" {
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
