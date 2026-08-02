//go:build !windows

package libbox

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"time"

	"github.com/kafeifei/xdial/core/config"
	"github.com/kafeifei/xdial/core/subscription"
	"github.com/sagernet/sing-box/common/srs"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
)

const maxNEConfigBytes = 2 * 1024 * 1024
const maxNERuleSetBytes int64 = 1 * 1024 * 1024
const neRuleSetCacheFreshFor = 24 * time.Hour

type neRuleSetFetcher func(string, int64) ([]byte, error)

// ConnectionPreparationCallback is the gomobile-safe structured progress
// channel used while Go prepares active RuleSets. Events contain stable task IDs
// from ConnectionPlan and never contain URLs, credentials, or rule contents.
type ConnectionPreparationCallback interface {
	OnPreparationEvent(eventJSON string)
}

type connectionPreparationEvent struct {
	TaskID  string `json:"task_id"`
	State   string `json:"state"`
	Code    string `json:"code,omitempty"`
	Message string `json:"message,omitempty"`
}

type connectionPreparationSink func(connectionPreparationEvent)

type transparentProxySession struct {
	ConfigJSON string                 `json:"config_json"`
	Plan       *config.ConnectionPlan `json:"plan"`
	// ApplicationCredentials is the active Mode's authenticated app identity →
	// derived SOCKS username map. It is session-only and lets the Provider pick
	// the matching native SOCKS user without reproducing Go's derivation.
	ApplicationCredentials map[string]string `json:"application_credentials,omitempty"`
	// LineOutbounds is a capability map for this exact active ConnectionPlan.
	// It contains no endpoint or credential material and intentionally excludes
	// enabled Lines that the active Mode did not reference.
	LineOutbounds map[string]string `json:"line_outbounds"`
	// SubscriptionOutbounds carries the exact route-visible outbound tags
	// returned by the same generator catalog that built this session's data
	// plane. It is restricted to subscription tasks in this exact
	// ConnectionPlan.
	SubscriptionOutbounds map[string][]string         `json:"subscription_outbounds"`
	RuleSetTags           []string                    `json:"rule_set_tags"`
	AnyConnect            *transparentProxyAnyConnect `json:"anyconnect,omitempty"`
	Tailscale             *transparentProxyTailscale  `json:"tailscale,omitempty"`
}

type transparentProxyAnyConnect struct {
	Server        string `json:"server"`
	Username      string `json:"username"`
	Password      string `json:"password"`
	AllowInsecure bool   `json:"allow_insecure"`
}

type transparentProxyTailscale struct {
	EndpointTag     string `json:"endpoint_tag"`
	ExitNode        string `json:"exit_node"`
	MagicDNSEnabled bool   `json:"magic_dns_enabled"`
	DNSServerTag    string `json:"dns_server_tag,omitempty"`
}

// GenerateConnectionPlan compiles the active Mode into a side-effect-free,
// credential-free connection checklist. The host calls it before starting the
// Network Extension so planning failures cannot leave session resources behind.
func GenerateConnectionPlan(profileJSON string) (string, error) {
	profile, err := config.ParseProfile([]byte(profileJSON))
	if err != nil {
		return "", err
	}
	plan, err := config.BuildConnectionPlan(profile)
	if err != nil {
		return "", err
	}
	encoded, err := json.Marshal(plan)
	if err != nil {
		return "", fmt.Errorf("encode connection plan: %w", err)
	}
	return string(encoded), nil
}

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

// GenerateTransparentProxySession 供 macOS Transparent Proxy 扩展调用。
// 返回值只存在于本次 NE start options / 扩展内存中；其中的 AnyConnect 凭据不得写入
// NETunnelProviderProtocol.providerConfiguration、日志或诊断接口。
func GenerateTransparentProxySession(
	profileJSON string,
	basePath string,
	listenPort int,
	socksUsername string,
	socksPassword string,
	underlayInterface string,
	systemDNSJSON string,
) (string, error) {
	return generateTransparentProxySession(
		profileJSON,
		basePath,
		listenPort,
		socksUsername,
		socksPassword,
		underlayInterface,
		systemDNSJSON,
		nil,
	)
}

