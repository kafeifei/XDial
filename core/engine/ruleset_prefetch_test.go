package engine

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/kafeifei/xdial/core/config"
)

func srsPayload() []byte {
	return append(append([]byte{}, srsMagic...), 0x01, 0x02, 0x03)
}

// gfwProfile 复刻用户的真实模式：URL 规则集 gfw 绑到指定线路。
func gfwProfile(url string, line config.Line, binding config.RuleBinding) *config.Profile {
	binding.RuleSetID = "gfw"
	return &config.Profile{
		Lines: []config.Line{line},
		RuleSets: []config.RuleSet{{
			ID: "gfw", Name: "gfwlist", Type: config.RuleSetTypeURL, Enabled: true, URL: url,
		}},
		Modes: []config.Mode{{
			ID: "m", Bindings: []config.RuleBinding{binding}, DefaultLineID: "direct",
		}},
		ActiveModeID: "m",
	}
}

func directRuleSetLine() config.Line {
	return config.Line{ID: "direct", Type: config.LineTypeDirect, Enabled: true}
}

func prepareForTest(t *testing.T, profile *config.Profile, dir string) (*config.Profile, []string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return prepareRuleSets(ctx, profile, dir, newRuleSetFetcher(nil, nil))
}

// 绑到 direct 的规则集描述的往往正是 Underlay 取不到的内容；为避免 sing-box
// 首次下载失败导致整个启动失败，daemon 先抓成本地文件。
func TestPrepareRuleSetsMaterializesDirectBoundSet(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write(srsPayload())
	}))
	defer server.Close()

	profile := gfwProfile(server.URL+"/gfw.srs", directRuleSetLine(), config.RuleBinding{LineID: "direct"})
	dir := t.TempDir()
	prepared, problems := prepareForTest(t, profile, dir)
	if len(problems) != 0 {
		t.Fatalf("unexpected problems: %v", problems)
	}

	localURL := prepared.RuleSets[0].URL
	if !strings.HasPrefix(localURL, "file://") {
		t.Fatalf("rule set was not materialized: %s", localURL)
	}
	if prepared.RuleSets[0].Format != "binary" {
		t.Fatalf("format = %q, want binary", prepared.RuleSets[0].Format)
	}
	content, err := os.ReadFile(strings.TrimPrefix(localURL, "file://"))
	if err != nil {
		t.Fatalf("read cached rule set: %v", err)
	}
	if string(content) != string(srsPayload()) {
		t.Fatalf("cached content mismatch")
	}
	// 调用方持有的 profile 必须原样不动。
	if profile.RuleSets[0].URL != server.URL+"/gfw.srs" {
		t.Fatalf("caller profile was mutated: %s", profile.RuleSets[0].URL)
	}
}

// 生成器只认 file:// 才输出 type:local，这里把两步接起来验证真实产物。
func TestPreparedRuleSetGeneratesLocalResource(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write(srsPayload())
	}))
	defer server.Close()

	profile := gfwProfile(server.URL+"/gfw.srs", directRuleSetLine(), config.RuleBinding{LineID: "direct"})
	prepared, _ := prepareForTest(t, profile, t.TempDir())

	data, err := config.GenerateSingBoxDesktop(prepared, 0, "", t.TempDir(), nil, "en0")
	if err != nil {
		t.Fatalf("generate: %v", err)
	}
	var cfg struct {
		Route struct {
			RuleSet []map[string]interface{} `json:"rule_set"`
		} `json:"route"`
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(cfg.Route.RuleSet) != 1 {
		t.Fatalf("rule_set = %v", cfg.Route.RuleSet)
	}
	set := cfg.Route.RuleSet[0]
	if set["type"] != "local" {
		t.Fatalf("type = %v, want local (remote download would FATAL on first start)", set["type"])
	}
	if _, ok := set["download_detour"]; ok {
		t.Fatalf("local rule set must not carry download_detour: %v", set)
	}
	if path, _ := set["path"].(string); path == "" {
		t.Fatalf("missing path: %v", set)
	}
}

// 抓不到且没有旧缓存：停用该规则并回报，连接照常，而不是让 sing-box 崩。
func TestPrepareRuleSetsDisablesUnavailableSet(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	defer server.Close()

	profile := gfwProfile(server.URL+"/gfw.srs", directRuleSetLine(), config.RuleBinding{LineID: "direct"})
	prepared, problems := prepareForTest(t, profile, t.TempDir())
	if len(problems) != 1 {
		t.Fatalf("problems = %v, want 1", problems)
	}
	if prepared.RuleSets[0].Enabled {
		t.Fatalf("unavailable rule set should be disabled")
	}
	if !profile.RuleSets[0].Enabled {
		t.Fatalf("caller profile was mutated")
	}

	data, err := config.GenerateSingBoxDesktop(prepared, 0, "", t.TempDir(), nil, "en0")
	if err != nil {
		t.Fatalf("generate: %v", err)
	}
	if strings.Contains(string(data), "rule_set") {
		t.Fatalf("disabled rule set still referenced: %s", data)
	}
}

