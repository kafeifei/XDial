package config

// invariants_test.go —— 把 XDial 架构约束写成 CI 门禁。
//
// 这里的每个测试守护一条架构约束条款，而不是某个函数的实现细节。它们的存在意义是：
// 任何“看起来很合理”的生成器改动，只要破坏了密封律 / 正交律 / DNS 归属，
// 都必须在这里变红，而不是等到用户机器上表现为“连上了但全断”。
//
// 命名约定：本文件所有 helper 以 inv 前缀开头，避免与 generator_test.go /
// generator_integration_test.go 里的同包 helper 撞名。
//
// 与生产代码的耦合纪律：允许调用 resolveOutboundTag / sbRuleSetTag /
// BuildSubscriptionRuntimeCatalog 这类**命名映射**函数（它们就是“tag 怎么叫”的
// 单一事实源，测试重写一遍只会漂移）；但绝不调用 buildModeRouteRules /
// buildDNS 这类**裁决逻辑**函数——否则断言会退化成“生成器等于它自己”。

import (
	"encoding/json"
	"reflect"
	"sort"
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// 公共夹具
// ---------------------------------------------------------------------------

const (
	invSocksPort   = 11080
	invVPNServerIP = "203.0.113.9"
	invBasePath    = "/tmp/xdial-invariants"
	invUnderlay    = "utun-underlay"
)

// invEnterpriseDNS 模拟 AnyConnect 隧道建立后服务端下发的企业 DNS。
// 桌面路径（GenerateSingBoxDesktop）永远是“先拨通再生成配置”，所以测试也必须带上它，
// 否则 enterprise-dns 分支根本不会出现，INV2/INV7 会因为“空配置”而假绿。
var invEnterpriseDNS = []string{"10.1.1.53"}

// invBaseProfile 是一份最小但覆盖三类出口的基准 profile：
// 内网手动规则 → AnyConnect 线路，公网 URL 规则 → trojan 线路，默认直连。
func invBaseProfile() *Profile {
	return &Profile{
		Lines: []Line{
			{ID: "direct", Name: "直连", Type: LineTypeDirect, Enabled: true},
			{ID: "corp", Name: "公司 VPN", Type: LineTypeVPN, Enabled: true,
				VPNServer: "vpn.example.com:443", VPNUsername: "user"},
			{ID: "px", Name: "海外中转", Type: LineTypeTrojan, Enabled: true,
				TrojanServer: "px.example.com", TrojanPort: 443,
				TrojanPassword: "secret", TrojanSNI: "px.example.com"},
		},
		RuleSets: []RuleSet{
			{ID: "intranet", Name: "内网", Type: RuleSetTypeManual, Enabled: true,
				Domains: []string{"corp.example"}, CIDRs: []string{"10.0.0.0/8"}},
			{ID: "remote", Name: "远程规则集", Type: RuleSetTypeURL, Enabled: true,
				URL: "https://example.com/rules.srs"},
		},
		Modes: []Mode{{
			ID: "m", Name: "默认模式",
			Bindings: []RuleBinding{
				{RuleSetID: "intranet", LineID: "corp"},
				{RuleSetID: "remote", LineID: "px"},
			},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "m",
	}
}

// invTailscaleLine 模拟旧桌面 Profile 中残留的内置 Tailscale 线路。
func invTailscaleLine() Line {
	return Line{ID: "ts", Name: "Tailnet", Type: LineTypeTailscale, Enabled: true}
}

// invUnusedTrojanLine 是一条 enabled 但不被任何 active Mode 引用的线路。
func invUnusedTrojanLine() Line {
	return Line{ID: "ghost", Name: "闲置节点", Type: LineTypeTrojan, Enabled: true,
		TrojanServer: "ghost.example.com", TrojanPort: 8443,
		TrojanPassword: "ghost", TrojanSNI: "ghost.example.com"}
}

// invUnusedRuleSet 是一份 enabled 但不被任何 active Mode 引用的规则集。
func invUnusedRuleSet() RuleSet {
	return RuleSet{ID: "ghost-rs", Name: "闲置规则", Type: RuleSetTypeManual, Enabled: true,
		Domains: []string{"ghost.example"}, CIDRs: []string{"192.0.2.0/24"}}
}

// invUnusedSubscription 是一份 enabled 但不被任何 active Mode 引用的订阅（自带规则）。
func invUnusedSubscription() Subscription {
	return Subscription{
		ID: "ghost-sub", Name: "闲置订阅", URL: "https://example.com/sub", Enabled: true,
		Lines: []Line{
			{ID: "n1", Name: "GhostNode", Type: LineTypeTrojan, Enabled: true,
				TrojanServer: "n1.example.com", TrojanPort: 443,
				TrojanPassword: "n1", TrojanSNI: "n1.example.com"},
		},
		Rules: []SubscriptionRule{
			{Type: "DOMAIN-SUFFIX", Value: "ghostsub.example", Group: "__default__"},
		},
	}
}

// invReferencedSubscription 是一份被 active Mode 显式绑定的订阅。
func invReferencedSubscription() Subscription {
	return Subscription{
		ID: "sub1", Name: "主订阅", URL: "https://example.com/sub1", Enabled: true,
		Lines: []Line{
			{ID: "n1", Name: "HK", Type: LineTypeTrojan, Enabled: true,
				TrojanServer: "hk.example.com", TrojanPort: 443,
				TrojanPassword: "hk", TrojanSNI: "hk.example.com"},
		},
		Rules: []SubscriptionRule{
			{Type: "DOMAIN-SUFFIX", Value: "stream.example", Group: "__default__"},
			{Type: "IP-CIDR", Value: "198.51.100.0/24", Group: "__default__"},
			{Type: "GEOIP", Value: "LAN", Group: "DIRECT"},
		},
	}
}

// invStreamRuleSet 是绑定到订阅的那条规则集。
func invStreamRuleSet() RuleSet {
	return RuleSet{ID: "stream", Name: "流媒体", Type: RuleSetTypeManual, Enabled: true,
		Domains: []string{"video.example"}}
}

// invGenerateDesktop 生成桌面配置并解析成 map；生成失败即 Fatal。
func invGenerateDesktop(t *testing.T, profile *Profile) map[string]interface{} {
	t.Helper()
	data, err := GenerateSingBoxDesktop(profile, invSocksPort, invVPNServerIP, invBasePath, invEnterpriseDNS, invUnderlay)
	if err != nil {
		t.Fatalf("GenerateSingBoxDesktop 失败: %v", err)
	}
	var cfg map[string]interface{}
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatalf("生成的配置不是合法 JSON: %v", err)
	}
	return cfg
}

// ---------------------------------------------------------------------------
// JSON 规范化：无序数组按稳定 key 排序，让语义等价的两份配置可以 DeepEqual
// ---------------------------------------------------------------------------

// invNormalize 就地规范化配置：把**语义上无序**的数组按 tag 排序。
//
// 明确不排序 route.rules / dns.rules —— 它们是有序裁决链，顺序就是语义。
func invNormalize(cfg map[string]interface{}) {
	invSortByTag(cfg["outbounds"])
	invSortByTag(cfg["endpoints"])
	if dns, ok := cfg["dns"].(map[string]interface{}); ok {
		invSortByTag(dns["servers"])
	}
	if route, ok := cfg["route"].(map[string]interface{}); ok {
		invSortByTag(route["rule_set"])
	}
}

func invSortByTag(value interface{}) {
	array, ok := value.([]interface{})
	if !ok {
		return
	}
	sort.SliceStable(array, func(i, j int) bool {
		return invTagOf(array[i]) < invTagOf(array[j])
	})
}

func invTagOf(value interface{}) string {
	object, ok := value.(map[string]interface{})
	if !ok {
		return ""
	}
	tag, _ := object["tag"].(string)
	return tag
}

func invPretty(value interface{}) string {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return "<无法序列化>"
	}
	return string(data)
}

// ---------------------------------------------------------------------------
// 通用小工具
// ---------------------------------------------------------------------------

func invStrings(value interface{}) []string {
	switch typed := value.(type) {
	case string:
		return []string{typed}
	case []interface{}:
		out := make([]string, 0, len(typed))
		for _, element := range typed {
			if s, ok := element.(string); ok {
				out = append(out, s)
			}
		}
		return out
	}
	return nil
}

func invSameStringSet(got []string, want []string) bool {
	if len(got) != len(want) {
		return false
	}
	a := append([]string(nil), got...)
	b := append([]string(nil), want...)
	sort.Strings(a)
	sort.Strings(b)
	return reflect.DeepEqual(a, b)
}

func invContainsAll(got []string, want []string) bool {
	index := make(map[string]bool, len(got))
	for _, s := range got {
		index[s] = true
	}
	for _, s := range want {
		if !index[s] {
			return false
		}
	}
	return true
}

func invRouteRules(t *testing.T, cfg map[string]interface{}) []map[string]interface{} {
	t.Helper()
	route, ok := cfg["route"].(map[string]interface{})
	if !ok {
		t.Fatalf("配置缺少 route 块")
	}
	return invObjectArray(route["rules"])
}

func invDNSServers(t *testing.T, cfg map[string]interface{}) []map[string]interface{} {
	t.Helper()
	dns, ok := cfg["dns"].(map[string]interface{})
	if !ok {
		t.Fatalf("配置缺少 dns 块")
	}
	return invObjectArray(dns["servers"])
}

func invDNSRules(cfg map[string]interface{}) []map[string]interface{} {
	dns, ok := cfg["dns"].(map[string]interface{})
	if !ok {
		return nil
	}
	return invObjectArray(dns["rules"])
}

func invObjectArray(value interface{}) []map[string]interface{} {
	array, ok := value.([]interface{})
	if !ok {
		return nil
	}
	out := make([]map[string]interface{}, 0, len(array))
	for _, element := range array {
		if object, ok := element.(map[string]interface{}); ok {
			out = append(out, object)
		}
	}
	return out
}

// invActiveOutboundTags 返回 active Mode **显式引用**的出口 tag 集合。
// 这是“归属追溯”的唯一合法来源：任何 DNS server / route rule 指向集合外的 tag，
// 都意味着生成器凭空造了一个用户看不见的出口。
func invActiveOutboundTags(profile *Profile) map[string]bool {
	tags := map[string]bool{}
	mode := profile.ActiveMode()
	if mode == nil {
		return tags
	}
	add := func(lineID, subscriptionID string) {
		if subscriptionID != "" {
			if tag := invSubscriptionMainTag(profile, subscriptionID); tag != "" {
				tags[tag] = true
			}
			return
		}
		if lineID == "" {
			return
		}
		if line := profile.FindLine(lineID); line != nil && line.Enabled {
			tags[resolveOutboundTag(line)] = true
		}
	}
	add(mode.DefaultLineID, mode.DefaultSubscriptionID)
	for _, binding := range mode.Bindings {
		ruleSet := profile.FindRuleSet(binding.RuleSetID)
		if ruleSet == nil || !ruleSet.Enabled {
			continue
		}
		add(binding.LineID, binding.SubscriptionID)
	}
	return tags
}

// invSubscriptionMainTag 借用运行时目录（生产代码里“订阅 tag 怎么命名”的事实源）
// 拿到订阅的主策略组 tag，避免在测试里重写一遍 slugify/去重规则。
func invSubscriptionMainTag(profile *Profile, subscriptionID string) string {
	catalog := BuildSubscriptionRuntimeCatalog(profile, PlatformMacOS)
	for _, subscription := range catalog.Subscriptions {
		if subscription.ID != subscriptionID {
			continue
		}
		if len(subscription.Groups) > 0 {
			return subscription.Groups[0].Tag
		}
	}
	return ""
}

// invActiveSubscriptions 返回 active Mode 显式引用且 enabled 的订阅。
func invActiveSubscriptions(profile *Profile) []*Subscription {
	mode := profile.ActiveMode()
	if mode == nil {
		return nil
	}
	ids := map[string]bool{}
	if mode.DefaultSubscriptionID != "" {
		ids[mode.DefaultSubscriptionID] = true
	}
	for _, binding := range mode.Bindings {
		ruleSet := profile.FindRuleSet(binding.RuleSetID)
		if ruleSet == nil || !ruleSet.Enabled || binding.SubscriptionID == "" {
			continue
		}
		ids[binding.SubscriptionID] = true
	}
	var out []*Subscription
	for index := range profile.Subscriptions {
		subscription := &profile.Subscriptions[index]
		if ids[subscription.ID] && subscription.Enabled {
			out = append(out, subscription)
		}
	}
	return out
}

// ===========================================================================
// INV1 —— 内部正交律：未被 active Mode 引用的对象不得影响本机流量决策
// ===========================================================================
//
// 守护：架构约束「内部正交律」+「声明≠生效」。Line/RuleSet/订阅可以存在于 profile 里
// （用户配了但没启用到当前模式），但只要 active Mode 没引用它，生成的数据面配置
// 就必须逐字节语义等价。
//
// 什么改动会让它变红：
//   - 生成器改成“所有 enabled 线路都生成 outbound”（历史上出现过，会让半成品节点
//     在 box.New 阶段拖垮整个模式）；
//   - 订阅规则改成“只要订阅 enabled 就注入 route.rules”（隐式抢注，违反 D28）；
//   - 任何形式的 preferred_by / 自动接管。
func TestINV1_UnreferencedObjectsDoNotAffectGeneratedConfig(t *testing.T) {
	baseline := invGenerateDesktop(t, invBaseProfile())
	invNormalize(baseline)

	cases := []struct {
		name   string
		mutate func(*Profile)
	}{
		{
			name: "加入未被引用的 enabled trojan 线路",
			mutate: func(p *Profile) {
				p.Lines = append(p.Lines, invUnusedTrojanLine())
			},
		},
		{
			name: "加入未被引用的旧 Tailscale 线路",
			mutate: func(p *Profile) {
				p.Lines = append(p.Lines, invTailscaleLine())
			},
		},
		{
			name: "加入未被引用的 enabled 规则集",
			mutate: func(p *Profile) {
				p.RuleSets = append(p.RuleSets, invUnusedRuleSet())
			},
		},
		{
			name: "加入未被引用的 enabled 订阅（自带规则）",
			mutate: func(p *Profile) {
				p.Subscriptions = append(p.Subscriptions, invUnusedSubscription())
			},
		},
		{
			name: "三者同时加入",
			mutate: func(p *Profile) {
				p.Lines = append(p.Lines, invUnusedTrojanLine())
				p.RuleSets = append(p.RuleSets, invUnusedRuleSet())
				p.Subscriptions = append(p.Subscriptions, invUnusedSubscription())
			},
		},
	}

	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			profile := invBaseProfile()
			testCase.mutate(profile)
			got := invGenerateDesktop(t, profile)
			invNormalize(got)
			if !reflect.DeepEqual(baseline, got) {
				t.Fatalf("未被引用的对象改变了生成配置（违反内部正交律）\n--- 基准 ---\n%s\n--- 实际 ---\n%s",
					invPretty(baseline), invPretty(got))
			}
		})
	}
}