// GenerateTransparentProxySessionWithCallback is identical to
// GenerateTransparentProxySession, but reports exact RuleSet preparation
// transitions to the Network Extension transaction journal.
func GenerateTransparentProxySessionWithCallback(
	profileJSON string,
	basePath string,
	listenPort int,
	socksUsername string,
	socksPassword string,
	underlayInterface string,
	systemDNSJSON string,
	callback ConnectionPreparationCallback,
) (string, error) {
	var sink connectionPreparationSink
	if callback != nil {
		sink = func(event connectionPreparationEvent) {
			encoded, err := json.Marshal(event)
			if err == nil {
				callback.OnPreparationEvent(string(encoded))
			}
		}
	}
	return generateTransparentProxySession(
		profileJSON,
		basePath,
		listenPort,
		socksUsername,
		socksPassword,
		underlayInterface,
		systemDNSJSON,
		sink,
	)
}

func generateTransparentProxySession(
	profileJSON string,
	basePath string,
	listenPort int,
	socksUsername string,
	socksPassword string,
	underlayInterface string,
	systemDNSJSON string,
	progress connectionPreparationSink,
) (string, error) {
	profile, err := config.ParseProfile([]byte(profileJSON))
	if err != nil {
		return "", err
	}
	plan, err := config.BuildConnectionPlan(profile)
	if err != nil {
		return "", err
	}
	ruleDir, err := prepareNERuleSetDirectory(basePath)
	if err != nil {
		return "", err
	}
	if err := materializeNERuleSetsWithEvents(
		profile,
		basePath,
		subscription.FetchStrictBytes,
		progress,
	); err != nil {
		return "", err
	}
	var systemDNS []string
	if err := json.Unmarshal([]byte(systemDNSJSON), &systemDNS); err != nil {
		return "", fmt.Errorf("decode system DNS snapshot: %w", err)
	}
	data, err := config.GenerateSingBoxTransparentProxy(
		profile,
		listenPort,
		socksUsername,
		socksPassword,
		basePath,
		underlayInterface,
		systemDNS,
	)
	if err != nil {
		return "", err
	}
	data, err = materializeGeneratedNERuleSetsWithEvents(
		data,
		ruleDir,
		subscription.FetchStrictBytes,
		progress,
	)
	if err != nil {
		return "", err
	}
	if len(data) > maxNEConfigBytes {
		return "", fmt.Errorf("generated NetworkExtension config exceeds %d-byte limit", maxNEConfigBytes)
	}
	applicationCredentials, err := config.ActiveApplicationSOCKSCredentials(profile, socksUsername)
	if err != nil {
		return "", err
	}

	session := transparentProxySession{
		ConfigJSON:             string(data),
		Plan:                   plan,
		ApplicationCredentials: applicationCredentials,
	}
	session.LineOutbounds, err = activeLineOutbounds(profile, plan)
	if err != nil {
		return "", err
	}
	session.SubscriptionOutbounds, err = activeSubscriptionOutbounds(profile, plan)
	if err != nil {
		return "", err
	}
	session.RuleSetTags, err = activeRouteRuleSetTags(data)
	if err != nil {
		return "", err
	}
	if line := profile.ActiveVPNLine(); line != nil {
		if strings.TrimSpace(line.VPNServer) == "" {
			return "", fmt.Errorf("AnyConnect server is missing")
		}
		if strings.TrimSpace(line.VPNUsername) == "" || line.VPNPassword == "" {
			return "", fmt.Errorf("AnyConnect credentials are missing")
		}
		session.AnyConnect = &transparentProxyAnyConnect{
			Server:        line.VPNServer,
			Username:      line.VPNUsername,
			Password:      line.VPNPassword,
			AllowInsecure: line.AllowInsecure,
		}
	}
	tailscaleLine, err := config.ActiveTailscaleLine(profile)
	if err != nil {
		return "", err
	}
	if tailscaleLine != nil {
		exitNode := strings.TrimSpace(tailscaleLine.TailscaleExitNode)
		if exitNode == "" {
			return "", fmt.Errorf("Tailscale exit node is missing")
		}
		var endpointTag string
		for _, member := range config.BuildLineRuntimeCatalog(profile).Lines {
			if member.ID == tailscaleLine.ID {
				endpointTag = member.Tag
				break
			}
		}
		if endpointTag == "" {
			return "", fmt.Errorf("Tailscale runtime endpoint is missing")
		}
		dnsServerTag := ""
		if tailscaleLine.TailscaleMagicDNS {
			dnsServerTag = config.TailscaleMagicDNSDNSServerTag(endpointTag)
		}
		session.Tailscale = &transparentProxyTailscale{
			EndpointTag:     endpointTag,
			ExitNode:        exitNode,
			MagicDNSEnabled: tailscaleLine.TailscaleMagicDNS,
			DNSServerTag:    dnsServerTag,
		}
	}
	encoded, err := json.Marshal(session)
	if err != nil {
		return "", fmt.Errorf("encode Transparent Proxy session: %w", err)
	}
	return string(encoded), nil
}

