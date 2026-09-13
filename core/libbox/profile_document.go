//go:build !windows

package libbox

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/sagernet/sing-box/option"
	sbjson "github.com/sagernet/sing/common/json"
	"strings"

	"github.com/kafeifei/xdial/core/config"
	"github.com/kafeifei/xdial/core/subscription"
)

// ImportProfile has no system ingress or connection side effects. Downloads of
// referenced rule sources occur only in this explicitly requested import.
func ImportProfile(content, format, namespace string, nodesOnly bool) (string, error) {
	var root map[string]json.RawMessage
	var profile *config.Profile
	var err error
	if json.Unmarshal([]byte(content), &root) == nil && (root["outbounds"] != nil || root["lines"] != nil || root["xdial"] != nil) {
		if nodesOnly {
			delete(root, "route")
			delete(root, "xdial")
			delete(root, "dns")
			delete(root, "experimental")
			delete(root, "inbounds")
			delete(root, "endpoints")
			var outbounds []map[string]interface{}
			if json.Unmarshal(root["outbounds"], &outbounds) != nil {
				return "", fmt.Errorf("lines-only import requires native outbounds")
			}
			var retained []map[string]interface{}
			var tags []string
			for _, outbound := range outbounds {
				if outbound["type"] == "selector" || outbound["type"] == "urltest" {
					continue
				}
				retained = append(retained, outbound)
				if tag, ok := outbound["tag"].(string); ok {
					tags = append(tags, tag)
				}
			}
			if len(tags) == 0 {
				return "", fmt.Errorf("no lines to import")
			}
			groupTag := "xdial-imported-lines"
			for _, tag := range tags {
				if tag == groupTag {
					return "", fmt.Errorf("reserved import group tag is already used")
				}
			}
			retained = append(retained, map[string]interface{}{"type": "selector", "tag": groupTag, "outbounds": tags})
			root["outbounds"], _ = json.Marshal(retained)
			root["route"], _ = json.Marshal(map[string]interface{}{"final": groupTag})
			encoded, _ := json.Marshal(root)
			content = string(encoded)
		}
		profile, err = config.ImportProfileDocument([]byte(content), namespace)
	} else {
		var parsed *subscription.ParseResult
		parsed, err = subscription.ParseStrict("", content, format)
		if err == nil && !nodesOnly {
			err = subscription.ExpandRulesetsStrict(parsed)
		}
		if err == nil {
			profile, err = config.ImportSubscriptionProfile(namespace, parsed.Lines, parsed.ProxyGroups, parsed.Rules, nodesOnly)
		}
	}
	if err != nil {
		return "", err
	}
	if err := validateProfileNativeOptions(profile); err != nil {
		return "", err
	}
	encoded, err := json.Marshal(profile)
	return string(encoded), err
}

func ExportProfile(profileJSON string) (string, error) {
	profile, err := config.ParseProfile([]byte(profileJSON))
	if err != nil {
		return "", fmt.Errorf("invalid Profile")
	}
	data, err := config.ExportProfileDocument(profile)
	if err != nil {
		return "", err
	}
	var value interface{}
	if err := json.Unmarshal(data, &value); err != nil {
		return "", err
	}
	redactDocumentSecrets(value)
	value.(map[string]interface{})["xdial"].(map[string]interface{})["requires_input"] = true
	data, err = json.MarshalIndent(value, "", "  ")
	return string(data), err
}

func redactDocumentSecrets(value interface{}) {
	switch value := value.(type) {
	case map[string]interface{}:
		for key, child := range value {
			lower := strings.ToLower(key)
			if strings.Contains(lower, "password") || strings.Contains(lower, "private_key") || strings.Contains(lower, "auth_key") || strings.Contains(lower, "token") || lower == "key" || lower == "key_path" || lower == "certificate" || lower == "certificate_path" || lower == "headers" || lower == "username" || lower == "uuid" || lower == "vmess_uuid" {
				switch child.(type) {
				case map[string]interface{}:
					value[key] = map[string]interface{}{}
				case []interface{}:
					value[key] = []interface{}{}
				default:
					value[key] = ""
				}
				continue
			}
			// Source URLs can carry credentials in path, query or user info.
			if lower == "url" || strings.HasSuffix(lower, "_url") {
				switch child.(type) {
				case map[string]interface{}:
					value[key] = map[string]interface{}{}
				case []interface{}:
					value[key] = []interface{}{}
				default:
					value[key] = ""
				}
				continue
			}
			redactDocumentSecrets(child)
		}
	case []interface{}:
		for _, child := range value {
			redactDocumentSecrets(child)
		}
	}
}

func ValidateProfileDocument(profileJSON string) error {
	profile, err := config.ParseProfile([]byte(profileJSON))
	if err != nil {
		return fmt.Errorf("invalid Profile")
	}
	if err := config.ValidateDocumentProfile(profile); err != nil {
		return err
	}
	return validateProfileNativeOptions(profile)
}

func ProfileStoragePath(profileJSON, basePath string) (string, error) {
	profile, err := config.ParseProfile([]byte(profileJSON))
	if err != nil {
		return "", fmt.Errorf("invalid Profile")
	}
	return config.ProfileDataPath(profile, basePath)
}

func CloneProfile(profileJSON, namespace string) (string, error) {
	profile, err := config.ParseProfile([]byte(profileJSON))
	if err != nil {
		return "", fmt.Errorf("invalid Profile")
	}
	result := config.CloneProfile(profile, namespace)
	encoded, err := json.Marshal(result)
	return string(encoded), err
}

func validateProfileNativeOptions(profile *config.Profile) error {
	ctx := boxContext(context.Background())
	for _, line := range profile.Lines {
		if err := config.ValidateNativeLineOptions(&line); err != nil {
			return err
		}
		outbound := config.LineOutbound(&line)
		if outbound == nil {
			continue
		} // Draft credentials are checked before connection.
		data, err := json.Marshal(outbound)
		if err != nil {
			return fmt.Errorf("invalid native outbound")
		}
		if _, err := sbjson.UnmarshalExtendedContext[option.Outbound](ctx, data); err != nil {
			return fmt.Errorf("unsupported or invalid native options for %s: %w", line.Type, err)
		}
	}
	return nil
}