// HTTP 200 但内容是错误页/登录门户：落盘同样会让 sing-box 启动期解析失败，
// 必须在写入前挡掉。
func TestPrepareRuleSetsRejectsNonRuleSetContent(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("<html>captive portal</html>"))
	}))
	defer server.Close()

	dir := t.TempDir()
	profile := gfwProfile(server.URL+"/gfw.srs", directRuleSetLine(), config.RuleBinding{LineID: "direct"})
	prepared, problems := prepareForTest(t, profile, dir)
	if len(problems) != 1 || prepared.RuleSets[0].Enabled {
		t.Fatalf("garbage content should be rejected, problems=%v", problems)
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 0 {
		t.Fatalf("garbage must not be cached: %v", entries)
	}
}

// 下载失败但有旧缓存：宁可用过期的 gfwlist，也不让整条规则失效。
func TestPrepareRuleSetsFallsBackToStaleCache(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "boom", http.StatusBadGateway)
	}))
	defer server.Close()

	dir := t.TempDir()
	profile := gfwProfile(server.URL+"/gfw.srs", directRuleSetLine(), config.RuleBinding{LineID: "direct"})
	stalePath := ruleSetCachePath(dir, &profile.RuleSets[0], "binary")
	if err := os.WriteFile(stalePath, srsPayload(), 0o600); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-72 * time.Hour)
	if err := os.Chtimes(stalePath, old, old); err != nil {
		t.Fatal(err)
	}

	prepared, problems := prepareForTest(t, profile, dir)
	if len(problems) != 0 {
		t.Fatalf("stale cache should keep the rule usable: %v", problems)
	}
	if prepared.RuleSets[0].URL != "file://"+stalePath {
		t.Fatalf("url = %s, want stale cache", prepared.RuleSets[0].URL)
	}
}

// 缓存够新时一个网络请求都不该发：连接路径上不做无谓等待。
func TestPrepareRuleSetsReusesFreshCache(t *testing.T) {
	var hits atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		w.Write(srsPayload())
	}))
	defer server.Close()

	dir := t.TempDir()
	profile := gfwProfile(server.URL+"/gfw.srs", directRuleSetLine(), config.RuleBinding{LineID: "direct"})
	if _, problems := prepareForTest(t, profile, dir); len(problems) != 0 {
		t.Fatalf("first pass failed: %v", problems)
	}
	if _, problems := prepareForTest(t, profile, dir); len(problems) != 0 {
		t.Fatalf("second pass failed: %v", problems)
	}
	if hits.Load() != 1 {
		t.Fatalf("hits = %d, want 1 (fresh cache must skip the network)", hits.Load())
	}
}

// 绑在订阅/代理线路上的规则集由 sing-box 自己下（download_detour 那条路是通的），
// daemon 不插手。
func TestPrepareRuleSetsSkipsProxyBoundSets(t *testing.T) {
	var hits atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		w.Write(srsPayload())
	}))
	defer server.Close()

	cases := []struct {
		name    string
		line    config.Line
		binding config.RuleBinding
	}{
		{
			name:    "subscription",
			line:    directRuleSetLine(),
			binding: config.RuleBinding{SubscriptionID: "sub"},
		},
		{
			name:    "shadowsocks line",
			line:    config.Line{ID: "ss", Type: config.LineTypeShadowsocks, Enabled: true},
			binding: config.RuleBinding{LineID: "ss"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			profile := gfwProfile(server.URL+"/gfw.srs", tc.line, tc.binding)
			prepared, problems := prepareForTest(t, profile, t.TempDir())
			if len(problems) != 0 {
				t.Fatalf("problems = %v", problems)
			}
			if prepared.RuleSets[0].URL != server.URL+"/gfw.srs" {
				t.Fatalf("url = %s, want untouched remote URL", prepared.RuleSets[0].URL)
			}
		})
	}
	if hits.Load() != 0 {
		t.Fatalf("hits = %d, want 0", hits.Load())
	}
}

// 绑到 VPN 线路但隧道不可用（fetcher 没有桥）时不能悄悄退回启动前 Underlay：
// 那正是被墙的那条路，而且用户要的是"经隧道取"。
func TestPrepareRuleSetsVPNBoundRequiresBridge(t *testing.T) {
	var hits atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		w.Write(srsPayload())
	}))
	defer server.Close()

	profile := gfwProfile(
		server.URL+"/gfw.srs",
		config.Line{ID: "vpn", Type: config.LineTypeVPN, Enabled: true, VPNServer: "vpn.example.com"},
		config.RuleBinding{LineID: "vpn"},
	)
	prepared, problems := prepareForTest(t, profile, t.TempDir())
	if len(problems) != 1 || prepared.RuleSets[0].Enabled {
		t.Fatalf("problems = %v, enabled = %v", problems, prepared.RuleSets[0].Enabled)
	}
	if hits.Load() != 0 {
		t.Fatalf("hits = %d, want 0 (must not fall back to the direct path)", hits.Load())
	}
}

