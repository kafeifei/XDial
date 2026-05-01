package config

// ExitType 出口类型
type ExitType string

const (
	ExitTypeDirect      ExitType = "direct"
	ExitTypeVPN         ExitType = "vpn"
	ExitTypeTrojan      ExitType = "trojan"
	ExitTypeShadowsocks ExitType = "shadowsocks"
	ExitTypeVMess       ExitType = "vmess"
)

// Exit 出口：流量从哪个通道出去
type Exit struct {
	ID      string   `json:"id"`
	Name    string   `json:"name"`
	Type    ExitType `json:"type"`
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
}

// RuleType 规则类型
type RuleType string

const (
	RuleTypeURL    RuleType = "url"
	RuleTypeManual RuleType = "manual"
)

// Rule 规则：匹配哪些流量
type Rule struct {
	ID      string   `json:"id"`
	Name    string   `json:"name"`
	Type    RuleType `json:"type"`
	Enabled bool     `json:"enabled"`

	// URL 规则（远程规则集）
	URL    string `json:"url,omitempty"`
	Format string `json:"format,omitempty"` // srs / json / text / clash / auto

	// 手动规则
	Domains []string `json:"domains,omitempty"`
	CIDRs   []string `json:"cidrs,omitempty"`
}

// Binding 策略组中的一条绑定：规则→出口
type Binding struct {
	RuleID string `json:"rule_id"`
	ExitID string `json:"exit_id"`
}

// Strategy 策略组：一组规则→出口的绑定
type Strategy struct {
	ID            string    `json:"id"`
	Name          string    `json:"name"`
	Bindings      []Binding `json:"bindings"`
	DefaultExitID string    `json:"default_exit_id"`
}

// Profile 完整配置
type Profile struct {
	Exits            []Exit     `json:"exits"`
	Rules            []Rule     `json:"rules"`
	Strategies       []Strategy `json:"strategies"`
	ActiveStrategyID string     `json:"active_strategy_id"`
}

func (p *Profile) ActiveStrategy() *Strategy {
	for i := range p.Strategies {
		if p.Strategies[i].ID == p.ActiveStrategyID {
			return &p.Strategies[i]
		}
	}
	return nil
}

func (p *Profile) FindExit(id string) *Exit {
	for i := range p.Exits {
		if p.Exits[i].ID == id {
			return &p.Exits[i]
		}
	}
	return nil
}

func (p *Profile) FindRule(id string) *Rule {
	for i := range p.Rules {
		if p.Rules[i].ID == id {
			return &p.Rules[i]
		}
	}
	return nil
}

// VPNExit 返回第一个 VPN 类型的出口（用于获取 VPN 服务器地址）
func (p *Profile) VPNExit() *Exit {
	for i := range p.Exits {
		if p.Exits[i].Type == ExitTypeVPN {
			return &p.Exits[i]
		}
	}
	return nil
}
