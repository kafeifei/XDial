package config

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"sort"
)

const runtimeConfigurationFingerprintPrefix = "runtime-v1:"

// runtimeConfigurationBuilder records the same effective closure selected by
// BuildConnectionPlan. Its projection is deliberately private: callers only
// receive the versioned digest, never endpoint, credential, or rule material.
type runtimeConfigurationBuilder struct {
	profile       *Profile
	scenario      runtimeConfigurationScenario
	ruleSets      map[string]runtimeConfigurationRuleSet
	lines         map[string]runtimeConfigurationLine
	subscriptions map[string]runtimeConfigurationSubscription
	usesTailscale bool
}

type runtimeConfigurationProjection struct {
	Scenario      runtimeConfigurationScenario       `json:"scenario"`
	RuleSets      []runtimeConfigurationRuleSet      `json:"rule_sets,omitempty"`
	Lines         []runtimeConfigurationLine         `json:"lines,omitempty"`
	Subscriptions []runtimeConfigurationSubscription `json:"subscriptions,omitempty"`
	Tailscale     *runtimeConfigurationTailscale     `json:"tailscale,omitempty"`
}

type runtimeConfigurationScenario struct {
	ID            string                        `json:"id"`
	Bindings      []runtimeConfigurationBinding `json:"bindings,omitempty"`
	DefaultTarget runtimeConfigurationTarget    `json:"default_target"`
}

type runtimeConfigurationBinding struct {
	RuleSetID string                     `json:"rule_set_id"`
	Target    runtimeConfigurationTarget `json:"target"`
}

type runtimeConfigurationTarget struct {
	Kind string `json:"kind"`
	ID   string `json:"id,omitempty"`
}

type runtimeConfigurationRuleSet struct {
	ID             string                       `json:"id"`
	Type           RuleSetType                  `json:"type"`
	Invert         bool                         `json:"invert,omitempty"`
	URL            string                       `json:"url,omitempty"`
	Format         string                       `json:"format,omitempty"`
	FetchLineID    string                       `json:"fetch_line_id,omitempty"`
	Domains        []string                     `json:"domains,omitempty"`
	CIDRs          []string                     `json:"cidrs,omitempty"`
	ProcessMatches []ApplicationProcessSelector `json:"process_matches,omitempty"`
}

type runtimeConfigurationLine struct {
	ID            string      `json:"id"`
	Type          LineType    `json:"type"`
	Configuration interface{} `json:"configuration"`
}

type runtimeConfigurationVPNLine struct {
	Server        string `json:"server"`
	Username      string `json:"username"`
	Password      string `json:"password"`
	AllowInsecure bool   `json:"allow_insecure,omitempty"`
}

type runtimeConfigurationTailscaleLine struct {
	ExitNode string `json:"exit_node,omitempty"`
	MagicDNS bool   `json:"magic_dns,omitempty"`
	AuthKey  string `json:"auth_key,omitempty"`
}

type runtimeConfigurationSubscription struct {
	ID        string                   `json:"id"`
	MainTag   string                   `json:"main_tag"`
	Outbounds []map[string]interface{} `json:"outbounds"`
	Rules     []map[string]interface{} `json:"rules,omitempty"`
	RuleSets  []map[string]interface{} `json:"rule_sets,omitempty"`
}

type runtimeConfigurationTailscale struct {
	Hostname string `json:"hostname,omitempty"`
}

func newRuntimeConfigurationBuilder(
	profile *Profile,
	scenario *Scenario,
) *runtimeConfigurationBuilder {
	return &runtimeConfigurationBuilder{
		profile: profile,
		scenario: runtimeConfigurationScenario{
			ID: scenario.ID,
		},
		ruleSets:      make(map[string]runtimeConfigurationRuleSet),
		lines:         make(map[string]runtimeConfigurationLine),
		subscriptions: make(map[string]runtimeConfigurationSubscription),
	}
}

func directRuntimeConfigurationTarget() runtimeConfigurationTarget {
	return runtimeConfigurationTarget{Kind: "direct"}
}

func lineRuntimeConfigurationTarget(line *Line) runtimeConfigurationTarget {
	if line == nil || line.Type == LineTypeDirect || line.ID == builtinDirectLineID {
		return directRuntimeConfigurationTarget()
	}
	return runtimeConfigurationTarget{Kind: "line", ID: line.ID}
}

func subscriptionRuntimeConfigurationTarget(
	subscription *Subscription,
) runtimeConfigurationTarget {
	if subscription == nil {
		return runtimeConfigurationTarget{}
	}
	return runtimeConfigurationTarget{Kind: "subscription", ID: subscription.ID}
}

func (builder *runtimeConfigurationBuilder) addBinding(
	ruleSetID string,
	target runtimeConfigurationTarget,
) {
	builder.scenario.Bindings = append(
		builder.scenario.Bindings,
		runtimeConfigurationBinding{RuleSetID: ruleSetID, Target: target},
	)
}

func (builder *runtimeConfigurationBuilder) setDefaultTarget(
	target runtimeConfigurationTarget,
) {
	builder.scenario.DefaultTarget = target
}

