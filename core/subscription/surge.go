package subscription

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/kafeifei/xdial/core/config"
)

func parseSurge(content string) (*ParseResult, error) {
	lines := strings.Split(content, "\n")
	sections := extractSurgeSections(lines)

	proxyLines := sections["Proxy"]
	if len(proxyLines) == 0 {
		return nil, fmt.Errorf("no [Proxy] section found")
	}

	var results []config.Line
	for _, line := range proxyLines {
		ln, ok := surgeLineToLine(line)
		if ok {
			results = append(results, ln)
		}
	}
	if len(results) == 0 {
		return nil, fmt.Errorf("no supported proxies found")
	}

	var groups []config.ProxyGroup
	for _, line := range sections["Proxy Group"] {
		g, ok := surgeLineToGroup(line)
		if ok {
			groups = append(groups, g)
		}
	}

	var rules []config.SubscriptionRule
	for _, line := range sections["Rule"] {
		r, ok := surgeLineToRule(line)
		if ok {
			rules = append(rules, r)
		}
	}

	return &ParseResult{Lines: results, ProxyGroups: groups, Rules: rules}, nil
}

func extractSurgeSections(lines []string) map[string][]string {
	sections := map[string][]string{}
	currentSection := ""

	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "[") && strings.HasSuffix(trimmed, "]") {
			currentSection = trimmed[1 : len(trimmed)-1]
			continue
		}
		if currentSection == "" {
			continue
		}
		if trimmed == "" || strings.HasPrefix(trimmed, "#") || strings.HasPrefix(trimmed, "//") {
			continue
		}
		sections[currentSection] = append(sections[currentSection], trimmed)
	}
	return sections
}

// Surge Proxy Group: Name = type, member1, member2, ...
// e.g. Netflix = select, Hong Kong 01, USA San Jose 01, url = http://...
func surgeLineToGroup(line string) (config.ProxyGroup, bool) {
	eqIdx := strings.Index(line, "=")
	if eqIdx < 0 {
		return config.ProxyGroup{}, false
	}
	name := strings.TrimSpace(line[:eqIdx])
	rest := strings.TrimSpace(line[eqIdx+1:])

	parts := strings.Split(rest, ",")
	if len(parts) < 2 {
		return config.ProxyGroup{}, false
	}

	typ := strings.TrimSpace(strings.ToLower(parts[0]))
	g := config.ProxyGroup{
		Name: name,
		Type: typ,
	}

	for _, p := range parts[1:] {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		// key=value 参数（url, interval 等）
		if i := strings.Index(p, "="); i > 0 {
			k := strings.TrimSpace(p[:i])
			v := strings.TrimSpace(p[i+1:])
			switch strings.ToLower(k) {
			case "url":
				g.URL = v
			case "interval":
				if n, err := strconv.Atoi(v); err == nil {
					g.Interval = n
				}
			}
			continue
		}
		g.Proxies = append(g.Proxies, p)
	}

	return g, len(g.Proxies) > 0
}

// Surge Rule: TYPE,value,group[,options]
// e.g. RULE-SET,https://...,Netflix,update-interval=86400
// e.g. DOMAIN-SUFFIX,google.com,Proxies
// e.g. GEOIP,CN,Direct
// e.g. FINAL,Final
func surgeLineToRule(line string) (config.SubscriptionRule, bool) {
	parts := strings.SplitN(line, ",", 4)
	if len(parts) < 2 {
		return config.SubscriptionRule{}, false
	}

	typ := strings.TrimSpace(parts[0])
	switch typ {
	case "FINAL":
		group := strings.TrimSpace(parts[1])
		return config.SubscriptionRule{Type: typ, Group: group}, true
	default:
		if len(parts) < 3 {
			return config.SubscriptionRule{}, false
		}
		value := strings.TrimSpace(parts[1])
		group := strings.TrimSpace(parts[2])
		return config.SubscriptionRule{Type: typ, Value: value, Group: group}, true
	}
}

