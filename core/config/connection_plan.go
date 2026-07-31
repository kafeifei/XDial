package config

import (
	"fmt"
	"strings"
)

// ConnectionPlan is the side-effect-free description of one connection attempt.
// It is compiled from the active Mode and is the single checklist consumed by the
// Network Extension transaction, UI, diagnostics, and tests.
type ConnectionPlan struct {
	SchemaVersion int                  `json:"schema_version"`
	Mode          ConnectionPlanMode   `json:"mode"`
	Tasks         []ConnectionPlanTask `json:"tasks"`
	Warnings      []ProfileWarning     `json:"warnings,omitempty"`
}

type ConnectionPlanMode struct {
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

// BuildConnectionPlan compiles only the objects that can affect the active Mode.
// It must remain side-effect free: cache inspection and network preparation belong
// to the platform transaction's Prepare phase.
func BuildConnectionPlan(profile *Profile) (*ConnectionPlan, error) {
	if profile == nil {
		return nil, fmt.Errorf("profile is nil")
	}
	mode := profile.ActiveMode()
	if mode == nil {
		return nil, fmt.Errorf("no active mode")
	}
	warnings, err := inspectModeReferences(profile, mode)
	if err != nil {
		return nil, err
	}

	plan := &ConnectionPlan{
		SchemaVersion: 1,
		Mode: ConnectionPlanMode{
			ID:   mode.ID,
			Name: mode.Name,
		},
		Warnings: warnings,
	}
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
	addRuleSet := func(ruleSet *RuleSet, targetTaskID, targetName string) {
		if ruleSet == nil || !ruleSet.Enabled {
			return
		}
		taskID := "rule-set:" + ruleSet.ID
		preparation := "inline"
		detail := "本地规则"
		if ruleSet.Type == RuleSetTypeURL {
			preparation = "cache-or-download"
			detail = "远程规则；优先使用经校验缓存，必要时下载"
		}
		if targetName != "" {
			detail += " → " + targetName
		}
		dependencies := []string{"underlay:system"}
		if targetTaskID != "" {
			// The edge is represented in Detail for the UI. A RuleSet can be
			// downloaded concurrently with its Line, so it does not depend on it.
			_ = targetTaskID
		}
		add(ConnectionPlanTask{
			ID:           taskID,
			Kind:         ConnectionTaskRuleSet,
			Name:         ruleSetLabel(ruleSet),
			Detail:       detail,
			Preparation:  preparation,
			Dependencies: dependencies,
			ResourceID:   ruleSet.ID,
			ResourceType: string(ruleSet.Type),
		})
		ruleTaskIDs = appendUniqueString(ruleTaskIDs, taskID)
	}
	addLine := func(line *Line) (string, string, bool) {
		if line == nil || !line.Enabled || !lineHasUsableOutbound(line) {
			return "", "", false
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
		return taskID, lineLabel(line), true
	}
	addDirect := func() (string, string) {
		line := profile.FindLine(builtinDirectLineID)
		if line == nil {
			line = &Line{
				ID:      builtinDirectLineID,
				Name:    "直连",
				Type:    LineTypeDirect,
				Enabled: true,
			}
		}
		taskID, name, _ := addLine(line)
		return taskID, name
	}
	addSubscription := func(subscription *Subscription) (string, string, bool) {
		if subscription == nil || !subscription.Enabled ||
			!subscriptionHasUsableOutbound(subscription) {
			return "", "", false
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
		return taskID, subscriptionLabel(subscription), true
	}
	resolveTarget := func(lineID, subscriptionID string) (string, string, bool) {
		if subscriptionID != "" {
			return addSubscription(profile.FindSubscription(subscriptionID))
		}
		if lineID == builtinDirectLineID {
			taskID, name := addDirect()
			return taskID, name, true
		}
		return addLine(profile.FindLine(lineID))
	}

	for _, binding := range mode.Bindings {
		ruleSet := profile.FindRuleSet(binding.RuleSetID)
		if ruleSet == nil || !ruleSet.Enabled {
			continue
		}
		targetTaskID, targetName, effective := resolveTarget(
			binding.LineID,
			binding.SubscriptionID,
		)
		if !effective {
			continue
		}
		addRuleSet(ruleSet, targetTaskID, targetName)
	}

	if _, _, effective := resolveTarget(
		mode.DefaultLineID,
		mode.DefaultSubscriptionID,
	); !effective {
		addDirect()
	}

	dnsDependencies := appendUniqueStrings(
		[]string{"underlay:system"},
		append(ruleTaskIDs, targetTaskIDs...)...,
	)
	add(ConnectionPlanTask{
		ID:           "dns:mode",
		Kind:         ConnectionTaskDNS,
		Name:         "分域解析",
		Detail:       "由当前 Mode 的规则与出口共同编译",
		Preparation:  "compile-and-start",
		Dependencies: dnsDependencies,
		ResourceID:   mode.ID,
	})

	dataPlaneDependencies := appendUniqueStrings(
		[]string{"underlay:system", "dns:mode"},
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
