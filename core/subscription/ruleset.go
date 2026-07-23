package subscription

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/kafeifei/xdial/core/config"
)

const (
	maxStrictRemoteRuleSets = 32
	maxStrictRuleSetBytes   = 1 * 1024 * 1024
	maxStrictRuleSetLines   = 20_000
	maxStrictExpandedRules  = 20_000
)

// ExpandRulesets 下载并就地展开所有 RULE-SET 规则为内联规则。
// 每条 RULE-SET 在其原始位置被替换为展开后的规则，保持分流规则的首匹配优先级
// （之前是把展开结果追加到 Rules 末尾，导致排在 RULE-SET 之后的规则反而先匹配）。
// 下载失败的 RULE-SET 保留原始占位（generator 的 buildSubscriptionRules 会跳过），
// 不改变后续规则的相对顺序。
func ExpandRulesets(result *ParseResult) {
	_ = expandRulesets(context.Background(), result, false)
}

// ExpandRulesetsStrict 用于移动端导入：所有远程规则都必须在同一总时限内成功展开，
// 否则整次导入失败，避免生成器跳过残留占位后静默改变路由语义。
func ExpandRulesetsStrict(result *ParseResult) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	return expandRulesets(ctx, result, true)
}

func expandRulesets(ctx context.Context, result *ParseResult, strict bool) error {
	return expandRulesetsWithFetcher(ctx, result, strict, fetchRuleSetContent)
}

type ruleSetFetcher func(context.Context, string, bool, int64) (string, error)

func expandRulesetsWithFetcher(ctx context.Context, result *ParseResult, strict bool, fetcher ruleSetFetcher) error {
	if result == nil {
		return nil
	}
	if strict {
		remoteCount := 0
		for _, rule := range result.Rules {
			if strings.EqualFold(rule.Type, "RULE-SET") {
				remoteCount++
			}
		}
		if remoteCount > maxStrictRemoteRuleSets {
			return fmt.Errorf("subscription contains too many remote rule sets")
		}
		if len(result.Rules) > maxStrictExpandedRules {
			return fmt.Errorf("subscription contains too many rules")
		}
	}

	out := make([]config.SubscriptionRule, 0, len(result.Rules))
	remainingBytes := int64(maxStrictRuleSetBytes)
	remainingLines := maxStrictRuleSetLines
	for _, rule := range result.Rules {
		if !strings.EqualFold(rule.Type, "RULE-SET") {
			if strict && len(out) >= maxStrictExpandedRules {
				return fmt.Errorf("subscription contains too many rules")
			}
			out = append(out, rule)
			continue
		}
		if strict {
			if err := validateStrictRemoteURL(rule.Value); err != nil {
				return err
			}
		}
		content, err := fetcher(ctx, rule.Value, strict, remainingBytes)
		if err != nil {
			if strict {
				return fmt.Errorf("remote rule set could not be downloaded")
			}
			out = append(out, rule) // 保留占位，不丢位置
			continue
		}
		if strict {
			if int64(len(content)) > remainingBytes {
				return fmt.Errorf("remote rule sets exceed the total size limit")
			}
			remainingBytes -= int64(len(content))
			lineCount := strings.Count(content, "\n") + 1
			if lineCount > remainingLines {
				return fmt.Errorf("remote rule sets contain too many lines")
			}
			remainingLines -= lineCount
		}
		lines := strings.Split(content, "\n")
		for _, line := range lines {
			if r, ok := ruleSetLineToRule(line, rule.Group); ok {
				if strict && len(out) >= maxStrictExpandedRules {
					return fmt.Errorf("subscription contains too many expanded rules")
				}
				out = append(out, r)
			}
		}
	}
	result.Rules = out
	return nil
}

func fetchRuleSetContent(ctx context.Context, url string, strict bool, maxBytes int64) (string, error) {
	if strict {
		return fetchStrictWithContextLimit(ctx, url, maxBytes)
	}
	return fetchWithContext(ctx, url)
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
