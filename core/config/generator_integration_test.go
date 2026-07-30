package config

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// singboxCheck 生成配置写入临时文件，调 sing-box check 验证
func singboxCheck(t *testing.T, profile *Profile, label string) {
	t.Helper()
	data, err := GenerateSingBox(profile, 10800, "")
	if err != nil {
		t.Fatalf("[%s] GenerateSingBox: %v", label, err)
	}
	singboxCheckConfig(t, data, label)
}

// singboxCheckConfig 把已生成好的配置交给 sing-box check。
func singboxCheckConfig(t *testing.T, data []byte, label string) {
	t.Helper()
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "sing-box.json")
	if err := os.WriteFile(cfgPath, data, 0644); err != nil {
		t.Fatalf("[%s] write: %v", label, err)
	}

	cmd := exec.Command("sing-box", "check", "-c", cfgPath)
	out, err := cmd.CombinedOutput()
	if err != nil {
		// 输出配置方便调试
		t.Logf("[%s] config:\n%s", label, string(data))
		t.Fatalf("[%s] sing-box check failed: %s\n%s", label, err, string(out))
	}
	t.Logf("[%s] sing-box check OK", label)
}

// --- 基础线路 ---

func directLine() Line {
	return Line{ID: "direct", Name: "直连", Type: LineTypeDirect, Enabled: true}
}

func vpnLine() Line {
	return Line{
		ID: "vpn", Name: "MyVPN", Type: LineTypeVPN, Enabled: true,
		VPNServer: "vpn.example.com", VPNUsername: "user", VPNPassword: "pass",
	}
}

func trojanLine() Line {
	return Line{
		ID: "trojan-1", Name: "HK Trojan", Type: LineTypeTrojan, Enabled: true,
		TrojanServer: "hk.example.com", TrojanPort: 443,
		TrojanPassword: "pass123", TrojanSNI: "hk.example.com",
	}
}

// --- 基础规则 ---

func internalRuleSet() RuleSet {
	return RuleSet{
		ID: "internal", Name: "内部域名", Type: RuleSetTypeManual, Enabled: true,
		Domains: []string{"example.com", "svc.example.com"},
	}
}

func gfwRuleSet() RuleSet {
	return RuleSet{
		ID: "gfw", Name: "GFWList", Type: RuleSetTypeURL, Enabled: true,
		URL:    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-gfw.srs",
		Format: "srs",
	}
}

func cnipRuleSet() RuleSet {
	return RuleSet{
		ID: "cnip", Name: "国内IP", Type: RuleSetTypeURL, Enabled: true,
		URL:    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-cn.srs",
		Format: "srs",
	}
}

// --- 基础订阅 ---

func testSubscription() Subscription {
	return Subscription{
		ID: "sub-test", Name: "TestSub", URL: "https://example.com/sub",
		Format: "surge", Enabled: true, Strategy: "urltest",
		Lines: []Line{
			{ID: "n1", Name: "HK 01", Type: LineTypeTrojan, Enabled: true,
				TrojanServer: "hk1.example.com", TrojanPort: 443, TrojanPassword: "p1", TrojanSNI: "hk1.example.com"},
			{ID: "n2", Name: "US 01", Type: LineTypeTrojan, Enabled: true,
				TrojanServer: "us1.example.com", TrojanPort: 443, TrojanPassword: "p2", TrojanSNI: "us1.example.com"},
			{ID: "n3", Name: "JP 01", Type: LineTypeTrojan, Enabled: true,
				TrojanServer: "jp1.example.com", TrojanPort: 443, TrojanPassword: "p3", TrojanSNI: "jp1.example.com"},
		},
		ProxyGroups: []ProxyGroup{
			{Name: "Proxies", Type: "select", Proxies: []string{"HK 01", "US 01", "JP 01"}},
			{Name: "Netflix", Type: "select", Proxies: []string{"US 01", "JP 01"}},
			{Name: "AI", Type: "url-test", Proxies: []string{"US 01", "JP 01"},
				URL: "https://www.gstatic.com/generate_204", Interval: 300},
			{Name: "Direct", Type: "select", Proxies: []string{"HK 01"}},
		},
		Rules: []SubscriptionRule{
			{Type: "DOMAIN-SUFFIX", Value: "netflix.com", Group: "Netflix"},
			{Type: "DOMAIN-SUFFIX", Value: "openai.com", Group: "AI"},
			{Type: "DOMAIN-KEYWORD", Value: "google", Group: "Proxies"},
			{Type: "GEOIP", Value: "CN", Group: "Direct"}, // 应该被跳过
			{Type: "FINAL", Group: "Proxies"},
		},
	}
}

