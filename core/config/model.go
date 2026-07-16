package config

import (
	"encoding/json"
)

// LineType 线路类型（流量出口）
type LineType string

const (
	LineTypeDirect      LineType = "direct"
	LineTypeVPN         LineType = "vpn"
	LineTypeTrojan      LineType = "trojan"
	LineTypeShadowsocks LineType = "shadowsocks"
	LineTypeVMess       LineType = "vmess"
	LineTypeTailscale   LineType = "tailscale"
)

// Line 线路：流量从哪个通道出去
type Line struct {
	ID      string   `json:"id"`
	Name    string   `json:"name"`
	Type    LineType `json:"type"`
	Enabled bool     `json:"enabled"`

	// VPN (AnyConnect via sslcon)
	VPNServer   string `json:"vpn_server,omitempty"`
	VPNUsername string `json:"vpn_username,omitempty"`
	VPNPassword string `json:"vpn_password,omitempty"`

	// Trojan
	TrojanServer   string `json:"trojan_server,omitempty"`
	TrojanPort     int    `json:"trojan_port,omitempty"`
	TrojanPassword string `json:"trojan_password,omitempty"`
	TrojanSNI      string `json:"trojan_sni,omitempty"`

	// Shadowsocks
	SSServer string `json:"ss_server,omitempty"`
	SSPort   int    `json:"ss_port,omitempty"`
	SSMethod string `json:"ss_method,omitempty"`
	SSPass   string `json:"ss_password,omitempty"`

	// VMess
	VMessServer string `json:"vmess_server,omitempty"`
	VMessPort   int    `json:"vmess_port,omitempty"`
	VMessUUID   string `json:"vmess_uuid,omitempty"`
	VMessAltID  int    `json:"vmess_alt_id,omitempty"`

	// Tailscale
	TailscaleHostname     string `json:"tailscale_hostname,omitempty"`
	TailscaleAcceptRoutes bool   `json:"tailscale_accept_routes,omitempty"`
	TailscaleExitNode     string `json:"tailscale_exit_node,omitempty"`

	// 通用传输选项
	TFO bool `json:"tfo,omitempty"` // TCP Fast Open
	UDP bool `json:"udp,omitempty"` // UDP relay / over TCP

	// AllowInsecure 跳过 TLS 证书验证（自签场景显式 opt-in）。默认 false=验证：
	// 之前 VPN 硬编码跳过验证、trojan 按 SNI!=server 启发式跳过，都是不安全默认，
	// 公开仓库里对全世界暴露 MITM 窃取凭据的面。
	AllowInsecure bool `json:"allow_insecure,omitempty"`
}

// RuleSetType 规则类型（流量匹配规则）
type RuleSetType string

const (
	RuleSetTypeURL    RuleSetType = "url"
	RuleSetTypeManual RuleSetType = "manual"
)

// RuleSet 规则：匹配哪些流量
type RuleSet struct {
	ID      string      `json:"id"`
	Name    string      `json:"name"`
	Type    RuleSetType `json:"type"`
	Enabled bool        `json:"enabled"`

	// URL 规则（远程规则集）
	URL    string `json:"url,omitempty"`
	Format string `json:"format,omitempty"`

	// 手动规则
	Domains []string `json:"domains,omitempty"`
	CIDRs   []string `json:"cidrs,omitempty"`
}

// RuleBinding 模式中的一条绑定：规则→线路（或订阅）
type RuleBinding struct {
	RuleSetID      string `json:"rule_set_id"`
	LineID         string `json:"line_id,omitempty"`
	SubscriptionID string `json:"subscription_id,omitempty"`
}

// Mode 模式：一组规则→线路的绑定
type Mode struct {
	ID                    string        `json:"id"`
	Name                  string        `json:"name"`
	Bindings              []RuleBinding `json:"bindings"`
	DefaultLineID         string        `json:"default_line_id"`
	DefaultSubscriptionID string        `json:"default_subscription_id,omitempty"`
}

// ProxyGroup 订阅内的策略组
type ProxyGroup struct {
	Name     string   `json:"name"`
	Type     string   `json:"type"`    // select / urltest / fallback
	Proxies  []string `json:"proxies"` // 节点名或其他组名
	URL      string   `json:"url,omitempty"`
	Interval int      `json:"interval,omitempty"`
}

