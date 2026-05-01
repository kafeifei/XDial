package config

// 模板策略组工厂函数
// 这些不是硬编码的预设——用户从模板创建自己的策略组后可任意修改

// TemplateOverseas 海外模式：自定义规则→VPN，其他→直连
func TemplateOverseas(ruleIDs []string, vpnExitID, directExitID string) Strategy {
	var bindings []Binding
	for _, rid := range ruleIDs {
		bindings = append(bindings, Binding{RuleID: rid, ExitID: vpnExitID})
	}
	return Strategy{
		Name:          "海外",
		Bindings:      bindings,
		DefaultExitID: directExitID,
	}
}

// TemplateDomestic 国内模式：自定义规则→VPN，GFW→VPN，其他→直连
func TemplateDomestic(domainRuleIDs []string, gfwRuleID, vpnExitID, directExitID string) Strategy {
	var bindings []Binding
	for _, rid := range domainRuleIDs {
		bindings = append(bindings, Binding{RuleID: rid, ExitID: vpnExitID})
	}
	if gfwRuleID != "" {
		bindings = append(bindings, Binding{RuleID: gfwRuleID, ExitID: vpnExitID})
	}
	return Strategy{
		Name:          "国内",
		Bindings:      bindings,
		DefaultExitID: directExitID,
	}
}

// TemplateDomesticSS 国内+SS模式：自定义规则→VPN，GFW→SS，其他→直连
func TemplateDomesticSS(domainRuleIDs []string, gfwRuleID, vpnExitID, ssExitID, directExitID string) Strategy {
	var bindings []Binding
	for _, rid := range domainRuleIDs {
		bindings = append(bindings, Binding{RuleID: rid, ExitID: vpnExitID})
	}
	if gfwRuleID != "" {
		bindings = append(bindings, Binding{RuleID: gfwRuleID, ExitID: ssExitID})
	}
	return Strategy{
		Name:          "国内+SS",
		Bindings:      bindings,
		DefaultExitID: directExitID,
	}
}
