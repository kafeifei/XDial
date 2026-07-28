package engine

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"

	"github.com/kafeifei/xdial/core/config"
)

const (
	// ruleSetFetchTimeout 单个规则集的下载超时。首连要等它，不能太长；超时只会
	// 降级不会崩，宁可放弃这条规则也不要把连接卡住。
	ruleSetFetchTimeout = 15 * time.Second
	// ruleSetPrepareBudget 整轮预取的总预算，防止多个规则集串起来把连接拖死。
	ruleSetPrepareBudget = 40 * time.Second
	// ruleSetCacheTTL 本地缓存的新鲜期，与 sing-box remote 规则集默认的
	// update_interval 一致：改由 daemon 在每次连接时按这个周期刷新。
	ruleSetCacheTTL = 24 * time.Hour
	// ruleSetMaxBytes 单个规则集大小上限，挡住填错 URL 时把磁盘写满。
	ruleSetMaxBytes = 20 << 20
)

// srsMagic 是 sing-box 二进制规则集的文件头（common/srs.MagicBytes）。校验它是
// 为了挡住"HTTP 200 但内容是登录门户/错误页"——那种垃圾一旦落盘，sing-box 解析
// 本地规则集失败同样是启动期硬失败，等于把远程下载的坑原样搬到本地。
var srsMagic = []byte{0x53, 0x52, 0x53}

// prepareRuleSets 在 sing-box 启动前，把「sing-box 自己下载不了」的远程规则集
// 抓成本地文件，返回改写后的 Profile 副本；调用方持有的 profile 不被修改。
//
// 为什么必须由 daemon 代抓：remote 规则集的首次下载在 sing-box 里是硬失败——
// route/rule/rule_set_remote.go 的 StartContext 拿不到内容就返回
// "initial rule-set: ..."，router 在 StartStateStart 阶段直接 FATAL 退出，整个
// 连接崩掉。而它能用的 download_detour 只有「router 启动前就绪的 outbound」：
//
//   - 订阅节点 / 策略组 / 代理线路：可以，outbound 在 preStart 的 StartStateStart
//     就已 Start，交给 sing-box 自己下（本函数跳过这些）。
//   - vpn：不行，桌面的 vpn outbound 是本地 go-socks5 桥，sing-box 把域名原样
//     CONNECT 过去，桥用 net.ResolveIPAddr("ip", …) 走启动前 Underlay 的系统 DNS
//     解析（也可能返回 IPv6，而 VPNBridge.DialTCP 只收 IPv4），解出来的地址还可能
//     与隧道内的解析视角不一致。
//   - direct：规则集描述的往往正是走不通的那批域名（gfwlist 的 .srs 就托管在
//     raw.githubusercontent.com），从它自己描述的被墙路径上下载必然失败。
//
// daemon 这一侧没有上述限制：绑 VPN 的规则集经企业 DNS + 隧道抓，其余用启动前
// 已存在的 Underlay 抓。落盘后写成 file:// URL，
// 生成器输出 {"type":"local","path":...}，与 NE 端已有做法一致。
//
// 抓不到时按「旧缓存 → 停用该规则」降级并回报：那条规则的流量退回模式默认出口，
// 其余照常连接。可降级、可重试、可提示，而不是整机没网。
func prepareRuleSets(
	ctx context.Context,
	profile *config.Profile,
	cacheDir string,
	fetcher *ruleSetFetcher,
) (*config.Profile, []string) {
	mode := profile.ActiveMode()
	if mode == nil {
		return profile, nil
	}
	targets := ruleSetPrefetchTargets(profile, mode)
	if len(targets) == 0 {
		return profile, nil
	}
	if err := os.MkdirAll(cacheDir, 0o700); err != nil {
		return profile, []string{fmt.Sprintf("规则集缓存目录不可用（%v），远程规则集只能交给 sing-box 自行下载", err)}
	}

	prepared := cloneProfileRuleSets(profile)
	var problems []string
	for _, target := range targets {
		ruleSet := prepared.FindRuleSet(target.ruleSetID)
		if ruleSet == nil {
			continue
		}
		localPath, format, err := fetcher.materialize(ctx, cacheDir, ruleSet, target.viaVPN)
		if err != nil {
			ruleSet.Enabled = false
			problems = append(problems, fmt.Sprintf("规则「%s」获取失败（%v），这部分流量已退回默认出口", ruleSet.Name, err))
			continue
		}
		// 写回判定结果，生成器不必再从 file:// 路径上猜一次格式。
		ruleSet.Format = format
		ruleSet.URL = "file://" + localPath
	}
	return prepared, problems
}

// cloneProfileRuleSets 复制 Profile 及其 RuleSets 切片。改写只影响这次生成的
// sing-box 配置：调用方（UI / 持久化）手里的 profile 必须保持原样，否则一次
// 抓取失败会把用户的规则开关真的关掉。
func cloneProfileRuleSets(profile *config.Profile) *config.Profile {
	clone := *profile
	clone.RuleSets = append([]config.RuleSet(nil), profile.RuleSets...)
	return &clone
}

