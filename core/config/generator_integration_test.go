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

// --- 基础港口 ---

func directPort() Port {
	return Port{ID: "direct", Name: "直连", Type: PortTypeDirect, Enabled: true}
}

func vpnPort() Port {
	return Port{
		ID: "vpn", Name: "MyVPN", Type: PortTypeVPN, Enabled: true,
		VPNServer: "vpn.example.com", VPNUsername: "user", VPNPassword: "pass",
	}
}

func trojanPort() Port {
	return Port{
		ID: "trojan-1", Name: "HK Trojan", Type: PortTypeTrojan, Enabled: true,
		TrojanServer: "hk.example.com", TrojanPort: 443,
		TrojanPassword: "pass123", TrojanSNI: "hk.example.com",
	}
}

// --- 基础货品 ---

func internalCargo() Cargo {
	return Cargo{
		ID: "internal", Name: "内部域名", Type: CargoTypeManual, Enabled: true,
		Domains: []string{"example.com", "svc.example.com"},
	}
}

func gfwCargo() Cargo {
	return Cargo{
		ID: "gfw", Name: "GFWList", Type: CargoTypeURL, Enabled: true,
		URL:    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-gfw.srs",
		Format: "srs",
	}
}

func cnipCargo() Cargo {
	return Cargo{
		ID: "cnip", Name: "国内IP", Type: CargoTypeURL, Enabled: true,
		URL:    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-cn.srs",
		Format: "srs",
	}
}

// --- 基础订阅 ---

