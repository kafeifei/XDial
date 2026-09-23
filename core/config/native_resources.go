package config

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"sort"
	"strings"

	"github.com/sagernet/sing-box/option"
)

func (line *Line) IsGroup() bool {
	return line != nil && (line.Type == LineTypeSelector || line.Type == LineTypeURLTest)
}

// Native rules remain sing-box expressions. This only classifies whether the
// whole expression can be evaluated before DNS, not whether a flow matches it.
func nativeRuleDomainOnly(raw json.RawMessage) bool {
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil || len(fields) == 0 {
		return false
	}
	hasMatch := false
	for key, value := range fields {
		switch key {
		case "type", "mode", "invert":
		case "domain", "domain_suffix", "domain_keyword", "domain_regex":
			hasMatch = true
		case "rules":
			var children []json.RawMessage
			if json.Unmarshal(value, &children) != nil || len(children) == 0 {
				return false
			}
			for _, child := range children {
				if !nativeRuleDomainOnly(child) {
					return false
				}
			}
			hasMatch = true
		default:
			return false
		}
	}
	return hasMatch
}

func validateNativeRule(raw json.RawMessage) error {
	var rule option.HeadlessRule
	if err := json.Unmarshal(raw, &rule); err != nil || !rule.IsValid() {
		return fmt.Errorf("invalid sing-box headless rule")
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil {
		return fmt.Errorf("invalid native rule")
	}
	for key, value := range fields {
		switch key {
		case "type", "mode", "invert", "domain", "domain_suffix", "domain_keyword", "domain_regex", "ip_cidr":
		case "rules":
			var children []json.RawMessage
			if json.Unmarshal(value, &children) != nil {
				return fmt.Errorf("invalid logical rule")
			}
			for _, child := range children {
				if err := validateNativeRule(child); err != nil {
					return err
				}
			}
		default:
			return fmt.Errorf("native rule field %q is not yet supported by this platform", key)
		}
	}
	return nil
}

func validateGroupDependencies(profile *Profile, line *Line) error {
	return validateGroupReferences(profile, line, true)
}

func validateGroupReferences(profile *Profile, line *Line, requireUsable bool) error {
	visiting := map[string]bool{}
	var visit func(*Line, int) error
	visit = func(item *Line, depth int) error {
		if item == nil || (requireUsable && !item.Enabled) {
			return fmt.Errorf("line group references an unavailable line")
		}
		if depth > 32 || visiting[item.ID] {
			return fmt.Errorf("line group dependency cycle or excessive nesting")
		}
		if !item.IsGroup() {
			if item.Type == LineTypeVPN || item.Type == LineTypeTailscale {
				return fmt.Errorf("AnyConnect and Tailscale must be bound directly to a Scenario")
			}
			if requireUsable && !lineHasUsableOutbound(item) {
				return fmt.Errorf("line group contains an invalid outbound")
			}
			return nil
		}
		if item.Type == LineTypeURLTest && groupContainsDirect(profile, item.ID, map[string]bool{}) {
			return fmt.Errorf("urltest groups containing Direct are not supported: dynamic DNS ownership would change; use a selector for Direct")
		}
		if len(item.GroupMembers) == 0 {
			return fmt.Errorf("line group has no members")
		}
		visiting[item.ID] = true
		defer delete(visiting, item.ID)
		selectedFound := item.GroupDefault == ""
		for _, id := range item.GroupMembers {
			if id == item.GroupDefault {
				selectedFound = true
			}
			if id == builtinDirectLineID {
				continue
			}
			if err := visit(profile.FindLine(id), depth+1); err != nil {
				return err
			}
		}
		if !selectedFound {
			return fmt.Errorf("line group default is not one of its members")
		}
		return nil
	}
	return visit(line, 0)
}

func expandGroupLineIDs(profile *Profile, ids map[string]bool) {
	seen := map[string]bool{}
	var visit func(string)
	visit = func(id string) {
		if seen[id] {
			return
		}
		seen[id] = true
		line := profile.FindLine(id)
		if !line.IsGroup() {
			return
		}
		for _, member := range line.GroupMembers {
			ids[member] = true
			visit(member)
		}
	}
	for id := range ids {
		visit(id)
	}
}

func groupOutbound(line *Line) map[string]interface{} {
	if len(line.GroupMembers) == 0 {
		return nil
	}
	tag := func(id string) string {
		if id == "direct" {
			return id
		}
		return "proxy-" + id
	}
	members := make([]string, 0, len(line.GroupMembers))
	for _, id := range line.GroupMembers {
		members = append(members, tag(id))
	}
	result := map[string]interface{}{"type": string(line.Type), "tag": resolveOutboundTag(line), "outbounds": members}
	if line.Type == LineTypeSelector && line.GroupDefault != "" {
		result["default"] = tag(line.GroupDefault)
	}
	if line.Type == LineTypeURLTest {
		if line.GroupURL != "" {
			result["url"] = line.GroupURL
		}
		if line.GroupInterval != "" {
			result["interval"] = line.GroupInterval
		}
	}
	return result
}

func GroupLineOutbounds(profile *Profile, id string) []map[string]interface{} {
	ids := map[string]bool{id: true}
	expandGroupLineIDs(profile, ids)
	var outbounds []map[string]interface{}
	for _, line := range profile.Lines {
		if ids[line.ID] && line.Type != LineTypeDirect {
			outbounds = append(outbounds, buildProxyOutbound(&line))
		}
	}
	sort.Slice(outbounds, func(i, j int) bool { return fmt.Sprint(outbounds[i]["tag"]) < fmt.Sprint(outbounds[j]["tag"]) })
	return outbounds
}

func CloneProfile(profile *Profile, namespace string) *Profile {
	encoded, _ := json.Marshal(profile)
	var result Profile
	_ = json.Unmarshal(encoded, &result)
	result.ID = namespace
	lines := map[string]string{"direct": "direct"}
	rules := map[string]string{}
	for _, line := range result.Lines {
		if line.ID != "direct" {
			lines[line.ID] = documentID(namespace, "line", line.ID)
		}
	}
	for _, rule := range result.RuleSets {
		rules[rule.ID] = documentID(namespace, "rule", rule.ID)
	}
	for i := range result.Lines {
		line := &result.Lines[i]
		line.IdentityProfileID, line.IdentityHostname = "", ""
		line.ID = lines[line.ID]
		for j, member := range line.GroupMembers {
			line.GroupMembers[j] = lines[member]
		}
		line.GroupDefault = lines[line.GroupDefault]
	}
	var remapRule func(*RuleSet)
	remapRule = func(rule *RuleSet) {
		rule.ID = documentID(namespace, "rule", rule.ID)
		if rule.FetchLineID != "" {
			rule.FetchLineID = lines[rule.FetchLineID]
		}
		for i := range rule.Conditions {
			remapRule(&rule.Conditions[i])
		}
	}
	for i := range result.RuleSets {
		remapRule(&result.RuleSets[i])
	}
	for i := range result.Scenarios {
		scenario := &result.Scenarios[i]
		oldID := scenario.ID
		scenario.ID = documentID(namespace, "scenario", oldID)
		if result.ActiveScenarioID == oldID {
			result.ActiveScenarioID = scenario.ID
		}
		scenario.DefaultLineID = lines[scenario.DefaultLineID]
		for j, id := range scenario.MatchOrder {
			scenario.MatchOrder[j] = documentID(namespace, "rule", id)
		}
		for j := range scenario.Bindings {
			for k, id := range scenario.Bindings[j].ConditionIDs {
				scenario.Bindings[j].ConditionIDs[k] = documentID(namespace, "rule", id)
			}
			scenario.Bindings[j].LineID = lines[scenario.Bindings[j].LineID]
			scenario.Bindings[j].RuleSetID = rules[scenario.Bindings[j].RuleSetID]
		}
	}
	result.Tailscale.Hostname = ""
	return &result
}

func nativeOutboundWithEdits(line *Line, compiled map[string]interface{}) map[string]interface{} {
	if err := ValidateNativeLineOptions(line); err != nil {
		return nil
	}
	if compiled == nil || len(line.NativeOptions) == 0 {
		return compiled
	}
	var base map[string]interface{}
	if json.Unmarshal(line.NativeOptions, &base) != nil {
		return nil
	}
	var merge func(map[string]interface{}, map[string]interface{})
	merge = func(dst, src map[string]interface{}) {
		for key, value := range src {
			if child, ok := value.(map[string]interface{}); ok {
				if prior, ok := dst[key].(map[string]interface{}); ok {
					merge(prior, child)
					continue
				}
			}
			dst[key] = value
		}
	}
	merge(base, compiled)
	return base
}

// ProfileDataPath isolates protocol identities and resource caches. An empty
// profile ID keeps legacy callers compatible; new Profile libraries always set it.
func ProfileDataPath(profile *Profile, base string) (string, error) {
	if profile == nil || profile.ID == "" {
		return base, nil
	}
	id := profile.ID
	// A global runtime still uses the original source's persistent Tailscale node.
	// The Go dependency collector owns this choice; the host only supplies ownership.
	if profile.ActiveScenario() != nil {
		line, err := ActiveTailscaleLine(profile)
		if err != nil {
			return "", err
		}
		if line != nil && line.IdentityProfileID != "" {
			id = line.IdentityProfileID
		}
	}
	if len(id) > 80 || strings.IndexFunc(id, func(r rune) bool {
		return !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-')
	}) >= 0 {
		return "", fmt.Errorf("invalid Profile identity")
	}
	if filepath.Base(base) == id && filepath.Base(filepath.Dir(base)) == "profiles" {
		return base, nil
	}
	return filepath.Join(base, "profiles", id), nil
}

// Selector choices are committed with the Scenario. URL tests remain native
// sing-box groups; their supported members share the proxy DNS policy.
func selectedGroupUsesDirect(profile *Profile, tag string) bool {
	line := profile.FindLine(strings.TrimPrefix(tag, "proxy-"))
	seen := map[string]bool{}
	for line != nil && line.Type == LineTypeSelector && !seen[line.ID] {
		seen[line.ID] = true
		selected := line.GroupDefault
		if selected == "" && len(line.GroupMembers) > 0 {
			selected = line.GroupMembers[0]
		}
		if selected == "direct" {
			return true
		}
		line = profile.FindLine(selected)
	}
	return false
}

func groupContainsDirect(profile *Profile, id string, seen map[string]bool) bool {
	if id == "direct" {
		return true
	}
	if seen[id] {
		return false
	}
	seen[id] = true
	line := profile.FindLine(id)
	if !line.IsGroup() {
		return false
	}
	for _, child := range line.GroupMembers {
		if groupContainsDirect(profile, child, seen) {
			return true
		}
	}
	return false
}

func ValidateNativeLineOptions(line *Line) error {
	if len(line.NativeOptions) == 0 {
		return nil
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(line.NativeOptions, &fields) != nil || fields == nil {
		return fmt.Errorf("native options must be an object")
	}
	return allowDocumentKeys(fields, "tls", "transport", "multiplex", "network", "security", "packet_encoding", "idle_session_check_interval", "idle_session_timeout", "min_idle_session", "udp_over_tcp")
}