func activeLineOutbounds(
	profile *config.Profile,
	plan *config.ConnectionPlan,
) (map[string]string, error) {
	runtimeTags := make(map[string]string)
	for _, member := range config.BuildLineRuntimeCatalog(profile).Lines {
		runtimeTags[member.ID] = member.Tag
	}

	active := make(map[string]string)
	for _, task := range plan.Tasks {
		if task.Kind != config.ConnectionTaskLine {
			continue
		}
		lineID := strings.TrimSpace(task.ResourceID)
		if lineID == "" {
			return nil, fmt.Errorf("active Line capability is missing an ID")
		}
		tag := runtimeTags[lineID]
		if task.ResourceType == string(config.LineTypeDirect) {
			// BuildConnectionPlan may synthesize the built-in Direct Line when
			// the Profile omits it, so it is not necessarily in the full catalog.
			tag = "direct"
		}
		if tag == "" {
			return nil, fmt.Errorf("active Line %q has no runtime outbound", lineID)
		}
		if existing, loaded := active[lineID]; loaded && existing != tag {
			return nil, fmt.Errorf("active Line %q has conflicting runtime outbounds", lineID)
		}
		active[lineID] = tag
	}
	return active, nil
}

func activeSubscriptionOutbounds(
	profile *config.Profile,
	plan *config.ConnectionPlan,
) (map[string][]string, error) {
	if profile == nil {
		return nil, fmt.Errorf("active Subscription capability profile is missing")
	}
	if plan == nil {
		return nil, fmt.Errorf("active Subscription capability plan is missing")
	}

	runtimeTags := make(map[string][]string)
	conflictingRuntimeTags := make(map[string]bool)
	for _, subscription := range config.BuildSubscriptionRuntimeCatalog(
		profile,
		config.PlatformTransparentProxy,
	).Subscriptions {
		subscriptionID := strings.TrimSpace(subscription.ID)
		if subscriptionID == "" {
			continue
		}
		tags := append([]string(nil), subscription.ReadinessTags...)
		if existing, loaded := runtimeTags[subscriptionID]; loaded &&
			!reflect.DeepEqual(existing, tags) {
			conflictingRuntimeTags[subscriptionID] = true
			continue
		}
		runtimeTags[subscriptionID] = tags
	}

	active := make(map[string][]string)
	for _, task := range plan.Tasks {
		if task.Kind != config.ConnectionTaskSubscription {
			continue
		}
		subscriptionID := strings.TrimSpace(task.ResourceID)
		if subscriptionID == "" {
			return nil, fmt.Errorf("active Subscription capability is missing an ID")
		}
		if conflictingRuntimeTags[subscriptionID] {
			return nil, fmt.Errorf(
				"active Subscription %q has conflicting runtime outbounds",
				subscriptionID,
			)
		}
		tags := runtimeTags[subscriptionID]
		if len(tags) == 0 {
			return nil, fmt.Errorf(
				"active Subscription %q has no runtime outbound",
				subscriptionID,
			)
		}
		if existing, loaded := active[subscriptionID]; loaded &&
			!reflect.DeepEqual(existing, tags) {
			return nil, fmt.Errorf(
				"active Subscription %q has conflicting runtime outbounds",
				subscriptionID,
			)
		}
		active[subscriptionID] = append([]string(nil), tags...)
	}
	return active, nil
}

