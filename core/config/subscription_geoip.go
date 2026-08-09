package config

import (
	"fmt"
	"net/url"
	"path/filepath"
	"strings"
)

const subscriptionGeoIPCodePlaceholder = "{code}"

type subscriptionGeoIPRuleSetResource struct {
	code  string
	tag   string
	url   string
	path  string
	local bool
}

type effectiveSubscriptionGeoIPRule struct {
	ruleIndex int
	code      string
	private   bool
	resource  subscriptionGeoIPRuleSetResource
}

func validateSubscriptionGeoIPRuleSetResources(subscription *Subscription) error {
	if subscription == nil {
		return fmt.Errorf("subscription is nil")
	}
	_, _, groupTags := buildSubscriptionOutbounds(subscription, PlatformMacOS)
	_, err := collectEffectiveSubscriptionGeoIPRules(subscription, groupTags)
	return err
}

// collectEffectiveSubscriptionGeoIPRules 是 GEOIP 规则能否进入数据面的唯一事实源。
// 指向已删除或不可用订阅组的陈旧规则不是有效依赖：既不能要求资源地址、创建计划任务，
// 也不能在 collectSubscriptionRules 会跳过它时改变运行指纹。
func collectEffectiveSubscriptionGeoIPRules(
	subscription *Subscription,
	groupTags map[string]string,
) ([]effectiveSubscriptionGeoIPRule, error) {
	if subscription == nil {
		return nil, fmt.Errorf("subscription is nil")
	}

	var result []effectiveSubscriptionGeoIPRule
	for index, rule := range subscription.Rules {
		if !strings.EqualFold(strings.TrimSpace(rule.Type), "GEOIP") {
			continue
		}
		_, effective := subscriptionRuleOutboundTag(rule.Group, groupTags)
		if !effective {
			continue
		}
		code, err := normalizeSubscriptionGeoIPCode(rule.Value)
		if err != nil {
			return nil, fmt.Errorf(
				"subscription %q GEOIP rule #%d is invalid: %w",
				subscription.ID,
				index+1,
				err,
			)
		}
		compiled := effectiveSubscriptionGeoIPRule{
			ruleIndex: index,
			code:      code,
		}
		if code == "private" || code == "lan" {
			compiled.private = true
			result = append(result, compiled)
			continue
		}
		resource, err := subscriptionGeoIPRuleSetResourceFor(subscription, code)
		if err != nil {
			return nil, fmt.Errorf(
				"subscription %q GEOIP rule #%d is invalid: %w",
				subscription.ID,
				index+1,
				err,
			)
		}
		compiled.resource = resource
		result = append(result, compiled)
	}
	return result, nil
}

func subscriptionGeoIPRuleSetResourceFor(
	subscription *Subscription,
	rawCode string,
) (subscriptionGeoIPRuleSetResource, error) {
	var resource subscriptionGeoIPRuleSetResource
	if subscription == nil {
		return resource, fmt.Errorf("subscription is nil")
	}
	code, err := normalizeSubscriptionGeoIPCode(rawCode)
	if err != nil {
		return resource, err
	}
	if code == "private" || code == "lan" {
		return resource, fmt.Errorf("private GEOIP codes use the built-in private-address matcher")
	}

	template := subscription.GeoIPRuleSetURLTemplate
	if template == "" {
		return resource, fmt.Errorf("geoip_rule_set_url_template is required")
	}
	if strings.TrimSpace(template) != template {
		return resource, fmt.Errorf("geoip_rule_set_url_template must not contain surrounding whitespace")
	}
	if !strings.Contains(template, subscriptionGeoIPCodePlaceholder) {
		return resource, fmt.Errorf(
			"geoip_rule_set_url_template must contain %q",
			subscriptionGeoIPCodePlaceholder,
		)
	}

	resolved := strings.ReplaceAll(template, subscriptionGeoIPCodePlaceholder, code)
	parsed, err := url.Parse(resolved)
	if err != nil {
		return resource, fmt.Errorf("geoip_rule_set_url_template is not a valid URL: %w", err)
	}
	if parsed.User != nil || parsed.Fragment != "" {
		return resource, fmt.Errorf("geoip_rule_set_url_template must not contain credentials or a fragment")
	}

	resource.code = code
	resource.tag = "sub-geoip-" + subscription.ID + "-" + code
	switch strings.ToLower(parsed.Scheme) {
	case "https":
		if parsed.Host == "" {
			return subscriptionGeoIPRuleSetResource{}, fmt.Errorf(
				"https geoip_rule_set_url_template must include a host",
			)
		}
		resource.url = resolved
	case "file":
		if parsed.Host != "" || parsed.RawQuery != "" {
			return subscriptionGeoIPRuleSetResource{}, fmt.Errorf(
				"file geoip_rule_set_url_template must use an absolute local path without a host or query",
			)
		}
		localPath, err := url.PathUnescape(parsed.EscapedPath())
		if err != nil || !filepath.IsAbs(localPath) || filepath.Clean(localPath) != localPath {
			return subscriptionGeoIPRuleSetResource{}, fmt.Errorf(
				"file geoip_rule_set_url_template must resolve to a canonical absolute path",
			)
		}
		resource.local = true
		resource.path = localPath
	default:
		return subscriptionGeoIPRuleSetResource{}, fmt.Errorf(
			"geoip_rule_set_url_template must use https:// or file://",
		)
	}
	return resource, nil
}

func normalizeSubscriptionGeoIPCode(raw string) (string, error) {
	code := strings.ToLower(strings.TrimSpace(raw))
	if code == "" {
		return "", fmt.Errorf("GEOIP code is empty")
	}
	if len(code) > 64 {
		return "", fmt.Errorf("GEOIP code is too long")
	}
	for index, char := range code {
		if (char >= 'a' && char <= 'z') ||
			(char >= '0' && char <= '9') ||
			(index > 0 && (char == '-' || char == '_')) {
			continue
		}
		return "", fmt.Errorf("GEOIP code contains unsupported characters")
	}
	return code, nil
}
