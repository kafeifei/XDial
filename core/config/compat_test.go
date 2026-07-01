package config

import (
	"encoding/json"
	"reflect"
	"testing"
)

// newFormatProfileJSON 是一份使用新 key 命名的完整 profile JSON：
// lines / rule_sets / modes / active_mode_id，模式绑定里 rule_set_id / line_id，
// 顶层 default_line_id，以及订阅内嵌的 lines。故意覆盖会与旧 key 冲突的所有位置，
// 特别是 Line 里的 trojan_port / ss_port / vmess_port —— 它们含 "port" 子串，
// 必须在规范化后原样保留、绝不被误伤。
const newFormatProfileJSON = `{
  "lines": [
    {"id": "direct", "name": "直连", "type": "direct", "enabled": true},
    {"id": "vpn", "name": "VPN", "type": "vpn", "enabled": true,
     "vpn_server": "vpn.example.com", "vpn_username": "u", "vpn_password": "p"},
    {"id": "tj", "name": "TJ", "type": "trojan", "enabled": true,
     "trojan_server": "tr.example.com", "trojan_port": 443,
     "trojan_password": "pw", "trojan_sni": "tr.example.com"},
    {"id": "ss1", "name": "SS", "type": "shadowsocks", "enabled": true,
     "ss_server": "ss.example.com", "ss_port": 8388,
     "ss_method": "aes-256-gcm", "ss_password": "sec"},
    {"id": "vm", "name": "VM", "type": "vmess", "enabled": true,
     "vmess_server": "vm.example.com", "vmess_port": 10086, "vmess_uuid": "uuid"}
  ],
  "rule_sets": [
    {"id": "corp", "name": "公司", "type": "manual", "enabled": true,
     "domains": ["corp.example.com"], "cidrs": ["10.0.0.0/8"]},
    {"id": "gfw", "name": "GFW", "type": "url", "enabled": true,
     "url": "https://example.com/gfw.srs", "format": "srs"}
  ],
  "modes": [
    {"id": "m1", "name": "默认",
     "bindings": [
       {"rule_set_id": "corp", "line_id": "vpn"},
       {"rule_set_id": "gfw", "subscription_id": "sub1"}
     ],
     "default_line_id": "direct"}
  ],
  "subscriptions": [
    {"id": "sub1", "name": "Sub", "url": "https://example.com/sub",
     "format": "surge", "enabled": true, "strategy": "selector",
     "lines": [
       {"id": "n1", "name": "N1", "type": "trojan", "enabled": true,
        "trojan_server": "n1.example.com", "trojan_port": 443,
        "trojan_password": "p1", "trojan_sni": "n1.example.com"}
     ],
     "updated_at": 0}
  ],
  "active_mode_id": "m1"
}`

// oldFormatProfileJSON 是与上面 new 格式语义完全相同、但使用旧比喻 key 命名的版本：
// ports / cargoes / cruises / active_cruise_id，绑定里 cargo_id / port_id，
// 顶层 default_port_id，订阅内嵌的 ports。Line 内部的 trojan_port / ss_port /
// vmess_port 在两份里都用同样的复合 key（它们不是被重命名的目标）。
const oldFormatProfileJSON = `{
  "ports": [
    {"id": "direct", "name": "直连", "type": "direct", "enabled": true},
    {"id": "vpn", "name": "VPN", "type": "vpn", "enabled": true,
     "vpn_server": "vpn.example.com", "vpn_username": "u", "vpn_password": "p"},
    {"id": "tj", "name": "TJ", "type": "trojan", "enabled": true,
     "trojan_server": "tr.example.com", "trojan_port": 443,
     "trojan_password": "pw", "trojan_sni": "tr.example.com"},
    {"id": "ss1", "name": "SS", "type": "shadowsocks", "enabled": true,
     "ss_server": "ss.example.com", "ss_port": 8388,
     "ss_method": "aes-256-gcm", "ss_password": "sec"},
    {"id": "vm", "name": "VM", "type": "vmess", "enabled": true,
     "vmess_server": "vm.example.com", "vmess_port": 10086, "vmess_uuid": "uuid"}
  ],
  "cargoes": [
    {"id": "corp", "name": "公司", "type": "manual", "enabled": true,
     "domains": ["corp.example.com"], "cidrs": ["10.0.0.0/8"]},
    {"id": "gfw", "name": "GFW", "type": "url", "enabled": true,
     "url": "https://example.com/gfw.srs", "format": "srs"}
  ],
  "cruises": [
    {"id": "m1", "name": "默认",
     "bindings": [
       {"cargo_id": "corp", "port_id": "vpn"},
       {"cargo_id": "gfw", "subscription_id": "sub1"}
     ],
     "default_port_id": "direct"}
  ],
  "subscriptions": [
    {"id": "sub1", "name": "Sub", "url": "https://example.com/sub",
     "format": "surge", "enabled": true, "strategy": "selector",
     "ports": [
       {"id": "n1", "name": "N1", "type": "trojan", "enabled": true,
        "trojan_server": "n1.example.com", "trojan_port": 443,
        "trojan_password": "p1", "trojan_sni": "n1.example.com"}
     ],
     "updated_at": 0}
  ],
  "active_cruise_id": "m1"
}`