// INV1c —— 桌面 Tailscale 不再享有任何例外。
//
// 官方 Tailscale 客户端只能作为 XDial 启动前已经存在的 Underlay。旧 profile
// 里残留但未被 Mode 引用的 Tailscale Line 必须和不存在逐字节等价。
func TestINV1c_DesktopTailscaleHasNoException(t *testing.T) {
	baseline := invGenerateDesktop(t, invBaseProfile())
	invNormalize(baseline)

	profile := invBaseProfile()
	profile.Lines = append(profile.Lines, invTailscaleLine())
	got := invGenerateDesktop(t, profile)
	invNormalize(got)
	if !reflect.DeepEqual(baseline, got) {
		t.Fatalf("旧 Tailscale 线路在桌面生成物中留下痕迹\n--- 基准 ---\n%s\n--- 实际 ---\n%s",
			invPretty(baseline), invPretty(got))
	}

	active := invBaseProfile()
	active.Lines = append(active.Lines, invTailscaleLine())
	active.Modes[0].DefaultLineID = "ts"
	if _, err := GenerateSingBoxDesktop(active, invSocksPort, invVPNServerIP, invBasePath, invEnterpriseDNS, invUnderlay); err == nil {
		t.Fatal("active 的旧 Tailscale 线路应在桌面生成阶段被明确拒绝")
	}
}

