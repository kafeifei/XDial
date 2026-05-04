package config

import (
	"encoding/json"
	"fmt"
	"path"
	"strings"
)

type SingBoxConfig struct {
	Log          map[string]interface{}   `json:"log"`
	DNS          map[string]interface{}   `json:"dns"`
	Inbounds     []map[string]interface{} `json:"inbounds"`
	Outbounds    []map[string]interface{} `json:"outbounds"`
	Route        map[string]interface{}   `json:"route"`
	Experimental map[string]interface{}   `json:"experimental,omitempty"`
}

// 测试 IP 信息的域名（流量走 selector 出口组）
var testDomains = []string{"ip.sb", "ipinfo.io", "ip-api.com"}

const (
	testSelectorTag    = "test-out"
	clashAPIController = "127.0.0.1:9090"
)

func GenerateSingBox(profile *Profile, socksPort int, vpnServerIP string) ([]byte, error) {
	cruise := profile.ActiveCruise()
	if cruise == nil {
		return nil, fmt.Errorf("no active cruise")
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

	for _, port := range profile.Ports {
		if !port.Enabled || port.Type == PortTypeDirect || port.Type == PortTypeVPN {
			continue
		}
		ob := buildProxyOutbound(&port)
		if ob != nil {
			outbounds = append(outbounds, ob)
		}
	}

	// selector 出口组：包含所有有效港口，App 通过 Clash API 切换以测试每个港口的真实 IP
	selectorMembers := []string{"direct", "vpn"}
	for _, ob := range outbounds {
		tag, _ := ob["tag"].(string)
		if tag == "direct" || tag == "vpn" {
			continue
		}
		selectorMembers = append(selectorMembers, tag)
	}
	outbounds = append(outbounds, map[string]interface{}{
		"type":      "selector",
		"tag":       testSelectorTag,
		"outbounds": selectorMembers,
		"default":   "direct",
	})

	routeRules := buildRouteRules(profile, cruise)
	ruleSets := collectRuleSets(profile, cruise)

	defaultTag := "direct"
	if cruise.DefaultPortID != "" {
		if p := profile.FindPort(cruise.DefaultPortID); p != nil {
			defaultTag = resolveOutboundTag(p)
		}
	}

	route := map[string]interface{}{
		"rules":                 routeRules,
		"auto_detect_interface": true,
		"final":                 defaultTag,
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
		Experimental: map[string]interface{}{
			"clash_api": map[string]interface{}{
				"external_controller": clashAPIController,
			},
		},
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

func buildRouteRules(profile *Profile, cruise *Cruise) []map[string]interface{} {
	var rules []map[string]interface{}

	rules = append(rules, map[string]interface{}{
		"action": "sniff",
	})

	rules = append(rules, map[string]interface{}{
		"protocol": "dns",
		"action":   "route",
		"outbound": "direct",
	})

	// 测试 IP 域名走 selector 出口组
	rules = append(rules, map[string]interface{}{
		"domain_suffix": testDomains,
		"outbound":      testSelectorTag,
	})

	for _, binding := range cruise.Bindings {
		cargo := profile.FindCargo(binding.CargoID)
		port := profile.FindPort(binding.PortID)
		if cargo == nil || port == nil || !cargo.Enabled {
			continue
		}

		outTag := resolveOutboundTag(port)
		routeRule := buildRouteRule(cargo, outTag)
		if routeRule != nil {
			rules = append(rules, routeRule)
		}
	}

	return rules
}

func buildRouteRule(c *Cargo, outTag string) map[string]interface{} {
	switch c.Type {
	case CargoTypeURL:
		if c.URL == "" {
			return nil
		}
		return map[string]interface{}{
			"rule_set": ruleSetTag(c),
			"outbound": outTag,
		}
	case CargoTypeManual:
		rule := map[string]interface{}{
			"outbound": outTag,
		}
		if len(c.Domains) > 0 {
			rule["domain_suffix"] = c.Domains
		}
		if len(c.CIDRs) > 0 {
			rule["ip_cidr"] = c.CIDRs
		}
		if len(c.Domains) == 0 && len(c.CIDRs) == 0 {
			return nil
		}
		return rule
	}
	return nil
}

func collectRuleSets(profile *Profile, cruise *Cruise) []map[string]interface{} {
	seen := map[string]bool{}
	var sets []map[string]interface{}

	for _, binding := range cruise.Bindings {
		c := profile.FindCargo(binding.CargoID)
		if c == nil || !c.Enabled || c.Type != CargoTypeURL || c.URL == "" {
			continue
		}
		tag := ruleSetTag(c)
		if seen[tag] {
			continue
		}
		seen[tag] = true

		format := resolveRuleSetFormat(c)
		sets = append(sets, map[string]interface{}{
			"type":            "remote",
			"tag":             tag,
			"format":          format,
			"url":             c.URL,
			"download_detour": "direct",
		})
	}
	return sets
}

func ruleSetTag(c *Cargo) string {
	return "ruleset-" + c.ID
}

func resolveRuleSetFormat(c *Cargo) string {
	if c.Format != "" && c.Format != "auto" {
		switch c.Format {
		case "srs":
			return "binary"
		case "json":
			return "source"
		default:
			return c.Format
		}
	}
	ext := strings.ToLower(path.Ext(c.URL))
	switch ext {
	case ".srs":
		return "binary"
	case ".json":
		return "source"
	default:
		return "binary"
	}
}

func resolveOutboundTag(port *Port) string {
	switch port.Type {
	case PortTypeDirect:
		return "direct"
	case PortTypeVPN:
		return "vpn"
	default:
		return "proxy-" + port.ID
	}
}

func buildProxyOutbound(port *Port) map[string]interface{} {
	switch port.Type {
	case PortTypeTrojan:
		if port.TrojanServer == "" {
			return nil
		}
		return map[string]interface{}{
			"type":        "trojan",
			"tag":         "proxy-" + port.ID,
			"server":      port.TrojanServer,
			"server_port": port.TrojanPort,
			"password":    port.TrojanPassword,
			"tls": map[string]interface{}{
				"enabled":     true,
				"server_name": port.TrojanSNI,
			},
		}
	case PortTypeShadowsocks:
		if port.SSServer == "" {
			return nil
		}
		return map[string]interface{}{
			"type":        "shadowsocks",
			"tag":         "proxy-" + port.ID,
			"server":      port.SSServer,
			"server_port": port.SSPort,
			"method":      port.SSMethod,
			"password":    port.SSPass,
		}
	case PortTypeVMess:
		if port.VMessServer == "" {
			return nil
		}
		return map[string]interface{}{
			"type":        "vmess",
			"tag":         "proxy-" + port.ID,
			"server":      port.VMessServer,
			"server_port": port.VMessPort,
			"uuid":        port.VMessUUID,
			"alter_id":    port.VMessAltID,
		}
	}
	return nil
}
