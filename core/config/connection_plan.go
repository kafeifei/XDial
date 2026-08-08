package config

import (
	"fmt"
	"strings"
)

// ConnectionPlan is the side-effect-free description of one connection attempt.
// It is compiled from the active Scenario and is the single checklist consumed by the
// Network Extension transaction, UI, diagnostics, and tests.
type ConnectionPlan struct {
	SchemaVersion            int                    `json:"schema_version"`
	Scenario                 ConnectionPlanScenario `json:"scenario"`
	ConfigurationFingerprint string                 `json:"configuration_fingerprint"`
	Tasks                    []ConnectionPlanTask   `json:"tasks"`
	Warnings                 []ProfileWarning       `json:"warnings,omitempty"`
}

type ConnectionPlanScenario struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type ConnectionPlanTask struct {
	ID           string   `json:"id"`
	Kind         string   `json:"kind"`
	Name         string   `json:"name"`
	Detail       string   `json:"detail,omitempty"`
	Preparation  string   `json:"preparation"`
	Dependencies []string `json:"dependencies,omitempty"`
	ResourceID   string   `json:"resource_id,omitempty"`
	ResourceType string   `json:"resource_type,omitempty"`
}

const (
	ConnectionTaskUnderlay     = "underlay"
	ConnectionTaskRuleSet      = "rule_set"
	ConnectionTaskLine         = "line"
	ConnectionTaskSubscription = "subscription"
	ConnectionTaskDNS          = "dns"
	ConnectionTaskDataPlane    = "data_plane"
	ConnectionTaskIngress      = "ingress"
)