// ===========================================================================
// INV2 —— DNS 归属：每个 dns.server 都必须有主
// ===========================================================================
//
// 守护：架构约束「DNS 原理：名字→线路→地址」+「解析权随线路走」。
// 每一个 dns.servers 条目要么属于显式的全局默认白名单（系统解析器 / 公共 fallback /
// bootstrap），要么必须能追溯到 active Mode 引用的某条 Line。
//
// 什么改动会让它变红：给某条“存在但没被引用”的线路生成解析器，或者硬编码
// 一个新的公共 DNS 而不进白名单。
func TestINV2_EveryDNSServerTracesToAnActiveLine(t *testing.T) {
	// 全局默认白名单：这三类不属于任何 Line，是盒子自身的基础设施。
	//   system     —— type:local，仅作诊断对照，不当默认（见 generator.go 注释）
	//   public-dns —— 桌面 final 解析器 / 出站域名 bootstrap（IP 直连 DoH）
	globalDefaults := map[string]string{
		"system":     "系统解析器（诊断对照用，非默认）",
		"public-dns": "桌面 final + 出站域名 bootstrap",
	}

	cases := []struct {
		name    string
		profile func() *Profile
	}{
		{
			name:    "基准 profile（VPN + trojan + 直连）",
			profile: invBaseProfile,
		},
		{
			name: "Tailscale 线路 enabled 但未被引用",
			profile: func() *Profile {
				p := invBaseProfile()
				p.Lines = append(p.Lines, invTailscaleLine())
				return p
			},
		},
		{
			name: "订阅被 active Mode 显式绑定",
			profile: func() *Profile {
				p := invBaseProfile()
				p.RuleSets = append(p.RuleSets, invStreamRuleSet())
				p.Subscriptions = append(p.Subscriptions, invReferencedSubscription())
				p.Modes[0].Bindings = append(p.Modes[0].Bindings,
					RuleBinding{RuleSetID: "stream", SubscriptionID: "sub1"})
				return p
			},
		},
	}

	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			profile := testCase.profile()
			cfg := invGenerateDesktop(t, profile)

			activeTags := invActiveOutboundTags(profile)
			// 企业 DNS 的归属：active Mode 里存在“手动规则集 → enabled AnyConnect 线路”的绑定。
			enterpriseOwned := len(collectVPNBoundDomains(profile, profile.ActiveMode())) > 0

			for _, server := range invDNSServers(t, cfg) {
				tag, _ := server["tag"].(string)
				if _, ok := globalDefaults[tag]; ok {
					continue
				}
				switch {
				case tag == desktopEnterpriseDNSTag:
					if !enterpriseOwned {
						t.Errorf("无主 DNS server %q：active Mode 没有任何绑定到 AnyConnect 线路的手动规则集", tag)
					}
				case strings.HasPrefix(tag, "proxy-dns-"):
					detour := strings.TrimPrefix(tag, "proxy-dns-")
					if !activeTags[detour] {
						t.Errorf("无主 DNS server %q：出口 %q 不在 active Mode 引用的线路集合 %v 里",
							tag, detour, activeTags)
					}
				default:
					t.Errorf("无主 DNS server %q：既不在全局默认白名单，也追溯不到任何 active Line\n%s",
						tag, invPretty(server))
				}
			}
		})
	}
}

