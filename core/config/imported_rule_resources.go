package config

import (
	"encoding/json"
	"fmt"
	"net/url"
	"path"
	"strings"
)

// MatchingRuleName describes a reusable predicate, never its Scenario destination.
// It deliberately does not guess service categories from a destination group name.
func MatchingRuleName(rule RuleSet) string {
	label := "匹配条件"
	var values []string
	switch rule.Type {
	case RuleSetTypeNative:
		var fields map[string][]string
		if json.Unmarshal(rule.NativeRule, &fields) == nil {
			label = "域名"
			for _, key := range []string{"domain", "domain_suffix", "domain_keyword", "domain_regex", "ip_cidr"} {
				if key == "ip_cidr" && len(fields[key]) != 0 {
					label = "IP"
				}
				values = append(values, fields[key]...)
			}
		}
	case RuleSetTypeApplication:
		label = "应用"
		values = append(values, rule.Processes...)
	case RuleSetTypeURL:
		label = "远程规则"
		if u, err := url.Parse(rule.URL); err == nil {
			name := path.Base(u.Path)
			if name != "." && name != "/" && name != "" {
				values = []string{name}
			}
		}
	case RuleSetTypeManual:
		label = "域名 / IP"
		values = append(values, rule.Domains...)
		values = append(values, rule.CIDRs...)
	}
	if len(values) == 0 {
		return label
	}
	first := []rune(strings.TrimSpace(values[0]))
	if len(first) > 60 {
		first = append(first[:60], '…')
	}
	if len(values) == 1 {
		return label + " · " + string(first)
	}
	return fmt.Sprintf("%s · %s 等 %d 项", label, string(first), len(values))
}

// SeparateImportedRuleResources removes only the old, generated policy wrappers.
// Private predicates become shared resources and every Scenario binding is
// expanded in place. User-created groups and unrelated resources are retained.
func SeparateImportedRuleResources(profile *Profile) (*Profile, error) {
	if err := validateDocumentProfile(profile); err != nil {
		return nil, err
	}
	generated := map[string]bool{}
	for _, line := range profile.Lines {
		for occurrence := 1; occurrence <= len(profile.RuleSets); occurrence++ {
			generated[documentID(profile.ID, "rule", fmt.Sprintf("policy/%s/%d", line.ID, occurrence))] = true
		}
	}
	result := *profile
	result.RuleSets = nil
	result.Scenarios = append([]Scenario(nil), profile.Scenarios...)
	replacements := map[string][]string{}
	for _, rule := range profile.RuleSets {
		if rule.Type != RuleSetTypeGroup || !generated[rule.ID] {
			result.RuleSets = append(result.RuleSets, rule)
			continue
		}
		for _, child := range rule.Conditions {
			child.Enabled = rule.Enabled && child.Enabled
			child.Name = MatchingRuleName(child)
			result.RuleSets = append(result.RuleSets, child)
			replacements[rule.ID] = append(replacements[rule.ID], child.ID)
		}
	}
	for index, scene := range profile.Scenarios {
		result.Scenarios[index].Bindings = nil
		for _, binding := range scene.Bindings {
			ids, replaced := replacements[binding.RuleSetID]
			if !replaced {
				result.Scenarios[index].Bindings = append(result.Scenarios[index].Bindings, binding)
				continue
			}
			for _, id := range ids {
				copy := binding
				copy.RuleSetID = id
				result.Scenarios[index].Bindings = append(result.Scenarios[index].Bindings, copy)
			}
		}
	}
	return &result, validateDocumentProfile(&result)
}
