package config

import (
	"fmt"
	"reflect"
)

// GroupProfileRulesByDestination keeps a single reusable rule per original
// destination. Scenario metadata retains interleaving and local partial scopes;
// ExpandRuleSetGroups lowers them to the existing sing-box compilation path.
func GroupProfileRulesByDestination(profile *Profile, referenceScenarioID string) (*Profile, error) {
	if err := validateDocumentProfile(profile); err != nil {
		return nil, err
	}
	var reference *Scenario
	for i := range profile.Scenarios {
		if profile.Scenarios[i].ID == referenceScenarioID {
			reference = &profile.Scenarios[i]
			break
		}
	}
	if reference == nil {
		return nil, fmt.Errorf("reference Scenario is missing")
	}
	alreadyGrouped := true
	for _, binding := range reference.Bindings {
		if binding.RuleSetID != documentID(profile.ID, "rule", "destination/"+binding.LineID) {
			alreadyGrouped = false
			break
		}
	}
	if alreadyGrouped {
		return profile, nil
	}
	flat, err := ExpandRuleSetGroups(profile)
	if err != nil {
		return nil, err
	}
	var base Scenario
	for _, scene := range flat.Scenarios {
		if scene.ID == referenceScenarioID {
			base = scene
			break
		}
	}
	result := *flat
	result.RuleSets = nil
	result.Scenarios = append([]Scenario(nil), flat.Scenarios...)
	owners := map[string]string{}
	groups := map[string]*RuleSet{}
	var groupOrder []string
	for _, binding := range base.Bindings {
		if binding.LineID == "" || binding.SubscriptionID != "" || owners[binding.RuleSetID] != "" {
			return nil, fmt.Errorf("source routing must bind each matching condition to one Line")
		}
		leaf := flat.FindRuleSet(binding.RuleSetID)
		line := flat.FindLine(binding.LineID)
		if leaf == nil || line == nil {
			return nil, fmt.Errorf("source routing has missing resources")
		}
		id := documentID(profile.ID, "rule", "destination/"+line.ID)
		if groups[id] == nil {
			groups[id] = &RuleSet{ID: id, Name: line.Name, Type: RuleSetTypeGroup, Enabled: true}
			groupOrder = append(groupOrder, id)
		}
		groups[id].Conditions = append(groups[id].Conditions, *leaf)
		owners[leaf.ID] = id
	}
	for _, id := range groupOrder {
		result.RuleSets = append(result.RuleSets, *groups[id])
	}
	// Preserve unbound/local resources, including explicit custom groups.
	for _, rule := range profile.RuleSets {
		if rule.Type == RuleSetTypeGroup {
			used := 0
			for _, child := range rule.Conditions {
				if owners[child.ID] != "" {
					used++
				}
			}
			if used == 0 {
				result.RuleSets = append(result.RuleSets, rule)
			} else if used != len(rule.Conditions) {
				return nil, fmt.Errorf("reference Scenario only covers part of an existing rule")
			}
		} else if owners[rule.ID] == "" {
			result.RuleSets = append(result.RuleSets, rule)
		}
	}
	// Unbound custom groups also need ownership when other Scenarios use them.
	for _, rule := range result.RuleSets {
		if rule.Type == RuleSetTypeGroup {
			for _, child := range rule.Conditions {
				owners[child.ID] = rule.ID
			}
		}
	}
	for i, scene := range flat.Scenarios {
		result.Scenarios[i].Bindings = nil
		result.Scenarios[i].MatchOrder = nil
		indices := map[string]int{}
		var originalOrder []string
		for _, binding := range scene.Bindings {
			id := owners[binding.RuleSetID]
			if id == "" {
				id = binding.RuleSetID
			}
			index, exists := indices[id]
			if !exists {
				index = len(result.Scenarios[i].Bindings)
				indices[id] = index
				result.Scenarios[i].Bindings = append(result.Scenarios[i].Bindings, RuleBinding{RuleSetID: id, LineID: binding.LineID, SubscriptionID: binding.SubscriptionID})
			}
			mapped := &result.Scenarios[i].Bindings[index]
			if mapped.LineID != binding.LineID || mapped.SubscriptionID != binding.SubscriptionID {
				return nil, fmt.Errorf("a local Scenario routes parts of the same rule to different destinations")
			}
			mapped.ConditionIDs = append(mapped.ConditionIDs, binding.RuleSetID)
			originalOrder = append(originalOrder, binding.RuleSetID)
		}
		var naturalOrder []string
		for j := range result.Scenarios[i].Bindings {
			binding := &result.Scenarios[i].Bindings[j]
			rule := result.FindRuleSet(binding.RuleSetID)
			all := []string{rule.ID}
			if rule.Type == RuleSetTypeGroup {
				all = nil
				for _, child := range rule.Conditions {
					all = append(all, child.ID)
				}
			}
			naturalOrder = append(naturalOrder, binding.ConditionIDs...)
			if reflect.DeepEqual(all, binding.ConditionIDs) {
				binding.ConditionIDs = nil
			}
		}
		if !reflect.DeepEqual(naturalOrder, originalOrder) {
			result.Scenarios[i].MatchOrder = originalOrder
		}
	}
	return &result, validateDocumentProfile(&result)
}