// ===========================================================================
// INV3 —— 外部密封律：DNS 绝不溢出到系统层
// ===========================================================================
//
// 守护：架构约束「外部密封律」。桌面配置必须自己劫持并应答 DNS；一旦把原始 DNS 包
// 以 route→direct 的形式放出盒外，启动前 Underlay 使用的 resolver 可能只在下层
// 虚拟网络内可达，接管路由的瞬间就会形成解析黑洞。
//
// 什么改动会让它变红：把 hijack-dns 换成 route/direct、或新增一条“DNS 协议直出”的
// 例外规则（无论理由是“兼容企业 DNS”还是“调试方便”）。
func TestINV3_DesktopSealsDNSInsideTheBox(t *testing.T) {
	cases := []struct {
		name    string
		profile func() *Profile
	}{
		{"基准 profile", invBaseProfile},
		{
			name: "带订阅",
			profile: func() *Profile {
				p := invBaseProfile()
				p.RuleSets = append(p.RuleSets, invStreamRuleSet())
				p.Subscriptions = append(p.Subscriptions, invReferencedSubscription())
				p.Modes[0].Bindings = append(p.Modes[0].Bindings,
					RuleBinding{RuleSetID: "stream", SubscriptionID: "sub1"})
				return p
			},
		},
	}

	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			cfg := invGenerateDesktop(t, testCase.profile())
			rules := invRouteRules(t, cfg)

			hijacked := false
			for _, rule := range rules {
				if rule["protocol"] == "dns" && rule["action"] == "hijack-dns" {
					hijacked = true
				}
				// 任何“DNS 协议 → 某个 outbound”的规则都是把 DNS 放出盒外。
				if rule["protocol"] == "dns" {
					if outbound, ok := rule["outbound"].(string); ok {
						t.Errorf("DNS 溢出：route rule 把 DNS 协议路由到 outbound %q\n%s",
							outbound, invPretty(rule))
					}
					if action, ok := rule["action"].(string); ok && action == "route" {
						t.Errorf("DNS 溢出：route rule 对 DNS 协议使用 action:route\n%s", invPretty(rule))
					}
				}
			}
			if !hijacked {
				t.Fatalf("缺少 hijack-dns 规则，DNS 会原样转发到物理口\n%s", invPretty(rules))
			}
		})
	}
}

// ===========================================================================
// INV4 —— 无隐藏规则：route.rules 每一条都要有出处
// ===========================================================================
//
// 守护：架构约束「Mode 是唯一裁决者」+ D28「供给出来的规则必须以一等公民身份进入 Mode
// 裁决，绝不隐式抢注」。
//
// 每条 route rule 必须属于以下三类之一：
//   (a) active Mode 的某个 binding（含 connectivity acceptance 那两条 —— 它们来自
//       用户可见 profile 的普通绑定，所以走 (a) 而不是白名单）；
//   (b) 被 Mode 引用的订阅供给的规则；
//   (c) 下面显式写死的系统规则白名单。
//
// 什么改动会让它变红：生成器为了“更好用”偷偷加一条规则（广告拦截、私有网段直连、
// 某个域名特判……）。白名单是唯一合法出口，加白名单必须是一次显式的、要过 review 的改动。

// invRuleContext 保留为白名单判定上下文；桌面当前没有带条件的系统例外。
type invRuleContext struct{}

