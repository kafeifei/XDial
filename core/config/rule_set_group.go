package config

import "fmt"

// ExpandRuleSetGroups lowers presentation groups to the existing compiler's
// ordered resources. It never matches traffic or changes the caller's Profile.
func ExpandRuleSetGroups(profile *Profile) (*Profile, error) {
	if profile == nil {
		return nil, fmt.Errorf("profile is nil")
	}
	hasGroups := false
	for _, rule := range profile.RuleSets {
		if rule.Type == RuleSetTypeGroup {
			hasGroups = true
		}
		if rule.Type != RuleSetTypeGroup && len(rule.Conditions) != 0 {
			return nil, fmt.Errorf("conditions require a grouped rule set")
		}
	}
	for _, scenario := range profile.Scenarios {
		hasGroups = hasGroups || len(scenario.MatchOrder) > 0
		for _, binding := range scenario.Bindings {
			hasGroups = hasGroups || len(binding.ConditionIDs) > 0
		}
	}
	if !hasGroups {
		return profile, nil
	}
	result := *profile
	result.RuleSets = nil
	result.Scenarios = append([]Scenario(nil), profile.Scenarios...)
	seen := map[string]bool{}
	members := map[string][]string{}
	reserve := func(id string) error {
		if id == "" || seen[id] {
			return fmt.Errorf("missing or duplicate rule set identity")
		}
		seen[id] = true
		return nil
	}
	for _, rule := range profile.RuleSets {
		if err := reserve(rule.ID); err != nil {
			return nil, err
		}
	}
	for _, rule := range profile.RuleSets {
		if rule.Type != RuleSetTypeGroup {
			members[rule.ID] = []string{rule.ID}
			result.RuleSets = append(result.RuleSets, rule)
			continue
		}
		if len(rule.Conditions) == 0 || rule.Invert || rule.NoResolve || len(rule.NativeRule) != 0 || rule.URL != "" || len(rule.Domains)+len(rule.CIDRs)+len(rule.Applications)+len(rule.Processes) != 0 {
			return nil, fmt.Errorf("grouped rule sets require conditions and cannot override their matching or DNS behavior")
		}
		for _, condition := range rule.Conditions {
			if condition.Type == RuleSetTypeGroup || len(condition.Conditions) != 0 {
				return nil, fmt.Errorf("nested rule set groups are not supported")
			}
			if err := reserve(condition.ID); err != nil {
				return nil, err
			}
			condition.Enabled = rule.Enabled && condition.Enabled
			members[rule.ID] = append(members[rule.ID], condition.ID)
			result.RuleSets = append(result.RuleSets, condition)
		}
	}
	for i := range result.Scenarios {
		result.Scenarios[i].Bindings = nil
		result.Scenarios[i].MatchOrder = nil
		selected := map[string]RuleBinding{}
		owners := map[string]string{}
		var naturalOrder []string
		for _, binding := range profile.Scenarios[i].Bindings {
			ids, ok := members[binding.RuleSetID]
			if !ok {
				return nil, fmt.Errorf("Scenario must reference a shared rule set, not a private condition")
			}
			if len(binding.ConditionIDs) > 0 {
				allowed := map[string]bool{}
				for _, id := range ids {
					allowed[id] = true
				}
				for _, id := range binding.ConditionIDs {
					if !allowed[id] {
						return nil, fmt.Errorf("Scenario selects a missing matching condition")
					}
				}
				ids = binding.ConditionIDs
			}
			for _, id := range ids {
				if _, exists := selected[id]; exists {
					return nil, fmt.Errorf("Scenario repeats a matching condition")
				}
				copy := binding
				copy.RuleSetID = id
				copy.ConditionIDs = nil
				selected[id], owners[id] = copy, binding.RuleSetID
				naturalOrder = append(naturalOrder, id)
			}
		}
		order := append([]string(nil), profile.Scenarios[i].MatchOrder...)
		seenOrder := map[string]bool{}
		for _, id := range order {
			if _, ok := selected[id]; !ok || seenOrder[id] {
				return nil, fmt.Errorf("Scenario matching order has missing or duplicate conditions")
			}
			seenOrder[id] = true
		}
		// New conditions join their rule's last imported position. New bindings
		// append after the imported sequence, without reordering existing entries.
		for _, id := range naturalOrder {
			if seenOrder[id] {
				continue
			}
			position := len(order)
			if len(profile.Scenarios[i].MatchOrder) > 0 {
				for index := len(order) - 1; index >= 0; index-- {
					if owners[order[index]] == owners[id] {
						position = index + 1
						break
					}
				}
			}
			order = append(order, "")
			copy(order[position+1:], order[position:])
			order[position] = id
			seenOrder[id] = true
		}
		for _, id := range order {
			result.Scenarios[i].Bindings = append(result.Scenarios[i].Bindings, selected[id])
		}
	}
	return &result, nil
}

