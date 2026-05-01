package config

const (
	LineIDCompanyVPN = "company_vpn"
	LineIDAirport    = "airport"
	LineIDDirect     = "direct"

	DiverterIDCompany = "company_domains"
	DiverterIDGFW     = "gfw"
	DiverterIDChinaIP = "china_ip"

	PresetIDOverseas        = "overseas"
	PresetIDDomestic        = "domestic"
	PresetIDDomesticAirport = "domestic_airport"
)

func DefaultDiverters() []Diverter {
	return []Diverter{
		{
			ID:      DiverterIDCompany,
			Name:    "公司域名",
			Type:    DiverterTypeCompanyDomains,
			Enabled: true,
		},
		{
			ID:      DiverterIDGFW,
			Name:    "GFW",
			Type:    DiverterTypeGFW,
			Enabled: true,
		},
		{
			ID:      DiverterIDChinaIP,
			Name:    "国内 IP",
			Type:    DiverterTypeChinaIP,
			Enabled: true,
		},
	}
}

func DefaultLines() []Line {
	return []Line{
		{
			ID:      LineIDCompanyVPN,
			Name:    "公司 VPN",
			Type:    LineTypeCompanyVPN,
			Enabled: true,
		},
		{
			ID:      LineIDAirport,
			Name:    "机场",
			Type:    LineTypeTrojan,
			Enabled: false,
		},
		{
			ID:      LineIDDirect,
			Name:    "直连",
			Type:    LineTypeDirect,
			Enabled: true,
		},
	}
}

func DefaultPresets() []Preset {
	return []Preset{
		{
			ID:   PresetIDOverseas,
			Name: "国外",
			Bindings: []Binding{
				{DiverterID: DiverterIDCompany, LineID: LineIDCompanyVPN},
				{DiverterID: DiverterIDGFW, LineID: LineIDDirect},
			},
		},
		{
			ID:   PresetIDDomestic,
			Name: "国内",
			Bindings: []Binding{
				{DiverterID: DiverterIDCompany, LineID: LineIDCompanyVPN},
				{DiverterID: DiverterIDGFW, LineID: LineIDCompanyVPN},
			},
		},
		{
			ID:   PresetIDDomesticAirport,
			Name: "国内+机场",
			Bindings: []Binding{
				{DiverterID: DiverterIDCompany, LineID: LineIDCompanyVPN},
				{DiverterID: DiverterIDGFW, LineID: LineIDAirport},
			},
		},
	}
}

func NewDefaultProfile() *Profile {
	return &Profile{
		Lines:          DefaultLines(),
		Diverters:      DefaultDiverters(),
		Presets:        DefaultPresets(),
		ActivePresetID: PresetIDOverseas,
		DefaultLineID:  LineIDDirect,
	}
}