// invSystemRuleWhitelist 系统规则白名单（逐条注明为何是系统规则）。
//
// 刻意**不在**白名单里的两类，说明如下：
//   - connectivity acceptance 规则（xdial-connectivity-direct /
//     xdial-connectivity-anyconnect）：它们是用户 profile 里真实存在的 RuleSet + Mode
//     binding，只是被生成器提到订阅规则之前而已。它们必须走 (a) 追溯；如果哪天
//     它们变成生成器凭空注入的，本测试就应该变红。
//   - 任何“默认直连私有网段 / 默认拦截广告”之类的便利规则：架构约束禁止隐式裁决。
var invSystemRuleWhitelist = []struct {
	reason string
	match  func(rule map[string]interface{}, ctx invRuleContext) bool
}{
	{
		// sniff 只做协议/域名识别，不选出口，不参与裁决，因此不算隐藏规则。
		reason: "sniff：协议嗅探，不裁决出口",
		match: func(rule map[string]interface{}, _ invRuleContext) bool {
			return len(rule) == 1 && rule["action"] == "sniff"
		},
	},
	{
		// hijack-dns 是外部密封律的实现本身（见 INV3），不是分流裁决。
		reason: "hijack-dns：外部密封律要求 DNS 在盒内应答",
		match: func(rule map[string]interface{}, _ invRuleContext) bool {
			return len(rule) == 2 && rule["protocol"] == "dns" && rule["action"] == "hijack-dns"
		},
	},
	{
		// 桌面「逐线路查公网地址」诊断：把探测域名导向 test-out selector，
		// 由 Clash API 临时切换成员。仅桌面存在，且只覆盖固定的 testDomains。
		reason: "诊断：testDomains → test-out selector（桌面逐线路公网地址探测）",
		match: func(rule map[string]interface{}, _ invRuleContext) bool {
			return rule["outbound"] == testSelectorTag &&
				invSameStringSet(invStrings(rule["domain_suffix"]), testDomains)
		},
	},
}

// invMatchesModeBinding 判断规则是否由 active Mode 的某条 binding 产生。
func invMatchesModeBinding(profile *Profile, rule map[string]interface{}) bool {
	mode := profile.ActiveMode()
	if mode == nil {
		return false
	}
	for _, binding := range mode.Bindings {
		ruleSet := profile.FindRuleSet(binding.RuleSetID)
		if ruleSet == nil || !ruleSet.Enabled {
			continue
		}
		var expectedTag string
		if binding.SubscriptionID != "" {
			expectedTag = invSubscriptionMainTag(profile, binding.SubscriptionID)
		} else {
			line := profile.FindLine(binding.LineID)
			if line == nil {
				continue
			}
			expectedTag = resolveOutboundTag(line)
		}
		if expectedTag == "" || rule["outbound"] != expectedTag {
			continue
		}
		switch ruleSet.Type {
		case RuleSetTypeURL:
			if rule["rule_set"] == sbRuleSetTag(ruleSet) {
				return true
			}
		case RuleSetTypeManual:
			domainsOK := len(ruleSet.Domains) == 0 ||
				invSameStringSet(invStrings(rule["domain_suffix"]), ruleSet.Domains)
			cidrsOK := len(ruleSet.CIDRs) == 0 ||
				invSameStringSet(invStrings(rule["ip_cidr"]), ruleSet.CIDRs)
			if domainsOK && cidrsOK && (len(ruleSet.Domains) > 0 || len(ruleSet.CIDRs) > 0) {
				return true
			}
		}
	}
	return false
}

// invMatchesSubscriptionRule 判断规则是否由某个被 Mode 引用的订阅供给。
//
// 这里只校验「匹配条件出自订阅的规则表」+「出口属于该订阅（或 direct / reject）」，
// 不逐字校验组名解析结果——出口正确性由 INV1/INV7 与订阅相关的既有测试覆盖，
// INV4 只回答“这条规则是不是凭空冒出来的”。
func invMatchesSubscriptionRule(profile *Profile, rule map[string]interface{}) bool {
	for _, subscription := range invActiveSubscriptions(profile) {
		outbound, hasOutbound := rule["outbound"].(string)
		if hasOutbound &&
			!strings.HasPrefix(outbound, "sub-"+subscription.ID) &&
			!strings.HasPrefix(outbound, "proxy-"+subscription.ID+"-") &&
			outbound != "direct" {
			continue
		}
		if !hasOutbound && rule["action"] != "reject" {
			continue
		}
		for _, subscriptionRule := range subscription.Rules {
			switch subscriptionRule.Type {
			case "DOMAIN-SUFFIX":
				if invSameStringSet(invStrings(rule["domain_suffix"]), []string{subscriptionRule.Value}) {
					return true
				}
			case "DOMAIN":
				if invSameStringSet(invStrings(rule["domain"]), []string{subscriptionRule.Value}) {
					return true
				}
			case "DOMAIN-KEYWORD":
				if invSameStringSet(invStrings(rule["domain_keyword"]), []string{subscriptionRule.Value}) {
					return true
				}
			case "IP-CIDR", "IP-CIDR6":
				if invSameStringSet(invStrings(rule["ip_cidr"]), []string{subscriptionRule.Value}) {
					return true
				}
			case "GEOIP":
				code := strings.ToLower(subscriptionRule.Value)
				if code == "private" || code == "lan" {
					if rule["ip_is_private"] == true {
						return true
					}
					continue
				}
				if rule["rule_set"] == "sub-geoip-"+subscription.ID+"-"+code {
					return true
				}
			}
		}
	}
	return false
}

func invClassifyRouteRule(profile *Profile, rule map[string]interface{}, ctx invRuleContext) string {
	if invMatchesModeBinding(profile, rule) {
		return "mode"
	}
	if invMatchesSubscriptionRule(profile, rule) {
		return "subscription"
	}
	for _, entry := range invSystemRuleWhitelist {
		if entry.match(rule, ctx) {
			return "system"
		}
	}
	return ""
}

