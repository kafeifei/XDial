package config

import (
	"fmt"
	"path/filepath"
	"strings"
)

// 本文件实现 INV6：模式引用的完整性检查，把"引用解析不了"这件事分成两类处理。
//
//	INV6a 悬空引用（FindLine/FindRuleSet/FindSubscription 返回 nil，
//	      或绑定压根没写出口）—— 配置已经损坏，生成直接失败。
//	      绝不允许"整条规则蒸发"式的静默降级：用户以为绑定生效了，
//	      实际流量落到 final，正是架构约束禁止的静默降级到 direct。
//
//	INV6b 显式禁用（对象存在但 Enabled=false）—— 这是用户自己的选择，
//	      允许跳过，但必须结构化上报，让 daemon/UI 能把"这条绑定当前没生效"
//	      展示出来，而不是悄悄少一条规则。
//
// 注意 INV6a 的检查不受 Enabled 影响：一条绑定即使当前被禁用，
// 它指向的 line/subscription 也必须真实存在。否则用户哪天一勾选，
// 悬空引用就变成静默错路由。

// builtinDirectLineID 是保留的线路 ID：direct outbound 由生成器无条件产出，
// 所以模式引用 "direct" 时即使 profile 的 Lines 里没有对应条目也不算悬空。
// 这是既有约定（默认 profile 里有这条线路，但大量精简配置直接引用它）。
const builtinDirectLineID = "direct"

// ProfileWarningKind 标识一条降级警告的类别。字符串值会进 JSON，
// 供 daemon/UI 直接消费，不要随意改名。
type ProfileWarningKind string

const (
	// WarningDisabledRuleSet 绑定引用的规则存在但被禁用，整条绑定不生效。
	WarningDisabledRuleSet ProfileWarningKind = "disabled_rule_set"
	// WarningDisabledLine 绑定引用的线路存在但被禁用，该绑定不产生路由规则。
	WarningDisabledLine ProfileWarningKind = "disabled_line"
	// WarningDisabledSubscription 绑定引用的订阅存在但被禁用。
	WarningDisabledSubscription ProfileWarningKind = "disabled_subscription"
	// WarningDisabledDefaultLine 模式默认出口线路被禁用，默认出口回落 direct。
	WarningDisabledDefaultLine ProfileWarningKind = "disabled_default_line"
	// WarningDisabledDefaultSubscription 模式默认出口订阅被禁用，默认出口回落 direct。
	WarningDisabledDefaultSubscription ProfileWarningKind = "disabled_default_subscription"
	// WarningUnavailableLine 仅为旧 JSON/API 兼容保留。active Mode 直接引用的 enabled
	// Line 无法生成 outbound 时现在必须返回 error，不再产生此 warning。
	WarningUnavailableLine ProfileWarningKind = "unavailable_line"
	// WarningUnavailableSubscription 仅为旧 JSON/API 兼容保留。active Mode 直接引用的
	// enabled Subscription 无法生成主 outbound 时现在必须返回 error。
	WarningUnavailableSubscription ProfileWarningKind = "unavailable_subscription"
)

// ProfileWarning 是一条"配置能生成，但某个绑定实际不生效"的结构化提示。
// 与 error 的区别：error 表示拒绝生成配置，warning 表示配置照生成但用户必须知情。
type ProfileWarning struct {
	Kind           ProfileWarningKind `json:"kind"`
	ModeID         string             `json:"mode_id,omitempty"`
	RuleSetID      string             `json:"rule_set_id,omitempty"`
	LineID         string             `json:"line_id,omitempty"`
	SubscriptionID string             `json:"subscription_id,omitempty"`
	Message        string             `json:"message"`
}

func (w ProfileWarning) String() string {
	return w.Message
}

// CollectProfileWarnings 校验活动模式的引用完整性。
//
// 返回 error = 配置里有悬空引用（INV6a），GenerateSingBox* 也一定会用同一份逻辑拒绝生成。
// 返回 warnings = 有对象存在但被显式禁用（INV6b），生成会继续，但调用方
// （daemon / UI）必须把这些提示展示给用户。
//
// active Mode 直接引用的 enabled Line / Subscription 若生成不出 outbound 则返回
// error。它不是用户主动禁用，而是无法兑现 Mode 已声明的出口；继续生成会让绑定消失
// 或让默认出口落到 direct，违反 fail-closed。
//
// 这是一个独立的只读入口，刻意不改 GenerateSingBox / GenerateSingBoxFor /
// GenerateSingBoxDesktop 的签名，现有调用方（core/engine、core/libbox）零改动。
func CollectProfileWarnings(profile *Profile) ([]ProfileWarning, error) {
	if profile == nil {
		return nil, fmt.Errorf("profile is nil")
	}
	mode := profile.ActiveMode()
	if mode == nil {
		return nil, fmt.Errorf("no active mode")
	}
	return inspectModeReferences(profile, mode)
}

