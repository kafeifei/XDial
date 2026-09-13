package config

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
)

// ProfileDocument is the portable sing-box resource envelope. Scenario routing
// and presentation metadata are the only XDial extensions. Platform ingress,
// Keychain material and runtime identity directories are never exported.
type ProfileDocument struct {
	Outbounds []json.RawMessage `json:"outbounds"`
	Route     documentRoute     `json:"route"`
	XDial     documentMetadata  `json:"xdial"`
}
type documentRoute struct {
	RuleSets []json.RawMessage `json:"rule_set,omitempty"`
	Rules    []json.RawMessage `json:"rules,omitempty"`
	Final    string            `json:"final,omitempty"`
}
type documentScenario struct {
	ID    string        `json:"id"`
	Name  string        `json:"name"`
	Icon  string        `json:"icon,omitempty"`
	SSIDs []string      `json:"match_ssids,omitempty"`
	Route documentRoute `json:"route"`
}
type documentObject struct {
	Kind         RuleSetType        `json:"kind,omitempty"`
	Domains      []string           `json:"domains,omitempty"`
	CIDRs        []string           `json:"cidrs,omitempty"`
	Name         string             `json:"name"`
	Disabled     bool               `json:"disabled,omitempty"`
	Invert       bool               `json:"invert,omitempty"`
	Applications []ApplicationMatch `json:"applications,omitempty"`
	Processes    []string           `json:"processes,omitempty"`
}
type documentMetadata struct {
	RequiresInput bool                      `json:"requires_input,omitempty"`
	SchemaVersion int                       `json:"schema_version"`
	Lines         map[string]documentObject `json:"lines,omitempty"`
	Rules         map[string]documentObject `json:"rules,omitempty"`
	AdapterLines  []Line                    `json:"adapter_lines,omitempty"`
	Scenarios     []documentScenario        `json:"scenarios"`
}

func documentID(namespace, kind, identity string) string {
	digest := sha256.Sum256([]byte(namespace + "\x00" + kind + "\x00" + identity))
	return kind + "-" + hex.EncodeToString(digest[:12])
}

