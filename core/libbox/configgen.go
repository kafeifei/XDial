//go:build !windows

package libbox

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"github.com/kafeifei/xdial/core/config"
	"github.com/kafeifei/xdial/core/subscription"
)

const maxNEConfigBytes = 2 * 1024 * 1024
const maxNERuleSetBytes int64 = 1 * 1024 * 1024

type neRuleSetFetcher func(string, int64) ([]byte, error)

// GenerateNEConfig 供 Swift App 侧调用:把当前 Profile(JSON,字段与 core/config.Profile
// 兼容 —— 即 macOS 版 AppState.buildProfileJSON() 同款格式)转换成 NE 模式的 sing-box
// 配置 JSON,产出结果直接传给 Libbox.Start 的 configJSON 参数。
//
// App 侧调用时机:TunnelManager 在把隧道交给系统拉起之前,用当前 AppState.profile
// 序列化出 profileJSON,连同 AnyConnect 凭据一起写进 App Group 共享存储,供
// PacketTunnelProvider.startTunnel 读取。
//
// vpnServerIP 是 AnyConnect 服务端地址,只在生成器的路由排除逻辑里使用(macOS 场景才
// 有意义);NE 模式下没有系统级路由排除概念,传空字符串即可。
// basePath 是 App Group 共享容器的绝对路径(FileManager
// .containerURL(forSecurityApplicationGroupIdentifier:) 拿到的路径),用于拼
// cache_file 的绝对路径,必须是扩展进程可写的目录。
func GenerateNEConfig(profileJSON string, vpnServerIP string, basePath string) (string, error) {
	return generateNEConfig(profileJSON, vpnServerIP, basePath, config.PlatformNE)
}

func generateNEConfig(profileJSON string, vpnServerIP string, basePath string, platform config.Platform) (string, error) {
	profile, err := config.ParseProfile([]byte(profileJSON))
	if err != nil {
		return "", err
	}
	ruleDir, err := prepareNERuleSetDirectory(basePath)
	if err != nil {
		return "", err
	}
	if err := materializeNERuleSets(profile, basePath, subscription.FetchStrictBytes); err != nil {
		return "", err
	}
	// socksPort 在 NE 模式下不生效(vpn 出口固定用自研 type:"vpn",见
	// generator.go 里的 NetworkExtension 分支),这里固定传 0。
	data, err := config.GenerateSingBoxFor(profile, 0, vpnServerIP, platform, basePath)
	if err != nil {
		return "", err
	}
	data, err = materializeGeneratedNERuleSets(data, ruleDir, subscription.FetchStrictBytes)
	if err != nil {
		return "", err
	}
	if len(data) > maxNEConfigBytes {
		return "", fmt.Errorf("generated NetworkExtension config exceeds %d-byte limit", maxNEConfigBytes)
	}
	return string(data), nil
}

// GenerateTailscaleSetupConfig 生成主 App 登录和发现节点所需的最小配置。
// 它只启动指定 Tailscale endpoint，不创建 TUN，也不启用该线路的出口节点或路由。
func GenerateTailscaleSetupConfig(profileJSON string, lineID string, basePath string) (string, error) {
	profile, err := config.ParseProfile([]byte(profileJSON))
	if err != nil {
		return "", err
	}
	lineID = strings.TrimSpace(lineID)
	if lineID == "" {
		return "", fmt.Errorf("Tailscale line is missing")
	}
	line := profile.FindLine(lineID)
	if line == nil {
		return "", fmt.Errorf("Tailscale line is missing")
	}
	if line.Type != config.LineTypeTailscale {
		return "", fmt.Errorf("line is not a Tailscale line")
	}
	if basePath == "" || !filepath.IsAbs(basePath) {
		return "", fmt.Errorf("shared Tailscale state directory is unavailable")
	}
	setupLine := *line
	setupLine.Enabled = true

	endpoint := map[string]interface{}{
		"type":            "tailscale",
		"tag":             "tailscale-" + setupLine.ID,
		"state_directory": config.TailscaleStateDirectory(basePath),
		// 与 buildTailscaleEndpoint 保持同一身份语义：state 全局单份、
		// 设备名来自全局身份、常驻节点（ephemeral 会在会话切换时丢身份）。
	}
	if profile.Tailscale.Hostname != "" {
		endpoint["hostname"] = profile.Tailscale.Hostname
	}
	document := map[string]interface{}{
		"log": map[string]interface{}{
			"disabled": true,
		},
		"dns": map[string]interface{}{
			"servers": []map[string]interface{}{{
				"type":        "udp",
				"tag":         "xdial-public-dns",
				"server":      "1.1.1.1",
				"server_port": 53,
			}},
			"final": "xdial-public-dns",
		},
		"endpoints": []map[string]interface{}{endpoint},
		"inbounds":  []interface{}{},
		"outbounds": []map[string]interface{}{{
			"type": "direct",
			"tag":  "direct",
		}},
		"route": map[string]interface{}{
			"final":                   "direct",
			"default_domain_resolver": "xdial-public-dns",
		},
	}
	data, err := json.Marshal(document)
	if err != nil {
		return "", fmt.Errorf("encode Tailscale setup config: %w", err)
	}
	return string(data), nil
}