// BuildConnectionPlan compiles only the objects that can affect the active Scenario.
// It must remain side-effect free: cache inspection and network preparation belong
// to the platform transaction's Prepare phase.
func BuildConnectionPlan(profile *Profile) (*ConnectionPlan, error) {
	if profile == nil {
		return nil, fmt.Errorf("profile is nil")
	}
	scenario := profile.ActiveScenario()
	if scenario == nil {
		return nil, fmt.Errorf("no active scenario")
	}
	warnings, err := inspectScenarioReferences(profile, scenario)
	if err != nil {
		return nil, err
	}

	plan := &ConnectionPlan{
		SchemaVersion: 3,
		Scenario: ConnectionPlanScenario{
			ID:   scenario.ID,
			Name: scenario.Name,
		},
		Warnings: warnings,
	}
	fingerprint := newRuntimeConfigurationBuilder(profile, scenario)
	plan.Tasks = append(plan.Tasks, ConnectionPlanTask{
		ID:          "underlay:system",
		Kind:        ConnectionTaskUnderlay,
		Name:        "系统基础网络",
		Detail:      "捕获启动前默认接口、候选接口和系统 DNS",
		Preparation: "capture",
	})

	seen := map[string]bool{"underlay:system": true}
	var ruleTaskIDs []string
	var targetTaskIDs []string
	add := func(task ConnectionPlanTask) {
		if task.ID == "" || seen[task.ID] {
			return
		}
		seen[task.ID] = true
		plan.Tasks = append(plan.Tasks, task)
	}
	addRuleSet := func(ruleSet *RuleSet, targetName string) {
		if ruleSet == nil || !ruleSet.Enabled {
			return
		}
		taskID := "rule-set:" + ruleSet.ID
		preparation := "inline"
		detail := "本地规则"
		if ruleSet.Type == RuleSetTypeURL {
			preparation = "cache-or-download"
			detail = "远程规则；经校验缓存立即启动，连接后更新"
		}
		if targetName != "" {
			detail += " → " + targetName
		}
		add(ConnectionPlanTask{
			ID:           taskID,
			Kind:         ConnectionTaskRuleSet,
			Name:         ruleSetLabel(ruleSet),
			Detail:       detail,
			Preparation:  preparation,
			Dependencies: []string{"underlay:system"},
			ResourceID:   ruleSet.ID,
			ResourceType: string(ruleSet.Type),
		})
		ruleTaskIDs = appendUniqueString(ruleTaskIDs, taskID)
		fingerprint.includeRuleSet(ruleSet)
	}
	addLine := func(line *Line) (string, string, runtimeConfigurationTarget, bool) {
		if line == nil || !line.Enabled || !lineHasUsableOutbound(line) {
			return "", "", runtimeConfigurationTarget{}, false
		}
		taskID := "line:" + line.ID
		preparation := "start-with-data-plane"
		detail := string(line.Type)
		switch line.Type {
		case LineTypeDirect:
			preparation = "inherit-underlay"
			detail = "沿用启动前系统基础网络"
		case LineTypeVPN:
			preparation = "connect-and-probe"
			detail = "建立 AnyConnect 会话并等待就绪"
		case LineTypeTailscale:
			preparation = "resume-and-probe"
			if line.TailscaleMagicDNS {
				detail = "恢复本机身份、验证 MagicDNS、选择 Exit Node 并验证真实出口"
			} else {
				detail = "恢复本机身份、选择 Exit Node 并验证真实出口"
			}
		}
		add(ConnectionPlanTask{
			ID:           taskID,
			Kind:         ConnectionTaskLine,
			Name:         lineLabel(line),
			Detail:       detail,
			Preparation:  preparation,
			Dependencies: []string{"underlay:system"},
			ResourceID:   line.ID,
			ResourceType: string(line.Type),
		})
		targetTaskIDs = appendUniqueString(targetTaskIDs, taskID)
		fingerprint.includeLine(line)
		return taskID, lineLabel(line), lineRuntimeConfigurationTarget(line), true
	}
	addDirect := func() (string, string, runtimeConfigurationTarget) {
		line := profile.FindLine(builtinDirectLineID)
		if line == nil {
			line = &Line{
				ID:      builtinDirectLineID,
				Name:    "直连",
				Type:    LineTypeDirect,
				Enabled: true,
			}
		}
		taskID, name, _, _ := addLine(line)
		return taskID, name, directRuntimeConfigurationTarget()
	}
	addSubscription := func(subscription *Subscription) (string, string, runtimeConfigurationTarget, bool) {
		if subscription == nil || !subscription.Enabled ||
			!subscriptionHasUsableOutbound(subscription) {
			return "", "", runtimeConfigurationTarget{}, false
		}
		taskID := "subscription:" + subscription.ID
		add(ConnectionPlanTask{
			ID:           taskID,
			Kind:         ConnectionTaskSubscription,
			Name:         subscriptionLabel(subscription),
			Detail:       fmt.Sprintf("%d 个已声明节点；随 sing-box 数据面启动", len(subscription.Lines)),
			Preparation:  "start-with-data-plane",
			Dependencies: []string{"underlay:system"},
			ResourceID:   subscription.ID,
			ResourceType: strings.TrimSpace(subscription.Strategy),
		})
		targetTaskIDs = appendUniqueString(targetTaskIDs, taskID)
		addGeneratedSubscriptionRuleSets(plan, seen, subscription, &ruleTaskIDs)
		fingerprint.includeSubscription(subscription)
		return taskID, subscriptionLabel(subscription),
			subscriptionRuntimeConfigurationTarget(subscription), true
	}
	resolveTarget := func(lineID, subscriptionID string) (string, string, runtimeConfigurationTarget, bool) {
		if subscriptionID != "" {
			return addSubscription(profile.FindSubscription(subscriptionID))
		}
		if lineID == builtinDirectLineID {
			taskID, name, target := addDirect()
			return taskID, name, target, true
		}
		return addLine(profile.FindLine(lineID))
	}

	for _, binding := range scenario.Bindings {
		ruleSet := profile.FindRuleSet(binding.RuleSetID)
		if ruleSet == nil || !ruleSet.Enabled {
			continue
		}
		targetTaskID, targetName, target, effective := resolveTarget(
			binding.LineID,
			binding.SubscriptionID,
		)
		if !effective {
			continue
		}
		_ = targetTaskID
		addRuleSet(ruleSet, targetName)
		fingerprint.addBinding(ruleSet.ID, target)
	}

	_, _, defaultTarget, effective := resolveTarget(
		scenario.DefaultLineID,
		scenario.DefaultSubscriptionID,
	)
	if !effective {
		_, _, defaultTarget = addDirect()
	}
	fingerprint.setDefaultTarget(defaultTarget)

	dnsDependencies := appendUniqueStrings(
		[]string{"underlay:system"},
		append(ruleTaskIDs, targetTaskIDs...)...,
	)
	add(ConnectionPlanTask{
		ID:           "dns:scenario",
		Kind:         ConnectionTaskDNS,
		Name:         "分域解析",
		Detail:       "由当前场景的规则与出口共同编译",
		Preparation:  "compile-and-start",
		Dependencies: dnsDependencies,
		ResourceID:   scenario.ID,
	})

	dataPlaneDependencies := appendUniqueStrings(
		[]string{"underlay:system", "dns:scenario"},
		targetTaskIDs...,
	)
	add(ConnectionPlanTask{
		ID:           "data-plane:sing-box",
		Kind:         ConnectionTaskDataPlane,
		Name:         "sing-box 数据面",
		Detail:       "启动完整配置并完成计划中的线路就绪检查",
		Preparation:  "start-and-probe",
		Dependencies: dataPlaneDependencies,
	})
	add(ConnectionPlanTask{
		ID:           "ingress:transparent-proxy",
		Kind:         ConnectionTaskIngress,
		Name:         "系统网络接管",
		Detail:       "所有准备完成后的唯一 Commit",
		Preparation:  "commit",
		Dependencies: []string{"data-plane:sing-box"},
	})
	plan.ConfigurationFingerprint, err = fingerprint.fingerprint()
	if err != nil {
		return nil, fmt.Errorf("fingerprint connection configuration: %w", err)
	}
	return plan, nil
}

func addGeneratedSubscriptionRuleSets(
	plan *ConnectionPlan,
	seen map[string]bool,
	subscription *Subscription,
	ruleTaskIDs *[]string,
) {
	for _, rule := range subscription.Rules {
		if !strings.EqualFold(strings.TrimSpace(rule.Type), "GEOIP") {
			continue
		}
		code := strings.ToLower(strings.TrimSpace(rule.Value))
		if code == "" || code == "private" || code == "lan" {
			continue
		}
		resourceID := "sub-geoip-" + subscription.ID + "-" + code
		taskID := "rule-set:generated:" + resourceID
		if seen[taskID] {
			continue
		}
		seen[taskID] = true
		plan.Tasks = append(plan.Tasks, ConnectionPlanTask{
			ID:           taskID,
			Kind:         ConnectionTaskRuleSet,
			Name:         "GEOIP " + strings.ToUpper(code),
			Detail:       "订阅 " + subscriptionLabel(subscription) + " 需要的远程规则",
			Preparation:  "cache-or-download",
			Dependencies: []string{"underlay:system"},
			ResourceID:   resourceID,
			ResourceType: "generated",
		})
		*ruleTaskIDs = appendUniqueString(*ruleTaskIDs, taskID)
	}
}

func appendUniqueString(values []string, value string) []string {
	for _, existing := range values {
		if existing == value {
			return values
		}
	}
	return append(values, value)
}

func appendUniqueStrings(values []string, additions ...string) []string {
	for _, addition := range additions {
		values = appendUniqueString(values, addition)
	}
	return values
}
