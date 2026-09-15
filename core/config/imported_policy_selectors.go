package config

import (
	"encoding/json"
	"fmt"
)

// NormalizeImportedPolicySelectors moves redundant per-category manual choices
// into Scenario bindings. Rule identity must already reflect the source policy,
// before resolving its selected exit. Shared pools and automatic groups remain.
// This is an import operation, not a runtime selector or a library migration.
func NormalizeImportedPolicySelectors(profile *Profile) (*Profile, error) {
	if err := validateDocumentProfile(profile); err != nil {
		return nil, err
	}
	plainSelector := func(line *Line) bool {
		return line != nil && line.Enabled && line.Type == LineTypeSelector && len(line.NativeOptions) == 0
	}
	remove := map[string]bool{}
	for i := range profile.Lines {
		pool := &profile.Lines[i]
		if !plainSelector(pool) {
			continue
		}
		members := map[string]bool{}
		for _, id := range pool.GroupMembers {
			line := profile.FindLine(id)
			if line == nil || line.IsGroup() || line.Type == LineTypeDirect {
				break
			}
			members[id] = true
		}
		if len(members) == 0 || len(members) != len(pool.GroupMembers) {
			continue
		}
		// Recognize wrappers structurally, never by provider/business names. A
		// wrapper repeats the complete pool (or only references it), plus Direct
		// and equivalent wrappers. A distinct restricted pool is not redundant.
		var wrapper func(string, map[string]bool) bool
		wrapper = func(id string, visiting map[string]bool) bool {
			line := profile.FindLine(id)
			if id == pool.ID || !plainSelector(line) || visiting[id] {
				return false
			}
			visiting[id] = true
			defer delete(visiting, id)
			hasPool := false
			leaves := map[string]bool{}
			for _, member := range line.GroupMembers {
				child := profile.FindLine(member)
				switch {
				case member == pool.ID:
					hasPool = true
				case member == builtinDirectLineID || child != nil && child.Type == LineTypeDirect:
				case members[member]:
					leaves[member] = true
				case child != nil && child.IsGroup() && wrapper(member, visiting):
					hasPool = true
				default:
					return false
				}
			}
			return hasPool && (len(leaves) == 0 || len(leaves) == len(members))
		}
		for _, line := range profile.Lines {
			if wrapper(line.ID, map[string]bool{}) {
				remove[line.ID] = true
			}
		}
	}
	// Downloads, native detours and retained groups are shared consumers. They
	// cannot inherit a per-Scenario choice, so keep the selectors they depend on.
	var protectRules func([]RuleSet)
	protectRules = func(rules []RuleSet) {
		for _, rule := range rules {
			delete(remove, rule.FetchLineID)
			protectRules(rule.Conditions)
		}
	}
	protectRules(profile.RuleSets)
	var protectNative func(interface{})
	protectNative = func(value interface{}) {
		switch value := value.(type) {
		case string:
			delete(remove, value)
			for id := range remove {
				if value == "proxy-"+id {
					delete(remove, id)
				}
			}
		case []interface{}:
			for _, child := range value {
				protectNative(child)
			}
		case map[string]interface{}:
			for _, child := range value {
				protectNative(child)
			}
		}
	}
	for _, line := range profile.Lines {
		var native interface{}
		if json.Unmarshal(line.NativeOptions, &native) == nil {
			protectNative(native)
		}
	}
	for changed := true; changed; {
		changed = false
		for _, line := range profile.Lines {
			if remove[line.ID] {
				continue
			}
			for _, id := range line.GroupMembers {
				if remove[id] {
					delete(remove, id)
					changed = true
				}
			}
		}
	}
	resolve := func(id string) string {
		for remove[id] {
			line := profile.FindLine(id)
			id = line.GroupDefault
			if id == "" {
				id = line.GroupMembers[0]
			}
		}
		return id
	}
	result := *profile
	result.Lines = nil
	for _, line := range profile.Lines {
		if !remove[line.ID] {
			result.Lines = append(result.Lines, line)
		}
	}
	result.Scenarios = append([]Scenario(nil), profile.Scenarios...)
	for i := range result.Scenarios {
		scene := &result.Scenarios[i]
		scene.DefaultLineID = resolve(scene.DefaultLineID)
		scene.Bindings = append([]RuleBinding(nil), scene.Bindings...)
		for j := range scene.Bindings {
			scene.Bindings[j].LineID = resolve(scene.Bindings[j].LineID)
		}
	}
	return &result, validateDocumentProfile(&result)
}

// ReimportScenario creates a fresh source import from the saved reference
// Scenario, without copying local Scenarios or unrelated local resources. All
// source candidates are collected before removing redundant policy selectors.
func ReimportScenario(profile *Profile, scenarioID, namespace string) (*Profile, error) {
	if namespace == "" || namespace == profile.ID {
		return nil, fmt.Errorf("a new Profile identity is required")
	}
	if err := validateDocumentProfile(profile); err != nil {
		return nil, err
	}
	var scene *Scenario
	for i := range profile.Scenarios {
		if profile.Scenarios[i].ID == scenarioID {
			scene = &profile.Scenarios[i]
			break
		}
	}
	if scene == nil {
		return nil, fmt.Errorf("reference Scenario missing")
	}
	result := *profile
	result.Scenarios = []Scenario{*scene}
	result.ActiveScenarioID = scene.ID
	result.RuleSets = nil
	neededRules := map[string]bool{}
	neededLines := map[string]bool{builtinDirectLineID: true, scene.DefaultLineID: true}
	for _, binding := range scene.Bindings {
		neededRules[binding.RuleSetID] = true
		neededLines[binding.LineID] = true
	}
	var collectFetch func(RuleSet)
	collectFetch = func(rule RuleSet) {
		if rule.FetchLineID != "" {
			neededLines[rule.FetchLineID] = true
		}
		for _, child := range rule.Conditions {
			collectFetch(child)
		}
	}
	for _, rule := range profile.RuleSets {
		if neededRules[rule.ID] {
			result.RuleSets = append(result.RuleSets, rule)
			collectFetch(rule)
		}
	}
	expandGroupLineIDs(profile, neededLines)
	result.Lines = nil
	for _, line := range profile.Lines {
		if neededLines[line.ID] {
			result.Lines = append(result.Lines, line)
		}
	}
	grouped := &result
	explicitRules := true
	for _, binding := range scene.Bindings {
		if result.FindRuleSet(binding.RuleSetID).Type != RuleSetTypeGroup {
			explicitRules = false
			break
		}
	}
	if !explicitRules {
		var err error
		grouped, err = GroupProfileRulesByDestination(&result, scene.ID)
		if err != nil {
			return nil, err
		}
	}
	normalized, err := NormalizeImportedPolicySelectors(grouped)
	if err != nil {
		return nil, err
	}
	return CloneProfile(normalized, namespace), nil
}