// 预设「国内」的形状：gfw 规则集绑在 AnyConnect 线路上。下载要经隧道，而且域名
// 必须由企业 DNS（TCP 53）解析后按 IPv4 拨出去——这正是 sing-box 的 vpn outbound
// 做不到、只能由 daemon 代抓的部分。
func TestPrepareRuleSetsFetchesVPNBoundSetThroughTunnel(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write(srsPayload())
	}))
	defer server.Close()
	parsed, err := url.Parse(server.URL)
	if err != nil {
		t.Fatal(err)
	}

	dnsAddr := startFakeEnterpriseDNS(t, net.ParseIP("127.0.0.1"))
	var mu sync.Mutex
	var dialed []string
	dial := func(ctx context.Context, addr string) (net.Conn, error) {
		mu.Lock()
		dialed = append(dialed, addr)
		mu.Unlock()
		return (&net.Dialer{}).DialContext(ctx, "tcp", addr)
	}
	fetcher := &ruleSetFetcher{
		direct: &http.Client{Transport: &http.Transport{
			DialContext: func(context.Context, string, string) (net.Conn, error) {
				return nil, errors.New("VPN 绑定的规则集不该走直连路径")
			},
		}},
		vpn: &http.Client{Transport: newTunnelTransport(dial, dnsAddr)},
	}

	profile := gfwProfile(
		"http://gfw.test:"+parsed.Port()+"/gfw.srs",
		config.Line{ID: "vpn", Type: config.LineTypeVPN, Enabled: true, VPNServer: "vpn.example.com"},
		config.RuleBinding{LineID: "vpn"},
	)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	prepared, problems := prepareRuleSets(ctx, profile, t.TempDir(), fetcher)
	if len(problems) != 0 {
		t.Fatalf("problems = %v", problems)
	}
	if !strings.HasPrefix(prepared.RuleSets[0].URL, "file://") {
		t.Fatalf("rule set was not materialized: %s", prepared.RuleSets[0].URL)
	}

	mu.Lock()
	defer mu.Unlock()
	want := []string{dnsAddr, "127.0.0.1:" + parsed.Port()}
	if len(dialed) != len(want) {
		t.Fatalf("tunnel dials = %v, want %v", dialed, want)
	}
	for i := range want {
		if dialed[i] != want[i] {
			t.Fatalf("tunnel dials = %v, want %v", dialed, want)
		}
	}
}

// startFakeEnterpriseDNS 起一个只会 DNS-over-TCP 的假企业 DNS：所有 A 查询都答
// 同一个地址。用它验证解析确实经隧道发出（而不是落到本机解析器）。
func startFakeEnterpriseDNS(t *testing.T, answer net.IP) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go serveFakeDNS(conn, answer)
		}
	}()
	return listener.Addr().String()
}

func serveFakeDNS(conn net.Conn, answer net.IP) {
	defer conn.Close()
	for {
		var length [2]byte
		if _, err := io.ReadFull(conn, length[:]); err != nil {
			return
		}
		query := make([]byte, int(length[0])<<8|int(length[1]))
		if _, err := io.ReadFull(conn, query); err != nil {
			return
		}
		response := buildFakeDNSResponse(query, answer)
		if response == nil {
			return
		}
		framed := append([]byte{byte(len(response) >> 8), byte(len(response))}, response...)
		if _, err := conn.Write(framed); err != nil {
			return
		}
	}
}

// buildFakeDNSResponse 原样回抄问题段，再补一条 A 记录（0xC00C 指回问题里的名字）。
func buildFakeDNSResponse(query []byte, answer net.IP) []byte {
	if len(query) < 12 {
		return nil
	}
	offset := 12
	for offset < len(query) && query[offset] != 0 {
		offset += int(query[offset]) + 1
	}
	offset += 5 // 根标签 0x00 + QTYPE + QCLASS
	if offset > len(query) {
		return nil
	}
	response := []byte{query[0], query[1], 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0, 0, 0, 0}
	response = append(response, query[12:offset]...)
	response = append(response, 0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0, 0, 0, 60, 0x00, 0x04)
	return append(response, answer.To4()...)
}

func TestRuleSetFormatInference(t *testing.T) {
	cases := []struct {
		ruleSet config.RuleSet
		want    string
	}{
		{config.RuleSet{URL: "https://example.com/a.srs"}, "binary"},
		{config.RuleSet{URL: "https://example.com/a.json"}, "source"},
		{config.RuleSet{URL: "https://example.com/a.json?token=1"}, "source"},
		{config.RuleSet{URL: "https://example.com/a", Format: "json"}, "source"},
		{config.RuleSet{URL: "https://example.com/a", Format: "auto"}, "binary"},
	}
	for _, tc := range cases {
		if got := ruleSetFormat(&tc.ruleSet); got != tc.want {
			t.Errorf("ruleSetFormat(%+v) = %s, want %s", tc.ruleSet, got, tc.want)
		}
	}
}
