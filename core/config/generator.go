package config

import (
	"encoding/json"
	"fmt"
	"path"
	"strings"
)

type SingBoxConfig struct {
	Log       map[string]interface{}   `json:"log"`
	DNS       map[string]interface{}   `json:"dns"`
	Inbounds  []map[string]interface{} `json:"inbounds"`
	Outbounds []map[string]interface{} `json:"outbounds"`
	Route     map[string]interface{}   `json:"route"`
}

func GenerateSingBox(profile *Profile, socksPort int, vpnServerIP string) ([]byte, error) {
	strategy := profile.ActiveStrategy()
	if strategy == nil {
		return nil, fmt.Errorf("no active strategy")
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

	for _, exit := range profile.Exits {
		if !exit.Enabled || exit.Type == ExitTypeDirect || exit.Type == ExitTypeVPN {
			continue
		}
		ob := buildProxyOutbound(&exit)
		if ob != nil {
			outbounds = append(outbounds, ob)
		}
	}

	routeRules := buildRouteRules(profile, strategy)
	ruleSets := collectRuleSets(profile, strategy)

	defaultTag := "direct"
	if strategy.DefaultExitID != "" {
		if e := profile.FindExit(strategy.DefaultExitID); e != nil {
			defaultTag = resolveOutboundTag(e)
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

func buildRouteRules(profile *Profile, strategy *Strategy) []map[string]interface{} {
	var rules []map[string]interface{}

	rules = append(rules, map[string]interface{}{
		"action": "sniff",
	})

	rules = append(rules, map[string]interface{}{
		"protocol": "dns",
		"action":   "route",
		"outbound": "direct",
	})

	for _, binding := range strategy.Bindings {
		rule := profile.FindRule(binding.RuleID)
		exit := profile.FindExit(binding.ExitID)
		if rule == nil || exit == nil || !rule.Enabled {
			continue
		}

		outTag := resolveOutboundTag(exit)
		routeRule := buildRouteRule(rule, outTag)
		if routeRule != nil {
			rules = append(rules, routeRule)
		}
	}

	return rules
}

func buildRouteRule(r *Rule, outTag string) map[string]interface{} {
	switch r.Type {
	case RuleTypeURL:
		if r.URL == "" {
			return nil
		}
		return map[string]interface{}{
			"rule_set": ruleSetTag(r),
			"outbound": outTag,
		}
	case RuleTypeManual:
		rule := map[string]interface{}{
			"outbound": outTag,
		}
		if len(r.Domains) > 0 {
			rule["domain_suffix"] = r.Domains
		}
		if len(r.CIDRs) > 0 {
			rule["ip_cidr"] = r.CIDRs
		}
		if len(r.Domains) == 0 && len(r.CIDRs) == 0 {
			return nil
		}
		return rule
	}
	return nil
}

func collectRuleSets(profile *Profile, strategy *Strategy) []map[string]interface{} {
	seen := map[string]bool{}
	var sets []map[string]interface{}

	for _, binding := range strategy.Bindings {
		r := profile.FindRule(binding.RuleID)
		if r == nil || !r.Enabled || r.Type != RuleTypeURL || r.URL == "" {
			continue
		}
		tag := ruleSetTag(r)
		if seen[tag] {
			continue
		}
		seen[tag] = true

		format := resolveRuleSetFormat(r)
		sets = append(sets, map[string]interface{}{
			"type":            "remote",
			"tag":             tag,
			"format":          format,
			"url":             r.URL,
			"download_detour": "direct",
		})
	}
	return sets
}

// ruleSetTag 为 URL 规则生成唯一的 sing-box rule_set tag
func ruleSetTag(r *Rule) string {
	return "ruleset-" + r.ID
}

// resolveRuleSetFormat 根据 Rule.Format 或 URL 后缀判断格式
func resolveRuleSetFormat(r *Rule) string {
	if r.Format != "" && r.Format != "auto" {
		switch r.Format {
		case "srs":
			return "binary"
		case "json":
			return "source"
		default:
			return r.Format
		}
	}
	ext := strings.ToLower(path.Ext(r.URL))
	switch ext {
	case ".srs":
		return "binary"
	case ".json":
		return "source"
	default:
		return "binary"
	}
}

func resolveOutboundTag(exit *Exit) string {
	switch exit.Type {
	case ExitTypeDirect:
		return "direct"
	case ExitTypeVPN:
		return "vpn"
	default:
		return "proxy-" + exit.ID
	}
}

func buildProxyOutbound(exit *Exit) map[string]interface{} {
	switch exit.Type {
	case ExitTypeTrojan:
		if exit.TrojanServer == "" {
			return nil
		}
		return map[string]interface{}{
			"type":        "trojan",
			"tag":         "proxy-" + exit.ID,
			"server":      exit.TrojanServer,
			"server_port": exit.TrojanPort,
			"password":    exit.TrojanPassword,
			"tls": map[string]interface{}{
				"enabled":     true,
				"server_name": exit.TrojanSNI,
			},
		}
	case ExitTypeShadowsocks:
		if exit.SSServer == "" {
			return nil
		}
		return map[string]interface{}{
			"type":        "shadowsocks",
			"tag":         "proxy-" + exit.ID,
			"server":      exit.SSServer,
			"server_port": exit.SSPort,
			"method":      exit.SSMethod,
			"password":    exit.SSPass,
		}
	case ExitTypeVMess:
		if exit.VMessServer == "" {
			return nil
		}
		return map[string]interface{}{
			"type":        "vmess",
			"tag":         "proxy-" + exit.ID,
			"server":      exit.VMessServer,
			"server_port": exit.VMessPort,
			"uuid":        exit.VMessUUID,
			"alter_id":    exit.VMessAltID,
		}
	}
	return nil
}