func TestINV4_NoHiddenRouteRules(t *testing.T) {
	cases := []struct {
		name    string
		profile func() *Profile
	}{
		{"基准 profile", invBaseProfile},
		{
			name: "带被引用的订阅（自带规则）",
			profile: func() *Profile {
				p := invBaseProfile()
				p.RuleSets = append(p.RuleSets, invStreamRuleSet())
				p.Subscriptions = append(p.Subscriptions, invReferencedSubscription())
				p.Modes[0].Bindings = append(p.Modes[0].Bindings,
					RuleBinding{RuleSetID: "stream", SubscriptionID: "sub1"})
				return p
			},
		},
		{
			name: "connectivity acceptance 规则集（必须走 binding 追溯，不吃白名单）",
			profile: func() *Profile {
				p := invBaseProfile()
				p.RuleSets = append(p.RuleSets,
					RuleSet{ID: connectivityDirectRuleSetID, Name: "验收直连", Type: RuleSetTypeManual,
						Enabled: true, CIDRs: []string{"1.0.0.1/32"}},
					RuleSet{ID: connectivityOutboundRuleSetID, Name: "验收隧道", Type: RuleSetTypeManual,
						Enabled: true, CIDRs: []string{"1.0.0.2/32"}},
				)
				p.Modes[0].Bindings = append(p.Modes[0].Bindings,
					RuleBinding{RuleSetID: connectivityDirectRuleSetID, LineID: "direct"},
					RuleBinding{RuleSetID: connectivityOutboundRuleSetID, LineID: "corp"},
				)
				return p
			},
		},
	}

	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			profile := testCase.profile()
			cfg := invGenerateDesktop(t, profile)
			ctx := invRuleContext{}

			for index, rule := range invRouteRules(t, cfg) {
				if invClassifyRouteRule(profile, rule, ctx) == "" {
					t.Errorf("隐藏规则 route.rules[%d]：既不属于任何 Mode binding / 订阅供给，也不在系统白名单\n%s",
						index, invPretty(rule))
				}
			}
		})
	}
}

// INV4b —— 用户显式绑定优先于订阅自带规则。
//
// 守护：架构约束 D28「供给出来的规则必须以一等公民身份进入 Mode 裁决，绝不隐式抢注」。
// 订阅自带规则若排在模式普通规则之前，用户在 UI 上明明把某域名绑到了 A 线路，
// 实际却被订阅的大范围规则抢先匹配走 B —— 这是最典型的“隐式抢注”。
//
// 什么改动会让它变红：把订阅规则重新提前到模式规则之前。
func TestINV4b_ModeBindingRulesPrecedeSubscriptionSuppliedRules(t *testing.T) {
	profile := invBaseProfile()
	profile.RuleSets = append(profile.RuleSets, invStreamRuleSet())
	profile.Subscriptions = append(profile.Subscriptions, invReferencedSubscription())
	profile.Modes[0].Bindings = append(profile.Modes[0].Bindings,
		RuleBinding{RuleSetID: "stream", SubscriptionID: "sub1"})

	cfg := invGenerateDesktop(t, profile)
	ctx := invRuleContext{}

	lastModeIndex, firstSubscriptionIndex := -1, -1
	rules := invRouteRules(t, cfg)
	for index, rule := range rules {
		switch invClassifyRouteRule(profile, rule, ctx) {
		case "mode":
			lastModeIndex = index
		case "subscription":
			if firstSubscriptionIndex < 0 {
				firstSubscriptionIndex = index
			}
		}
	}
	if lastModeIndex < 0 || firstSubscriptionIndex < 0 {
		t.Fatalf("夹具没有同时产生模式规则和订阅规则（mode=%d sub=%d）\n%s",
			lastModeIndex, firstSubscriptionIndex, invPretty(rules))
	}
	if lastModeIndex > firstSubscriptionIndex {
		t.Fatalf("订阅自带规则抢在模式绑定之前：最后一条模式规则 index=%d，第一条订阅规则 index=%d\n%s",
			lastModeIndex, firstSubscriptionIndex, invPretty(rules))
	}
}

// ===========================================================================
// INV6 —— 引用完整性
// ===========================================================================
//
// 守护：铁律「失败 fail-closed 且用户可感知，绝不静默降级」。
// 悬空引用（binding 指向不存在的 RuleSet/Line/订阅）意味着用户以为配好的分流
// 根本没生效；静默跳过就是最恶劣的静默降级——流量会落到 final（通常是 direct），
// 用户完全无感。
//
// 什么改动会让它变红：把悬空引用改回 `continue` 静默跳过。
func TestINV6a_DanglingReferencesAreRejected(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*Profile)
	}{
		{
			name: "binding 指向不存在的 RuleSetID",
			mutate: func(p *Profile) {
				p.Modes[0].Bindings = append(p.Modes[0].Bindings,
					RuleBinding{RuleSetID: "nope", LineID: "px"})
			},
		},
		{
			name: "binding 指向不存在的 LineID",
			mutate: func(p *Profile) {
				p.Modes[0].Bindings[1].LineID = "nope"
			},
		},
		{
			name: "binding 指向不存在的 SubscriptionID",
			mutate: func(p *Profile) {
				p.Modes[0].Bindings[1] = RuleBinding{RuleSetID: "remote", SubscriptionID: "nope"}
			},
		},
		{
			name: "默认出口指向不存在的 LineID",
			mutate: func(p *Profile) {
				p.Modes[0].DefaultLineID = "nope"
			},
		},
		{
			name: "默认出口指向不存在的 SubscriptionID",
			mutate: func(p *Profile) {
				p.Modes[0].DefaultLineID = ""
				p.Modes[0].DefaultSubscriptionID = "nope"
			},
		},
	}

	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			profile := invBaseProfile()
			testCase.mutate(profile)
			data, err := GenerateSingBoxDesktop(profile, invSocksPort, invVPNServerIP, invBasePath, invEnterpriseDNS, invUnderlay)
			if err == nil {
				t.Fatalf("悬空引用被静默吞掉，期望返回错误。生成结果:\n%s", string(data))
			}
		})
	}
}