func activeRouteRuleSetTags(configJSON []byte) ([]string, error) {
	var document struct {
		Route struct {
			RuleSets []struct {
				Tag string `json:"tag"`
			} `json:"rule_set"`
		} `json:"route"`
	}
	if err := json.Unmarshal(configJSON, &document); err != nil {
		return nil, fmt.Errorf("decode active rule-set capabilities: %w", err)
	}
	tags := make([]string, 0, len(document.Route.RuleSets))
	seen := make(map[string]bool)
	for _, ruleSet := range document.Route.RuleSets {
		tag := strings.TrimSpace(ruleSet.Tag)
		if tag == "" || seen[tag] {
			continue
		}
		seen[tag] = true
		tags = append(tags, tag)
	}
	return tags, nil
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
	return GenerateTailscaleSetupConfigWithAuthKey(profileJSON, lineID, basePath, "")
}

// GenerateTailscaleSetupConfigWithAuthKey 只为一次显式注册请求加入瞬时 Auth Key。
// 调用方不得把 key 写回 Profile；返回配置也只能存在于限时 setup session 的内存中。
func GenerateTailscaleSetupConfigWithAuthKey(profileJSON string, lineID string, basePath string, authKey string) (string, error) {
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
	authKey = strings.TrimSpace(authKey)
	if len(authKey) > 4096 {
		return "", fmt.Errorf("Tailscale Auth Key is too long")
	}
	setupLine := *line
	setupLine.Enabled = true

	endpoint := map[string]interface{}{
		"type":             "tailscale",
		"tag":              "tailscale-" + setupLine.ID,
		"state_directory":  config.TailscaleStateDirectory(basePath),
		"system_interface": false,
		"accept_routes":    false,
		// 与 buildTailscaleEndpoint 保持同一身份语义：state 全局单份、
		// 设备名来自全局身份、常驻节点（ephemeral 会在会话切换时丢身份）。
	}
	if profile.Tailscale.Hostname != "" {
		endpoint["hostname"] = profile.Tailscale.Hostname
	}
	if authKey != "" {
		endpoint["auth_key"] = authKey
	}
	document := map[string]interface{}{
		"log": map[string]interface{}{
			"disabled": true,
		},
		"dns": map[string]interface{}{
			"servers": []map[string]interface{}{{
				"type": "local",
				"tag":  "xdial-setup-system-dns",
			}},
			"final": "xdial-setup-system-dns",
		},
		"endpoints": []map[string]interface{}{endpoint},
		"inbounds":  []interface{}{},
		"outbounds": []map[string]interface{}{{
			"type": "direct",
			"tag":  "direct",
		}},
		"route": map[string]interface{}{
			"final":                   "direct",
			"default_domain_resolver": "xdial-setup-system-dns",
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
	// 这里保存的是按“规则身份 + 原始 URL + 格式”寻址、且已经完成语义校验的
	// last-known-good 副本。不能在每次生成前清空：Underlay 变化时，当前网络可能正好
	// 无法访问远程规则源；若启动强依赖再次下载，XDial 会在接管流量前自锁。
	//
	// 旧文件不会自动参与配置。只有本次活动 Mode 明确引用、缓存键完全匹配并再次通过
	// 内容校验的文件才会被写进生成结果。
	if err := os.MkdirAll(ruleDir, 0o700); err != nil {
		return "", fmt.Errorf("prepare local rule-set directory: %w", err)
	}
	return ruleDir, nil
}

// materializeNERuleSets 在系统路由切入扩展前，由 App 进程严格下载活动模式引用的
// 远程规则并写入 App Group。扩展只读本地文件，不再让 sing-box 自行跟随未校验的
// URL/重定向，从而封住 localhost、内网地址和 DNS rebinding 通道。
func materializeNERuleSets(profile *config.Profile, basePath string, fetch neRuleSetFetcher) error {
	return materializeNERuleSetsWithEvents(profile, basePath, fetch, nil)
}

func materializeNERuleSetsWithEvents(
	profile *config.Profile,
	basePath string,
	fetch neRuleSetFetcher,
	progress connectionPreparationSink,
) error {
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
		taskID := "rule-set:" + rule.ID
		emitConnectionPreparation(
			progress,
			connectionPreparationEvent{
				TaskID: taskID,
				State:  "running",
			},
		)
		if strings.TrimSpace(rule.URL) == "" {
			emitConnectionPreparationFailure(
				progress,
				taskID,
				"rule-set-address-missing",
			)
			return fmt.Errorf("remote rule set is missing an address")
		}
		originalURL := rule.URL
		originalFormat := neRuleSetFormat(rule)
		storedFormat := originalFormat
		if storedFormat == "text" {
			storedFormat = "source"
		}
		localPath := neRuleSetCachePath(
			ruleDir,
			"profile",
			rule.ID,
			originalURL,
			originalFormat,
			storedFormat,
		)
		content, matchKind, err := loadOrFetchNERuleSet(
			localPath,
			storedFormat,
			remaining,
			func(limit int64) ([]byte, error) {
				fetched, fetchErr := fetch(originalURL, limit)
				if fetchErr != nil {
					return nil, fetchErr
				}
				if originalFormat == "text" {
					converted, convertErr := convertTextRuleSet(fetched)
					if convertErr != nil {
						return nil, fmt.Errorf("remote text rule set is invalid")
					}
					return converted, nil
				}
				return fetched, nil
			},
		)
		if err != nil {
			emitConnectionPreparationFailure(
				progress,
				taskID,
				"rule-set-unavailable",
			)
			return fmt.Errorf("rule set %q is unavailable and has no valid local copy", rule.ID)
		}
		remaining -= int64(len(content))
		rule.URL = "file://" + localPath
		rule.Format = storedFormat
		rule.RuntimeMatchKind = matchKind
		emitConnectionPreparation(
			progress,
			connectionPreparationEvent{
				TaskID: taskID,
				State:  "ready",
			},
		)
	}
	return nil
}

// loadOrFetchNERuleSet keeps connection startup cache-first. A fresh, validated copy is
// immediately reusable, so a routine reconnect or an Underlay rebuild never depends on
// the rule host being reachable in the short interval before XDial is active. Once the
// copy ages out, a successful fetch atomically replaces it; a failed refresh keeps using
// the last validated copy.
func loadOrFetchNERuleSet(
	localPath string,
	format string,
	limit int64,
	fetch func(int64) ([]byte, error),
) ([]byte, config.RuleSetMatchKind, error) {
	cached, cachedKind, cachedInfo, cachedErr := readValidatedNERuleSet(localPath, format, limit)
	if cachedErr == nil && time.Since(cachedInfo.ModTime()) <= neRuleSetCacheFreshFor {
		return cached, cachedKind, nil
	}

	content, fetchErr := fetch(limit)
	if fetchErr == nil {
		matchKind, validateErr := validateNERuleSet(content, format, limit)
		if validateErr == nil {
			if writeErr := writeNERuleSetCache(localPath, content); writeErr != nil {
				return nil, config.RuleSetMatchUnknown, writeErr
			}
			return content, matchKind, nil
		}
		fetchErr = validateErr
	}

	if cachedErr == nil {
		return cached, cachedKind, nil
	}
	return nil, config.RuleSetMatchUnknown, fetchErr
}

func readValidatedNERuleSet(
	localPath string,
	format string,
	limit int64,
) ([]byte, config.RuleSetMatchKind, os.FileInfo, error) {
	info, err := os.Stat(localPath)
	if err != nil {
		return nil, config.RuleSetMatchUnknown, nil, err
	}
	if !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > limit {
		return nil, config.RuleSetMatchUnknown, nil, fmt.Errorf("cached rule set is invalid")
	}
	content, err := os.ReadFile(localPath)
	if err != nil {
		return nil, config.RuleSetMatchUnknown, nil, err
	}
	matchKind, err := validateNERuleSet(content, format, limit)
	if err != nil {
		return nil, config.RuleSetMatchUnknown, nil, err
	}
	return content, matchKind, info, nil
}

func validateNERuleSet(
	content []byte,
	format string,
	limit int64,
) (config.RuleSetMatchKind, error) {
	if len(content) == 0 || int64(len(content)) > limit {
		return config.RuleSetMatchUnknown, fmt.Errorf("remote rule sets exceed the total size limit")
	}
	if format == "source" && !json.Valid(content) {
		return config.RuleSetMatchUnknown, fmt.Errorf("remote rule set contains invalid JSON")
	}
	matchKind, err := classifyNERuleSet(content, format)
	if err != nil {
		return config.RuleSetMatchUnknown, fmt.Errorf("remote rule set semantics are invalid")
	}
	return matchKind, nil
}

func writeNERuleSetCache(localPath string, content []byte) error {
	if err := os.MkdirAll(filepath.Dir(localPath), 0o700); err != nil {
		return fmt.Errorf("prepare local rule-set directory: %w", err)
	}
	temp, err := os.CreateTemp(filepath.Dir(localPath), ".xdial-rule-set-*")
	if err != nil {
		return fmt.Errorf("store local rule set: %w", err)
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)
	if err := temp.Chmod(0o600); err != nil {
		temp.Close()
		return fmt.Errorf("store local rule set: %w", err)
	}
	if _, err := temp.Write(content); err != nil {
		temp.Close()
		return fmt.Errorf("store local rule set: %w", err)
	}
	if err := temp.Sync(); err != nil {
		temp.Close()
		return fmt.Errorf("store local rule set: %w", err)
	}
	if err := temp.Close(); err != nil {
		return fmt.Errorf("store local rule set: %w", err)
	}
	if err := os.Rename(tempPath, localPath); err != nil {
		return fmt.Errorf("store local rule set: %w", err)
	}
	return nil
}

func neRuleSetCachePath(
	ruleDir string,
	namespace string,
	identity string,
	rawURL string,
	inputFormat string,
	storedFormat string,
) string {
	digest := sha256.Sum256([]byte(strings.Join(
		[]string{namespace, identity, rawURL, inputFormat},
		"\x00",
	)))
	extension := ".srs"
	if storedFormat == "source" {
		extension = ".json"
	}
	return filepath.Join(ruleDir, hex.EncodeToString(digest[:12])+extension)
}

func classifyNERuleSet(content []byte, format string) (config.RuleSetMatchKind, error) {
	var compat option.PlainRuleSetCompat
	var err error
	switch format {
	case "binary":
		compat, err = srs.Read(bytes.NewReader(content), true)
	case "source":
		err = json.Unmarshal(content, &compat)
	default:
		return config.RuleSetMatchUnknown, fmt.Errorf("unsupported rule set format")
	}
	if err != nil {
		return config.RuleSetMatchUnknown, err
	}
	plain, err := compat.Upgrade()
	if err != nil {
		return config.RuleSetMatchUnknown, err
	}
	hasDomain, hasIP, ambiguous := classifyHeadlessRules(plain.Rules)
	switch {
	case hasDomain && !hasIP && !ambiguous:
		return config.RuleSetMatchDomain, nil
	case hasIP && !hasDomain && !ambiguous:
		return config.RuleSetMatchIP, nil
	default:
		return config.RuleSetMatchMixed, nil
	}
}

func classifyHeadlessRules(rules []option.HeadlessRule) (hasDomain, hasIP, ambiguous bool) {
	for _, rule := range rules {
		switch rule.Type {
		case "", C.RuleTypeDefault:
			options := rule.DefaultOptions
			domain := len(options.Domain) > 0 ||
				len(options.DomainSuffix) > 0 ||
				len(options.DomainKeyword) > 0 ||
				len(options.DomainRegex) > 0 ||
				len(options.AdGuardDomain) > 0 ||
				options.DomainMatcher != nil ||
				options.AdGuardDomainMatcher != nil
			ip := len(options.IPCIDR) > 0 || options.IPSet != nil
			hasDomain = hasDomain || domain
			hasIP = hasIP || ip
			if options.Invert || hasNonDestinationRuleConditions(options) || (!domain && !ip) {
				ambiguous = true
			}
		case C.RuleTypeLogical:
			domain, ip, nestedAmbiguous := classifyHeadlessRules(rule.LogicalOptions.Rules)
			hasDomain = hasDomain || domain
			hasIP = hasIP || ip
			ambiguous = ambiguous || nestedAmbiguous || rule.LogicalOptions.Invert
		default:
			ambiguous = true
		}
	}
	if len(rules) == 0 {
		ambiguous = true
	}
	return
}

func hasNonDestinationRuleConditions(options option.DefaultHeadlessRule) bool {
	remaining := options
	remaining.Domain = nil
	remaining.DomainSuffix = nil
	remaining.DomainKeyword = nil
	remaining.DomainRegex = nil
	remaining.IPCIDR = nil
	remaining.DomainMatcher = nil
	remaining.IPSet = nil
	remaining.AdGuardDomain = nil
	remaining.AdGuardDomainMatcher = nil
	remaining.Invert = false
	return !reflect.DeepEqual(remaining, option.DefaultHeadlessRule{})
}

// materializeGeneratedNERuleSets catches remote resources introduced during generation
// (currently Clash GEOIP compatibility). They are fetched by the App process through the
// same strict transport and rewritten to local files before the extension ever sees config.
func materializeGeneratedNERuleSets(data []byte, ruleDir string, fetch neRuleSetFetcher) ([]byte, error) {
	return materializeGeneratedNERuleSetsWithEvents(
		data,
		ruleDir,
		fetch,
		nil,
	)
}

func materializeGeneratedNERuleSetsWithEvents(
	data []byte,
	ruleDir string,
	fetch neRuleSetFetcher,
	progress connectionPreparationSink,
) ([]byte, error) {
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
	countedPaths := make(map[string]bool)
	for _, rawSet := range rawSets {
		set, _ := rawSet.(map[string]interface{})
		if set == nil || set["type"] != "local" {
			continue
		}
		localPath, _ := set["path"].(string)
		if localPath == "" || countedPaths[localPath] {
			continue
		}
		relative, relativeErr := filepath.Rel(ruleDir, localPath)
		if relativeErr != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
			continue
		}
		info, statErr := os.Stat(localPath)
		if statErr != nil {
			return nil, fmt.Errorf("read local rule-set: %w", statErr)
		}
		countedPaths[localPath] = true
		remaining -= info.Size()
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
		taskID := "rule-set:generated:" + tag
		emitConnectionPreparation(
			progress,
			connectionPreparationEvent{
				TaskID: taskID,
				State:  "running",
			},
		)
		localPath := neRuleSetCachePath(
			ruleDir,
			"generated",
			tag,
			rawURL,
			format,
			format,
		)
		content, _, fetchErr := loadOrFetchNERuleSet(
			localPath,
			format,
			remaining,
			func(limit int64) ([]byte, error) {
				return fetch(rawURL, limit)
			},
		)
		if fetchErr != nil {
			emitConnectionPreparationFailure(
				progress,
				taskID,
				"generated-rule-set-unavailable",
			)
			return nil, fmt.Errorf("generated rule set %q is unavailable and has no valid local copy", tag)
		}
		remaining -= int64(len(content))
		set["type"] = "local"
		set["path"] = localPath
		delete(set, "url")
		delete(set, "download_detour")
		changed = true
		emitConnectionPreparation(
			progress,
			connectionPreparationEvent{
				TaskID: taskID,
				State:  "ready",
			},
		)
	}
	if !changed {
		return data, nil
	}
	return json.MarshalIndent(document, "", "  ")
}

func emitConnectionPreparation(
	progress connectionPreparationSink,
	event connectionPreparationEvent,
) {
	if progress != nil {
		progress(event)
	}
}

func emitConnectionPreparationFailure(
	progress connectionPreparationSink,
	taskID string,
	code string,
) {
	emitConnectionPreparation(
		progress,
		connectionPreparationEvent{
			TaskID:  taskID,
			State:   "failed",
			Code:    code,
			Message: "规则准备失败",
		},
	)
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