// ParseRuntimeProfile is used before resource preparation as well as generation,
// so URL downloads, application identities and route compilation see one order.
func ParseRuntimeProfile(data []byte) (*Profile, error) {
	profile, err := ParseProfile(data)
	if err != nil {
		return nil, err
	}
	return ExpandRuleSetGroups(profile)
}

func restoreDocumentRuleGroups(profile *Profile, metadata documentMetadata, tags map[string]string, namespace string) error {
	owners := map[string]string{}
	groups := map[string]RuleSet{}
	for _, entry := range metadata.RuleGroups {
		if entry.Tag == "" || tags[entry.Tag] != "" || len(entry.Conditions) == 0 {
			return fmt.Errorf("invalid or duplicate rule group")
		}
		info, ok := metadata.Rules[entry.Tag]
		if !ok || info.Kind != RuleSetTypeGroup || info.Invert || info.NoResolve || len(info.Domains)+len(info.CIDRs)+len(info.Applications)+len(info.Processes) != 0 {
			return fmt.Errorf("invalid rule group metadata")
		}
		group := RuleSet{ID: documentID(namespace, "rule", entry.Tag), Name: info.Name, Type: RuleSetTypeGroup, Enabled: !info.Disabled}
		for _, tag := range entry.Conditions {
			id := tags[tag]
			leaf := profile.FindRuleSet(id)
			if leaf == nil || owners[id] != "" {
				return fmt.Errorf("rule group has missing or shared private conditions")
			}
			owners[id] = group.ID
			group.Conditions = append(group.Conditions, *leaf)
		}
		groups[group.ID] = group
		tags[entry.Tag] = group.ID
	}
	if len(groups) == 0 {
		return nil
	}
	var result []RuleSet
	emitted := map[string]bool{}
	for _, leaf := range profile.RuleSets {
		if groupID := owners[leaf.ID]; groupID != "" {
			if !emitted[groupID] {
				result = append(result, groups[groupID])
				emitted[groupID] = true
			}
		} else {
			result = append(result, leaf)
		}
	}
	for tag, id := range tags {
		if owners[id] != "" {
			delete(tags, tag)
		}
	}
	profile.RuleSets = result
	return nil
}

// CompactProfileRuleSets packages one Scenario's consecutive same-target
// resources. Shared/multiple-Scenario graphs need an explicit user redesign,
// so this migration refuses them rather than changing cross-Scenario meaning.
func CompactProfileRuleSets(profile *Profile) (*Profile, error) {
	if err := validateDocumentProfile(profile); err != nil {
		return nil, err
	}
	if len(profile.Scenarios) != 1 {
		return nil, fmt.Errorf("compaction requires a single Scenario")
	}
	scene := profile.Scenarios[0]
	allGrouped := true
	for _, r := range profile.RuleSets {
		if r.Type != RuleSetTypeGroup {
			allGrouped = false
		}
	}
	if allGrouped {
		return profile, nil
	}
	for _, r := range profile.RuleSets {
		if r.Type == RuleSetTypeGroup {
			return nil, fmt.Errorf("mixed existing groups require explicit editing")
		}
	}
	result := *profile
	result.RuleSets = nil
	result.Scenarios = append([]Scenario(nil), profile.Scenarios...)
	result.Scenarios[0].Bindings = nil
	seen := map[string]bool{}
	counts := map[string]int{}
	lastTarget := ""
	for _, binding := range scene.Bindings {
		leaf := profile.FindRuleSet(binding.RuleSetID)
		if leaf == nil || seen[leaf.ID] || binding.LineID == "" || binding.SubscriptionID != "" {
			return nil, fmt.Errorf("compaction requires unique Line-bound resources")
		}
		seen[leaf.ID] = true
		if len(result.RuleSets) == 0 || lastTarget != binding.LineID {
			counts[binding.LineID]++
			name := "直连"
			if line := profile.FindLine(binding.LineID); line != nil && line.Name != "" {
				name = line.Name
			}
			if counts[binding.LineID] > 1 {
				name += fmt.Sprintf(" %d", counts[binding.LineID])
			}
			id := documentID(profile.ID, "rule", fmt.Sprintf("policy/%s/%d", binding.LineID, counts[binding.LineID]))
			result.RuleSets = append(result.RuleSets, RuleSet{ID: id, Name: name, Type: RuleSetTypeGroup, Enabled: true})
			result.Scenarios[0].Bindings = append(result.Scenarios[0].Bindings, RuleBinding{RuleSetID: id, LineID: binding.LineID})
			lastTarget = binding.LineID
		}
		group := &result.RuleSets[len(result.RuleSets)-1]
		group.Conditions = append(group.Conditions, *leaf)
	}
	if len(seen) != len(profile.RuleSets) {
		return nil, fmt.Errorf("compaction cannot remove unbound resources")
	}
	return &result, validateDocumentProfile(&result)
}