func prepareNERuleSetDirectory(basePath string) (string, error) {
	if basePath == "" || !filepath.IsAbs(basePath) {
		return "", fmt.Errorf("shared rule-set directory is unavailable")
	}
	ruleDir := filepath.Join(basePath, "xdial-rule-sets")
	// 每次生成从空目录开始，避免上一次配置遗留的文件或链接参与本次启动。
	if err := os.RemoveAll(ruleDir); err != nil {
		return "", fmt.Errorf("prepare local rule-set directory: %w", err)
	}
	if err := os.MkdirAll(ruleDir, 0o700); err != nil {
		return "", fmt.Errorf("prepare local rule-set directory: %w", err)
	}
	return ruleDir, nil
}

// materializeNERuleSets 在系统路由切入扩展前，由 App 进程严格下载活动模式引用的
// 远程规则并写入 App Group。扩展只读本地文件，不再让 sing-box 自行跟随未校验的
// URL/重定向，从而封住 localhost、内网地址和 DNS rebinding 通道。
func materializeNERuleSets(profile *config.Profile, basePath string, fetch neRuleSetFetcher) error {
	mode := profile.ActiveMode()
	if mode == nil {
		return fmt.Errorf("no active mode")
	}

	var rules []*config.RuleSet
	seen := make(map[string]bool)
	for _, binding := range mode.Bindings {
		rule := profile.FindRuleSet(binding.RuleSetID)
		if rule == nil || !rule.Enabled || rule.Type != config.RuleSetTypeURL || seen[rule.ID] {
			continue
		}
		seen[rule.ID] = true
		rules = append(rules, rule)
	}
	if len(rules) == 0 {
		return nil
	}
	if basePath == "" || !filepath.IsAbs(basePath) {
		return fmt.Errorf("shared rule-set directory is unavailable")
	}

	ruleDir := filepath.Join(basePath, "xdial-rule-sets")
	if err := os.MkdirAll(ruleDir, 0o700); err != nil {
		return fmt.Errorf("prepare local rule-set directory: %w", err)
	}

	remaining := maxNERuleSetBytes
	for _, rule := range rules {
		if strings.TrimSpace(rule.URL) == "" {
			return fmt.Errorf("remote rule set is missing an address")
		}
		content, err := fetch(rule.URL, remaining)
		if err != nil {
			return fmt.Errorf("remote rule set could not be prepared")
		}
		if len(content) == 0 || int64(len(content)) > remaining {
			return fmt.Errorf("remote rule sets exceed the total size limit")
		}
		remaining -= int64(len(content))

		format := neRuleSetFormat(rule)
		if format == "text" {
			content, err = convertTextRuleSet(content)
			if err != nil {
				return fmt.Errorf("remote text rule set is invalid")
			}
			format = "source"
		}
		if format == "source" && !json.Valid(content) {
			return fmt.Errorf("remote rule set contains invalid JSON")
		}
		digest := sha256.Sum256([]byte(rule.ID))
		extension := ".srs"
		if format == "source" {
			extension = ".json"
		}
		filename := hex.EncodeToString(digest[:12]) + extension
		localPath := filepath.Join(ruleDir, filename)
		if err := os.WriteFile(localPath, content, 0o600); err != nil {
			return fmt.Errorf("store local rule set: %w", err)
		}
		rule.URL = "file://" + localPath
		rule.Format = format
	}
	return nil
}