func testSubscription() Subscription {
	return Subscription{
		ID: "sub-test", Name: "TestSub", URL: "https://example.com/sub",
		Format: "surge", Enabled: true, Strategy: "urltest",
		Ports: []Port{
			{ID: "n1", Name: "HK 01", Type: PortTypeTrojan, Enabled: true,
				TrojanServer: "hk1.example.com", TrojanPort: 443, TrojanPassword: "p1", TrojanSNI: "hk1.example.com"},
			{ID: "n2", Name: "US 01", Type: PortTypeTrojan, Enabled: true,
				TrojanServer: "us1.example.com", TrojanPort: 443, TrojanPassword: "p2", TrojanSNI: "us1.example.com"},
			{ID: "n3", Name: "JP 01", Type: PortTypeTrojan, Enabled: true,
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
			{Type: "GEOIP", Value: "CN", Group: "Direct"},  // 应该被跳过
			{Type: "FINAL", Group: "Proxies"},
		},
	}
}

func testSubscriptionNoGroups() Subscription {
	return Subscription{
		ID: "sub-plain", Name: "PlainSub", URL: "https://example.com/plain",
		Format: "base64", Enabled: true, Strategy: "urltest",
		Ports: []Port{
			{ID: "p1", Name: "Node A", Type: PortTypeShadowsocks, Enabled: true,
				SSServer: "a.example.com", SSPort: 8388, SSMethod: "aes-256-gcm", SSPass: "pass"},
			{ID: "p2", Name: "Node B", Type: PortTypeShadowsocks, Enabled: true,
				SSServer: "b.example.com", SSPort: 8388, SSMethod: "aes-256-gcm", SSPass: "pass"},
		},
	}
}

// =====================
// 测试用例
// =====================

// 1. 纯手动港口，无订阅（原有功能）
func TestGenerate_ManualOnly(t *testing.T) {
	p := &Profile{
		Ports:   []Port{directPort(), vpnPort(), trojanPort()},
		Cargoes: []Cargo{internalCargo(), gfwCargo(), cnipCargo()},
		Cruises: []Cruise{{
			ID: "c1", Name: "海外",
			Bindings: []Binding{
				{CargoID: "internal", PortID: "vpn"},
				{CargoID: "gfw", PortID: "direct"},
				{CargoID: "cnip", PortID: "trojan-1"},
			},
			DefaultPortID: "direct",
		}},
		ActiveCruiseID: "c1",
	}
	singboxCheck(t, p, "manual-only")
}

// 2. 邮轮 binding 指向订阅整体
func TestGenerate_BindingToSubscription(t *testing.T) {
	p := &Profile{
		Ports:         []Port{directPort(), vpnPort()},
		Cargoes:       []Cargo{internalCargo(), gfwCargo()},
		Subscriptions: []Subscription{testSubscription()},
		Cruises: []Cruise{{
			ID: "c1", Name: "国内",
			Bindings: []Binding{
				{CargoID: "internal", PortID: "vpn"},
				{CargoID: "gfw", SubscriptionID: "sub-test"}, // GFW → 订阅
			},
			DefaultPortID: "direct",
		}},
		ActiveCruiseID: "c1",
	}
	singboxCheck(t, p, "binding-to-sub")
}

// 3. 默认出口指向订阅
func TestGenerate_DefaultToSubscription(t *testing.T) {
	p := &Profile{
		Ports:         []Port{directPort(), vpnPort()},
		Cargoes:       []Cargo{internalCargo()},
		Subscriptions: []Subscription{testSubscription()},
		Cruises: []Cruise{{
			ID: "c1", Name: "全走订阅",
			Bindings: []Binding{
				{CargoID: "internal", PortID: "vpn"},
			},
			DefaultSubscriptionID: "sub-test",
		}},
		ActiveCruiseID: "c1",
	}
	singboxCheck(t, p, "default-to-sub")
}

// 4. 混合：手动港口 + 订阅
func TestGenerate_Mixed(t *testing.T) {
	p := &Profile{
		Ports:         []Port{directPort(), vpnPort(), trojanPort()},
		Cargoes:       []Cargo{internalCargo(), gfwCargo(), cnipCargo()},
		Subscriptions: []Subscription{testSubscription()},
		Cruises: []Cruise{{
			ID: "c1", Name: "混合",
			Bindings: []Binding{
				{CargoID: "internal", PortID: "vpn"},        // 手动
				{CargoID: "gfw", SubscriptionID: "sub-test"}, // 订阅
				{CargoID: "cnip", PortID: "trojan-1"},        // 手动
			},
			DefaultPortID: "direct",
		}},
		ActiveCruiseID: "c1",
	}
	singboxCheck(t, p, "mixed")
}

// 5. 纯节点订阅（无策略组，无规则）
func TestGenerate_PlainSubscription(t *testing.T) {
	p := &Profile{
		Ports:         []Port{directPort()},
		Cargoes:       []Cargo{gfwCargo()},
		Subscriptions: []Subscription{testSubscriptionNoGroups()},
		Cruises: []Cruise{{
			ID: "c1", Name: "Plain",
			Bindings: []Binding{
				{CargoID: "gfw", SubscriptionID: "sub-plain"},
			},
			DefaultPortID: "direct",
		}},
		ActiveCruiseID: "c1",
	}
	singboxCheck(t, p, "plain-sub")
}

// 6. 订阅被禁用
func TestGenerate_DisabledSubscription(t *testing.T) {
	sub := testSubscription()
	sub.Enabled = false

	p := &Profile{
		Ports:         []Port{directPort(), vpnPort()},
		Cargoes:       []Cargo{internalCargo(), gfwCargo()},
		Subscriptions: []Subscription{sub},
		Cruises: []Cruise{{
			ID: "c1", Name: "Disabled",
			Bindings: []Binding{
				{CargoID: "internal", PortID: "vpn"},
				{CargoID: "gfw", SubscriptionID: "sub-test"}, // 订阅禁用，应跳过
			},
			DefaultPortID: "direct",
		}},
		ActiveCruiseID: "c1",
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
		Ports:         []Port{directPort()},
		Cargoes:       []Cargo{gfwCargo()},
		Subscriptions: []Subscription{sub},
		Cruises: []Cruise{{
			ID: "c1", Name: "Empty",
			Bindings: []Binding{
				{CargoID: "gfw", SubscriptionID: "sub-empty"},
			},
			DefaultPortID: "direct",
		}},
		ActiveCruiseID: "c1",
	}
	singboxCheck(t, p, "empty-sub")
}

// 8. 多订阅（都有 GEOIP,CN，不能 tag 冲突）
func TestGenerate_MultipleSubscriptions(t *testing.T) {
	sub1 := testSubscription()
	sub2 := testSubscription()
	sub2.ID = "sub-test2"
	sub2.Name = "TestSub2"
	sub2.Ports = []Port{
		{ID: "m1", Name: "Node M1", Type: PortTypeVMess, Enabled: true,
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
		Ports:         []Port{directPort(), vpnPort()},
		Cargoes:       []Cargo{internalCargo()},
		Subscriptions: []Subscription{sub1, sub2},
		Cruises: []Cruise{{
			ID: "c1", Name: "Multi",
			Bindings: []Binding{
				{CargoID: "internal", PortID: "vpn"},
			},
			DefaultPortID: "direct",
		}},
		ActiveCruiseID: "c1",
	}
	singboxCheck(t, p, "multi-sub")
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
		Ports:         []Port{directPort(), vpnPort()},
		Cargoes:       []Cargo{internalCargo()},
		Subscriptions: []Subscription{sub},
		Cruises: []Cruise{{
			ID: "c1", Name: "Verify",
			Bindings: []Binding{
				{CargoID: "internal", PortID: "vpn"},
			},
			DefaultSubscriptionID: "sub-test",
		}},
		ActiveCruiseID: "c1",
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

	// 手动港口
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

	// 验证邮轮规则在订阅规则之前
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
		t.Errorf("cruise rule (idx=%d) should come before subscription rule (idx=%d)", internalIdx, netflixIdx)
	}

	t.Logf("Content verification: %d outbounds, %d rules, final=%s", len(outbounds), len(rules), final)
}