func (builder *runtimeConfigurationBuilder) includeRuleSet(ruleSet *RuleSet) {
	if ruleSet == nil || !ruleSet.Enabled {
		return
	}
	if _, exists := builder.ruleSets[ruleSet.ID]; exists {
		return
	}

	entry := runtimeConfigurationRuleSet{
		ID:     ruleSet.ID,
		Type:   ruleSet.Type,
		Invert: ruleSet.Invert,
	}
	switch ruleSet.Type {
	case RuleSetTypeURL:
		entry.URL = ruleSet.URL
		entry.Format = ruleSet.Format
		entry.FetchLineID = ruleSet.EffectiveFetchLineID()
		if entry.FetchLineID != builtinDirectLineID {
			builder.includeLine(builder.profile.FindLine(entry.FetchLineID))
		}
	case RuleSetTypeManual:
		entry.Domains = ruleSet.Domains
		entry.CIDRs = ruleSet.CIDRs
	case RuleSetTypeApplication:
		entry.ProcessMatches = applicationRuleSetSelectors(ruleSet)
	}
	builder.ruleSets[ruleSet.ID] = entry
}

func (builder *runtimeConfigurationBuilder) includeLine(line *Line) {
	if line == nil || !line.Enabled || line.Type == LineTypeDirect {
		return
	}
	if _, exists := builder.lines[line.ID]; exists {
		return
	}

	var configuration interface{}
	switch line.Type {
	case LineTypeVPN:
		configuration = runtimeConfigurationVPNLine{
			Server:        line.VPNServer,
			Username:      line.VPNUsername,
			Password:      line.VPNPassword,
			AllowInsecure: line.AllowInsecure,
		}
	case LineTypeTailscale:
		configuration = runtimeConfigurationTailscaleLine{
			ExitNode: line.TailscaleExitNode,
			MagicDNS: line.TailscaleMagicDNS,
			AuthKey:  line.TailscaleAuthKey,
		}
		builder.usesTailscale = true
	default:
		configuration = buildProxyOutbound(line)
	}
	if configuration == nil {
		return
	}
	builder.lines[line.ID] = runtimeConfigurationLine{
		ID:            line.ID,
		Type:          line.Type,
		Configuration: configuration,
	}
}

func (builder *runtimeConfigurationBuilder) includeSubscription(
	subscription *Subscription,
) {
	if subscription == nil || !subscription.Enabled {
		return
	}
	if _, exists := builder.subscriptions[subscription.ID]; exists {
		return
	}

	outbounds, mainTag, groupTags := buildSubscriptionOutbounds(
		subscription,
		PlatformMacOS,
	)
	if mainTag == "" {
		return
	}
	rules, ruleSets := buildSubscriptionRules(subscription, groupTags)
	builder.subscriptions[subscription.ID] = runtimeConfigurationSubscription{
		ID:        subscription.ID,
		MainTag:   mainTag,
		Outbounds: outbounds,
		Rules:     rules,
		RuleSets:  ruleSets,
	}
}

func (builder *runtimeConfigurationBuilder) fingerprint() (string, error) {
	projection := runtimeConfigurationProjection{
		Scenario:      builder.scenario,
		RuleSets:      sortedRuntimeConfigurationRuleSets(builder.ruleSets),
		Lines:         sortedRuntimeConfigurationLines(builder.lines),
		Subscriptions: sortedRuntimeConfigurationSubscriptions(builder.subscriptions),
	}
	if builder.usesTailscale {
		projection.Tailscale = &runtimeConfigurationTailscale{
			Hostname: builder.profile.Tailscale.Hostname,
		}
	}
	encoded, err := json.Marshal(projection)
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256(encoded)
	return runtimeConfigurationFingerprintPrefix + hex.EncodeToString(digest[:]), nil
}

func sortedRuntimeConfigurationRuleSets(
	entries map[string]runtimeConfigurationRuleSet,
) []runtimeConfigurationRuleSet {
	keys := sortedRuntimeConfigurationKeys(entries)
	result := make([]runtimeConfigurationRuleSet, 0, len(keys))
	for _, key := range keys {
		result = append(result, entries[key])
	}
	return result
}

func sortedRuntimeConfigurationLines(
	entries map[string]runtimeConfigurationLine,
) []runtimeConfigurationLine {
	keys := sortedRuntimeConfigurationKeys(entries)
	result := make([]runtimeConfigurationLine, 0, len(keys))
	for _, key := range keys {
		result = append(result, entries[key])
	}
	return result
}

func sortedRuntimeConfigurationSubscriptions(
	entries map[string]runtimeConfigurationSubscription,
) []runtimeConfigurationSubscription {
	keys := sortedRuntimeConfigurationKeys(entries)
	result := make([]runtimeConfigurationSubscription, 0, len(keys))
	for _, key := range keys {
		result = append(result, entries[key])
	}
	return result
}

func sortedRuntimeConfigurationKeys[T any](entries map[string]T) []string {
	keys := make([]string, 0, len(entries))
	for key := range entries {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}
