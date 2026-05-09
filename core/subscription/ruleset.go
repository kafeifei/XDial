package subscription

import (
	"strings"

	"github.com/kafeifei/xdial/core/config"
)

// ExpandRulesets 下载并展开所有 RULE-SET 规则为内联规则。
// 原始 RULE-SET 保留不动（buildSubscriptionRules 中 continue），
// 展开后的规则追加到 Rules 末尾。
func ExpandRulesets(result *ParseResult) {
	if result == nil {
		return
	}
	var expanded []config.SubscriptionRule
	for _, rule := range result.Rules {
		if rule.Type != "RULE-SET" {
			continue
		}
		lines, err := fetchRuleSetContent(rule.Value)
		if err != nil {
			continue
		}
		for _, line := range lines {
			if r, ok := ruleSetLineToRule(line, rule.Group); ok {
				expanded = append(expanded, r)
			}
		}
	}
	result.Rules = append(result.Rules, expanded...)
}

func fetchRuleSetContent(url string) ([]string, error) {
	content, err := fetch(url)
	if err != nil {
		return nil, err
	}
	return strings.Split(content, "\n"), nil
}

// ruleSetLineToRule 解析 .list 文件中的单行
// 格式: TYPE,value   (DOMAIN-SUFFIX,google.com)
func ruleSetLineToRule(line, group string) (config.SubscriptionRule, bool) {
	line = strings.TrimSpace(line)
	if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, "//") {
		return config.SubscriptionRule{}, false
	}
	parts := strings.SplitN(line, ",", 2)
	if len(parts) != 2 {
		return config.SubscriptionRule{}, false
	}
	typ := strings.TrimSpace(parts[0])
	value := strings.TrimSpace(parts[1])
	if typ == "" || value == "" {
		return config.SubscriptionRule{}, false
	}
	switch typ {
	case "DOMAIN-SUFFIX", "DOMAIN", "DOMAIN-KEYWORD", "IP-CIDR", "IP-CIDR6", "GEOIP":
		return config.SubscriptionRule{Type: typ, Value: value, Group: group}, true
	}
	return config.SubscriptionRule{}, false
}
