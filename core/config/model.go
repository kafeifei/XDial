package config

type LineType string

const (
	LineTypeDirect      LineType = "direct"
	LineTypeCompanyVPN  LineType = "company_vpn"
	LineTypeTrojan      LineType = "trojan"
	LineTypeShadowsocks LineType = "shadowsocks"
	LineTypeVMess       LineType = "vmess"
)

type Line struct {
	ID      string   `json:"id"`
	Name    string   `json:"name"`
	Type    LineType `json:"type"`
	Enabled bool     `json:"enabled"`

	// Company VPN (AnyConnect via sslcon)
	VPNServer   string `json:"vpn_server,omitempty"`
	VPNUsername string `json:"vpn_username,omitempty"`
	VPNPassword string `json:"vpn_password,omitempty"`
	VPNProtocol string `json:"vpn_protocol,omitempty"`

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

type DiverterType string

const (
	DiverterTypeCompanyDomains DiverterType = "company_domains"
	DiverterTypeGFW            DiverterType = "gfw"
	DiverterTypeChinaIP        DiverterType = "china_ip"
	DiverterTypeCustom         DiverterType = "custom"
)

type Diverter struct {
	ID      string       `json:"id"`
	Name    string       `json:"name"`
	Type    DiverterType `json:"type"`
	Enabled bool         `json:"enabled"`

	Domains []string `json:"domains,omitempty"`
	CIDRs   []string `json:"cidrs,omitempty"`
}

type Binding struct {
	DiverterID string `json:"diverter_id"`
	LineID     string `json:"line_id"`
}

type Preset struct {
	ID       string    `json:"id"`
	Name     string    `json:"name"`
	Bindings []Binding `json:"bindings"`
}

type Profile struct {
	Lines           []Line     `json:"lines"`
	Diverters       []Diverter `json:"diverters"`
	Presets          []Preset   `json:"presets"`
	ActivePresetID  string     `json:"active_preset_id"`
	DefaultLineID   string     `json:"default_line_id"`
	SubscriptionURL string     `json:"subscription_url,omitempty"`
}

func (p *Profile) ActivePreset() *Preset {
	for i := range p.Presets {
		if p.Presets[i].ID == p.ActivePresetID {
			return &p.Presets[i]
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

func (p *Profile) FindDiverter(id string) *Diverter {
	for i := range p.Diverters {
		if p.Diverters[i].ID == id {
			return &p.Diverters[i]
		}
	}
	return nil
}
