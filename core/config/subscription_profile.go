package config

import (
	"encoding/json"
	"fmt"
	"strconv"
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
		if line.Type == LineTypeDirect {
			if line.Name == "DIRECT" {
				continue
			}
			tags[line.Name] = "direct"
			continue
		}
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
	groupsByKey := map[string]int{}
	var pending *subscriptionRuleGroup
	flush := func() {
		if pending == nil {
			return
		}
		rule := pending.finish()
		rule.Name = MatchingRuleName(rule)
		if pending.sourceName != "" {
			rule.Name = pending.sourceName + " · " + rule.Name
		}
		profile.RuleSets = append(profile.RuleSets, rule)
		scenario.Bindings = append(scenario.Bindings, RuleBinding{RuleSetID: rule.ID, LineID: pending.target})
		pending = nil
	}
	for index, entry := range rules {
		target := tags[entry.Group]
		if target == "" {
			return nil, fmt.Errorf("subscription rule references an unsupported target (including REJECT); choose lines-only import explicitly if desired")
		}
		if strings.EqualFold(entry.Type, "FINAL") {
			flush()
			if index != len(rules)-1 {
				return nil, fmt.Errorf("subscription has rules after FINAL")
			}
			scenario.DefaultLineID = target
			continue
		}
		rule, err := importSubscriptionRule(entry)
		if err != nil {
			return nil, err
		}
		if rule == nil {
			flush()
			profile.ImportWarnings = append(profile.ImportWarnings, entry)
			continue
		}
		key, _ := subscriptionRuleGroupKey(entry, rule)
		if pending == nil || pending.key != key {
			flush()
			groupsByKey[key]++
			id := documentID(namespace, "rule", fmt.Sprintf("segment/%s/%d", key, groupsByKey[key]))
			pending = &subscriptionRuleGroup{key: key, target: target, sourceName: entry.SourceName, rule: *rule, matches: map[string][]string{}}
			pending.rule.ID = id
			pending.rule.Processes = nil
		}
		pending.append(rule)
	}
	flush()
	profile.Scenarios = []Scenario{scenario}
	profile.ActiveScenarioID = scenario.ID
	grouped, err := GroupProfileRulesByDestination(profile, scenario.ID)
	if err != nil {
		return nil, err
	}
	return NormalizeImportedPolicySelectors(grouped)
}

// ValidateDocumentProfile checks references for every Scenario without starting
// a Box, downloading a RuleSet or opening a Line.
func ValidateDocumentProfile(profile *Profile) error { return validateDocumentProfile(profile) }

func LineOutbound(line *Line) map[string]interface{} { return buildProxyOutbound(line) }

// These adapters materialize explicit, editable resources in the Profile; no
// country/ASN lookup or second rules engine is introduced into the platform.
const importedGeoIPURL = "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-"
const importedASNURL = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/asn/AS"

func importSubscriptionRule(entry SubscriptionRule) (*RuleSet, error) {
	kind := strings.ToUpper(entry.Type)
	rule := &RuleSet{Name: fmt.Sprintf("%s %s", kind, entry.Value), Type: RuleSetTypeNative, Enabled: true}
	for _, option := range strings.Split(entry.Options, ",") {
		option = strings.TrimSpace(option)
		if option == "" {
			continue
		}
		if option != "no-resolve" || (kind != "IP-CIDR" && kind != "IP-CIDR6" && kind != "GEOIP" && kind != "IP-ASN") {
			return nil, fmt.Errorf("subscription rule type %q has an unsupported option", kind)
		}
		rule.NoResolve = true
	}
	var key string
	switch kind {
	case "DOMAIN":
		key = "domain"
	case "DOMAIN-SUFFIX":
		key = "domain_suffix"
	case "DOMAIN-KEYWORD":
		key = "domain_keyword"
	case "IP-CIDR", "IP-CIDR6":
		key = "ip_cidr"
	case "PROCESS-NAME":
		if _, valid := canonicalApplicationProcessSelector(entry.Value); !valid {
			return nil, fmt.Errorf("subscription contains an invalid PROCESS-NAME expression")
		}
		rule.Type = RuleSetTypeApplication
		rule.Processes = []string{entry.Value}
		return rule, nil
	case "GEOIP":
		code := strings.ToLower(entry.Value)

		if len(code) != 2 || code[0] < 'a' || code[0] > 'z' || code[1] < 'a' || code[1] > 'z' {
			return nil, fmt.Errorf("subscription contains an invalid GEOIP country code")
		}
		rule.Type, rule.Format, rule.FetchLineID = RuleSetTypeURL, "binary", "direct"
		rule.URL = importedGeoIPURL + code + ".srs"
		return rule, nil
	case "IP-ASN":
		asn, err := strconv.ParseUint(entry.Value, 10, 32)
		if err != nil || asn == 0 {
			return nil, fmt.Errorf("subscription contains an invalid ASN")
		}
		rule.Type, rule.Format, rule.FetchLineID = RuleSetTypeURL, "binary", "direct"
		rule.URL = importedASNURL + strconv.FormatUint(asn, 10) + ".srs"
		return rule, nil
	case "USER-AGENT":
		// No equivalent HTTP-header matcher exists in sing-box. Retain the
		// original entry for explicit preview acknowledgement and round trips.
		return nil, nil
	default:
		return nil, fmt.Errorf("subscription rule type %q needs an import adapter", kind)
	}
	rule.NativeRule, _ = json.Marshal(map[string]interface{}{key: []string{entry.Value}})
	return rule, nil
}

// A rule set owns many match conditions. Only adjacent entries with identical
// source, target and DNS behavior can merge; crossing a policy boundary would
// change the first-match routing order. IDs depend on source/segment identity,
// not the current domain list, so adding a domain preserves local references.
type subscriptionRuleGroup struct {
	sourceName string
	key        string
	target     string
	rule       RuleSet
	matches    map[string][]string
}

func subscriptionRuleGroupKey(entry SubscriptionRule, rule *RuleSet) (string, string) {
	family, label := string(rule.Type), "应用"
	if rule.Type == RuleSetTypeNative {
		if nativeRuleDomainOnly(rule.NativeRule) {
			family, label = "domain", "域名"
		} else {
			family, label = "ip", "IP"
		}
	} else if rule.Type == RuleSetTypeURL {
		family, label = rule.URL, strings.ToUpper(entry.Type)+" "+entry.Value
	}
	key, _ := json.Marshal([]string{entry.SourceID, entry.Group, family, strconv.FormatBool(rule.NoResolve)})
	return string(key), label
}

func (group *subscriptionRuleGroup) append(rule *RuleSet) {
	if rule.Type == RuleSetTypeNative {
		var fields map[string][]string
		_ = json.Unmarshal(rule.NativeRule, &fields)
		for key, values := range fields {
			group.matches[key] = append(group.matches[key], values...)
		}
	} else if rule.Type == RuleSetTypeApplication {
		group.rule.Processes = append(group.rule.Processes, rule.Processes...)
	}
}

func (group *subscriptionRuleGroup) finish() RuleSet {
	if group.rule.Type == RuleSetTypeNative {
		group.rule.NativeRule, _ = json.Marshal(group.matches)
	}
	return group.rule
}
