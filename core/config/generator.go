package config

import (
	"encoding/json"
	"fmt"
)

type SingBoxConfig struct {
	Log       map[string]interface{}   `json:"log"`
	DNS       map[string]interface{}   `json:"dns"`
	Inbounds  []map[string]interface{} `json:"inbounds"`
	Outbounds []map[string]interface{} `json:"outbounds"`
	Route     map[string]interface{}   `json:"route"`
}

func GenerateSingBox(profile *Profile, socksPort int, vpnServerIP string) ([]byte, error) {
	preset := profile.ActivePreset()
	if preset == nil {
		return nil, fmt.Errorf("no active preset")
	}

	outbounds := []map[string]interface{}{
		{"type": "direct", "tag": "direct"},
		{
			"type":        "socks",
			"tag":         "vpn",
			"server":      "127.0.0.1",
			"server_port": socksPort,
		},
	}

	for _, line := range profile.Lines {
		if !line.Enabled || line.Type == LineTypeDirect || line.Type == LineTypeCompanyVPN {
			continue
		}
		ob := buildProxyOutbound(&line)
		if ob != nil {
			outbounds = append(outbounds, ob)
		}
	}

	routeRules := buildRouteRules(profile, preset)
	ruleSets := collectRuleSets(profile, preset)

	route := map[string]interface{}{
		"rules":                 routeRules,
		"auto_detect_interface": true,
		"final":                 "direct",
	}
	if len(ruleSets) > 0 {
		route["rule_set"] = ruleSets
	}

	cfg := SingBoxConfig{
		Log: map[string]interface{}{
			"level": "info",
		},
		DNS: buildDNS(),
		Inbounds: []map[string]interface{}{
			buildTUNInbound(vpnServerIP),
		},
		Outbounds: outbounds,
		Route:     route,
	}

	return json.MarshalIndent(cfg, "", "  ")
}

func buildTUNInbound(vpnServerIP string) map[string]interface{} {
	inbound := map[string]interface{}{
		"type":         "tun",
		"tag":          "tun-in",
		"address":      []string{"198.18.0.1/15"},
		"mtu":          9000,
		"auto_route":   true,
		"strict_route": false,
		"stack":        "system",
	}
	if vpnServerIP != "" {
		inbound["route_exclude_address"] = []string{vpnServerIP + "/32"}
	}
	return inbound
}

func buildDNS() map[string]interface{} {
	return map[string]interface{}{
		"servers": []map[string]interface{}{
			{
				"tag":  "system",
				"type": "local",
			},
		},
	}
}

func buildRouteRules(profile *Profile, preset *Preset) []map[string]interface{} {
	var rules []map[string]interface{}

	rules = append(rules, map[string]interface{}{
		"action": "sniff",
	})

	rules = append(rules, map[string]interface{}{
		"protocol": "dns",
		"action":   "route",
		"outbound": "direct",
	})

	for _, binding := range preset.Bindings {
		diverter := profile.FindDiverter(binding.DiverterID)
		line := profile.FindLine(binding.LineID)
		if diverter == nil || line == nil || !diverter.Enabled {
			continue
		}

		outTag := resolveOutboundTag(line)
		rule := buildRule(diverter, outTag)
		if rule != nil {
			rules = append(rules, rule)
		}
	}

	return rules
}

func buildRule(d *Diverter, outTag string) map[string]interface{} {
	switch d.Type {
	case DiverterTypeCompanyDomains:
		if len(d.Domains) == 0 {
			return nil
		}
		return map[string]interface{}{
			"domain_suffix": d.Domains,
			"outbound":      outTag,
		}
	case DiverterTypeGFW:
		return map[string]interface{}{
			"rule_set":  "geosite-gfw",
			"outbound":  outTag,
		}
	case DiverterTypeChinaIP:
		return map[string]interface{}{
			"rule_set":  "geoip-cn",
			"outbound":  outTag,
		}
	case DiverterTypeCustom:
		rule := map[string]interface{}{
			"outbound": outTag,
		}
		if len(d.Domains) > 0 {
			rule["domain_suffix"] = d.Domains
		}
		if len(d.CIDRs) > 0 {
			rule["ip_cidr"] = d.CIDRs
		}
		return rule
	}
	return nil
}

func collectRuleSets(profile *Profile, preset *Preset) []map[string]interface{} {
	needed := map[string]bool{}
	for _, binding := range preset.Bindings {
		d := profile.FindDiverter(binding.DiverterID)
		if d == nil || !d.Enabled {
			continue
		}
		switch d.Type {
		case DiverterTypeGFW:
			needed["geosite-gfw"] = true
		case DiverterTypeChinaIP:
			needed["geoip-cn"] = true
		}
	}

	var sets []map[string]interface{}
	if needed["geosite-gfw"] {
		sets = append(sets, map[string]interface{}{
			"type":            "remote",
			"tag":             "geosite-gfw",
			"format":          "binary",
			"url":             "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-gfw.srs",
			"download_detour": "direct",
		})
	}
	if needed["geoip-cn"] {
		sets = append(sets, map[string]interface{}{
			"type":            "remote",
			"tag":             "geoip-cn",
			"format":          "binary",
			"url":             "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-cn.srs",
			"download_detour": "direct",
		})
	}
	return sets
}

func resolveOutboundTag(line *Line) string {
	switch line.Type {
	case LineTypeDirect:
		return "direct"
	case LineTypeCompanyVPN:
		return "vpn"
	default:
		return "proxy-" + line.ID
	}
}

func buildProxyOutbound(line *Line) map[string]interface{} {
	switch line.Type {
	case LineTypeTrojan:
		if line.TrojanServer == "" {
			return nil
		}
		return map[string]interface{}{
			"type":        "trojan",
			"tag":         "proxy-" + line.ID,
			"server":      line.TrojanServer,
			"server_port": line.TrojanPort,
			"password":    line.TrojanPassword,
			"tls": map[string]interface{}{
				"enabled":     true,
				"server_name": line.TrojanSNI,
			},
		}
	case LineTypeShadowsocks:
		if line.SSServer == "" {
			return nil
		}
		return map[string]interface{}{
			"type":        "shadowsocks",
			"tag":         "proxy-" + line.ID,
			"server":      line.SSServer,
			"server_port": line.SSPort,
			"method":      line.SSMethod,
			"password":    line.SSPass,
		}
	case LineTypeVMess:
		if line.VMessServer == "" {
			return nil
		}
		return map[string]interface{}{
			"type":        "vmess",
			"tag":         "proxy-" + line.ID,
			"server":      line.VMessServer,
			"server_port": line.VMessPort,
			"uuid":        line.VMessUUID,
			"alter_id":    line.VMessAltID,
		}
	}
	return nil
}