// INV6b —— 显式禁用（Enabled=false）不是错误，但必须让用户可感知（warning）。
//
// 与 INV6a 的区别：禁用是用户的显式意图，不该 fail；悬空是配置损坏，必须 fail。
// 但"少了一条规则"这件事绝不能悄悄发生 —— CollectProfileWarnings 必须结构化上报，
// daemon/UI 才能把"这条绑定当前没生效"展示出来。
//
// 什么改动会让它变红：把禁用也升级成 error（用户勾掉一条线路就连不上了），
// 或者反过来把 warning 悄悄删掉（回到静默降级）。
func TestINV6b_DisabledReferencesWarnButDoNotFail(t *testing.T) {
	profile := invBaseProfile()
	// px 线路被显式禁用，但 远程规则集仍绑定着它。
	for index := range profile.Lines {
		if profile.Lines[index].ID == "px" {
			profile.Lines[index].Enabled = false
		}
	}
	// intranet 规则集被显式禁用，但 binding 仍在。
	for index := range profile.RuleSets {
		if profile.RuleSets[index].ID == "intranet" {
			profile.RuleSets[index].Enabled = false
		}
	}

	data, err := GenerateSingBoxDesktop(profile, invSocksPort, invVPNServerIP, invBasePath, invEnterpriseDNS, invUnderlay)
	if err != nil {
		t.Fatalf("显式禁用不应导致生成失败: %v", err)
	}
	var cfg map[string]interface{}
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatalf("生成的配置不是合法 JSON: %v", err)
	}
	for _, outbound := range invObjectArray(cfg["outbounds"]) {
		if outbound["tag"] == "proxy-px" {
			t.Errorf("被禁用的线路仍生成了 outbound:\n%s", invPretty(outbound))
		}
	}
	for _, rule := range invRouteRules(t, cfg) {
		if invSameStringSet(invStrings(rule["domain_suffix"]), []string{"corp.example"}) {
			t.Errorf("被禁用的规则集仍生成了 route rule:\n%s", invPretty(rule))
		}
	}

	warnings, err := CollectProfileWarnings(profile)
	if err != nil {
		t.Fatalf("显式禁用不应被判为悬空引用: %v", err)
	}
	got := map[ProfileWarningKind]bool{}
	for _, warning := range warnings {
		got[warning.Kind] = true
		if warning.Message == "" {
			t.Errorf("warning 缺少可展示的中文说明: %+v", warning)
		}
		if warning.ModeID != profile.ActiveModeID {
			t.Errorf("warning 未标注所属模式: %+v", warning)
		}
	}
	for _, kind := range []ProfileWarningKind{WarningDisabledRuleSet, WarningDisabledLine} {
		if !got[kind] {
			t.Errorf("缺少 %q 类别的降级提示，用户无从得知这条绑定没生效: %+v", kind, warnings)
		}
	}
}

// INVD30 —— v1 每 profile 至多一条 active 的 AnyConnect 线路。
//
// 守护：关键决策 D30。sslcon 是包级单例，两条 active AnyConnect 线路在运行期
// 必然互相踩掉；桌面路径当前只在 PlatformNE 下做了这个校验，桌面同样需要硬校验。
func TestINVD30_DesktopRejectsMultipleActiveAnyConnectLines(t *testing.T) {
	profile := invBaseProfile()
	profile.Lines = append(profile.Lines, Line{
		ID: "corp2", Name: "第二条 VPN", Type: LineTypeVPN, Enabled: true,
		VPNServer: "vpn2.example.com:443", VPNUsername: "user",
	})
	profile.RuleSets = append(profile.RuleSets, RuleSet{
		ID: "intranet2", Name: "内网2", Type: RuleSetTypeManual, Enabled: true,
		Domains: []string{"corp2.example"},
	})
	profile.Modes[0].Bindings = append(profile.Modes[0].Bindings,
		RuleBinding{RuleSetID: "intranet2", LineID: "corp2"})

	data, err := GenerateSingBoxDesktop(profile, invSocksPort, invVPNServerIP, invBasePath, invEnterpriseDNS, invUnderlay)
	if err == nil {
		t.Fatalf("两条 active AnyConnect 线路应当被硬校验拒绝（D30）。生成结果:\n%s", string(data))
	}
}