func testSubscriptionNoGroups() Subscription {
	return Subscription{
		ID: "sub-plain", Name: "PlainSub", URL: "https://example.com/plain",
		Format: "base64", Enabled: true, Strategy: "urltest",
		Lines: []Line{
			{ID: "p1", Name: "Node A", Type: LineTypeShadowsocks, Enabled: true,
				SSServer: "a.example.com", SSPort: 8388, SSMethod: "aes-256-gcm", SSPass: "pass"},
			{ID: "p2", Name: "Node B", Type: LineTypeShadowsocks, Enabled: true,
				SSServer: "b.example.com", SSPort: 8388, SSMethod: "aes-256-gcm", SSPass: "pass"},
		},
	}
}

// =====================
// 测试用例
// =====================

func vmessLine() Line {
	return Line{
		ID: "vmess-1", Name: "America VMess", Type: LineTypeVMess, Enabled: true,
		VMessServer: "us.example.com", VMessPort: 443,
		VMessUUID: "test-uuid", VMessAltID: 0,
	}
}

func tailscaleLine() Line {
	return Line{
		ID: "tailscale-1", Name: "Tailnet", Type: LineTypeTailscale, Enabled: true,
	}
}

func tailscaleIdentity() TailscaleIdentity {
	return TailscaleIdentity{Hostname: "xdial-test"}
}

// 桌面连接路径（GenerateSingBoxDesktop）的产物也必须过 sing-box 的解析：
// 它比 GenerateSingBox 多出 enterprise-dns（detour vpn）和 proxy-dns-*
// （detour 到代理线路）两类 DNS server，字段写错只有 check 能发现。
func TestGenerate_DesktopUserSplitCombination(t *testing.T) {
	if _, err := exec.LookPath("sing-box"); err != nil {
		t.Skip("sing-box not installed")
	}
	p := &Profile{
		Lines:    []Line{directLine(), vpnLine(), trojanLine()},
		RuleSets: []RuleSet{internalRuleSet(), gfwRuleSet()},
		Modes: []Mode{{
			ID: "split", Name: "分流",
			Bindings: []RuleBinding{
				{RuleSetID: "internal", LineID: "vpn"},
				{RuleSetID: "gfw", LineID: "trojan-1"},
			},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "split",
	}

	data, err := GenerateSingBoxDesktop(p, 10800, "1.2.3.4", t.TempDir(), []string{"10.8.0.10"}, "en0")
	if err != nil {
		t.Fatalf("[desktop-split] GenerateSingBoxDesktop: %v", err)
	}
	singboxCheckConfig(t, data, "desktop-split")
}

func TestGenerate_DesktopTailscale(t *testing.T) {
	if _, err := exec.LookPath("sing-box"); err != nil {
		t.Skip("sing-box not installed")
	}
	p := &Profile{
		Lines: []Line{directLine(), tailscaleLine()},
		Modes: []Mode{{
			ID: "tailnet", Name: "Tailnet", DefaultLineID: "tailscale-1",
		}},
		ActiveModeID: "tailnet",
		Tailscale:    tailscaleIdentity(),
	}
	data, err := GenerateSingBoxDesktop(p, 0, "", t.TempDir(), nil, "en0")
	if err != nil {
		t.Fatalf("[tailscale-desktop] GenerateSingBoxDesktop: %v", err)
	}
	singboxCheckConfig(t, data, "tailscale-desktop")
}

func TestGenerate_NETailscale(t *testing.T) {
	p := &Profile{
		Lines: []Line{directLine(), tailscaleLine()},
		Modes: []Mode{{
			ID: "tailnet", Name: "Tailnet", DefaultLineID: "tailscale-1",
		}},
		ActiveModeID: "tailnet",
		Tailscale:    tailscaleIdentity(),
	}
	data, err := GenerateSingBoxFor(p, 0, "", PlatformNE, t.TempDir())
	if err != nil {
		t.Fatalf("[tailscale-ne] GenerateSingBoxFor: %v", err)
	}

	// xdial-mobile 是 App 内注册的 libbox DNS transport，命令行 sing-box 不认识。
	// 这里只把 DNS 替换为标准 transport，让官方 validator 继续覆盖 Tailscale
	// endpoint 和其余原生配置字段；自定义 transport 由 core/libbox 测试覆盖。
	var cfg map[string]interface{}
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatalf("[tailscale-ne] decode: %v", err)
	}
	cfg["dns"] = map[string]interface{}{
		"servers": []map[string]interface{}{{
			"type": "udp", "tag": mobilePublicDNSTag, "server": "1.1.1.1", "server_port": 53,
		}},
		"final": mobilePublicDNSTag,
	}
	checkData, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		t.Fatalf("[tailscale-ne] encode validator config: %v", err)
	}
	singboxCheckConfig(t, checkData, "tailscale-ne")
}

