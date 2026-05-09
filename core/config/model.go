package config

// PortType 港口类型（流量出口）
type PortType string

const (
	PortTypeDirect      PortType = "direct"
	PortTypeVPN         PortType = "vpn"
	PortTypeTrojan      PortType = "trojan"
	PortTypeShadowsocks PortType = "shadowsocks"
	PortTypeVMess       PortType = "vmess"
)

// Port 港口：流量从哪个通道出去
type Port struct {
	ID      string   `json:"id"`
	Name    string   `json:"name"`
	Type    PortType `json:"type"`
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

	// 通用传输选项
	TFO bool `json:"tfo,omitempty"` // TCP Fast Open
	UDP bool `json:"udp,omitempty"` // UDP relay / over TCP
}

// CargoType 货品类型（流量匹配规则）
type CargoType string

const (
	CargoTypeURL    CargoType = "url"
	CargoTypeManual CargoType = "manual"
)

// Cargo 货品：匹配哪些流量
type Cargo struct {
	ID      string    `json:"id"`
	Name    string    `json:"name"`
	Type    CargoType `json:"type"`
	Enabled bool      `json:"enabled"`

	// URL 货品（远程规则集）
	URL    string `json:"url,omitempty"`
	Format string `json:"format,omitempty"`

	// 手动货品
	Domains []string `json:"domains,omitempty"`
	CIDRs   []string `json:"cidrs,omitempty"`
}

// Binding 邮轮中的一条绑定：货品→港口（或订阅）
type Binding struct {
	CargoID        string `json:"cargo_id"`
	PortID         string `json:"port_id,omitempty"`
	SubscriptionID string `json:"subscription_id,omitempty"`
}

// Cruise 邮轮：一组货品→港口的绑定
type Cruise struct {
	ID                    string    `json:"id"`
	Name                  string    `json:"name"`
	Bindings              []Binding `json:"bindings"`
	DefaultPortID         string    `json:"default_port_id"`
	DefaultSubscriptionID string    `json:"default_subscription_id,omitempty"`
}

// ProxyGroup 订阅内的策略组
type ProxyGroup struct {
	Name     string   `json:"name"`
	Type     string   `json:"type"`                // select / urltest / fallback
	Proxies  []string `json:"proxies"`             // 节点名或其他组名
	URL      string   `json:"url,omitempty"`
	Interval int      `json:"interval,omitempty"`
}

// SubscriptionRule 订阅内的规则
type SubscriptionRule struct {
	Type  string `json:"type"`   // RULE-SET / DOMAIN-SUFFIX / DOMAIN / IP-CIDR / GEOIP / FINAL
	Value string `json:"value"`  // URL 或匹配值
	Group string `json:"group"`  // 策略组名
}

// Subscription 订阅：通过 URL 批量导入的完整配置
type Subscription struct {
	ID           string             `json:"id"`
	Name         string             `json:"name"`
	URL          string             `json:"url"`
	Format       string             `json:"format"`
	Enabled      bool               `json:"enabled"`
	Strategy     string             `json:"strategy"`
	Ports        []Port             `json:"ports"`
	ProxyGroups  []ProxyGroup       `json:"proxy_groups,omitempty"`
	Rules        []SubscriptionRule `json:"rules,omitempty"`
	UpdatedAt    int64              `json:"updated_at"`
	TestURL      string             `json:"test_url,omitempty"`
	TestInterval int                `json:"test_interval,omitempty"`
}

// Profile 完整配置
type Profile struct {
	Ports          []Port         `json:"ports"`
	Cargoes        []Cargo        `json:"cargoes"`
	Cruises        []Cruise       `json:"cruises"`
	Subscriptions  []Subscription `json:"subscriptions,omitempty"`
	ActiveCruiseID string         `json:"active_cruise_id"`
}

func (p *Profile) ActiveCruise() *Cruise {
	for i := range p.Cruises {
		if p.Cruises[i].ID == p.ActiveCruiseID {
			return &p.Cruises[i]
		}
	}
	return nil
}

func (p *Profile) FindPort(id string) *Port {
	for i := range p.Ports {
		if p.Ports[i].ID == id {
			return &p.Ports[i]
		}
	}
	return nil
}

func (p *Profile) FindCargo(id string) *Cargo {
	for i := range p.Cargoes {
		if p.Cargoes[i].ID == id {
			return &p.Cargoes[i]
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

// VPNPort 返回第一个 VPN 类型的港口（用于获取 VPN 服务器地址）
func (p *Profile) VPNPort() *Port {
	for i := range p.Ports {
		if p.Ports[i].Type == PortTypeVPN {
			return &p.Ports[i]
		}
	}
	return nil
}