// ===========================================================================
// INV7（收窄版）—— 域名绑定与 DNS 分域必须来自同一份 Mode 裁决
// ===========================================================================
//
// 为什么收窄：原始表述「任意域名的 DNS 判定与路由判定相同」在当前设计下**不可满足**。
// 路由裁决可以基于 IP（ip_cidr / GEOIP / ip_is_private），而 DNS 裁决发生在拿到 IP
// **之前**——名字→线路→地址，顺序不可交换。基于 IP 的绑定天然无法参与 DNS 分域，
// 强行要求二者对任意域名一致，等于要求 DNS 阶段就知道解析结果，逻辑上自相矛盾。
// 因此收窄为：**只对基于域名的绑定**要求双向一致。
//
// 唯一显式豁免：direct 线路不声明解析器（它本就要本地视角），不产生 dns 分支。
//
// 什么改动会让它变红：给路由加了域名绑定却忘了同步 dns.rules（分流看似生效，
// 实际用本地解析结果去连隧道那头），或者反过来在 dns.rules 里塞了没有路由对应的域名分支。
func TestINV7_DomainBindingsAndDNSRulesAgree(t *testing.T) {
	profile := invBaseProfile()
	// 再加一条「URL 规则集 → AnyConnect 线路」：预设模式“国内”就是这个形状，
	// 它必须走“经隧道的公共 DoH”，而不是企业 DNS，也不能落到 final 的境内解析器。
	profile.RuleSets = append(profile.RuleSets, RuleSet{
		ID: "cnip", Name: "国内", Type: RuleSetTypeURL, Enabled: true,
		URL: "https://example.com/geosite-cn.srs",
	})
	profile.Modes[0].Bindings = append(profile.Modes[0].Bindings,
		RuleBinding{RuleSetID: "cnip", LineID: "corp"})

	cfg := invGenerateDesktop(t, profile)
	dnsRules := invDNSRules(cfg)

	type expectation struct {
		serverTag  string
		ruleSetTag string
		domains    []string
		from       string
	}
	var expectations []expectation

	mode := profile.ActiveMode()
	for _, binding := range mode.Bindings {
		ruleSet := profile.FindRuleSet(binding.RuleSetID)
		if ruleSet == nil || !ruleSet.Enabled {
			continue
		}
		line := profile.FindLine(binding.LineID)
		if line == nil || !line.Enabled {
			continue
		}
		lineTag := resolveOutboundTag(line)
		switch {
		case lineTag == "direct":
			continue // 直连不声明解析器，本地视角
		case lineTag == "vpn" && ruleSet.Type == RuleSetTypeManual:
			if len(ruleSet.Domains) == 0 {
				continue
			}
			expectations = append(expectations, expectation{
				serverTag: desktopEnterpriseDNSTag,
				domains:   ruleSet.Domains,
				from:      "手动规则集 " + ruleSet.ID + " → AnyConnect 线路（内网名只有企业 DNS 有记录）",
			})
		case ruleSet.Type == RuleSetTypeURL:
			expectations = append(expectations, expectation{
				serverTag:  desktopProxyDNSTag(lineTag),
				ruleSetTag: sbRuleSetTag(ruleSet),
				from:       "URL 规则集 " + ruleSet.ID + " → 线路 " + lineTag,
			})
		case ruleSet.Type == RuleSetTypeManual:
			if len(ruleSet.Domains) == 0 {
				continue
			}
			expectations = append(expectations, expectation{
				serverTag: desktopProxyDNSTag(lineTag),
				domains:   ruleSet.Domains,
				from:      "手动规则集 " + ruleSet.ID + " → 线路 " + lineTag,
			})
		}
	}
	if len(expectations) == 0 {
		t.Fatalf("夹具没有产生任何基于域名的绑定，测试无意义")
	}

	matches := func(rule map[string]interface{}, exp expectation) bool {
		if rule["server"] != exp.serverTag {
			return false
		}
		if exp.ruleSetTag != "" {
			return rule["rule_set"] == exp.ruleSetTag
		}
		return invContainsAll(invStrings(rule["domain_suffix"]), exp.domains)
	}

	// 正向：每条域名绑定都要在 dns.rules 里有对应分支。
	for _, exp := range expectations {
		found := false
		for _, rule := range dnsRules {
			if matches(rule, exp) {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("域名绑定缺少对应的 DNS 分域规则：%s（期望 server=%q）\ndns.rules:\n%s",
				exp.from, exp.serverTag, invPretty(dnsRules))
		}
	}

	// 反向：dns.rules 里出现的域名分支都要追溯得到某条域名绑定。
	for index, rule := range dnsRules {
		hasDomainMatcher := rule["domain_suffix"] != nil || rule["domain"] != nil ||
			rule["domain_keyword"] != nil || rule["rule_set"] != nil
		if !hasDomainMatcher {
			continue // ip_accept_any 等非域名分支，见上文豁免
		}
		traced := false
		for _, exp := range expectations {
			if matches(rule, exp) {
				traced = true
				break
			}
		}
		if !traced {
			t.Errorf("dns.rules[%d] 是一条追溯不到任何域名绑定的域名分支：\n%s", index, invPretty(rule))
		}
	}
}

// ===========================================================================
// INV-UNDERLAY —— XDial 不识别、不选择、不重排启动前网络
// ===========================================================================
//
// Underlay 可能已经包含网线、Wi-Fi 和任意数量的外部 VPN。桌面生成器只能把
// 宿主从系统默认路由取得的快照逐字交给 sing-box，不能自行猜接口；也不能回落
// 到会跳过 macOS 无网关 utun 的 auto_detect_interface。
func TestINVUnderlay_DesktopForwardsSystemSnapshot(t *testing.T) {
	cfg := invGenerateDesktop(t, invBaseProfile())
	route, ok := cfg["route"].(map[string]interface{})
	if !ok {
		t.Fatalf("route 结构无效：%s", invPretty(cfg["route"]))
	}
	if got := route["default_interface"]; got != invUnderlay {
		t.Fatalf("桌面必须逐字转交系统 Underlay 快照：got=%v want=%q\n%s",
			got, invUnderlay, invPretty(route))
	}
	if _, exists := route["auto_detect_interface"]; exists {
		t.Fatalf("桌面不得回落到会跳过无网关 utun 的 auto_detect_interface：%s", invPretty(route))
	}

	outbounds, ok := cfg["outbounds"].([]interface{})
	if !ok {
		t.Fatalf("outbounds 结构无效：%s", invPretty(cfg["outbounds"]))
	}
	for _, raw := range outbounds {
		outbound, ok := raw.(map[string]interface{})
		if !ok {
			t.Fatalf("outbound 结构无效：%s", invPretty(raw))
		}
		if _, exists := outbound["bind_interface"]; exists {
			t.Fatalf("XDial 不得把 outbound 绑定到产品或物理接口：%s", invPretty(outbound))
		}
	}
}

func TestINVUnderlay_DesktopRejectsMissingSystemSnapshot(t *testing.T) {
	_, err := GenerateSingBoxDesktop(
		invBaseProfile(),
		invSocksPort,
		invVPNServerIP,
		invBasePath,
		invEnterpriseDNS,
		"",
	)
	if err == nil || !strings.Contains(err.Error(), "underlay interface snapshot") {
		t.Fatalf("空 Underlay 快照必须 fail-closed，got=%v", err)
	}
}