type ruleSetPrefetchTarget struct {
	ruleSetID string
	// viaVPN 表示该规则集绑定在 AnyConnect 线路上，下载要经隧道走。
	viaVPN bool
}

// ruleSetPrefetchTargets 挑出必须由 daemon 代抓的 URL 规则集。
//
// 遍历顺序与 config 侧生成 rule_set 资源的顺序一致（同一规则集以第一条绑定为准），
// 保证"谁来抓"和"抓不到时停用谁"指的是同一条。
func ruleSetPrefetchTargets(profile *config.Profile, mode *config.Mode) []ruleSetPrefetchTarget {
	var targets []ruleSetPrefetchTarget
	seen := map[string]bool{}
	for _, binding := range mode.Bindings {
		ruleSet := profile.FindRuleSet(binding.RuleSetID)
		if ruleSet == nil || !ruleSet.Enabled || ruleSet.Type != config.RuleSetTypeURL {
			continue
		}
		if ruleSet.URL == "" || strings.HasPrefix(ruleSet.URL, "file://") {
			continue
		}
		if seen[ruleSet.ID] {
			continue
		}
		seen[ruleSet.ID] = true

		// 订阅（节点或策略组）是 sing-box 启动前就绪的 outbound，download_detour
		// 能用，让它自己下——那条路径本来就是通的，代抓反而少一条可用出口。
		if binding.SubscriptionID != "" {
			continue
		}
		line := profile.FindLine(binding.LineID)
		if line != nil && line.Enabled {
			switch line.Type {
			case config.LineTypeTrojan, config.LineTypeShadowsocks, config.LineTypeVMess:
				continue
			}
		}
		targets = append(targets, ruleSetPrefetchTarget{
			ruleSetID: ruleSet.ID,
			viaVPN:    line != nil && line.Enabled && line.Type == config.LineTypeVPN,
		})
	}
	return targets
}

// ruleSetFetcher 持有两条下载路径：启动前 Underlay，以及经 AnyConnect 隧道。
type ruleSetFetcher struct {
	direct *http.Client
	// vpn 为 nil 表示本次连接没有 AnyConnect 隧道可用。
	vpn *http.Client
}

// tunnelDialer 是"经 AnyConnect 隧道拨一个 IP:端口"，实现就是 VPNBridge.DialTCP。
type tunnelDialer func(ctx context.Context, addr string) (net.Conn, error)

// newRuleSetFetcher 构造下载器。bridge 为 nil（没有 VPN 线路）时只有直连路径。
func newRuleSetFetcher(bridge *VPNBridge, enterpriseDNS []string) *ruleSetFetcher {
	fetcher := &ruleSetFetcher{
		direct: &http.Client{Transport: &http.Transport{
			// 预取发生在 sing-box 起来之前，此刻系统网络就是启动前已经叠加好的
			// Underlay；XDial 不识别也不拆解其中有哪些网络产品。
			DialContext:       (&net.Dialer{Timeout: 10 * time.Second}).DialContext,
			DisableKeepAlives: true,
		}},
	}
	if bridge != nil {
		transport := newTunnelTransport(bridge.DialTCP, tunnelDNSServer(enterpriseDNS))
		fetcher.vpn = &http.Client{Transport: transport}
	}
	return fetcher
}

// tunnelDNSServer 取企业 DNS 的查询地址。服务端下发的是裸 IP，补上 53 端口。
func tunnelDNSServer(enterpriseDNS []string) string {
	if len(enterpriseDNS) == 0 {
		return ""
	}
	return net.JoinHostPort(enterpriseDNS[0], "53")
}

// newTunnelTransport 让下载经 AnyConnect 隧道出去：域名先用企业 DNS 解析
// （TCP 53——桥只实现了 TCP，UDP 拨不出去），再拿解析出的 IPv4 走 dial。
// 这两步正是 sing-box 的 vpn outbound 做不到的部分（见 prepareRuleSets 注释）。
//
// dnsServer 为空（服务端没下发 DNS）时退回本机解析器：解出的地址可能被污染，
// 但连接仍然经隧道出去，比整条规则不可用好。
func newTunnelTransport(dial tunnelDialer, dnsServer string) *http.Transport {
	resolver := &net.Resolver{PreferGo: true}
	if dnsServer != "" {
		resolver = &net.Resolver{
			PreferGo: true,
			// 忽略 network 参数一律给 TCP 连接：Go 的解析器按"conn 是不是
			// net.PacketConn"决定报文封装，拿到流式 conn 就走 DNS-over-TCP 分帧。
			Dial: func(ctx context.Context, _, _ string) (net.Conn, error) {
				return dial(ctx, dnsServer)
			},
		}
	}
	return &http.Transport{
		DialContext: func(ctx context.Context, _, addr string) (net.Conn, error) {
			host, port, err := net.SplitHostPort(addr)
			if err != nil {
				return nil, err
			}
			if net.ParseIP(host) != nil {
				return dial(ctx, addr)
			}
			// 只要 IPv4：桥是纯 IPv4 的 gVisor 栈，AAAA 结果拨不出去。
			ips, err := resolver.LookupIP(ctx, "ip4", host)
			if err != nil {
				return nil, fmt.Errorf("经隧道解析 %s: %w", host, err)
			}
			var lastErr error = fmt.Errorf("%s 没有可用的 IPv4 地址", host)
			for _, ip := range ips {
				conn, dialErr := dial(ctx, net.JoinHostPort(ip.String(), port))
				if dialErr == nil {
					return conn, nil
				}
				lastErr = dialErr
			}
			return nil, lastErr
		},
		DisableKeepAlives: true,
	}
}

