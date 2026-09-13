package config

import (
	"encoding/json"
	"fmt"
	"strings"
)

// ImportSubscriptionProfile promotes subscription resources into the Profile.
// There is no subscription target left in the resulting Scenario.
func ImportSubscriptionProfile(namespace string, lines []Line, groups []ProxyGroup, rules []SubscriptionRule, nodesOnly bool) (*Profile, error) {
	profile := &Profile{ID: namespace, Lines: []Line{{ID: "direct", Name: "直连", Type: LineTypeDirect, Enabled: true}}}
	tags := map[string]string{"DIRECT": "direct"}
	var members []string
	for _, original := range lines {
		line := original
		line.ID = documentID(namespace, "line", line.Name)
		if tags[line.Name] != "" {
			return nil, fmt.Errorf("duplicate subscription node name")
		}
		if !lineHasUsableOutbound(&line) {
			return nil, fmt.Errorf("subscription contains an unsupported or incomplete node")
		}
		tags[line.Name] = line.ID
		profile.Lines = append(profile.Lines, line)
		members = append(members, line.ID)
	}
	if len(members) == 0 {
		return nil, fmt.Errorf("subscription contains no usable lines")
	}
	defaultID := documentID(namespace, "group", "imported-lines")
	if nodesOnly {
		groups = nil
		rules = nil
	}
	if len(groups) == 0 {
		profile.Lines = append(profile.Lines, Line{ID: defaultID, Name: "订阅线路", Type: LineTypeSelector, Enabled: true, GroupMembers: members, GroupDefault: members[0]})
	} else {
		for _, group := range groups {
			if tags[group.Name] != "" {
				return nil, fmt.Errorf("duplicate group name")
			}
			tags[group.Name] = documentID(namespace, "group", group.Name)
		}
		for index, group := range groups {
			kind := LineTypeSelector
			switch strings.ToLower(group.Type) {
			case "select", "selector":
			case "urltest", "url-test":
				kind = LineTypeURLTest
			default:
				return nil, fmt.Errorf("subscription group type %q is not supported", group.Type)
			}
			line := Line{ID: tags[group.Name], Name: group.Name, Type: kind, Enabled: true, GroupURL: group.URL}
			if group.Interval > 0 {
				line.GroupInterval = fmt.Sprintf("%ds", group.Interval)
			}
			for _, member := range group.Proxies {
				id := tags[member]
				if id == "" {
					return nil, fmt.Errorf("group references an unavailable target")
				}
				line.GroupMembers = append(line.GroupMembers, id)
			}
			if group.Selected != "" {
				line.GroupDefault = tags[group.Selected]
			}
			profile.Lines = append(profile.Lines, line)
			if index == 0 {
				defaultID = line.ID
			}
		}
	}
	scenario := Scenario{ID: documentID(namespace, "scenario", "default"), Name: "默认场景", DefaultLineID: defaultID}
	for index, entry := range rules {
		target := tags[entry.Group]
		if target == "" {
			return nil, fmt.Errorf("subscription rule references an unsupported target (including REJECT); choose lines-only import explicitly if desired")
		}
		if strings.EqualFold(entry.Type, "FINAL") {
			if index != len(rules)-1 {
				return nil, fmt.Errorf("subscription has rules after FINAL")
			}
			scenario.DefaultLineID = target
			continue
		}
		var key string
		switch strings.ToUpper(entry.Type) {
		case "DOMAIN":
			key = "domain"
		case "DOMAIN-SUFFIX":
			key = "domain_suffix"
		case "DOMAIN-KEYWORD":
			key = "domain_keyword"
		case "IP-CIDR", "IP-CIDR6":
			key = "ip_cidr"
		default:
			return nil, fmt.Errorf("subscription rule type %q needs an import adapter", entry.Type)
		}
		raw, _ := json.Marshal(map[string]interface{}{key: []string{entry.Value}})
		ruleID := documentID(namespace, "rule", "match/"+string(raw))
		if profile.FindRuleSet(ruleID) == nil {
			profile.RuleSets = append(profile.RuleSets, RuleSet{ID: ruleID, Name: fmt.Sprintf("%s %s", entry.Type, entry.Value), Type: RuleSetTypeNative, Enabled: true, NativeRule: raw})
		}
		scenario.Bindings = append(scenario.Bindings, RuleBinding{RuleSetID: ruleID, LineID: target})
	}
	profile.Scenarios = []Scenario{scenario}
	profile.ActiveScenarioID = scenario.ID
	return profile, validateDocumentProfile(profile)
}

// ValidateDocumentProfile checks references for every Scenario without starting
// a Box, downloading a RuleSet or opening a Line.
func ValidateDocumentProfile(profile *Profile) error { return validateDocumentProfile(profile) }

func LineOutbound(line *Line) map[string]interface{} { return buildProxyOutbound(line) }