// ImportProfileDocument rejects unsupported semantics instead of silently
// stripping them. More sing-box options can be admitted without changing the
// portable envelope or the platform's Profile library.
func ImportProfileDocument(data []byte, namespace string) (*Profile, error) {
	if len(data) > 4*1024*1024 {
		return nil, fmt.Errorf("configuration exceeds 4 MiB")
	}
	var root map[string]json.RawMessage
	if json.Unmarshal(data, &root) != nil {
		return nil, fmt.Errorf("invalid JSON configuration")
	}
	if root["lines"] != nil {
		profile, err := ParseProfile(data)
		if err != nil {
			return nil, fmt.Errorf("invalid legacy XDial configuration")
		}
		if len(profile.Subscriptions) > 0 {
			return nil, fmt.Errorf("legacy nested subscriptions require migration; import their source links as Profiles")
		}
		profile = CloneProfile(profile, namespace)
		return profile, validateDocumentProfile(profile)
	}
	for key, value := range root {
		switch key {
		case "outbounds", "route", "xdial", "log":
		case "dns", "inbounds", "endpoints", "experimental":
			trimmed := strings.TrimSpace(string(value))
			if trimmed != "{}" && trimmed != "[]" && trimmed != "null" {
				return nil, fmt.Errorf("this build cannot yet import sing-box %s semantics; the configuration was not changed", key)
			}
		default:
			return nil, fmt.Errorf("unsupported configuration field %q", key)
		}
	}
	if value := root["route"]; value != nil {
		var routeFields map[string]json.RawMessage
		if json.Unmarshal(value, &routeFields) != nil {
			return nil, fmt.Errorf("invalid route configuration")
		}
		if err := allowDocumentKeys(routeFields, "rule_set", "rules", "final"); err != nil {
			return nil, err
		}
	}
	if raw := root["xdial"]; raw != nil {
		var metadata documentMetadata
		decoder := json.NewDecoder(bytes.NewReader(raw))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&metadata); err != nil {
			return nil, fmt.Errorf("invalid or unsupported XDial metadata: %w", err)
		}
		for _, scene := range metadata.Scenarios {
			if len(scene.Route.RuleSets) != 0 {
				return nil, fmt.Errorf("Scenario rule sets must be shared in the Profile route.rule_set")
			}
		}
	}
	var document ProfileDocument
	if err := json.Unmarshal(data, &document); err != nil {
		return nil, fmt.Errorf("invalid sing-box configuration")
	}
	if document.XDial.SchemaVersion != 0 && document.XDial.SchemaVersion != 1 {
		return nil, fmt.Errorf("unsupported XDial schema version")
	}
	profile := &Profile{ID: namespace, Lines: []Line{{ID: "direct", Name: "直连", Type: LineTypeDirect, Enabled: true}}}
	tags := map[string]string{"direct": "direct"}
	seen := map[string]bool{}
	for _, raw := range document.Outbounds {
		var fields map[string]interface{}
		if json.Unmarshal(raw, &fields) != nil {
			return nil, fmt.Errorf("invalid outbound")
		}
		tag, _ := fields["tag"].(string)
		if tag == "" || seen[tag] {
			return nil, fmt.Errorf("missing or duplicate outbound tag")
		}
		if tag == "direct" && fields["type"] != "direct" {
			return nil, fmt.Errorf("direct is a reserved outbound tag")
		}
		seen[tag] = true
		tags[tag] = documentID(namespace, "line", tag)
		if fields["type"] == "direct" {
			tags[tag] = "direct"
		}
	}
	for _, line := range document.XDial.AdapterLines {
		if line.ID == "" || seen[line.ID] {
			return nil, fmt.Errorf("duplicate adapter line tag")
		}
		seen[line.ID] = true
		tags[line.ID] = documentID(namespace, "line", line.ID)
	}
	for _, raw := range document.Outbounds {
		line, err := importDocumentOutbound(raw, tags, document.XDial.RequiresInput)
		if err != nil {
			return nil, err
		}
		var header struct {
			Tag string `json:"tag"`
		}
		_ = json.Unmarshal(raw, &header)
		if metadata, ok := document.XDial.Lines[header.Tag]; ok {
			line.Name = metadata.Name
			line.Enabled = !metadata.Disabled
		}
		if line.Type == LineTypeDirect {
			profile.Lines[0] = *line
		} else {
			profile.Lines = append(profile.Lines, *line)
		}
	}
	for _, original := range document.XDial.AdapterLines {
		line := original
		line.ID = tags[original.ID]
		profile.Lines = append(profile.Lines, line)
	}
	ruleTags := map[string]string{}
	for _, raw := range document.Route.RuleSets {
		var fields map[string]json.RawMessage
		if json.Unmarshal(raw, &fields) != nil {
			return nil, fmt.Errorf("invalid rule set")
		}
		var tag, kind string
		_ = json.Unmarshal(fields["tag"], &tag)
		_ = json.Unmarshal(fields["type"], &kind)
		if tag == "" || ruleTags[tag] != "" {
			return nil, fmt.Errorf("missing or duplicate rule set tag")
		}
		id := documentID(namespace, "rule", tag)
		ruleTags[tag] = id
		rule := RuleSet{ID: id, Name: tag, Enabled: true}
		switch kind {
		case "remote":
			if err := allowDocumentKeys(fields, "type", "tag", "url", "format", "download_detour"); err != nil {
				return nil, err
			}
			rule.Type = RuleSetTypeURL
			_ = json.Unmarshal(fields["url"], &rule.URL)
			if rule.URL == "" && !document.XDial.RequiresInput {
				return nil, fmt.Errorf("remote rule set requires a URL")
			}
			_ = json.Unmarshal(fields["format"], &rule.Format)
			var detour string
			_ = json.Unmarshal(fields["download_detour"], &detour)
			rule.FetchLineID = "direct"
			if detour != "" {
				rule.FetchLineID = tags[detour]
				if rule.FetchLineID == "" {
					return nil, fmt.Errorf("unknown rule set download detour")
				}
			}
		case "inline", "":
			if err := allowDocumentKeys(fields, "type", "tag", "rules"); err != nil {
				return nil, err
			}
			var rules []json.RawMessage
			if json.Unmarshal(fields["rules"], &rules) != nil {
				return nil, fmt.Errorf("invalid inline rule set")
			}
			if len(rules) == 0 && document.XDial.Rules[tag].Kind != RuleSetTypeManual && document.XDial.Rules[tag].Kind != RuleSetTypeApplication {
				return nil, fmt.Errorf("empty inline rule set")
			}
			rule.Type = RuleSetTypeNative
			if len(rules) == 1 {
				rule.NativeRule = rules[0]
			} else {
				rule.NativeRule, _ = json.Marshal(map[string]interface{}{"type": "logical", "mode": "or", "rules": rules})
			}
		default:
			return nil, fmt.Errorf("rule set type %q is not supported for portable import", kind)
		}
		if metadata, ok := document.XDial.Rules[tag]; ok {
			rule.Name = metadata.Name
			rule.Enabled = !metadata.Disabled
			rule.Invert = metadata.Invert
			if metadata.Kind == RuleSetTypeManual {
				rule.Type = RuleSetTypeManual
				rule.NativeRule = nil
				rule.Domains = metadata.Domains
				rule.CIDRs = metadata.CIDRs
			}
			if metadata.Kind == RuleSetTypeApplication || len(metadata.Applications) > 0 || len(metadata.Processes) > 0 {
				rule.Type = RuleSetTypeApplication
				rule.NativeRule = nil
				rule.Applications = metadata.Applications
				rule.Processes = metadata.Processes
			}
		}
		profile.RuleSets = append(profile.RuleSets, rule)
	}
	scenarios := document.XDial.Scenarios
	if len(scenarios) == 0 {
		scenarios = []documentScenario{{ID: "default", Name: "默认场景", Route: document.Route}}
	}
	for _, entry := range scenarios {
		if entry.ID == "" {
			return nil, fmt.Errorf("scenario identity is missing")
		}
		scenario := Scenario{ID: documentID(namespace, "scenario", entry.ID), Name: entry.Name, Icon: entry.Icon, MatchSSIDs: entry.SSIDs}
		scenario.DefaultLineID = tags[entry.Route.Final]
		if entry.Route.Final == "" {
			if len(document.Outbounds) > 0 {
				var first struct {
					Tag string `json:"tag"`
				}
				_ = json.Unmarshal(document.Outbounds[0], &first)
				scenario.DefaultLineID = tags[first.Tag]
			} else {
				scenario.DefaultLineID = "direct"
			}
		}
		if scenario.DefaultLineID == "" {
			return nil, fmt.Errorf("unknown final outbound")
		}
		for index, raw := range entry.Route.Rules {
			var fields map[string]json.RawMessage
			if json.Unmarshal(raw, &fields) != nil {
				return nil, fmt.Errorf("invalid route rule")
			}
			var action, outbound string
			_ = json.Unmarshal(fields["action"], &action)
			_ = json.Unmarshal(fields["outbound"], &outbound)
			if action != "" && action != "route" {
				return nil, fmt.Errorf("route action %q is not yet supported for import", action)
			}
			lineID := tags[outbound]
			if lineID == "" {
				return nil, fmt.Errorf("route references an unknown outbound")
			}
			delete(fields, "action")
			delete(fields, "outbound")
			var ruleID string
			if value := fields["rule_set"]; value != nil {
				var tag string
				if json.Unmarshal(value, &tag) != nil {
					return nil, fmt.Errorf("multiple rule_set references require an explicit logical rule")
				}
				ruleID = ruleTags[tag]
				if ruleID == "" || len(fields) != 1 {
					return nil, fmt.Errorf("unsupported rule_set reference or additional match conditions")
				}
			} else {
				encoded, _ := json.Marshal(fields)
				if err := validateNativeRule(encoded); err != nil {
					return nil, err
				}
				ruleID = documentID(namespace, "rule", "match/"+string(encoded))
				if profile.FindRuleSet(ruleID) == nil {
					profile.RuleSets = append(profile.RuleSets, RuleSet{ID: ruleID, Name: fmt.Sprintf("分流规则 %d", index+1), Type: RuleSetTypeNative, Enabled: true, NativeRule: encoded})
				}
			}
			scenario.Bindings = append(scenario.Bindings, RuleBinding{RuleSetID: ruleID, LineID: lineID})
		}
		profile.Scenarios = append(profile.Scenarios, scenario)
	}
	profile.ActiveScenarioID = profile.Scenarios[0].ID
	return profile, validateDocumentProfile(profile)
}