// SubscriptionRule 订阅内的规则
type SubscriptionRule struct {
	Type  string `json:"type"`  // RULE-SET / DOMAIN-SUFFIX / DOMAIN / IP-CIDR / GEOIP / FINAL
	Value string `json:"value"` // URL 或匹配值
	Group string `json:"group"` // 策略组名
}

// Subscription 订阅：通过 URL 批量导入的完整配置
type Subscription struct {
	ID           string             `json:"id"`
	Name         string             `json:"name"`
	URL          string             `json:"url"`
	Format       string             `json:"format"`
	Enabled      bool               `json:"enabled"`
	Strategy     string             `json:"strategy"`
	Lines        []Line             `json:"lines"`
	ProxyGroups  []ProxyGroup       `json:"proxy_groups,omitempty"`
	Rules        []SubscriptionRule `json:"rules,omitempty"`
	UpdatedAt    int64              `json:"updated_at"`
	TestURL      string             `json:"test_url,omitempty"`
	TestInterval int                `json:"test_interval,omitempty"`
}

// Profile 完整配置
type Profile struct {
	Lines         []Line         `json:"lines"`
	RuleSets      []RuleSet      `json:"rule_sets"`
	Modes         []Mode         `json:"modes"`
	Subscriptions []Subscription `json:"subscriptions,omitempty"`
	ActiveModeID  string         `json:"active_mode_id"`
}

// UnmarshalJSON 让 Profile 解码时兼容旧比喻命名的 JSON key
// （ports/cargoes/cruises/active_cruise_id/cargo_id/port_id/default_port_id），
// 使 Go 侧无论收到新格式还是旧格式的 profileJSON 都能正确解码。
// 规范化通过 normalizeProfileKeys 递归重写 key 完成，然后用别名类型
// （profileAlias，无自定义 UnmarshalJSON）解码，避免无限递归。
func (p *Profile) UnmarshalJSON(data []byte) error {
	normalized, err := normalizeProfileKeys(data)
	if err != nil {
		return err
	}
	type profileAlias Profile
	var alias profileAlias
	if err := json.Unmarshal(normalized, &alias); err != nil {
		return err
	}
	*p = Profile(alias)
	return nil
}

// ParseProfile 从 JSON 解码 Profile，兼容新旧两种 key 命名。
// 是所有 profileJSON 解码入口的推荐调用点（等价于 json.Unmarshal 到 *Profile，
// 因为 Profile 已实现兼容旧 key 的 UnmarshalJSON）。
func ParseProfile(data []byte) (*Profile, error) {
	var p Profile
	if err := json.Unmarshal(data, &p); err != nil {
		return nil, err
	}
	return &p, nil
}

func (p *Profile) ActiveMode() *Mode {
	for i := range p.Modes {
		if p.Modes[i].ID == p.ActiveModeID {
			return &p.Modes[i]
		}
	}
	return nil
}

func (p *Profile) FindLine(id string) *Line {
	for i := range p.Lines {
		if p.Lines[i].ID == id {
			return &p.Lines[i]
		}
	}
	return nil
}

func (p *Profile) FindRuleSet(id string) *RuleSet {
	for i := range p.RuleSets {
		if p.RuleSets[i].ID == id {
			return &p.RuleSets[i]
		}
	}
	return nil
}

func (p *Profile) FindSubscription(id string) *Subscription {
	for i := range p.Subscriptions {
		if p.Subscriptions[i].ID == id {
			return &p.Subscriptions[i]
		}
	}
	return nil
}

// VPNLine 返回第一个 VPN 类型的线路（用于获取 VPN 服务器地址）
func (p *Profile) VPNLine() *Line {
	for i := range p.Lines {
		if p.Lines[i].Type == LineTypeVPN {
			return &p.Lines[i]
		}
	}
	return nil
}

// ActiveVPNLine 返回活动模式实际引用的 VPN 线路。
func (p *Profile) ActiveVPNLine() *Line {
	mode := p.ActiveMode()
	if mode == nil {
		return nil
	}
	for _, binding := range mode.Bindings {
		line := p.FindLine(binding.LineID)
		if line != nil && line.Enabled && line.Type == LineTypeVPN {
			return line
		}
	}
	line := p.FindLine(mode.DefaultLineID)
	if line != nil && line.Enabled && line.Type == LineTypeVPN {
		return line
	}
	return nil
}
