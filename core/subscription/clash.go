package subscription

import (
	"fmt"
	"strings"

	"github.com/kafeifei/xdial/core/config"
	"gopkg.in/yaml.v3"
)

type clashConfig struct {
	Proxies     []map[string]interface{} `yaml:"proxies"`
	ProxyGroups []map[string]interface{} `yaml:"proxy-groups"`
	Rules       []string                 `yaml:"rules"`
}

func parseClash(content string) (*ParseResult, error) {
	var cfg clashConfig
	if err := yaml.Unmarshal([]byte(content), &cfg); err != nil {
		return nil, fmt.Errorf("yaml parse: %w", err)
	}

	var ports []config.Port
	for _, p := range cfg.Proxies {
		port, ok := clashProxyToPort(p)
		if ok {
			ports = append(ports, port)
		}
	}
	if len(ports) == 0 {
		return nil, fmt.Errorf("no supported proxies found")
	}

	var groups []config.ProxyGroup
	for _, g := range cfg.ProxyGroups {
		group, ok := clashProxyGroup(g)
		if ok {
			groups = append(groups, group)
		}
	}

	var rules []config.SubscriptionRule
	for _, r := range cfg.Rules {
		rule, ok := clashRule(r)
		if ok {
			rules = append(rules, rule)
		}
	}

	return &ParseResult{Ports: ports, ProxyGroups: groups, Rules: rules}, nil
}

func clashProxyGroup(g map[string]interface{}) (config.ProxyGroup, bool) {
	name := getString(g, "name")
	typ := getString(g, "type")
	if name == "" || typ == "" {
		return config.ProxyGroup{}, false
	}

	pg := config.ProxyGroup{
		Name:     name,
		Type:     typ,
		URL:      getString(g, "url"),
		Interval: getInt(g, "interval"),
	}

	if proxies, ok := g["proxies"].([]interface{}); ok {
		for _, p := range proxies {
			if s, ok := p.(string); ok {
				pg.Proxies = append(pg.Proxies, s)
			}
		}
	}

	return pg, len(pg.Proxies) > 0
}

func clashRule(line string) (config.SubscriptionRule, bool) {
	parts := strings.SplitN(line, ",", 4)
	if len(parts) < 2 {
		return config.SubscriptionRule{}, false
	}
	typ := strings.TrimSpace(parts[0])
	if typ == "MATCH" || typ == "FINAL" {
		return config.SubscriptionRule{Type: "FINAL", Group: strings.TrimSpace(parts[1])}, true
	}
	if len(parts) < 3 {
		return config.SubscriptionRule{}, false
	}
	return config.SubscriptionRule{
		Type:  typ,
		Value: strings.TrimSpace(parts[1]),
		Group: strings.TrimSpace(parts[2]),
	}, true
}

func clashProxyToPort(p map[string]interface{}) (config.Port, bool) {
	typ := strings.ToLower(getString(p, "type"))
	name := getString(p, "name")
	server := getString(p, "server")
	port := getInt(p, "port")

	if server == "" || port == 0 {
		return config.Port{}, false
	}

	base := config.Port{
		ID:      shortID(),
		Name:    name,
		Enabled: true,
	}

	switch typ {
	case "ss", "shadowsocks":
		base.Type = config.PortTypeShadowsocks
		base.SSServer = server
		base.SSPort = port
		base.SSMethod = getString(p, "cipher")
		base.SSPass = getString(p, "password")
		return base, true

	case "vmess":
		base.Type = config.PortTypeVMess
		base.VMessServer = server
		base.VMessPort = port
		base.VMessUUID = getString(p, "uuid")
		base.VMessAltID = getInt(p, "alterId")
		return base, true

	case "trojan":
		base.Type = config.PortTypeTrojan
		base.TrojanServer = server
		base.TrojanPort = port
		base.TrojanPassword = getString(p, "password")
		sni := getString(p, "sni")
		if sni == "" {
			sni = server
		}
		base.TrojanSNI = sni
		return base, true

	default:
		return config.Port{}, false
	}
}

func getString(m map[string]interface{}, key string) string {
	v, ok := m[key]
	if !ok {
		return ""
	}
	s, ok := v.(string)
	if ok {
		return s
	}
	return fmt.Sprintf("%v", v)
}

func getInt(m map[string]interface{}, key string) int {
	v, ok := m[key]
	if !ok {
		return 0
	}
	switch n := v.(type) {
	case int:
		return n
	case float64:
		return int(n)
	case int64:
		return int(n)
	}
	return 0
}