// materialize 返回规则集可用的本地文件路径与格式：缓存够新就直接用，否则下载；
// 下载失败但有旧缓存时用旧的（过期的 gfwlist 也远好过整条规则失效）。
func (f *ruleSetFetcher) materialize(
	ctx context.Context,
	cacheDir string,
	ruleSet *config.RuleSet,
	viaVPN bool,
) (string, string, error) {
	format := ruleSetFormat(ruleSet)
	localPath := ruleSetCachePath(cacheDir, ruleSet, format)
	if info, err := os.Stat(localPath); err == nil && info.Size() > 0 {
		if time.Since(info.ModTime()) < ruleSetCacheTTL {
			return localPath, format, nil
		}
	}

	content, err := f.download(ctx, ruleSet.URL, viaVPN)
	if err == nil {
		err = validateRuleSetContent(content, format)
	}
	if err != nil {
		if info, statErr := os.Stat(localPath); statErr == nil && info.Size() > 0 {
			slog.Warn("rule set refresh failed, using stale cache",
				"rule_set", ruleSet.ID, "path", localPath, "err", err)
			return localPath, format, nil
		}
		return "", "", err
	}
	if err := writeRuleSetCache(localPath, content); err != nil {
		return "", "", err
	}
	slog.Info("rule set prefetched", "rule_set", ruleSet.ID, "bytes", len(content), "via_vpn", viaVPN)
	return localPath, format, nil
}

func (f *ruleSetFetcher) download(ctx context.Context, rawURL string, viaVPN bool) ([]byte, error) {
	client := f.direct
	if viaVPN {
		if f.vpn == nil {
			return nil, fmt.Errorf("AnyConnect 隧道不可用")
		}
		client = f.vpn
	}
	ctx, cancel := context.WithTimeout(ctx, ruleSetFetchTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %s", resp.Status)
	}
	content, err := io.ReadAll(io.LimitReader(resp.Body, ruleSetMaxBytes+1))
	if err != nil {
		return nil, err
	}
	if len(content) == 0 {
		return nil, fmt.Errorf("内容为空")
	}
	if len(content) > ruleSetMaxBytes {
		return nil, fmt.Errorf("超过 %d 字节上限", ruleSetMaxBytes)
	}
	return content, nil
}

func validateRuleSetContent(content []byte, format string) error {
	if format == "source" {
		if !json.Valid(content) {
			return fmt.Errorf("内容不是合法 JSON")
		}
		return nil
	}
	if len(content) < len(srsMagic) || string(content[:len(srsMagic)]) != string(srsMagic) {
		return fmt.Errorf("内容不是 sing-box 二进制规则集")
	}
	return nil
}

// writeRuleSetCache 先写临时文件再 rename：中途失败或被打断时，留在原位的是上一
// 份完整缓存，而不是半截文件——半截文件会让 sing-box 在启动期解析失败。
func writeRuleSetCache(localPath string, content []byte) error {
	tmpPath := localPath + ".tmp"
	if err := os.WriteFile(tmpPath, content, 0o600); err != nil {
		return fmt.Errorf("写入规则集缓存: %w", err)
	}
	if err := os.Rename(tmpPath, localPath); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("提交规则集缓存: %w", err)
	}
	return nil
}

// ruleSetCacheDirectory 返回 daemon 自己管理的规则集缓存目录。
func ruleSetCacheDirectory(statePath string) string {
	return filepath.Join(statePath, "rulesets")
}

// ruleSetCachePath 摘要里带上 URL：用户改了规则集地址就换一份缓存文件，
// 不会读到上一个地址留下的内容。
func ruleSetCachePath(cacheDir string, ruleSet *config.RuleSet, format string) string {
	digest := sha256.Sum256([]byte(ruleSet.ID + "\n" + ruleSet.URL))
	extension := ".srs"
	if format == "source" {
		extension = ".json"
	}
	return filepath.Join(cacheDir, hex.EncodeToString(digest[:12])+extension)
}

// ruleSetFormat 与 config 侧 sbResolveRuleSetFormat 同一套判定：显式 Format 优先，
// 否则看 URL 扩展名，都拿不准按 binary。
func ruleSetFormat(ruleSet *config.RuleSet) string {
	switch strings.ToLower(ruleSet.Format) {
	case "srs", "binary":
		return "binary"
	case "json", "source":
		return "source"
	}
	if parsed, err := url.Parse(ruleSet.URL); err == nil {
		switch strings.ToLower(path.Ext(parsed.Path)) {
		case ".json":
			return "source"
		case ".srs":
			return "binary"
		}
	}
	return "binary"
}