// 1. 纯手动线路，无订阅（原有功能）
func TestGenerate_ManualOnly(t *testing.T) {
	p := &Profile{
		Lines:    []Line{directLine(), vpnLine(), trojanLine()},
		RuleSets: []RuleSet{internalRuleSet(), gfwRuleSet(), cnipRuleSet()},
		Modes: []Mode{{
			ID: "c1", Name: "海外",
			Bindings: []RuleBinding{
				{RuleSetID: "internal", LineID: "vpn"},
				{RuleSetID: "gfw", LineID: "direct"},
				{RuleSetID: "cnip", LineID: "trojan-1"},
			},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "c1",
	}
	singboxCheck(t, p, "manual-only")
}

// 1b. 国内 IP 走 VMess（验证 cnip→vmess 分流正确）
func TestGenerate_ManualOnlyVMess(t *testing.T) {
	p := &Profile{
		Lines:    []Line{directLine(), vpnLine(), vmessLine()},
		RuleSets: []RuleSet{internalRuleSet(), gfwRuleSet(), cnipRuleSet()},
		Modes: []Mode{{
			ID: "c1", Name: "国内",
			Bindings: []RuleBinding{
				{RuleSetID: "internal", LineID: "vpn"},
				{RuleSetID: "gfw", LineID: "direct"},
				{RuleSetID: "cnip", LineID: "vmess-1"},
			},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "c1",
	}
	singboxCheck(t, p, "manual-vmess")
}

// 2. 模式 binding 指向订阅整体
func TestGenerate_BindingToSubscription(t *testing.T) {
	p := &Profile{
		Lines:         []Line{directLine(), vpnLine()},
		RuleSets:      []RuleSet{internalRuleSet(), gfwRuleSet()},
		Subscriptions: []Subscription{testSubscription()},
		Modes: []Mode{{
			ID: "c1", Name: "国内",
			Bindings: []RuleBinding{
				{RuleSetID: "internal", LineID: "vpn"},
				{RuleSetID: "gfw", SubscriptionID: "sub-test"}, // GFW → 订阅
			},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "c1",
	}
	singboxCheck(t, p, "binding-to-sub")
}

// 3. 默认出口指向订阅
func TestGenerate_DefaultToSubscription(t *testing.T) {
	p := &Profile{
		Lines:         []Line{directLine(), vpnLine()},
		RuleSets:      []RuleSet{internalRuleSet()},
		Subscriptions: []Subscription{testSubscription()},
		Modes: []Mode{{
			ID: "c1", Name: "全走订阅",
			Bindings: []RuleBinding{
				{RuleSetID: "internal", LineID: "vpn"},
			},
			DefaultSubscriptionID: "sub-test",
		}},
		ActiveModeID: "c1",
	}
	singboxCheck(t, p, "default-to-sub")
}

// 4. 混合：手动线路 + 订阅
func TestGenerate_Mixed(t *testing.T) {
	p := &Profile{
		Lines:         []Line{directLine(), vpnLine(), trojanLine()},
		RuleSets:      []RuleSet{internalRuleSet(), gfwRuleSet(), cnipRuleSet()},
		Subscriptions: []Subscription{testSubscription()},
		Modes: []Mode{{
			ID: "c1", Name: "混合",
			Bindings: []RuleBinding{
				{RuleSetID: "internal", LineID: "vpn"},         // 手动
				{RuleSetID: "gfw", SubscriptionID: "sub-test"}, // 订阅
				{RuleSetID: "cnip", LineID: "trojan-1"},        // 手动
			},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "c1",
	}
	singboxCheck(t, p, "mixed")
}

// 5. 纯节点订阅（无策略组，无规则）
func TestGenerate_PlainSubscription(t *testing.T) {
	p := &Profile{
		Lines:         []Line{directLine()},
		RuleSets:      []RuleSet{gfwRuleSet()},
		Subscriptions: []Subscription{testSubscriptionNoGroups()},
		Modes: []Mode{{
			ID: "c1", Name: "Plain",
			Bindings: []RuleBinding{
				{RuleSetID: "gfw", SubscriptionID: "sub-plain"},
			},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "c1",
	}
	singboxCheck(t, p, "plain-sub")
}

// 6. 订阅被禁用
func TestGenerate_DisabledSubscription(t *testing.T) {
	sub := testSubscription()
	sub.Enabled = false

	p := &Profile{
		Lines:         []Line{directLine(), vpnLine()},
		RuleSets:      []RuleSet{internalRuleSet(), gfwRuleSet()},
		Subscriptions: []Subscription{sub},
		Modes: []Mode{{
			ID: "c1", Name: "Disabled",
			Bindings: []RuleBinding{
				{RuleSetID: "internal", LineID: "vpn"},
				{RuleSetID: "gfw", SubscriptionID: "sub-test"}, // 订阅禁用，应跳过
			},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "c1",
	}
	singboxCheck(t, p, "disabled-sub")
}

// 7. 订阅节点为空
func TestGenerate_EmptySubscription(t *testing.T) {
	sub := Subscription{
		ID: "sub-empty", Name: "Empty", URL: "https://example.com",
		Enabled: true, Strategy: "urltest",
	}

	p := &Profile{
		Lines:         []Line{directLine()},
		RuleSets:      []RuleSet{gfwRuleSet()},
		Subscriptions: []Subscription{sub},
		Modes: []Mode{{
			ID: "c1", Name: "Empty",
			Bindings: []RuleBinding{
				{RuleSetID: "gfw", SubscriptionID: "sub-empty"},
			},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "c1",
	}
	singboxCheck(t, p, "empty-sub")
}

// 8. 多订阅（都有 GEOIP,CN，不能 tag 冲突）
func TestGenerate_MultipleSubscriptions(t *testing.T) {
	sub1 := testSubscription()
	sub2 := testSubscription()
	sub2.ID = "sub-test2"
	sub2.Name = "TestSub2"
	sub2.Lines = []Line{
		{ID: "m1", Name: "Node M1", Type: LineTypeVMess, Enabled: true,
			VMessServer: "m1.example.com", VMessPort: 443, VMessUUID: "uuid-1"},
	}
	sub2.ProxyGroups = []ProxyGroup{
		{Name: "Auto", Type: "url-test", Proxies: []string{"Node M1"}},
	}
	sub2.Rules = []SubscriptionRule{
		{Type: "GEOIP", Value: "CN", Group: "Auto"},
		{Type: "FINAL", Group: "Auto"},
	}

	p := &Profile{
		Lines:         []Line{directLine(), vpnLine()},
		RuleSets:      []RuleSet{internalRuleSet()},
		Subscriptions: []Subscription{sub1, sub2},
		Modes: []Mode{{
			ID: "c1", Name: "Multi",
			Bindings: []RuleBinding{
				{RuleSetID: "internal", LineID: "vpn"},
			},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "c1",
	}
	singboxCheck(t, p, "multi-sub")
}

// 8b. 引用被禁用 port 的 binding / 默认出口：必须 fallback，不能让 sing-box 配置非法
func TestGenerate_DisabledPortReferences(t *testing.T) {
	disabledTrojan := trojanLine()
	disabledTrojan.ID = "trojan-disabled"
	disabledTrojan.Enabled = false

	p := &Profile{
		Lines:    []Line{directLine(), vpnLine(), disabledTrojan},
		RuleSets: []RuleSet{internalRuleSet(), gfwRuleSet()},
		Modes: []Mode{{
			ID: "c1", Name: "Disabled-Refs",
			Bindings: []RuleBinding{
				{RuleSetID: "internal", LineID: "vpn"},
				{RuleSetID: "gfw", LineID: "trojan-disabled"}, // 引用禁用 port，应跳过
			},
			DefaultLineID: "trojan-disabled", // 默认出口禁用，应 fallback 到 direct
		}},
		ActiveModeID: "c1",
	}

	data, err := GenerateSingBox(p, 10800, "")
	if err != nil {
		t.Fatalf("GenerateSingBox: %v", err)
	}

	var cfg map[string]interface{}
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	// 收集所有 outbound tag
	tags := map[string]bool{}
	for _, ob := range cfg["outbounds"].([]interface{}) {
		tags[ob.(map[string]interface{})["tag"].(string)] = true
	}

	if tags["proxy-trojan-disabled"] {
		t.Error("disabled port should not produce outbound")
	}

	route := cfg["route"].(map[string]interface{})
	final := route["final"].(string)
	if final == "proxy-trojan-disabled" {
		t.Errorf("final must not reference disabled port, got %q", final)
	}
	if final != "direct" {
		t.Errorf("final should fallback to direct, got %q", final)
	}

	// 模式规则里不应出现引用禁用 line 的规则
	for _, r := range route["rules"].([]interface{}) {
		rm := r.(map[string]interface{})
		if outTag, ok := rm["outbound"].(string); ok && outTag == "proxy-trojan-disabled" {
			t.Errorf("route rule references disabled port: %v", rm)
		}
	}

	singboxCheck(t, p, "disabled-port-refs")
}

// 8c. 策略组成员全部失效：跳过的组不能成为 mainTag，subscription rule 也不能引用它
func TestGenerate_DanglingGroupReferences(t *testing.T) {
	// 第一个组 "Dead" 的所有 proxy 都指向不存在的节点 → 跳过 outbound 生成
	// 第二个组 "Live" 有真实成员 → 应被选为 mainTag
	sub := Subscription{
		ID: "sub-dangle", Name: "DangleSub", URL: "https://example.com",
		Format: "clash", Enabled: true, Strategy: "selector",
		Lines: []Line{
			{ID: "n1", Name: "HK 01", Type: LineTypeTrojan, Enabled: true,
				TrojanServer: "hk1.example.com", TrojanPort: 443, TrojanPassword: "p1", TrojanSNI: "hk1.example.com"},
		},
		ProxyGroups: []ProxyGroup{
			{Name: "Dead", Type: "select", Proxies: []string{"ghost-1", "ghost-2"}}, // 全是无效引用
			{Name: "Live", Type: "select", Proxies: []string{"HK 01"}},
		},
		Rules: []SubscriptionRule{
			{Type: "DOMAIN-SUFFIX", Value: "example.org", Group: "Dead"}, // 应被跳过
			{Type: "DOMAIN-SUFFIX", Value: "example.com", Group: "Live"}, // 应保留
		},
	}

	p := &Profile{
		Lines:         []Line{directLine(), vpnLine()},
		RuleSets:      []RuleSet{internalRuleSet()},
		Subscriptions: []Subscription{sub},
		Modes: []Mode{{
			ID: "c1", Name: "Dangle",
			Bindings: []RuleBinding{
				{RuleSetID: "internal", LineID: "vpn"},
			},
			DefaultSubscriptionID: "sub-dangle",
		}},
		ActiveModeID: "c1",
	}

	data, err := GenerateSingBox(p, 10800, "")
	if err != nil {
		t.Fatalf("GenerateSingBox: %v", err)
	}

	var cfg map[string]interface{}
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	tags := map[string]bool{}
	for _, ob := range cfg["outbounds"].([]interface{}) {
		tags[ob.(map[string]interface{})["tag"].(string)] = true
	}

	deadTag := "sub-sub-dangle-dead"
	liveTag := "sub-sub-dangle-live"

	if tags[deadTag] {
		t.Errorf("dead group must not generate outbound, but tag %q exists", deadTag)
	}
	if !tags[liveTag] {
		t.Errorf("live group missing outbound, tags=%v", tags)
	}

	route := cfg["route"].(map[string]interface{})
	final := route["final"].(string)
	if final == deadTag {
		t.Errorf("final must not reference dead group, got %q", final)
	}
	if final != liveTag {
		t.Errorf("final should fallback to first live group %q, got %q", liveTag, final)
	}

	for _, r := range route["rules"].([]interface{}) {
		rm := r.(map[string]interface{})
		if outTag, ok := rm["outbound"].(string); ok && outTag == deadTag {
			t.Errorf("route rule references dead group: %v", rm)
		}
	}

	singboxCheck(t, p, "dangling-group")
}

// 9. 用真实订阅数据（如果有）
func TestGenerate_RealSubscription(t *testing.T) {
	_, _ = os.ReadFile("/tmp/sub_test.txt") // 确认文件存在

	profileJSON, err := os.ReadFile("/tmp/xdial-engine/sing-box.json")
	if err != nil {
		t.Skip("no sing-box.json to validate")
	}

	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "sing-box.json")
	os.WriteFile(cfgPath, profileJSON, 0644)

	cmd := exec.Command("sing-box", "check", "-c", cfgPath)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("[real-sub] sing-box check failed: %s\n%s", err, string(out))
	}
	t.Logf("[real-sub] sing-box check OK, config size: %d bytes", len(profileJSON))
}

// 9. 验证配置内容正确性（不只是合法性）
func TestGenerate_ContentVerification(t *testing.T) {
	sub := testSubscription()
	p := &Profile{
		Lines:         []Line{directLine(), vpnLine()},
		RuleSets:      []RuleSet{internalRuleSet()},
		Subscriptions: []Subscription{sub},
		Modes: []Mode{{
			ID: "c1", Name: "Verify",
			Bindings: []RuleBinding{
				{RuleSetID: "internal", LineID: "vpn"},
			},
			DefaultSubscriptionID: "sub-test",
		}},
		ActiveModeID: "c1",
	}

	data, err := GenerateSingBox(p, 10800, "")
	if err != nil {
		t.Fatalf("GenerateSingBox: %v", err)
	}

	var cfg map[string]interface{}
	json.Unmarshal(data, &cfg)

	// 验证 outbounds 包含订阅节点和策略组
	outbounds := cfg["outbounds"].([]interface{})
	tags := map[string]bool{}
	for _, ob := range outbounds {
		tag := ob.(map[string]interface{})["tag"].(string)
		tags[tag] = true
	}

	// 手动线路
	if !tags["direct"] {
		t.Error("missing direct outbound")
	}
	if !tags["vpn"] {
		t.Error("missing vpn outbound")
	}

	// 订阅节点
	if !tags["proxy-sub-test-n1"] {
		t.Error("missing subscription node proxy-sub-test-n1")
	}

	// 订阅策略组
	if !tags["sub-sub-test-proxies"] {
		t.Errorf("missing subscription group, have: %v", tags)
	}

	// 验证 route final 指向订阅主策略组
	route := cfg["route"].(map[string]interface{})
	final := route["final"].(string)
	if final != "sub-sub-test-proxies" {
		t.Errorf("final = %q, want sub-sub-test-proxies", final)
	}

	// 验证模式规则在订阅自带规则之前。
	// 架构约束：Mode 是唯一裁决者，订阅只是供给源（D28）—— 用户在模式里显式绑定的
	// 规则必须先匹配，订阅自带的宽匹配（GEOIP,CN 之类）只能当兜底，否则订阅
	// 一更新就能把用户的显式分流整片遮蔽掉。
	rules := route["rules"].([]interface{})
	var internalIdx, netflixIdx int
	for i, r := range rules {
		rm := r.(map[string]interface{})
		if ds, ok := rm["domain_suffix"]; ok {
			if arr, ok := ds.([]interface{}); ok {
				for _, d := range arr {
					if d.(string) == "example.com" {
						internalIdx = i
					}
					if d.(string) == "netflix.com" {
						netflixIdx = i
					}
				}
			}
		}
	}
	if internalIdx == 0 {
		t.Error("internal domain rule not found")
	}
	if netflixIdx == 0 {
		t.Error("netflix subscription rule not found")
	}
	if internalIdx > netflixIdx {
		t.Errorf("mode rule (idx=%d) should come before subscription rule (idx=%d)", internalIdx, netflixIdx)
	}

	t.Logf("Content verification: %d outbounds, %d rules, final=%s", len(outbounds), len(rules), final)
}

// 10. REJECT 规则应翻译成 action:reject，而非被静默丢弃
func TestGenerate_RejectRuleTranslated(t *testing.T) {
	sub := Subscription{
		ID: "sub-rj", Name: "RejectSub", URL: "https://example.com", Format: "clash",
		Enabled: true, Strategy: "selector",
		Lines: []Line{
			{ID: "n1", Name: "HK 01", Type: LineTypeTrojan, Enabled: true,
				TrojanServer: "hk1.example.com", TrojanPort: 443, TrojanPassword: "p1", TrojanSNI: "hk1.example.com"},
		},
		ProxyGroups: []ProxyGroup{
			{Name: "Proxies", Type: "select", Proxies: []string{"HK 01"}},
		},
		Rules: []SubscriptionRule{
			{Type: "DOMAIN-SUFFIX", Value: "ads.example.com", Group: "REJECT"},
			{Type: "DOMAIN-SUFFIX", Value: "site.example.com", Group: "Proxies"},
		},
	}
	p := &Profile{
		Lines:         []Line{directLine(), vpnLine()},
		Subscriptions: []Subscription{sub},
		Modes:         []Mode{{ID: "m1", Name: "M", DefaultSubscriptionID: "sub-rj"}},
		ActiveModeID:  "m1",
	}
	data, err := GenerateSingBox(p, 1080, "")
	if err != nil {
		t.Fatalf("generate: %v", err)
	}
	var cfg map[string]interface{}
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	route := cfg["route"].(map[string]interface{})
	found := false
	for _, r := range route["rules"].([]interface{}) {
		rm := r.(map[string]interface{})
		ds, _ := rm["domain_suffix"].([]interface{})
		if len(ds) == 1 && ds[0].(string) == "ads.example.com" {
			found = true
			if rm["action"] != "reject" {
				t.Errorf("REJECT rule should carry action:reject, got %v", rm)
			}
			if _, has := rm["outbound"]; has {
				t.Errorf("reject rule must not carry outbound: %v", rm)
			}
		}
	}
	if !found {
		t.Errorf("REJECT rule was dropped, rules=%v", route["rules"])
	}
	// 哨兵值绝不能作为 outbound tag 泄漏
	for _, ob := range cfg["outbounds"].([]interface{}) {
		if ob.(map[string]interface{})["tag"].(string) == rejectTag {
			t.Error("sentinel rejectTag leaked as outbound tag")
		}
	}
}

// 11. 纯 REJECT 组（proxies:[REJECT]）：不生成 outbound，指向它的规则翻译成 action:reject
func TestGenerate_PureRejectGroup(t *testing.T) {
	sub := Subscription{
		ID: "sub-adblock", Name: "AdblockSub", URL: "https://example.com", Format: "clash",
		Enabled: true, Strategy: "selector",
		Lines: []Line{
			{ID: "n1", Name: "HK 01", Type: LineTypeTrojan, Enabled: true,
				TrojanServer: "hk1.example.com", TrojanPort: 443, TrojanPassword: "p1", TrojanSNI: "hk1.example.com"},
		},
		ProxyGroups: []ProxyGroup{
			{Name: "Proxies", Type: "select", Proxies: []string{"HK 01"}},
			{Name: "AdBlock", Type: "select", Proxies: []string{"REJECT"}},
		},
		Rules: []SubscriptionRule{
			{Type: "DOMAIN-SUFFIX", Value: "ads.example.com", Group: "AdBlock"},
		},
	}
	p := &Profile{
		Lines:         []Line{directLine(), vpnLine()},
		Subscriptions: []Subscription{sub},
		Modes:         []Mode{{ID: "m1", Name: "M", DefaultSubscriptionID: "sub-adblock"}},
		ActiveModeID:  "m1",
	}
	data, err := GenerateSingBox(p, 1080, "")
	if err != nil {
		t.Fatalf("generate: %v", err)
	}
	var cfg map[string]interface{}
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	for _, ob := range cfg["outbounds"].([]interface{}) {
		tag := ob.(map[string]interface{})["tag"].(string)
		if tag == "sub-sub-adblock-adblock" {
			t.Error("pure reject group must not generate an outbound")
		}
		if tag == rejectTag {
			t.Error("sentinel leaked as outbound tag")
		}
	}
	route := cfg["route"].(map[string]interface{})
	found := false
	for _, r := range route["rules"].([]interface{}) {
		rm := r.(map[string]interface{})
		ds, _ := rm["domain_suffix"].([]interface{})
		if len(ds) == 1 && ds[0].(string) == "ads.example.com" {
			found = true
			if rm["action"] != "reject" {
				t.Errorf("rule to pure-reject group should be action:reject, got %v", rm)
			}
		}
	}
	if !found {
		t.Error("rule pointing at pure reject group was dropped")
	}
	if route["final"].(string) == rejectTag {
		t.Error("final must not be the sentinel")
	}
}

// 12. 中文同长组名 slugify 撞车 → 必须生成唯一 outbound tag（否则 sing-box 拒启动）
func TestGenerate_DuplicateChineseGroupTags(t *testing.T) {
	sub := Subscription{
		ID: "sub-cn", Name: "CNSub", URL: "https://example.com", Format: "clash",
		Enabled: true, Strategy: "selector",
		Lines: []Line{
			{ID: "n1", Name: "N1", Type: LineTypeTrojan, Enabled: true,
				TrojanServer: "a.example.com", TrojanPort: 443, TrojanPassword: "p1", TrojanSNI: "a.example.com"},
			{ID: "n2", Name: "N2", Type: LineTypeTrojan, Enabled: true,
				TrojanServer: "b.example.com", TrojanPort: 443, TrojanPassword: "p2", TrojanSNI: "b.example.com"},
		},
		ProxyGroups: []ProxyGroup{
			{Name: "香港节点", Type: "select", Proxies: []string{"N1"}},
			{Name: "台湾节点", Type: "select", Proxies: []string{"N2"}},
		},
		Rules: []SubscriptionRule{
			{Type: "DOMAIN-SUFFIX", Value: "hk.example.com", Group: "香港节点"},
			{Type: "DOMAIN-SUFFIX", Value: "tw.example.com", Group: "台湾节点"},
		},
	}
	p := &Profile{
		Lines:         []Line{directLine(), vpnLine()},
		Subscriptions: []Subscription{sub},
		Modes:         []Mode{{ID: "m1", Name: "M", DefaultSubscriptionID: "sub-cn"}},
		ActiveModeID:  "m1",
	}
	data, err := GenerateSingBox(p, 1080, "")
	if err != nil {
		t.Fatalf("generate failed (duplicate tag collision?): %v", err)
	}
	var cfg map[string]interface{}
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	seen := map[string]bool{}
	for _, ob := range cfg["outbounds"].([]interface{}) {
		tag := ob.(map[string]interface{})["tag"].(string)
		if seen[tag] {
			t.Errorf("duplicate outbound tag: %q", tag)
		}
		seen[tag] = true
	}
	// 第一个组保留无后缀 base（Swift NetworkInfo 只按第一个组算 tag，须兼容）
	base := "sub-" + sub.ID + "-" + slugify("香港节点")
	if !seen[base] {
		t.Errorf("first group must keep base tag %q, tags=%v", base, seen)
	}
	// 撞车的第二个组拿到 -N 后缀
	if !seen[base+"-2"] {
		t.Errorf("colliding second group must get -N suffix, tags=%v", seen)
	}
	// 两条规则都保留且指向不同出口
	route := cfg["route"].(map[string]interface{})
	hk, tw := "", ""
	for _, r := range route["rules"].([]interface{}) {
		rm := r.(map[string]interface{})
		ds, _ := rm["domain_suffix"].([]interface{})
		if len(ds) != 1 {
			continue
		}
		switch ds[0].(string) {
		case "hk.example.com":
			hk, _ = rm["outbound"].(string)
		case "tw.example.com":
			tw, _ = rm["outbound"].(string)
		}
	}
	if hk == "" || tw == "" {
		t.Errorf("both group rules must survive, hk=%q tw=%q", hk, tw)
	}
	if hk == tw {
		t.Errorf("colliding groups must map to distinct outbounds, both=%q", hk)
	}
}
