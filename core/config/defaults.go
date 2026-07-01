package config

// 模式模板工厂函数
// 用户从模板创建自己的模式后可任意修改

// TemplateOverseas 海外模式：自定义规则→VPN，其他→直连
func TemplateOverseas(ruleSetIDs []string, vpnLineID, directLineID string) Mode {
	var bindings []RuleBinding
	for _, rid := range ruleSetIDs {
		bindings = append(bindings, RuleBinding{RuleSetID: rid, LineID: vpnLineID})
	}
	return Mode{
		Name:          "海外",
		Bindings:      bindings,
		DefaultLineID: directLineID,
	}
}

// TemplateDomestic 国内模式：自定义规则→VPN，GFW→VPN，其他→直连
func TemplateDomestic(domainRuleSetIDs []string, gfwRuleSetID, vpnLineID, directLineID string) Mode {
	var bindings []RuleBinding
	for _, rid := range domainRuleSetIDs {
		bindings = append(bindings, RuleBinding{RuleSetID: rid, LineID: vpnLineID})
	}
	if gfwRuleSetID != "" {
		bindings = append(bindings, RuleBinding{RuleSetID: gfwRuleSetID, LineID: vpnLineID})
	}
	return Mode{
		Name:          "国内",
		Bindings:      bindings,
		DefaultLineID: directLineID,
	}
}

// TemplateDomesticSS 国内+SS模式：自定义规则→VPN，GFW→SS，其他→直连
func TemplateDomesticSS(domainRuleSetIDs []string, gfwRuleSetID, vpnLineID, ssLineID, directLineID string) Mode {
	var bindings []RuleBinding
	for _, rid := range domainRuleSetIDs {
		bindings = append(bindings, RuleBinding{RuleSetID: rid, LineID: vpnLineID})
	}
	if gfwRuleSetID != "" {
		bindings = append(bindings, RuleBinding{RuleSetID: gfwRuleSetID, LineID: ssLineID})
	}
	return Mode{
		Name:          "国内+SS",
		Bindings:      bindings,
		DefaultLineID: directLineID,
	}
}