func allowDocumentKeys(fields map[string]json.RawMessage, allowed ...string) error {
	for key := range fields {
		found := false
		for _, value := range allowed {
			if key == value {
				found = true
				break
			}
		}
		if !found {
			return fmt.Errorf("unsupported configuration field %q", key)
		}
	}
	return nil
}

func importDocumentOutbound(raw json.RawMessage, tags map[string]string, allowIncomplete bool) (*Line, error) {
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil {
		return nil, fmt.Errorf("invalid outbound")
	}
	get := func(key string) string { var result string; _ = json.Unmarshal(fields[key], &result); return result }
	integer := func(key string) int { var result int; _ = json.Unmarshal(fields[key], &result); return result }
	boolean := func(key string) bool { var result bool; _ = json.Unmarshal(fields[key], &result); return result }
	line := &Line{ID: tags[get("tag")], Name: get("tag"), Type: LineType(get("type")), Enabled: true, TFO: boolean("tcp_fast_open")}
	// Interface binding and detours need an explicit resource dependency model;
	// accepting them here would bypass the platform's Underlay/Line boundary.
	if fields["detour"] != nil || fields["bind_interface"] != nil || fields["domain_resolver"] != nil {
		return nil, fmt.Errorf("outbound detour/interface/resolver overrides are not yet supported for import")
	}
	var tls map[string]json.RawMessage
	_ = json.Unmarshal(fields["tls"], &tls)
	var sni string
	_ = json.Unmarshal(tls["server_name"], &sni)
	_ = json.Unmarshal(tls["insecure"], &line.AllowInsecure)
	switch line.Type {
	case LineTypeDirect:
		if err := allowDocumentKeys(fields, "type", "tag"); err != nil {
			return nil, err
		}
	case LineTypeSelector, LineTypeURLTest:
		if err := allowDocumentKeys(fields, "type", "tag", "outbounds", "default", "url", "interval"); err != nil {
			return nil, err
		}
		var members []string
		if json.Unmarshal(fields["outbounds"], &members) != nil {
			return nil, fmt.Errorf("invalid group members")
		}
		for _, member := range members {
			id := tags[member]
			if id == "" {
				return nil, fmt.Errorf("unknown group member")
			}
			line.GroupMembers = append(line.GroupMembers, id)
		}
		if selected := get("default"); selected != "" {
			line.GroupDefault = tags[selected]
			if line.GroupDefault == "" {
				return nil, fmt.Errorf("unknown group default")
			}
		}
		line.GroupURL = get("url")
		line.GroupInterval = get("interval")
		return line, nil
	case LineTypeTrojan:
		line.TrojanServer = get("server")
		line.TrojanPort = integer("server_port")
		line.TrojanPassword = get("password")
		line.TrojanSNI = sni
		if string(tls["enabled"]) != "true" {
			return nil, fmt.Errorf("Trojan import requires enabled TLS")
		}
	case LineTypeShadowsocks:
		line.SSServer = get("server")
		line.SSPort = integer("server_port")
		line.SSMethod = get("method")
		line.SSPass = get("password")
	case LineTypeVMess:
		line.VMessServer = get("server")
		line.VMessPort = integer("server_port")
		line.VMessUUID = get("uuid")
		line.VMessAltID = integer("alter_id")
	case LineTypeAnyTLS:
		line.AnyTLSServer = get("server")
		line.AnyTLSPort = integer("server_port")
		line.AnyTLSPassword = get("password")
		line.AnyTLSSNI = sni
		_ = json.Unmarshal(tls["alpn"], &line.AnyTLSALPN)
		if string(tls["enabled"]) != "true" {
			return nil, fmt.Errorf("AnyTLS import requires enabled TLS")
		}
	default:
		return nil, fmt.Errorf("outbound protocol %q is not supported by this build", line.Type)
	}
	if err := allowDocumentKeys(fields, "type", "tag", "server", "server_port", "password", "method", "uuid", "alter_id", "tls", "transport", "multiplex", "tcp_fast_open", "network", "security", "packet_encoding", "idle_session_check_interval", "idle_session_timeout", "min_idle_session"); err != nil {
		return nil, err
	}
	// Preserve native options not exposed by the regular form. Generated editable
	// fields overlay this immutable copy, so form edits and advanced fields coexist.
	for _, key := range []string{"type", "tag", "server", "server_port", "password", "method", "uuid", "alter_id", "tcp_fast_open"} {
		delete(fields, key)
	}
	if line.Type == LineTypeTrojan || line.Type == LineTypeAnyTLS {
		if line.Type == LineTypeAnyTLS {
			delete(tls, "alpn")
		}
		delete(tls, "enabled")
		delete(tls, "server_name")
		delete(tls, "insecure")
		fields["tls"], _ = json.Marshal(tls)
	}
	line.NativeOptions, _ = json.Marshal(fields)
	if !allowIncomplete && !lineHasUsableOutbound(line) {
		return nil, fmt.Errorf("invalid %s outbound credentials or options", line.Type)
	}
	return line, nil
}

