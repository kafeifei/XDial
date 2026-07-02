package subscription

import (
	"strings"

	"github.com/kafeifei/xdial/core/config"
)

// ExpandRulesets 下载并就地展开所有 RULE-SET 规则为内联规则。
// 每条 RULE-SET 在其原始位置被替换为展开后的规则，保持分流规则的首匹配优先级
// （之前是把展开结果追加到 Rules 末尾，导致排在 RULE-SET 之后的规则反而先匹配）。
// 下载失败的 RULE-SET 保留原始占位（generator 的 buildSubscriptionRules 会跳过），
// 不改变后续规则的相对顺序。
func ExpandRulesets(result *ParseResult) {
	if result == nil {
		return
	}
	out := make([]config.SubscriptionRule, 0, len(result.Rules))
	for _, rule := range result.Rules {
		if rule.Type != "RULE-SET" {
			out = append(out, rule)
			continue
		}
		lines, err := fetchRuleSetContent(rule.Value)
		if err != nil {
			out = append(out, rule) // 保留占位，不丢位置
			continue
		}
		for _, line := range lines {
			if r, ok := ruleSetLineToRule(line, rule.Group); ok {
				out = append(out, r)
			}
		}
	}
	result.Rules = out
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