// inspectModeReferences 是 INV6 的唯一实现点：generateSingBox 与
// CollectProfileWarnings 都走它，保证"能不能生成"和"为什么某条没生效"的判定一致。
func inspectModeReferences(profile *Profile, mode *Mode) ([]ProfileWarning, error) {
	var warnings []ProfileWarning
	warn := func(w ProfileWarning) {
		w.ModeID = mode.ID
		warnings = append(warnings, w)
	}

	for index := range mode.Bindings {
		binding := mode.Bindings[index]

		if binding.RuleSetID == "" {
			return nil, fmt.Errorf("mode %q binding #%d has no rule set reference", mode.ID, index+1)
		}
		ruleSet := profile.FindRuleSet(binding.RuleSetID)
		if ruleSet == nil {
			return nil, fmt.Errorf("mode %q references missing rule set %q", mode.ID, binding.RuleSetID)
		}

		// 先把出口引用的"存在性"验掉（不看 Enabled）——见文件头注释。
		var (
			line         *Line
			subscription *Subscription
		)
		switch {
		case binding.SubscriptionID != "":
			subscription = profile.FindSubscription(binding.SubscriptionID)
			if subscription == nil {
				return nil, fmt.Errorf("mode %q binds rule set %q to missing subscription %q",
					mode.ID, binding.RuleSetID, binding.SubscriptionID)
			}
		case binding.LineID == builtinDirectLineID:
			// 内建直连：不需要 profile 里有对应 Line，也没有可禁用的对象。
		case binding.LineID != "":
			line = profile.FindLine(binding.LineID)
			if line == nil {
				return nil, fmt.Errorf("mode %q binds rule set %q to missing line %q",
					mode.ID, binding.RuleSetID, binding.LineID)
			}
		default:
			return nil, fmt.Errorf("mode %q binds rule set %q to neither a line nor a subscription",
				mode.ID, binding.RuleSetID)
		}

		switch ruleSet.Type {
		case RuleSetTypeURL, RuleSetTypeManual, RuleSetTypeApplication:
		default:
			return nil, fmt.Errorf(
				"mode %q references rule set %q with unsupported type %q",
				mode.ID,
				ruleSet.ID,
				ruleSet.Type,
			)
		}

		// 规则被禁用时整条绑定不生效，出口那侧就不再重复提示。
		if !ruleSet.Enabled {
			warn(ProfileWarning{
				Kind:           WarningDisabledRuleSet,
				RuleSetID:      ruleSet.ID,
				LineID:         binding.LineID,
				SubscriptionID: binding.SubscriptionID,
				Message: fmt.Sprintf("规则 %q 已禁用，模式 %q 里绑定它的分流不生效",
					ruleSetLabel(ruleSet), modeLabel(mode)),
			})
			continue
		}
		if ruleSet.Type == RuleSetTypeApplication {
			if err := validateApplicationRuleSet(ruleSet); err != nil {
				return nil, fmt.Errorf("mode %q references invalid application rule set %q: %w",
					mode.ID, ruleSet.ID, err)
			}
		}

		if subscription != nil {
			if !subscription.Enabled {
				warn(ProfileWarning{
					Kind:           WarningDisabledSubscription,
					RuleSetID:      ruleSet.ID,
					SubscriptionID: subscription.ID,
					Message: fmt.Sprintf("订阅 %q 已禁用，规则 %q 绑定的流量回落到模式默认出口",
						subscriptionLabel(subscription), ruleSetLabel(ruleSet)),
				})
				continue
			}
			if !subscriptionHasUsableOutbound(subscription) {
				return nil, fmt.Errorf(
					"mode %q binds enabled rule set %q to enabled subscription %q, but the subscription cannot generate an outbound",
					mode.ID,
					ruleSet.ID,
					subscription.ID,
				)
			}
			continue
		}
		if line == nil {
			// 内建直连，恒可用。
			continue
		}

		if !line.Enabled {
			warn(ProfileWarning{
				Kind:      WarningDisabledLine,
				RuleSetID: ruleSet.ID,
				LineID:    line.ID,
				Message: fmt.Sprintf("线路 %q 已禁用，规则 %q 绑定的流量回落到模式默认出口",
					lineLabel(line), ruleSetLabel(ruleSet)),
			})
			continue
		}
		if !lineHasUsableOutbound(line) {
			return nil, fmt.Errorf(
				"mode %q binds enabled rule set %q to enabled line %q (type %q), but the line cannot generate an outbound",
				mode.ID,
				ruleSet.ID,
				line.ID,
				line.Type,
			)
		}
	}

	// 默认出口：悬空同样报错；禁用则回落 direct 并告警（generateSingBox 里
	// defaultTag 的解析结果与这里一一对应）。
	switch {
	case mode.DefaultSubscriptionID != "":
		subscription := profile.FindSubscription(mode.DefaultSubscriptionID)
		if subscription == nil {
			return nil, fmt.Errorf("mode %q default subscription %q does not exist",
				mode.ID, mode.DefaultSubscriptionID)
		}
		if !subscription.Enabled {
			warn(ProfileWarning{
				Kind:           WarningDisabledDefaultSubscription,
				SubscriptionID: subscription.ID,
				Message: fmt.Sprintf("模式 %q 的默认出口订阅 %q 已禁用，默认出口回落直连",
					modeLabel(mode), subscriptionLabel(subscription)),
			})
		} else if !subscriptionHasUsableOutbound(subscription) {
			return nil, fmt.Errorf(
				"mode %q uses enabled subscription %q as its default, but the subscription cannot generate an outbound",
				mode.ID,
				subscription.ID,
			)
		}
	case mode.DefaultLineID == builtinDirectLineID:
		// 内建直连默认出口，恒可用。
	case mode.DefaultLineID != "":
		line := profile.FindLine(mode.DefaultLineID)
		if line == nil {
			return nil, fmt.Errorf("mode %q default line %q does not exist",
				mode.ID, mode.DefaultLineID)
		}
		if !line.Enabled {
			warn(ProfileWarning{
				Kind:   WarningDisabledDefaultLine,
				LineID: line.ID,
				Message: fmt.Sprintf("模式 %q 的默认出口线路 %q 已禁用，默认出口回落直连",
					modeLabel(mode), lineLabel(line)),
			})
		} else if !lineHasUsableOutbound(line) {
			return nil, fmt.Errorf(
				"mode %q uses enabled line %q (type %q) as its default, but the line cannot generate an outbound",
				mode.ID,
				line.ID,
				line.Type,
			)
		}
	}

	return warnings, nil
}

