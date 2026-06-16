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

	// 订阅 outbound：节点 + 策略组（或默认 urltest/selector）
	subTagMap := make(map[string]string)
	subGroupTagMap := make(map[string]map[string]string) // subID -> groupName -> tag
	for _, sub := range profile.Subscriptions {
		if !sub.Enabled || len(sub.Ports) == 0 {
			continue
		}
		obs, mainTag, groupTags := buildSubscriptionOutbounds(&sub)
		if mainTag != "" {
			outbounds = append(outbounds, obs...)
			subTagMap[sub.ID] = mainTag
			subGroupTagMap[sub.ID] = groupTags
		}
	}

	// selector 出口组：包含所有有效港口和订阅组
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

	// 收集所有已生成的 outbound tag，规则引用前要校验，避免引用不存在 tag 导致 sing-box 启动失败
	validTags := map[string]bool{}
	for _, ob := range outbounds {
		if tag, _ := ob["tag"].(string); tag != "" {
			validTags[tag] = true
		}
	}

	routeRules := buildSystemRouteRules()
	ruleSets := collectRuleSets(profile, cruise)

	// 订阅自带规则在邮轮规则之前（让订阅的分组规则优先匹配）
	for _, sub := range profile.Subscriptions {
		if !sub.Enabled {
			continue
		}
		groupTags := subGroupTagMap[sub.ID]
		if groupTags == nil {
			continue
		}
		subRules, subSets := buildSubscriptionRules(&sub, groupTags)
		routeRules = append(routeRules, subRules...)
		for _, s := range subSets {
			tag := s["tag"].(string)
			dup := false
			for _, existing := range ruleSets {
				if existing["tag"].(string) == tag { dup = true; break }
			}
			if !dup { ruleSets = append(ruleSets, s) }
		}
	}

	// 邮轮规则作为兜底（引用不存在的 outbound 时跳过）
	cruiseRules := buildCruiseRouteRules(profile, cruise, subTagMap, validTags)
	routeRules = append(routeRules, cruiseRules...)

	defaultTag := "direct"
	if cruise.DefaultSubscriptionID != "" {
		if tag, ok := subTagMap[cruise.DefaultSubscriptionID]; ok && validTags[tag] {
			defaultTag = tag
		}
	} else if cruise.DefaultPortID != "" {
		if p := profile.FindPort(cruise.DefaultPortID); p != nil {
			candidate := resolveOutboundTag(p)
			if validTags[candidate] {
				defaultTag = candidate
			}
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
			"cache_file": map[string]interface{}{
				"enabled": true,
				"path":    "cache.db",
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

func buildSystemRouteRules() []map[string]interface{} {
	return []map[string]interface{}{
		{"action": "sniff"},
		{"protocol": "dns", "action": "route", "outbound": "direct"},
		{"domain_suffix": testDomains, "outbound": testSelectorTag},
	}
}

func buildCruiseRouteRules(profile *Profile, cruise *Cruise, subTagMap map[string]string, validTags map[string]bool) []map[string]interface{} {
	var rules []map[string]interface{}

	for _, binding := range cruise.Bindings {
		cargo := profile.FindCargo(binding.CargoID)
		if cargo == nil || !cargo.Enabled {
			continue
		}

		var outTag string
		if binding.SubscriptionID != "" {
			outTag = subTagMap[binding.SubscriptionID]
		} else {
			port := profile.FindPort(binding.PortID)
			if port == nil {
				continue
			}
			outTag = resolveOutboundTag(port)
		}
		if outTag == "" || !validTags[outTag] {
			continue
		}

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

// buildSubscriptionOutbounds 返回所有 outbound、主 tag、以及组名→tag 映射
func buildSubscriptionOutbounds(sub *Subscription) ([]map[string]interface{}, string, map[string]string) {
	prefix := sub.ID + "-"

	// 1. 生成所有节点 outbound，建立 name→tag 映射
	var nodeObs []map[string]interface{}
	nameToTag := map[string]string{}
	for _, port := range sub.Ports {
		if !port.Enabled {
			continue
		}
		portCopy := port
		portCopy.ID = prefix + port.ID
		ob := buildProxyOutbound(&portCopy)
		if ob != nil {
			tag := ob["tag"].(string)
			nodeObs = append(nodeObs, ob)
			nameToTag[port.Name] = tag
		}
	}
	if len(nodeObs) == 0 {
		return nil, "", nil
	}

	groupTags := map[string]string{} // groupName → tag
	var groupObs []map[string]interface{}

	if len(sub.ProxyGroups) > 0 {
		// 2a. 有策略组：每个策略组生成一个 outbound
		// 先注册所有组名 tag，以便组间互相引用
		for _, g := range sub.ProxyGroups {
			groupTags[g.Name] = "sub-" + prefix + slugify(g.Name)
		}
		// "DIRECT" / "Direct" 映射到内置 direct
		nameToTag["DIRECT"] = "direct"
		nameToTag["Direct"] = "direct"

		for _, g := range sub.ProxyGroups {
			var memberTags []string
			for _, name := range g.Proxies {
				if tag, ok := nameToTag[name]; ok {
					memberTags = append(memberTags, tag)
				} else if tag, ok := groupTags[name]; ok {
					memberTags = append(memberTags, tag)
				}
			}
			if len(memberTags) == 0 {
				// 没有任何有效成员就不生成 outbound，同时从 groupTags 移除，
				// 避免 mainTag / subscription rules 后续引用一个不存在的 tag
				delete(groupTags, g.Name)
				continue
			}

			ob := map[string]interface{}{
				"tag":       groupTags[g.Name],
				"outbounds": memberTags,
			}
			switch g.Type {
			case "url-test", "urltest":
				ob["type"] = "urltest"
				url := g.URL
				if url == "" {
					url = "https://www.gstatic.com/generate_204"
				}
				ob["url"] = url
				interval := g.Interval
				if interval <= 0 {
					interval = 300
				}
				if interval > 1800 {
					interval = 1800
				}
				ob["interval"] = fmt.Sprintf("%ds", interval)
			default:
				ob["type"] = "selector"
			}
			groupObs = append(groupObs, ob)
		}
	} else {
		// 2b. 无策略组：生成一个默认 group
		var allTags []string
		for _, ob := range nodeObs {
			allTags = append(allTags, ob["tag"].(string))
		}
		groupTag := "sub-" + sub.ID
		group := map[string]interface{}{
			"tag":       groupTag,
			"outbounds": allTags,
		}
		switch sub.Strategy {
		case "selector":
			group["type"] = "selector"
		default:
			group["type"] = "urltest"
			url := sub.TestURL
			if url == "" {
				url = "https://www.gstatic.com/generate_204"
			}
			group["url"] = url
			interval := sub.TestInterval
			if interval <= 0 {
				interval = 300
			}
			if interval > 1800 {
				interval = 1800
			}
			group["interval"] = fmt.Sprintf("%ds", interval)
		}
		groupObs = append(groupObs, group)
		groupTags["__default__"] = groupTag
	}

	// 主 tag：第一个真正生成了 outbound 的策略组（按原顺序找），或默认组
	mainTag := ""
	if len(sub.ProxyGroups) > 0 {
		for _, g := range sub.ProxyGroups {
			if tag, ok := groupTags[g.Name]; ok {
				mainTag = tag
				break
			}
		}
	} else {
		mainTag = groupTags["__default__"]
	}

	all := append(nodeObs, groupObs...)
	return all, mainTag, groupTags
}

// buildSubscriptionRules 将订阅的规则转换为 sing-box route rules 和 rule_sets
func buildSubscriptionRules(sub *Subscription, groupTags map[string]string) ([]map[string]interface{}, []map[string]interface{}) {
	var rules []map[string]interface{}
	var sets []map[string]interface{}
	seenGeoIP := map[string]bool{}

	for _, r := range sub.Rules {
		outTag := groupTags[r.Group]
		if outTag == "" {
			if r.Group == "DIRECT" || r.Group == "Direct" {
				outTag = "direct"
			} else {
				continue
			}
		}

		switch r.Type {
		case "RULE-SET":
			// Clash/Surge .list 格式与 sing-box rule-set 不兼容，跳过
			// 后续可考虑下载解析后内联
			continue
		case "DOMAIN-SUFFIX":
			rules = append(rules, map[string]interface{}{
				"domain_suffix": []string{r.Value},
				"outbound":      outTag,
			})
		case "DOMAIN":
			rules = append(rules, map[string]interface{}{
				"domain": []string{r.Value},
				"outbound": outTag,
			})
		case "DOMAIN-KEYWORD":
			rules = append(rules, map[string]interface{}{
				"domain_keyword": []string{r.Value},
				"outbound":       outTag,
			})
		case "IP-CIDR", "IP-CIDR6":
			rules = append(rules, map[string]interface{}{
				"ip_cidr":  []string{r.Value},
				"outbound": outTag,
			})
		case "GEOIP":
			// sing-box 1.12 移除了内置 geoip，转换为远程 rule-set
			code := strings.ToLower(r.Value)
			setTag := "sub-geoip-" + sub.ID + "-" + code
			if !seenGeoIP[setTag] {
				seenGeoIP[setTag] = true
				sets = append(sets, map[string]interface{}{
					"type":            "remote",
					"tag":             setTag,
					"format":          "binary",
					"url":             "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-" + code + ".srs",
					"download_detour": "direct",
				})
			}
			rules = append(rules, map[string]interface{}{
				"rule_set": setTag,
				"outbound": outTag,
			})
		case "FINAL":
			// FINAL 不生成 route rule，由 sing-box 的 "final" 字段处理
			continue
		}
	}
	return rules, sets
}

func slugify(s string) string {
	// 简单 slug：取前 16 字符，替换非字母数字为 -
	r := strings.Map(func(c rune) rune {
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') {
			return c
		}
		return '-'
	}, s)
	if len(r) > 16 {
		r = r[:16]
	}
	return strings.ToLower(r)
}

func applyTransport(ob map[string]interface{}, port *Port) {
	if port.TFO {
		ob["tcp_fast_open"] = true
	}
	if port.UDP {
		ob["udp_over_tcp"] = true
	}
}

func buildProxyOutbound(port *Port) map[string]interface{} {
	switch port.Type {
	case PortTypeTrojan:
		if port.TrojanServer == "" {
			return nil
		}
		tls := map[string]interface{}{
			"enabled":     true,
			"server_name": port.TrojanSNI,
		}
		// SNI 和服务器不一致时需要跳过证书验证（伪装 SNI 场景）
		if port.TrojanSNI != "" && port.TrojanSNI != port.TrojanServer {
			tls["insecure"] = true
		}
		ob := map[string]interface{}{
			"type":        "trojan",
			"tag":         "proxy-" + port.ID,
			"server":      port.TrojanServer,
			"server_port": port.TrojanPort,
			"password":    port.TrojanPassword,
			"tls":         tls,
		}
		applyTransport(ob, port)
		return ob
	case PortTypeShadowsocks:
		if port.SSServer == "" {
			return nil
		}
		ob := map[string]interface{}{
			"type":        "shadowsocks",
			"tag":         "proxy-" + port.ID,
			"server":      port.SSServer,
			"server_port": port.SSPort,
			"method":      port.SSMethod,
			"password":    port.SSPass,
		}
		applyTransport(ob, port)
		return ob
	case PortTypeVMess:
		if port.VMessServer == "" {
			return nil
		}
		ob := map[string]interface{}{
			"type":        "vmess",
			"tag":         "proxy-" + port.ID,
			"server":      port.VMessServer,
			"server_port": port.VMessPort,
			"uuid":        port.VMessUUID,
			"alter_id":    port.VMessAltID,
		}
		applyTransport(ob, port)
		return ob
	}
	return nil
}