// Surge format: Name = type, server, port, key=value, key=value, ...
func surgeLineToLine(line string) (config.Line, bool) {
	eqIdx := strings.Index(line, "=")
	if eqIdx < 0 {
		return config.Line{}, false
	}
	name := strings.TrimSpace(line[:eqIdx])
	rest := strings.TrimSpace(line[eqIdx+1:])

	parts := strings.SplitN(rest, ",", 4)
	if len(parts) < 3 {
		return config.Line{}, false
	}

	typ := strings.TrimSpace(strings.ToLower(parts[0]))
	server := strings.TrimSpace(parts[1])
	portNum, err := strconv.Atoi(strings.TrimSpace(parts[2]))
	if err != nil || server == "" {
		return config.Line{}, false
	}

	kvs := make(map[string]string)
	if len(parts) > 3 {
		lastKey := ""
		for _, kv := range strings.Split(parts[3], ",") {
			// 普通分隔空格可以去掉；制表符等控制字符必须保留下来，交给
			// AnyTLS 的同源 ALPN 校验拒绝，不能清洗成另一个合法协议名。
			kv = strings.Trim(kv, " ")
			if i := strings.Index(kv, "="); i > 0 {
				lastKey = strings.ToLower(strings.TrimSpace(kv[:i]))
				kvs[lastKey] = strings.Trim(kv[i+1:], " ")
			} else if lastKey == "alpn" {
				// Surge 风格是逗号分隔参数；兼容 alpn=h2,http/1.1 时，
				// 没有 "=" 的紧邻项只能是上一项 ALPN 列表的延续。
				kvs[lastKey] += "," + kv
			}
		}
	}

	base := config.Line{
		ID:      shortID(),
		Name:    name,
		Enabled: true,
	}

	switch typ {
	case "ss", "shadowsocks", "custom":
		base.Type = config.LineTypeShadowsocks
		base.SSServer = server
		base.SSPort = portNum
		base.SSMethod = kvs["encrypt-method"]
		base.SSPass = kvs["password"]
		return base, true

	case "vmess":
		base.Type = config.LineTypeVMess
		base.VMessServer = server
		base.VMessPort = portNum
		base.VMessUUID = kvs["username"]
		if kvs["vmess-aead"] == "true" {
			base.VMessAltID = 0
		}
		base.TFO = kvs["tfo"] == "true"
		base.UDP = kvs["udp-relay"] == "true"
		return base, true

	case "trojan":
		base.Type = config.LineTypeTrojan
		base.TrojanServer = server
		base.TrojanPort = portNum
		base.TrojanPassword = kvs["password"]
		sni := kvs["sni"]
		if sni == "" {
			sni = server
		}
		base.TrojanSNI = sni
		base.TFO = kvs["tfo"] == "true"
		base.UDP = kvs["udp-relay"] == "true"
		return base, true

	case "anytls":
		base.Type = config.LineTypeAnyTLS
		base.AnyTLSServer = server
		base.AnyTLSPort = portNum
		base.AnyTLSPassword = kvs["password"]
		sni := kvs["sni"]
		if sni == "" {
			sni = kvs["server-name"]
		}
		if sni == "" {
			sni = kvs["servername"]
		}
		if sni == "" {
			sni = server
		}
		base.AnyTLSSNI = sni

		base.AnyTLSClientFingerprint = normalizeAnyTLSFingerprint(kvs["client-fingerprint"])
		rawALPN, valid := splitAnyTLSALPN(kvs["alpn"])
		if !valid {
			return config.Line{}, false
		}
		base.AnyTLSALPN = normalizeAnyTLSALPN(rawALPN)

		if value, exists := kvs["idle-session-check-interval"]; exists {
			seconds, valid := parseAnyTLSSessionSeconds(value)
			if !valid {
				return config.Line{}, false
			}
			base.AnyTLSIdleSessionCheckInterval = seconds
		}
		if value, exists := kvs["idle-session-timeout"]; exists {
			seconds, valid := parseAnyTLSSessionSeconds(value)
			if !valid {
				return config.Line{}, false
			}
			base.AnyTLSIdleSessionTimeout = seconds
		}
		if value, exists := kvs["min-idle-session"]; exists {
			count, valid := parseAnyTLSMinIdleSession(value)
			if !valid {
				return config.Line{}, false
			}
			base.AnyTLSMinIdleSession = count
		}

		var ok bool
		base.AllowInsecure, ok = surgeOptionalBool(kvs, "skip-cert-verify")
		if !ok {
			return config.Line{}, false
		}
		base.UDP, ok = surgeOptionalBool(kvs, "udp", "udp-relay")
		if !ok {
			return config.Line{}, false
		}
		if !config.LineHasUsableOutbound(&base) {
			return config.Line{}, false
		}
		base.TFO, ok = surgeOptionalBool(kvs, "tfo")
		if !ok {
			return config.Line{}, false
		}
		return base, true

	default:
		return config.Line{}, false
	}
}

func surgeOptionalBool(values map[string]string, keys ...string) (bool, bool) {
	for _, key := range keys {
		if value, exists := values[key]; exists {
			return parseOptionalBool(value)
		}
	}
	return false, true
}
