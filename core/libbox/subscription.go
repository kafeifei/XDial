//go:build !windows

package libbox

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/google/uuid"
	"github.com/kafeifei/xdial/core/config"
	"github.com/kafeifei/xdial/core/subscription"
)

const maxParsedSubscriptionBytes = 1 * 1024 * 1024

// SubscriptionRuntimeCatalog returns the exact generated node/group tag mapping
// used by the NetworkExtension data plane. The JSON-only API is gomobile-safe.
func SubscriptionRuntimeCatalog(profileJSON string) (string, error) {
	profile, err := config.ParseProfile([]byte(profileJSON))
	if err != nil {
		return "", fmt.Errorf("invalid profile")
	}
	catalog := config.BuildSubscriptionRuntimeCatalog(profile, config.PlatformNE)
	data, err := json.Marshal(catalog)
	if err != nil {
		return "", fmt.Errorf("encode runtime subscription catalog: %w", err)
	}
	return string(data), nil
}

// ParseSubscription 解析订阅并展开远程规则集，返回可直接交给 Swift 解码的 JSON。
func ParseSubscription(url, content, format string) (string, error) {
	result, err := subscription.ParseStrict(url, content, format)
	if err != nil {
		if content == "" && url != "" {
			return "", fmt.Errorf("subscription request or parsing failed")
		}
		return "", fmt.Errorf("parse subscription: %w", err)
	}

	if err := subscription.ExpandRulesetsStrict(result); err != nil {
		return "", err
	}
	if err := validateSubscriptionRules(result); err != nil {
		return "", err
	}
	sanitizeSubscriptionGroups(result)
	data, err := json.Marshal(result)
	if err != nil {
		return "", fmt.Errorf("encode subscription result: %w", err)
	}
	if len(data) > maxParsedSubscriptionBytes {
		return "", fmt.Errorf("parsed subscription is too large")
	}
	return string(data), nil
}

func validateSubscriptionRules(result *subscription.ParseResult) error {
	supportedTypes := map[string]bool{
		"DOMAIN-SUFFIX":  true,
		"DOMAIN":         true,
		"DOMAIN-KEYWORD": true,
		"IP-CIDR":        true,
		"IP-CIDR6":       true,
		"GEOIP":          true,
		"FINAL":          true,
	}
	for i := range result.Rules {
		typ := strings.ToUpper(strings.TrimSpace(result.Rules[i].Type))
		if !supportedTypes[typ] {
			return fmt.Errorf("subscription contains unsupported rules")
		}
		result.Rules[i].Type = typ
	}

	nodes := make(map[string]bool, len(result.Lines))
	for _, line := range result.Lines {
		if strings.TrimSpace(line.Name) == "" || !subscriptionNodeUsable(line) {
			return fmt.Errorf("subscription contains invalid nodes")
		}
		if _, exists := nodes[line.Name]; exists {
			return fmt.Errorf("subscription contains duplicate node names")
		}
		nodes[line.Name] = true
	}
	groups := make(map[string]config.ProxyGroup, len(result.ProxyGroups))
	for _, group := range result.ProxyGroups {
		switch strings.ToLower(strings.TrimSpace(group.Type)) {
		case "select", "selector", "url-test", "urltest":
		default:
			return fmt.Errorf("subscription contains unsupported group types")
		}
		if strings.TrimSpace(group.Name) == "" {
			return fmt.Errorf("subscription contains invalid groups")
		}
		if _, exists := groups[group.Name]; exists {
			return fmt.Errorf("subscription contains duplicate group names")
		}
		groups[group.Name] = group
	}
	usableGroups := resolveUsableSubscriptionGroups(groups, nodes)
	for _, rule := range result.Rules {
		if usableGroups[rule.Group] {
			continue
		}
		switch strings.ToUpper(rule.Group) {
		case "DIRECT", "REJECT", "REJECT-DROP", "REJECT-TINYGIF", "BLOCK":
			continue
		default:
			return fmt.Errorf("subscription rule references an unavailable group")
		}
	}
	return nil
}

func subscriptionNodeUsable(line config.Line) bool {
	if !line.Enabled {
		return false
	}
	switch line.Type {
	case config.LineTypeTrojan:
		return line.TrojanServer != "" && line.TrojanPort > 0 && line.TrojanPort <= 65535 && line.TrojanPassword != ""
	case config.LineTypeShadowsocks:
		return line.SSServer != "" && line.SSPort > 0 && line.SSPort <= 65535 && line.SSMethod != "" && line.SSPass != ""
	case config.LineTypeVMess:
		_, err := uuid.Parse(line.VMessUUID)
		return line.VMessServer != "" && line.VMessPort > 0 && line.VMessPort <= 65535 && err == nil
	default:
		return false
	}
}

func resolveUsableSubscriptionGroups(groups map[string]config.ProxyGroup, nodes map[string]bool) map[string]bool {
	const (
		groupUnusable = iota
		groupReject
		groupOutbound
	)
	states := make(map[string]int, len(groups))
	for changed := true; changed; {
		changed = false
		for name, group := range groups {
			nextState := groupUnusable
			for _, member := range group.Proxies {
				if isSubscriptionRejectName(member) {
					nextState = groupReject
					continue
				}
				if nodes[member] || member == "DIRECT" || member == "Direct" || states[member] == groupOutbound {
					nextState = groupOutbound
					break
				}
			}
			if nextState > states[name] {
				states[name] = nextState
				changed = true
			}
		}
	}
	usable := make(map[string]bool, len(states))
	for name, state := range states {
		usable[name] = state != groupUnusable
	}
	return usable
}

func isSubscriptionRejectName(name string) bool {
	switch strings.ToUpper(name) {
	case "REJECT", "REJECT-DROP", "REJECT-TINYGIF", "BLOCK":
		return true
	default:
		return false
	}
}

func sanitizeSubscriptionGroups(result *subscription.ParseResult) {
	for i := range result.ProxyGroups {
		result.ProxyGroups[i].URL = ""
	}
}
