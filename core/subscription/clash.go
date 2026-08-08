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

	var lines []config.Line
	for _, p := range cfg.Proxies {
		line, ok := clashProxyToLine(p)
		if ok {
			lines = append(lines, line)
		}
	}
	if len(lines) == 0 {
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

	return &ParseResult{Lines: lines, ProxyGroups: groups, Rules: rules}, nil
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

func clashProxyToLine(p map[string]interface{}) (config.Line, bool) {
	typ := strings.ToLower(getString(p, "type"))
	name := getString(p, "name")
	server := getString(p, "server")
	port := getInt(p, "port")

	if server == "" || port == 0 {
		return config.Line{}, false
	}

	base := config.Line{
		ID:      shortID(),
		Name:    name,
		Enabled: true,
	}

	switch typ {
	case "ss", "shadowsocks":
		base.Type = config.LineTypeShadowsocks
		base.SSServer = server
		base.SSPort = port
		base.SSMethod = getString(p, "cipher")
		base.SSPass = getString(p, "password")
		return base, true

	case "vmess":
		base.Type = config.LineTypeVMess
		base.VMessServer = server
		base.VMessPort = port
		base.VMessUUID = getString(p, "uuid")
		base.VMessAltID = getInt(p, "alterId")
		return base, true

	case "trojan":
		base.Type = config.LineTypeTrojan
		base.TrojanServer = server
		base.TrojanPort = port
		base.TrojanPassword = getString(p, "password")
		sni := getString(p, "sni")
		if sni == "" {
			sni = server
		}
		base.TrojanSNI = sni
		// Clash 用 skip-cert-verify 表达"跳过证书校验"，映射过来保留订阅原意，
		// 否则默认走校验（生成器不再按 SNI!=server 启发式关闭校验）
		base.AllowInsecure = getBool(p, "skip-cert-verify")
		return base, true

	case "anytls":
		base.Type = config.LineTypeAnyTLS
		base.AnyTLSServer = server
		base.AnyTLSPort = port
		base.AnyTLSPassword = getString(p, "password")
		sni := getString(p, "sni")
		if sni == "" {
			sni = getString(p, "servername")
		}
		if sni == "" {
			sni = server
		}
		base.AnyTLSSNI = sni
		base.AnyTLSClientFingerprint = normalizeAnyTLSFingerprint(
			getString(p, "client-fingerprint"),
		)

		alpn, ok := clashAnyTLSALPN(p)
		if !ok {
			return config.Line{}, false
		}
		base.AnyTLSALPN = alpn

		if value, exists := p["idle-session-check-interval"]; exists {
			seconds, valid := parseAnyTLSSessionSeconds(value)
			if !valid {
				return config.Line{}, false
			}
			base.AnyTLSIdleSessionCheckInterval = seconds
		}
		if value, exists := p["idle-session-timeout"]; exists {
			seconds, valid := parseAnyTLSSessionSeconds(value)
			if !valid {
				return config.Line{}, false
			}
			base.AnyTLSIdleSessionTimeout = seconds
		}
		if value, exists := p["min-idle-session"]; exists {
			count, valid := parseAnyTLSMinIdleSession(value)
			if !valid {
				return config.Line{}, false
			}
			base.AnyTLSMinIdleSession = count
		}

		base.AllowInsecure, ok = clashOptionalBool(p, "skip-cert-verify")
		if !ok {
			return config.Line{}, false
		}
		base.UDP, ok = clashOptionalBool(p, "udp", "udp-relay")
		if !ok {
			return config.Line{}, false
		}
		// 协议选项边界与实际 outbound 生成共用一个事实源。TFO 在后面解析：
		// 即使订阅声明了不受支持的 tfo=true，也要先完整导入该事实，再由
		// 运行时能力检查 fail-closed，不能在解析时偷偷改成 false。
		if !config.LineHasUsableOutbound(&base) {
			return config.Line{}, false
		}
		base.TFO, ok = clashOptionalBool(p, "tfo")
		if !ok {
			return config.Line{}, false
		}
		return base, true

	default:
		return config.Line{}, false
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

func getBool(m map[string]interface{}, key string) bool {
	switch v := m[key].(type) {
	case bool:
		return v
	case string:
		return v == "true" || v == "1"
	}
	return false
}

func clashOptionalBool(m map[string]interface{}, keys ...string) (bool, bool) {
	for _, key := range keys {
		if value, exists := m[key]; exists {
			return parseOptionalBool(value)
		}
	}
	return false, true
}

func clashAnyTLSALPN(m map[string]interface{}) ([]string, bool) {
	value, exists := m["alpn"]
	if !exists {
		return nil, true
	}

	var protocols []string
	switch typed := value.(type) {
	case string:
		var ok bool
		protocols, ok = splitAnyTLSALPN(typed)
		if !ok {
			return nil, false
		}
	case []string:
		protocols = append(protocols, typed...)
	case []interface{}:
		protocols = make([]string, 0, len(typed))
		for _, item := range typed {
			protocol, ok := item.(string)
			if !ok {
				return nil, false
			}
			protocols = append(protocols, protocol)
		}
	default:
		return nil, false
	}
	return normalizeAnyTLSALPN(protocols), true
}
