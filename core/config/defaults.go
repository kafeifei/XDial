package config

// 邮轮模板工厂函数
// 用户从模板创建自己的邮轮后可任意修改

// TemplateOverseas 海外模式：自定义货品→VPN，其他→直连
func TemplateOverseas(cargoIDs []string, vpnPortID, directPortID string) Cruise {
	var bindings []Binding
	for _, cid := range cargoIDs {
		bindings = append(bindings, Binding{CargoID: cid, PortID: vpnPortID})
	}
	return Cruise{
		Name:          "海外",
		Bindings:      bindings,
		DefaultPortID: directPortID,
	}
}

// TemplateDomestic 国内模式：自定义货品→VPN，GFW→VPN，其他→直连
func TemplateDomestic(domainCargoIDs []string, gfwCargoID, vpnPortID, directPortID string) Cruise {
	var bindings []Binding
	for _, cid := range domainCargoIDs {
		bindings = append(bindings, Binding{CargoID: cid, PortID: vpnPortID})
	}
	if gfwCargoID != "" {
		bindings = append(bindings, Binding{CargoID: gfwCargoID, PortID: vpnPortID})
	}
	return Cruise{
		Name:          "国内",
		Bindings:      bindings,
		DefaultPortID: directPortID,
	}
}

// TemplateDomesticSS 国内+SS模式：自定义货品→VPN，GFW→SS，其他→直连
func TemplateDomesticSS(domainCargoIDs []string, gfwCargoID, vpnPortID, ssPortID, directPortID string) Cruise {
	var bindings []Binding
	for _, cid := range domainCargoIDs {
		bindings = append(bindings, Binding{CargoID: cid, PortID: vpnPortID})
	}
	if gfwCargoID != "" {
		bindings = append(bindings, Binding{CargoID: gfwCargoID, PortID: ssPortID})
	}
	return Cruise{
		Name:          "国内+SS",
		Bindings:      bindings,
		DefaultPortID: directPortID,
	}
}