// materializeGeneratedNERuleSets catches remote resources introduced during generation
// (currently Clash GEOIP compatibility). They are fetched by the App process through the
// same strict transport and rewritten to local files before the extension ever sees config.
func materializeGeneratedNERuleSets(data []byte, ruleDir string, fetch neRuleSetFetcher) ([]byte, error) {
	var document map[string]interface{}
	if err := json.Unmarshal(data, &document); err != nil {
		return nil, fmt.Errorf("generated configuration is invalid")
	}
	route, _ := document["route"].(map[string]interface{})
	rawSets, _ := route["rule_set"].([]interface{})
	if len(rawSets) == 0 {
		return data, nil
	}

	remaining := maxNERuleSetBytes
	entries, err := os.ReadDir(ruleDir)
	if err != nil {
		return nil, fmt.Errorf("read local rule-set directory: %w", err)
	}
	for _, entry := range entries {
		if entry.Type().IsRegular() {
			info, statErr := entry.Info()
			if statErr != nil {
				return nil, fmt.Errorf("read local rule-set: %w", statErr)
			}
			remaining -= info.Size()
		}
	}
	if remaining < 0 {
		return nil, fmt.Errorf("remote rule sets exceed the total size limit")
	}

	changed := false
	for _, rawSet := range rawSets {
		set, _ := rawSet.(map[string]interface{})
		if set == nil || set["type"] != "remote" {
			continue
		}
		rawURL, _ := set["url"].(string)
		tag, _ := set["tag"].(string)
		format, _ := set["format"].(string)
		if rawURL == "" || tag == "" || (format != "source" && format != "binary") {
			return nil, fmt.Errorf("generated remote rule set is invalid")
		}
		content, fetchErr := fetch(rawURL, remaining)
		if fetchErr != nil {
			return nil, fmt.Errorf("remote rule set could not be prepared")
		}
		if len(content) == 0 || int64(len(content)) > remaining {
			return nil, fmt.Errorf("remote rule sets exceed the total size limit")
		}
		if format == "source" && !json.Valid(content) {
			return nil, fmt.Errorf("remote rule set contains invalid JSON")
		}
		remaining -= int64(len(content))

		digest := sha256.Sum256([]byte("generated:" + tag))
		extension := ".srs"
		if format == "source" {
			extension = ".json"
		}
		localPath := filepath.Join(ruleDir, hex.EncodeToString(digest[:12])+extension)
		if err := os.WriteFile(localPath, content, 0o600); err != nil {
			return nil, fmt.Errorf("store local rule set: %w", err)
		}
		if err := os.Chmod(localPath, 0o600); err != nil {
			return nil, fmt.Errorf("secure local rule set: %w", err)
		}
		set["type"] = "local"
		set["path"] = localPath
		delete(set, "url")
		delete(set, "download_detour")
		changed = true
	}
	if !changed {
		return data, nil
	}
	return json.MarshalIndent(document, "", "  ")
}

func neRuleSetFormat(rule *config.RuleSet) string {
	switch strings.ToLower(rule.Format) {
	case "text":
		return "text"
	case "json", "source":
		return "source"
	case "srs", "binary":
		return "binary"
	}
	parsed, err := url.Parse(rule.URL)
	if err == nil && strings.EqualFold(filepath.Ext(parsed.Path), ".json") {
		return "source"
	}
	return "binary"
}