func validateApplicationRuleSet(ruleSet *RuleSet) error {
	if len(ruleSet.Applications) == 0 {
		return fmt.Errorf("applications is empty")
	}
	for applicationIndex, application := range ruleSet.Applications {
		if _, ok := canonicalApplicationBundlePath(application.Path); !ok {
			return fmt.Errorf("application #%d bundle path is invalid", applicationIndex+1)
		}
	}
	return nil
}

// canonicalApplicationBundlePath validates the persisted Surge-style App
// Bundle selector without consulting the live filesystem. Planning remains
// side-effect free, while the Provider can compare the exact same lexical path
// against the audit-token-derived executable path at flow time.
func canonicalApplicationBundlePath(raw string) (string, bool) {
	if raw == "" || len(raw) > 4096 || strings.TrimSpace(raw) != raw ||
		strings.IndexByte(raw, 0) >= 0 || !filepath.IsAbs(raw) {
		return "", false
	}
	cleaned := filepath.Clean(raw)
	base := filepath.Base(cleaned)
	if cleaned != raw || len(base) <= len(".app") ||
		!strings.HasSuffix(strings.ToLower(base), ".app") {
		return "", false
	}
	return cleaned, true
}

// lineHasUsableOutbound 判断一条 enabled 线路能不能真的生成出 outbound。
// direct / vpn / tailscale 由生成器直接构造，恒可用；代理类线路参数不全时
// buildProxyOutbound 返回 nil。active Mode 直接引用这种线路时必须拒绝规划和生成，
// 不能把缺失 outbound 降为 warning。
func lineHasUsableOutbound(line *Line) bool {
	switch line.Type {
	case LineTypeDirect, LineTypeVPN, LineTypeTailscale:
		return true
	default:
		return buildProxyOutbound(line) != nil
	}
}

// LineHasUsableOutbound exposes the generator's exact Line capability check to
// control-plane consumers. Callers must not reimplement protocol validation:
// accepting a node here that buildProxyOutbound later drops would make a
// subscription look ready while its actual outbound is absent.
func LineHasUsableOutbound(line *Line) bool {
	return lineHasUsableOutbound(line)
}

// subscriptionHasUsableOutbound 判断订阅能否生成出可被规则引用的主 tag。
// 平台只影响 urltest 的探测 URL，不影响 mainTag 是否存在，故固定用 PlatformMacOS。
func subscriptionHasUsableOutbound(subscription *Subscription) bool {
	_, mainTag, _ := buildSubscriptionOutbounds(subscription, PlatformMacOS)
	return mainTag != ""
}

func modeLabel(mode *Mode) string {
	if mode.Name != "" {
		return mode.Name
	}
	return mode.ID
}

func lineLabel(line *Line) string {
	if line.Name != "" {
		return line.Name
	}
	return line.ID
}

func ruleSetLabel(ruleSet *RuleSet) string {
	if ruleSet.Name != "" {
		return ruleSet.Name
	}
	return ruleSet.ID
}

func subscriptionLabel(subscription *Subscription) string {
	if subscription.Name != "" {
		return subscription.Name
	}
	return subscription.ID
}