// TestCompat_OldFormatDecodesLikeNew 验证：旧比喻 key 的 profile JSON 解码后
// 与等价的新 key JSON 解码结果完全一致（含 Line 内部 trojan_port/ss_port/
// vmess_port 未被误伤、Subscription 内嵌 lines、Mode 绑定 rule_set_id/line_id）。
func TestCompat_OldFormatDecodesLikeNew(t *testing.T) {
	newProfile, err := ParseProfile([]byte(newFormatProfileJSON))
	if err != nil {
		t.Fatalf("parse new format: %v", err)
	}
	oldProfile, err := ParseProfile([]byte(oldFormatProfileJSON))
	if err != nil {
		t.Fatalf("parse old format: %v", err)
	}

	if !reflect.DeepEqual(newProfile, oldProfile) {
		t.Fatalf("old-format decode != new-format decode\n new=%+v\n old=%+v", newProfile, oldProfile)
	}
}

// TestCompat_PortSubstringNotClobbered 精准锚定：解码旧格式后，Line 里含 "port"
// 子串的复合字段（TrojanPort/SSPort/VMessPort）必须保留原值，证明 key 重写用的是
// 精确匹配而非子串替换。
func TestCompat_PortSubstringNotClobbered(t *testing.T) {
	p, err := ParseProfile([]byte(oldFormatProfileJSON))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	tj := p.FindLine("tj")
	if tj == nil || tj.TrojanPort != 443 {
		t.Errorf("trojan_port lost: %+v", tj)
	}
	ss := p.FindLine("ss1")
	if ss == nil || ss.SSPort != 8388 {
		t.Errorf("ss_port lost: %+v", ss)
	}
	vm := p.FindLine("vm")
	if vm == nil || vm.VMessPort != 10086 {
		t.Errorf("vmess_port lost: %+v", vm)
	}
}

// TestCompat_NewFormatIdempotent 验证规范化对新格式是幂等的：新格式 JSON 直接解码，
// 与先经 UnmarshalJSON（内部规范化）解码结果一致（其实就是同一路径，这里额外确认
// 规范化不会破坏已是新 key 的数据）。
func TestCompat_NewFormatIdempotent(t *testing.T) {
	var viaUnmarshal Profile
	if err := json.Unmarshal([]byte(newFormatProfileJSON), &viaUnmarshal); err != nil {
		t.Fatalf("unmarshal new: %v", err)
	}
	// 手动构造期望结构里的关键字段做基本校验（完整对比已由上一个测试覆盖）。
	if viaUnmarshal.ActiveModeID != "m1" {
		t.Errorf("active_mode_id = %q, want m1", viaUnmarshal.ActiveModeID)
	}
	if len(viaUnmarshal.Lines) != 5 {
		t.Errorf("lines = %d, want 5", len(viaUnmarshal.Lines))
	}
	if len(viaUnmarshal.RuleSets) != 2 {
		t.Errorf("rule_sets = %d, want 2", len(viaUnmarshal.RuleSets))
	}
	if len(viaUnmarshal.Modes) != 1 || len(viaUnmarshal.Modes[0].Bindings) != 2 {
		t.Errorf("modes/bindings mismatch: %+v", viaUnmarshal.Modes)
	}
	if viaUnmarshal.Modes[0].Bindings[0].RuleSetID != "corp" ||
		viaUnmarshal.Modes[0].Bindings[0].LineID != "vpn" {
		t.Errorf("binding[0] = %+v, want rule_set_id=corp line_id=vpn", viaUnmarshal.Modes[0].Bindings[0])
	}
	if len(viaUnmarshal.Subscriptions) != 1 || len(viaUnmarshal.Subscriptions[0].Lines) != 1 {
		t.Errorf("subscription lines mismatch: %+v", viaUnmarshal.Subscriptions)
	}
}