// convertTextRuleSet converts the plain domain/CIDR lists exposed by the desktop
// editor into a native sing-box source rule-set. Unsupported syntax fails closed:
// silently dropping an exclusion or policy token would change routing semantics.
func convertTextRuleSet(content []byte) ([]byte, error) {
	type sourceRule struct {
		Domain       []string `json:"domain,omitempty"`
		DomainSuffix []string `json:"domain_suffix,omitempty"`
		IPCIDR       []string `json:"ip_cidr,omitempty"`
	}
	type sourceRuleSet struct {
		Version int          `json:"version"`
		Rules   []sourceRule `json:"rules"`
	}

	var exactDomains []string
	var domainSuffixes []string
	var cidrs []string
	exactSeen := make(map[string]struct{})
	suffixSeen := make(map[string]struct{})
	cidrSeen := make(map[string]struct{})

	appendUnique := func(target *[]string, seen map[string]struct{}, value string) {
		if _, exists := seen[value]; exists {
			return
		}
		seen[value] = struct{}{}
		*target = append(*target, value)
	}
	appendDomain := func(target *[]string, seen map[string]struct{}, raw string) error {
		domain, ok := normalizeRuleDomain(raw)
		if !ok {
			return fmt.Errorf("invalid domain")
		}
		appendUnique(target, seen, domain)
		return nil
	}
	appendCIDR := func(raw string) error {
		if prefix, err := netip.ParsePrefix(raw); err == nil {
			appendUnique(&cidrs, cidrSeen, prefix.Masked().String())
			return nil
		}
		if address, err := netip.ParseAddr(raw); err == nil {
			bits := 128
			if address.Is4() {
				bits = 32
			}
			appendUnique(&cidrs, cidrSeen, netip.PrefixFrom(address, bits).String())
			return nil
		}
		return fmt.Errorf("invalid network")
	}

	for lineIndex, rawLine := range strings.Split(string(content), "\n") {
		line := strings.TrimSpace(strings.TrimSuffix(rawLine, "\r"))
		if lineIndex == 0 {
			line = strings.TrimPrefix(line, "\uFEFF")
		}
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, "!") || strings.HasPrefix(line, ";") {
			continue
		}
		if strings.HasPrefix(line, "@@") {
			return nil, fmt.Errorf("exclusion rules are unsupported")
		}

		if parts := strings.Split(line, ","); len(parts) > 1 {
			kind := strings.ToUpper(strings.TrimSpace(parts[0]))
			value := strings.TrimSpace(parts[1])
			switch kind {
			case "DOMAIN":
				if len(parts) != 2 || appendDomain(&exactDomains, exactSeen, value) != nil {
					return nil, fmt.Errorf("invalid domain rule")
				}
			case "DOMAIN-SUFFIX":
				if len(parts) != 2 || appendDomain(&domainSuffixes, suffixSeen, value) != nil {
					return nil, fmt.Errorf("invalid domain suffix rule")
				}
			case "IP-CIDR", "IP-CIDR6":
				if len(parts) != 2 || appendCIDR(value) != nil {
					return nil, fmt.Errorf("invalid network rule")
				}
			default:
				return nil, fmt.Errorf("unsupported policy rule")
			}
			continue
		}

		fields := strings.Fields(line)
		if len(fields) == 2 {
			if _, err := netip.ParseAddr(fields[0]); err == nil {
				if appendDomain(&exactDomains, exactSeen, fields[1]) != nil {
					return nil, fmt.Errorf("invalid hosts entry")
				}
				continue
			}
			return nil, fmt.Errorf("unsupported text rule")
		}
		if len(fields) != 1 {
			return nil, fmt.Errorf("unsupported text rule")
		}

		if appendCIDR(line) == nil {
			continue
		}
		if strings.HasPrefix(line, "||") && strings.HasSuffix(line, "^") {
			line = strings.TrimSuffix(strings.TrimPrefix(line, "||"), "^")
		}
		line = strings.TrimPrefix(strings.TrimPrefix(line, "*."), ".")
		if appendDomain(&domainSuffixes, suffixSeen, line) != nil {
			return nil, fmt.Errorf("invalid plain rule")
		}
	}

	if len(exactDomains) == 0 && len(domainSuffixes) == 0 && len(cidrs) == 0 {
		return nil, fmt.Errorf("empty rule set")
	}
	return json.Marshal(sourceRuleSet{
		Version: 3,
		Rules: []sourceRule{{
			Domain:       exactDomains,
			DomainSuffix: domainSuffixes,
			IPCIDR:       cidrs,
		}},
	})
}

func normalizeRuleDomain(raw string) (string, bool) {
	domain := strings.ToLower(strings.TrimSuffix(strings.TrimSpace(raw), "."))
	if domain == "" || len(domain) > 253 || strings.ContainsAny(domain, "/:@[]") {
		return "", false
	}
	for _, label := range strings.Split(domain, ".") {
		if label == "" || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return "", false
		}
		for _, char := range label {
			if (char >= 'a' && char <= 'z') || (char >= '0' && char <= '9') || char == '-' || char == '_' {
				continue
			}
			return "", false
		}
	}
	return domain, true
}