// Documents may contain unfinished forms or redacted credentials. Reference
// validation is separate from runtime preparation, which still fails closed.
func validateDocumentProfile(profile *Profile) error {
	if len(profile.Lines) == 0 || len(profile.Scenarios) == 0 {
		return fmt.Errorf("configuration requires a Line and Scenario")
	}
	if len(profile.Subscriptions) != 0 {
		return fmt.Errorf("nested subscriptions are not supported in a Profile document")
	}
	lines := map[string]bool{"direct": true}
	seen := map[string]bool{}
	for i := range profile.Lines {
		line := &profile.Lines[i]
		if line.ID == "" || seen[line.ID] {
			return fmt.Errorf("missing or duplicate line identity")
		}
		seen[line.ID], lines[line.ID] = true, true
		switch line.Type {
		case LineTypeDirect, LineTypeVPN, LineTypeTailscale, LineTypeTrojan, LineTypeShadowsocks, LineTypeVMess, LineTypeAnyTLS:
		case LineTypeSelector, LineTypeURLTest:
			if err := validateGroupReferences(profile, line, false); err != nil {
				return err
			}
		default:
			return fmt.Errorf("unsupported line type %q", line.Type)
		}
	}
	rules := map[string]bool{}
	for _, rule := range profile.RuleSets {
		if rule.ID == "" || rules[rule.ID] {
			return fmt.Errorf("missing or duplicate rule identity")
		}
		rules[rule.ID] = true
		switch rule.Type {
		case RuleSetTypeNative:
			if err := validateNativeRule(rule.NativeRule); err != nil {
				return err
			}
		case RuleSetTypeURL:
			if rule.FetchLineID != "" && !lines[rule.FetchLineID] {
				return fmt.Errorf("rule set references a missing download line")
			}
		case RuleSetTypeManual, RuleSetTypeApplication:
		default:
			return fmt.Errorf("unsupported rule set type %q", rule.Type)
		}
	}
	seen = map[string]bool{}
	for _, scenario := range profile.Scenarios {
		if scenario.ID == "" || seen[scenario.ID] {
			return fmt.Errorf("missing or duplicate scenario identity")
		}
		seen[scenario.ID] = true
		if !lines[scenario.DefaultLineID] || scenario.DefaultSubscriptionID != "" {
			return fmt.Errorf("Scenario references an unavailable default line")
		}
		for _, binding := range scenario.Bindings {
			if !lines[binding.LineID] || !rules[binding.RuleSetID] || binding.SubscriptionID != "" {
				return fmt.Errorf("Scenario binding references a missing Line or RuleSet")
			}
		}
	}
	return nil
}

