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
	LineTypeAnyTLS      LineType = "anytls"
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

	// AnyTLS
	AnyTLSServer                   string   `json:"anytls_server,omitempty"`
	AnyTLSPort                     int      `json:"anytls_port,omitempty"`
	AnyTLSPassword                 string   `json:"anytls_password,omitempty"`
	AnyTLSSNI                      string   `json:"anytls_sni,omitempty"`
	AnyTLSClientFingerprint        string   `json:"anytls_client_fingerprint,omitempty"`
	AnyTLSALPN                     []string `json:"anytls_alpn,omitempty"`
	AnyTLSIdleSessionCheckInterval int      `json:"anytls_idle_session_check_interval,omitempty"`
	AnyTLSIdleSessionTimeout       int      `json:"anytls_idle_session_timeout,omitempty"`
	AnyTLSMinIdleSession           int      `json:"anytls_min_idle_session,omitempty"`

	// Tailscale
	//
	// 身份（设备名、登录态、state 目录）不在这里 —— 它是整个 Profile 全局唯一的一份，
	// 见 Profile.Tailscale。Line 上只留“这条线路怎么用那个 tailnet”：
	// 选哪个出口，以及是否显式启用这条线路的 MagicDNS 与节点路由。
	// 两者都只在 Line 被 active Mode 引用时进入数据面。
	TailscaleExitNode string `json:"tailscale_exit_node,omitempty"`
	TailscaleMagicDNS bool   `json:"tailscale_magic_dns,omitempty"`

	// TailscaleAuthKey 仅为旧移动端 Profile 兼容字段。D33 桌面控制面不得持久化它；
	// Auth Key 只在用户显式注册请求里瞬时进入 setup session，日常桌面配置生成会忽略
	// 这个字段。
	//
	// 只能用可复用的持久 key，不要 ephemeral key：ephemeral 节点在会话关闭后
	// 被控制面立刻回收，下次复用 state 会被要求重新登录（见 buildTailscaleEndpoint）。
	//
	// 敏感值：与 VPNPassword 同级，任何对外暴露 profile 的地方（调试接口、日志）
	// 都必须脱敏。
	TailscaleAuthKey string `json:"tailscale_auth_key,omitempty"`

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
	RuleSetTypeURL         RuleSetType = "url"
	RuleSetTypeManual      RuleSetType = "manual"
	RuleSetTypeApplication RuleSetType = "application"
)

// RuleSetMatchKind 是 NetworkExtension 在严格下载并解析远程规则集后写入的
// 单次生成元数据。它不属于用户配置，也不会持久化；Transparent Proxy 用它
// 区分“先按 Line 解析域名”和“先按系统 DNS 得到 IP”这两个阶段。
type RuleSetMatchKind string

const (
	RuleSetMatchUnknown RuleSetMatchKind = ""
	RuleSetMatchDomain  RuleSetMatchKind = "domain"
	RuleSetMatchIP      RuleSetMatchKind = "ip"
	RuleSetMatchMixed   RuleSetMatchKind = "mixed"
)

// ApplicationMatch 是一个由用户选择的 macOS App Bundle。数据面按 Path 的
// Bundle 前缀匹配实际发起连接的可执行文件，与 Surge Mac 的 App Bundle 模式一致。
// 旧 Profile 里的 identities 字段由 JSON 解码器忽略，不再参与任何路由语义。
type ApplicationMatch struct {
	Name string `json:"name,omitempty"`
	Path string `json:"path"`
}

// RuleSet 规则：匹配哪些流量
type RuleSet struct {
	ID      string      `json:"id"`
	Name    string      `json:"name"`
	Type    RuleSetType `json:"type"`
	Enabled bool        `json:"enabled"`

	// URL 规则（远程规则集）
	URL    string `json:"url,omitempty"`
	Format string `json:"format,omitempty"`
	// Invert 只作用于 URL RuleSet 的匹配条件。它让“海外 IP”可以复用
	// 国内 IP 列表并取反，避免维护一份庞大且容易漂移的补集。
	Invert bool `json:"invert,omitempty"`

	// 手动规则
	Domains []string `json:"domains,omitempty"`
	CIDRs   []string `json:"cidrs,omitempty"`

	// 应用规则。它只保存 App Bundle 路径及控制面展示元数据，不携带任何 Line 或
	// Mode 信息；只有 active Mode 的 binding 才会把它编译为数据面规则。
	Applications []ApplicationMatch `json:"applications,omitempty"`

	RuntimeMatchKind RuleSetMatchKind `json:"-"`
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
	Selected string   `json:"selected,omitempty"`
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
	Selected     string             `json:"selected,omitempty"`
	Lines        []Line             `json:"lines"`
	ProxyGroups  []ProxyGroup       `json:"proxy_groups,omitempty"`
	Rules        []SubscriptionRule `json:"rules,omitempty"`
	UpdatedAt    int64              `json:"updated_at"`
	TestURL      string             `json:"test_url,omitempty"`
	TestInterval int                `json:"test_interval,omitempty"`
}

// TailscaleIdentity 是本机在 tailnet 中的身份，整个 Profile 全局唯一一份。
//
// 一个 tsnet 实例就是 tailnet 里的一台设备，两个实例不能共用同一份 state
// （node key 不能同时活跃在两处），所以身份必须是全局的：所有 Tailscale 线路
// 共享同一次登录、同一个 state 目录，退出登录一次全部失效。
type TailscaleIdentity struct {
	// Hostname 注册到 tailnet 的设备名，首次登录时自动生成后固定不变
	// （见 GenerateTailscaleHostname）。不由用户填写 —— 手填既容易和官方
	// 客户端注册的同名设备混淆，也无法保证唯一。
	Hostname string `json:"hostname,omitempty"`
}

// Profile 完整配置
type Profile struct {
	Lines         []Line            `json:"lines"`
	RuleSets      []RuleSet         `json:"rule_sets"`
	Modes         []Mode            `json:"modes"`
	Subscriptions []Subscription    `json:"subscriptions,omitempty"`
	ActiveModeID  string            `json:"active_mode_id"`
	Tailscale     TailscaleIdentity `json:"tailscale,omitempty"`
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