func ExportProfileDocument(profile *Profile) ([]byte, error) {
	document := ProfileDocument{XDial: documentMetadata{SchemaVersion: 1, Lines: map[string]documentObject{}, Rules: map[string]documentObject{}}}
	if len(profile.Subscriptions) > 0 {
		return nil, fmt.Errorf("legacy nested subscriptions must be migrated before export")
	}
	for _, line := range profile.Lines {
		metadata := documentObject{Name: line.Name, Disabled: !line.Enabled}
		document.XDial.Lines[line.ID] = metadata
		var outbound map[string]interface{}
		if line.Type == LineTypeDirect {
			outbound = map[string]interface{}{"type": "direct", "tag": line.ID}
		} else {
			outbound = buildProxyOutbound(&line)
		}
		if outbound == nil {
			document.XDial.AdapterLines = append(document.XDial.AdapterLines, line)
			continue
		}
		outbound["tag"] = line.ID
		if line.IsGroup() {
			outbound["outbounds"] = line.GroupMembers
			if line.GroupDefault != "" {
				outbound["default"] = line.GroupDefault
			}
		}
		raw, _ := json.Marshal(outbound)
		document.Outbounds = append(document.Outbounds, raw)
	}
	for _, rule := range profile.RuleSets {
		document.XDial.Rules[rule.ID] = documentObject{Kind: rule.Type, Domains: rule.Domains, CIDRs: rule.CIDRs, Name: rule.Name, Disabled: !rule.Enabled, Invert: rule.Invert, Applications: rule.Applications, Processes: rule.Processes}
		resource := map[string]interface{}{"tag": rule.ID}
		switch rule.Type {
		case RuleSetTypeURL:
			resource["type"] = "remote"
			resource["url"] = rule.URL
			resource["format"] = sbResolveRuleSetFormat(&rule)
			resource["download_detour"] = rule.EffectiveFetchLineID()
		case RuleSetTypeNative:
			resource["type"] = "inline"
			resource["rules"] = []json.RawMessage{rule.NativeRule}
		case RuleSetTypeManual:
			rules := []map[string]interface{}{}
			if len(rule.Domains) > 0 {
				rules = append(rules, map[string]interface{}{"domain_suffix": rule.Domains})
			}
			if len(rule.CIDRs) > 0 {
				rules = append(rules, map[string]interface{}{"ip_cidr": rule.CIDRs})
			}
			resource["type"] = "inline"
			resource["rules"] = rules
		case RuleSetTypeApplication:
			// App bundle identities belong to the XDial platform extension.
			resource["type"] = "inline"
			resource["rules"] = []map[string]interface{}{{"process_name": rule.Processes}}
		default:
			return nil, fmt.Errorf("unsupported rule set type")
		}
		raw, _ := json.Marshal(resource)
		document.Route.RuleSets = append(document.Route.RuleSets, raw)
	}
	for _, scenario := range profile.Scenarios {
		entry := documentScenario{ID: scenario.ID, Name: scenario.Name, Icon: scenario.Icon, SSIDs: scenario.MatchSSIDs, Route: documentRoute{Final: scenario.DefaultLineID}}
		for _, binding := range scenario.Bindings {
			if binding.SubscriptionID != "" {
				return nil, fmt.Errorf("nested subscription binding cannot be exported")
			}
			raw, _ := json.Marshal(map[string]interface{}{"rule_set": binding.RuleSetID, "action": "route", "outbound": binding.LineID})
			entry.Route.Rules = append(entry.Route.Rules, raw)
		}
		document.XDial.Scenarios = append(document.XDial.Scenarios, entry)
	}
	return json.MarshalIndent(document, "", "  ")
}
