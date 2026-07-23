package config

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakeExit struct {
	ln       net.Listener
	Addr     string
	Requests []requestRecord
	mu       sync.Mutex
}

type requestRecord struct {
	Host string
	Path string
}

const smokeRuleSetFetchOutbound = "smoke-rule-set-fetch-direct"

func newFakeExit() *fakeExit {
	return &fakeExit{}
}

func (fe *fakeExit) Start() error {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	fe.ln = ln
	fe.Addr = ln.Addr().String()
	go fe.acceptLoop()
	return nil
}

func (fe *fakeExit) acceptLoop() {
	for {
		conn, err := fe.ln.Accept()
		if err != nil {
			return
		}
		go fe.handleConn(conn)
	}
}

func (fe *fakeExit) handleConn(conn net.Conn) {
	defer conn.Close()

	buf := make([]byte, 4096)
	n, err := conn.Read(buf)
	if err != nil || n < 3 {
		return
	}
	conn.Write([]byte{0x05, 0x00})

	n, err = conn.Read(buf)
	if err != nil || n < 5 {
		return
	}
	atyp := buf[3]
	var host string
	switch atyp {
	case 0x01:
		if n < 10 {
			return
		}
		host = net.IP(buf[4:8]).String()
	case 0x03:
		domainLen := int(buf[4])
		if n < 5+domainLen+2 {
			return
		}
		host = string(buf[5 : 5+domainLen])
	case 0x04:
		if n < 22 {
			return
		}
		host = net.IP(buf[4:20]).String()
	default:
		return
	}

	fe.mu.Lock()
	fe.Requests = append(fe.Requests, requestRecord{Host: host})
	fe.mu.Unlock()

	conn.Write([]byte{0x05, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00})

	// 等待 sing-box 发来 HTTP 请求
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	n, _ = conn.Read(buf)
	reqStr := string(buf[:n])
	path := "/"
	if idx := strings.Index(reqStr, " "); idx >= 0 {
		rest := reqStr[idx+1:]
		if idx2 := strings.Index(rest, " "); idx2 >= 0 {
			path = rest[:idx2]
		}
	}
	fe.mu.Lock()
	if len(fe.Requests) > 0 {
		fe.Requests[len(fe.Requests)-1].Path = path
	}
	fe.mu.Unlock()

	resp := "HTTP/1.1 200 OK\r\nX-Exit: " + fe.Addr + "\r\nContent-Length: 2\r\n\r\nok"
	conn.Write([]byte(resp))

	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	for {
		if _, err := conn.Read(buf); err != nil {
			break
		}
	}
}

func (fe *fakeExit) Close() {
	fe.ln.Close()
}

func (fe *fakeExit) receivedHosts() []string {
	fe.mu.Lock()
	defer fe.mu.Unlock()
	var hosts []string
	for _, r := range fe.Requests {
		hosts = append(hosts, r.Host)
	}
	return hosts
}

type smokeRunner struct {
	t         *testing.T
	fakeExits map[string]*fakeExit
	httpPort  int
	cmd       *exec.Cmd
	cancel    context.CancelFunc
	tmpDir    string
}

func newSmokeRunner(t *testing.T, profile *Profile) *smokeRunner {
	t.Helper()

	if _, err := exec.LookPath("sing-box"); err != nil {
		t.Skip("sing-box not found, skipping smoke test")
	}

	runner := &smokeRunner{t: t, fakeExits: make(map[string]*fakeExit)}

	raw, err := GenerateSingBox(profile, 0, "")
	if err != nil {
		t.Fatalf("GenerateSingBox: %v", err)
	}

	var cfg map[string]interface{}
	if err := json.Unmarshal(raw, &cfg); err != nil {
		t.Fatalf("unmarshal config: %v", err)
	}

	outbounds := cfg["outbounds"].([]interface{})
	for _, obRaw := range outbounds {
		ob := obRaw.(map[string]interface{})
		tag := ob["tag"].(string)
		typ := ob["type"].(string)
		if typ == "selector" {
			continue
		}
		fe := newFakeExit()
		if err := fe.Start(); err != nil {
			t.Fatalf("start fake exit for %s: %v", tag, err)
		}
		runner.fakeExits[tag] = fe
	}

	newOutbounds := make([]map[string]interface{}, 0, len(outbounds))
	for _, obRaw := range outbounds {
		ob := obRaw.(map[string]interface{})
		tag := ob["tag"].(string)
		typ := ob["type"].(string)

		switch {
		case typ == "selector":
			newOutbounds = append(newOutbounds, ob)
		case typ == "urltest":
			ob["type"] = "selector"
			delete(ob, "url")
			delete(ob, "interval")
			delete(ob, "tolerance")
			newOutbounds = append(newOutbounds, ob)
		default:
			fe, ok := runner.fakeExits[tag]
			if !ok {
				t.Fatalf("no fake exit for outbound tag %s", tag)
			}
			host, port, _ := net.SplitHostPort(fe.Addr)
			portNum := 0
			fmt.Sscanf(port, "%d", &portNum)
			newOb := map[string]interface{}{
				"type":        "socks",
				"tag":         tag,
				"server":      host,
				"server_port": portNum,
			}
			newOutbounds = append(newOutbounds, newOb)
		}
	}
	// 数据面分流断言把产品里的 direct 也改写成本地 SOCKS，以免测试结果依赖
	// 公网可达性。远程 rule-set 的本地 HTTP fixture 则需要一条不参与路由选择的
	// 真实 direct detour，否则下载请求也会被测试 SOCKS 截获并收到假响应。
	newOutbounds = append(newOutbounds, map[string]interface{}{
		"type": "direct",
		"tag":  smokeRuleSetFetchOutbound,
	})

	httpLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen for http inbound: %v", err)
	}
	runner.httpPort = httpLn.Addr().(*net.TCPAddr).Port
	httpLn.Close()

	cfg["inbounds"] = []map[string]interface{}{
		{
			"type":        "http",
			"tag":         "http-in",
			"listen":      "127.0.0.1",
			"listen_port": runner.httpPort,
		},
	}
	cfg["outbounds"] = newOutbounds
	cfg["experimental"] = map[string]interface{}{}

	runner.tmpDir = t.TempDir()
	if route, ok := cfg["route"].(map[string]interface{}); ok {
		if rss, ok := route["rule_set"].([]interface{}); ok && len(rss) > 0 {
			fileLn, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatalf("listen for rule_set file server: %v", err)
			}
			filePort := fileLn.Addr().(*net.TCPAddr).Port
			go http.Serve(fileLn, http.FileServer(http.Dir(runner.tmpDir)))

			for _, rsRaw := range rss {
				rs := rsRaw.(map[string]interface{})
				filename := rs["tag"].(string) + ".json"
				oldURL, _ := rs["url"].(string)
				localPath, _ := rs["path"].(string)

				if localPath != "" || strings.HasPrefix(oldURL, "file://") {
					if localPath == "" {
						localPath = strings.TrimPrefix(oldURL, "file://")
					}
					src, err := os.ReadFile(localPath)
					if err != nil {
						t.Fatalf("read rule_set source: %v", err)
					}
					os.WriteFile(filepath.Join(runner.tmpDir, filename), src, 0644)
				} else {
					os.WriteFile(filepath.Join(runner.tmpDir, filename),
						[]byte(`{"version":1,"rules":[]}`), 0644)
				}
				rs["type"] = "remote"
				rs["url"] = fmt.Sprintf("http://127.0.0.1:%d/%s", filePort, filename)
				rs["download_detour"] = smokeRuleSetFetchOutbound
				delete(rs, "path")
				if rs["format"] == "binary" {
					rs["format"] = "source"
				}
			}
		}
	}

	finalCfg, _ := json.MarshalIndent(cfg, "", "  ")
	cfgPath := filepath.Join(runner.tmpDir, "sing-box.json")
	if err := os.WriteFile(cfgPath, finalCfg, 0644); err != nil {
		t.Fatalf("write config: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	runner.cancel = cancel
	runner.cmd = exec.CommandContext(ctx, "sing-box", "run", "-c", cfgPath)
	runner.cmd.Stderr = os.Stderr
	if err := runner.cmd.Start(); err != nil {
		t.Fatalf("start sing-box: %v", err)
	}

	if !runner.waitReady(10 * time.Second) {
		runner.stop()
		t.Fatal("sing-box did not become ready")
	}

	return runner
}

func (r *smokeRunner) waitReady(timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", r.httpPort), 500*time.Millisecond)
		if err == nil {
			conn.Close()
			return true
		}
		time.Sleep(200 * time.Millisecond)
	}
	return false
}

func (r *smokeRunner) stop() {
	if r.cancel != nil {
		r.cancel()
	}
	if r.cmd != nil && r.cmd.Process != nil {
		r.cmd.Process.Kill()
		r.cmd.Wait()
	}
	for _, fe := range r.fakeExits {
		fe.Close()
	}
}

func (r *smokeRunner) proxyRequest(targetHost string) (*http.Response, error) {
	proxyURL, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", r.httpPort))
	transport := &http.Transport{Proxy: http.ProxyURL(proxyURL)}
	client := &http.Client{Transport: transport, Timeout: 10 * time.Second}
	return client.Get("http://" + targetHost + "/test")
}

func (r *smokeRunner) assertHost(tag string, targetHost string) {
	r.t.Helper()
	fe, ok := r.fakeExits[tag]
	if !ok {
		r.t.Fatalf("unknown fake exit tag: %s", tag)
	}
	for _, h := range fe.receivedHosts() {
		if h == targetHost {
			return
		}
	}
	r.t.Errorf("fake exit %q did NOT receive request for host %q. Received: %v",
		tag, targetHost, fe.receivedHosts())
}

func (r *smokeRunner) requestAndAssert(targetHost string, expectTag string) {
	r.t.Helper()
	resp, err := r.proxyRequest(targetHost)
	if err != nil {
		r.t.Fatalf("proxy request to %s: %v", targetHost, err)
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	r.assertHost(expectTag, targetHost)
}

// ---------------------------------------------------------------------------
// 测试用例
// ---------------------------------------------------------------------------

func TestSmoke_BasicSplit(t *testing.T) {
	profile := &Profile{
		Lines: []Line{
			{ID: "my-vpn", Type: LineTypeVPN, Enabled: true, VPNServer: "vpn.example.com"},
			{ID: "my-trojan", Type: LineTypeTrojan, Enabled: true,
				TrojanServer: "tr.example.com", TrojanPort: 443, TrojanPassword: "pass", TrojanSNI: "tr.example.com"},
		},
		RuleSets: []RuleSet{
			{ID: "corp", Name: "公司", Type: RuleSetTypeManual, Enabled: true,
				Domains: []string{"corp.example.com", "internal.example.com"}},
			{ID: "social", Name: "社交", Type: RuleSetTypeManual, Enabled: true,
				Domains: []string{"twitter.com", "facebook.com"}},
		},
		Modes: []Mode{{
			ID: "main",
			Bindings: []RuleBinding{
				{RuleSetID: "corp", LineID: "my-vpn"},
				{RuleSetID: "social", LineID: "my-trojan"},
			},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "main",
	}

	r := newSmokeRunner(t, profile)
	defer r.stop()

	r.requestAndAssert("corp.example.com", "vpn")
	r.requestAndAssert("internal.example.com", "vpn")
	r.requestAndAssert("twitter.com", "proxy-my-trojan")
	r.requestAndAssert("facebook.com", "proxy-my-trojan")
	r.requestAndAssert("baidu.com", "direct")
}

func TestSmoke_DefaultVPN(t *testing.T) {
	profile := &Profile{
		Lines: []Line{
			{ID: "my-vpn", Type: LineTypeVPN, Enabled: true, VPNServer: "vpn.example.com"},
		},
		RuleSets: []RuleSet{
			{ID: "gfw", Name: "GFW", Type: RuleSetTypeManual, Enabled: true,
				Domains: []string{"google.com"}},
		},
		Modes: []Mode{{
			ID: "main",
			Bindings: []RuleBinding{
				{RuleSetID: "gfw", LineID: "my-vpn"},
			},
			DefaultLineID: "my-vpn",
		}},
		ActiveModeID: "main",
	}

	r := newSmokeRunner(t, profile)
	defer r.stop()

	r.requestAndAssert("google.com", "vpn")
	r.requestAndAssert("example.com", "vpn")
}

func TestSmoke_MultipleRuleSets(t *testing.T) {
	profile := &Profile{
		Lines: []Line{
			{ID: "my-vpn", Type: LineTypeVPN, Enabled: true, VPNServer: "vpn.example.com"},
			{ID: "my-ss", Type: LineTypeShadowsocks, Enabled: true,
				SSServer: "ss.example.com", SSPort: 8388, SSMethod: "aes-256-gcm", SSPass: "secret"},
		},
		RuleSets: []RuleSet{
			{ID: "corp", Name: "公司", Type: RuleSetTypeManual, Enabled: true,
				Domains: []string{"corp.example.com"}, CIDRs: []string{"10.0.0.0/8"}},
			{ID: "gfw", Name: "GFW", Type: RuleSetTypeManual, Enabled: true,
				Domains: []string{"google.com", "youtube.com"}},
		},
		Modes: []Mode{{
			ID: "main",
			Bindings: []RuleBinding{
				{RuleSetID: "corp", LineID: "my-vpn"},
				{RuleSetID: "gfw", LineID: "my-ss"},
			},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "main",
	}

	r := newSmokeRunner(t, profile)
	defer r.stop()

	r.requestAndAssert("corp.example.com", "vpn")
	r.requestAndAssert("google.com", "proxy-my-ss")
	r.requestAndAssert("youtube.com", "proxy-my-ss")
}

func TestSmoke_OnlyCIDR(t *testing.T) {
	profile := &Profile{
		Lines: []Line{
			{ID: "my-vpn", Type: LineTypeVPN, Enabled: true, VPNServer: "vpn.example.com"},
		},
		RuleSets: []RuleSet{
			{ID: "private", Name: "私有网段", Type: RuleSetTypeManual, Enabled: true,
				CIDRs: []string{"172.16.0.0/12"}},
		},
		Modes: []Mode{{
			ID: "main",
			Bindings: []RuleBinding{
				{RuleSetID: "private", LineID: "my-vpn"},
			},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "main",
	}

	r := newSmokeRunner(t, profile)
	defer r.stop()

	r.requestAndAssert("example.com", "direct")
}

func TestSmoke_EmptyRuleSet(t *testing.T) {
	profile := &Profile{
		Lines: []Line{
			{ID: "my-vpn", Type: LineTypeVPN, Enabled: true, VPNServer: "vpn.example.com"},
		},
		RuleSets: []RuleSet{
			{ID: "empty", Name: "空的", Type: RuleSetTypeManual, Enabled: true},
		},
		Modes: []Mode{{
			ID: "main",
			Bindings: []RuleBinding{
				{RuleSetID: "empty", LineID: "my-vpn"},
			},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "main",
	}

	r := newSmokeRunner(t, profile)
	defer r.stop()

	r.requestAndAssert("corp.example.com", "direct")
}

func TestSmoke_DisabledRuleSet(t *testing.T) {
	profile := &Profile{
		Lines: []Line{
			{ID: "my-vpn", Type: LineTypeVPN, Enabled: true, VPNServer: "vpn.example.com"},
		},
		RuleSets: []RuleSet{
			{ID: "disabled", Name: "禁用的", Type: RuleSetTypeManual, Enabled: false,
				Domains: []string{"should-not-match.com"}},
		},
		Modes: []Mode{{
			ID: "main",
			Bindings: []RuleBinding{
				{RuleSetID: "disabled", LineID: "my-vpn"},
			},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "main",
	}

	r := newSmokeRunner(t, profile)
	defer r.stop()

	r.requestAndAssert("should-not-match.com", "direct")
}

func TestSmoke_URLJsonRuleSet(t *testing.T) {
	ruleSetJSON := map[string]interface{}{
		"version": 1,
		"rules": []map[string]interface{}{
			{"domain_suffix": []string{"test-gfw.local", "blocked.local"}},
		},
	}
	ruleBytes, _ := json.Marshal(ruleSetJSON)
	localRuleFile := filepath.Join(t.TempDir(), "test-rules.json")
	os.WriteFile(localRuleFile, ruleBytes, 0644)

	profile := &Profile{
		Lines: []Line{
			{ID: "my-vpn", Type: LineTypeVPN, Enabled: true, VPNServer: "vpn.example.com"},
		},
		RuleSets: []RuleSet{
			{ID: "gfw", Name: "GFW", Type: RuleSetTypeURL, Enabled: true,
				URL: "file://" + localRuleFile, Format: "json"},
		},
		Modes: []Mode{{
			ID: "main",
			Bindings: []RuleBinding{
				{RuleSetID: "gfw", LineID: "my-vpn"},
			},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "main",
	}

	r := newSmokeRunner(t, profile)
	defer r.stop()

	r.requestAndAssert("test-gfw.local", "vpn")
	r.requestAndAssert("blocked.local", "vpn")
	r.requestAndAssert("normal.local", "direct")
}

func TestSmoke_URLSrsRuleSet(t *testing.T) {
	profile := &Profile{
		Lines: []Line{
			{ID: "my-vpn", Type: LineTypeVPN, Enabled: true, VPNServer: "vpn.example.com"},
		},
		RuleSets: []RuleSet{
			{ID: "gfw", Name: "GFW", Type: RuleSetTypeURL, Enabled: true,
				URL:    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-gfw.srs",
				Format: "srs"},
		},
		Modes: []Mode{{
			ID: "main",
			Bindings: []RuleBinding{
				{RuleSetID: "gfw", LineID: "my-vpn"},
			},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "main",
	}

	r := newSmokeRunner(t, profile)
	defer r.stop()

	r.requestAndAssert("google.com", "direct")
}

func TestSmoke_URLJsonFormat(t *testing.T) {
	profile := &Profile{
		Lines: []Line{
			{ID: "my-vpn", Type: LineTypeVPN, Enabled: true, VPNServer: "vpn.example.com"},
		},
		RuleSets: []RuleSet{
			{ID: "cnip", Name: "国内IP", Type: RuleSetTypeURL, Enabled: true,
				URL: "https://example.com/rule.json", Format: "json"},
		},
		Modes: []Mode{{
			ID: "main",
			Bindings: []RuleBinding{
				{RuleSetID: "cnip", LineID: "my-vpn"},
			},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "main",
	}

	raw, err := GenerateSingBox(profile, 0, "")
	if err != nil {
		t.Fatalf("GenerateSingBox: %v", err)
	}
	var cfg map[string]interface{}
	json.Unmarshal(raw, &cfg)

	rss := cfg["route"].(map[string]interface{})["rule_set"].([]interface{})
	found := false
	for _, rs := range rss {
		rsMap := rs.(map[string]interface{})
		if rsMap["tag"] == "ruleset-cnip" {
			if rsMap["format"] != "source" {
				t.Errorf("expected format=source, got %v", rsMap["format"])
			}
			found = true
		}
	}
	if !found {
		t.Error("ruleset-cnip not found in rule_sets")
	}
}

func TestSmoke_AutoFormat(t *testing.T) {
	ruleSet := &RuleSet{Format: "auto", URL: "https://example.com/geosite-gfw.srs"}
	if f := sbResolveRuleSetFormat(ruleSet); f != "binary" {
		t.Errorf("auto + .srs URL: expected binary, got %s", f)
	}
	ruleSet2 := &RuleSet{Format: "auto", URL: "https://example.com/rule.json"}
	if f := sbResolveRuleSetFormat(ruleSet2); f != "source" {
		t.Errorf("auto + .json URL: expected source, got %s", f)
	}
	ruleSet3 := &RuleSet{Format: "auto", URL: "https://example.com/rule.list"}
	if f := sbResolveRuleSetFormat(ruleSet3); f != "binary" {
		t.Errorf("auto + .list URL: expected binary (default), got %s", f)
	}
}

func TestSmoke_UnsupportedFormatFallsBackSafely(t *testing.T) {
	ruleSet := &RuleSet{Format: "my-custom-format", URL: "https://example.com/rule.bin"}
	if f := sbResolveRuleSetFormat(ruleSet); f != "binary" {
		t.Errorf("unsupported format must not pass through to sing-box, got %s", f)
	}
}

func TestSmoke_URLRuleSetDedup(t *testing.T) {
	profile := &Profile{
		Lines: []Line{
			{ID: "my-vpn", Type: LineTypeVPN, Enabled: true, VPNServer: "vpn.example.com"},
			{ID: "my-trojan", Type: LineTypeTrojan, Enabled: true,
				TrojanServer: "tr.example.com", TrojanPort: 443, TrojanPassword: "p", TrojanSNI: "tr.example.com"},
		},
		RuleSets: []RuleSet{
			{ID: "gfw", Name: "GFW", Type: RuleSetTypeURL, Enabled: true,
				URL: "https://example.com/geosite-gfw.srs", Format: "srs"},
		},
		Modes: []Mode{{
			ID: "main",
			Bindings: []RuleBinding{
				{RuleSetID: "gfw", LineID: "my-vpn"},
			},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "main",
	}

	raw, err := GenerateSingBox(profile, 0, "")
	if err != nil {
		t.Fatalf("GenerateSingBox: %v", err)
	}
	var cfg map[string]interface{}
	json.Unmarshal(raw, &cfg)

	rss := cfg["route"].(map[string]interface{})["rule_set"].([]interface{})
	count := 0
	for _, rs := range rss {
		rsMap := rs.(map[string]interface{})
		if rsMap["tag"] == "ruleset-gfw" {
			count++
		}
	}
	if count != 1 {
		t.Errorf("expected 1 ruleset-gfw, got %d", count)
	}
}

func TestSmoke_DirectBinding(t *testing.T) {
	profile := &Profile{
		Lines: []Line{
			{ID: "direct", Type: LineTypeDirect, Enabled: true},
			{ID: "my-vpn", Type: LineTypeVPN, Enabled: true, VPNServer: "vpn.example.com"},
		},
		RuleSets: []RuleSet{
			{ID: "china", Name: "国内", Type: RuleSetTypeManual, Enabled: true,
				Domains: []string{"baidu.com", "qq.com"}},
		},
		Modes: []Mode{{
			ID: "main",
			Bindings: []RuleBinding{
				{RuleSetID: "china", LineID: "direct"},
			},
			DefaultLineID: "my-vpn",
		}},
		ActiveModeID: "main",
	}

	r := newSmokeRunner(t, profile)
	defer r.stop()

	r.requestAndAssert("baidu.com", "direct")
	r.requestAndAssert("qq.com", "direct")
	r.requestAndAssert("google.com", "vpn")
}

func TestSmoke_NonexistentBinding(t *testing.T) {
	profile := &Profile{
		Lines: []Line{
			{ID: "my-vpn", Type: LineTypeVPN, Enabled: true, VPNServer: "vpn.example.com"},
		},
		RuleSets: []RuleSet{
			{ID: "real", Name: "真实", Type: RuleSetTypeManual, Enabled: true,
				Domains: []string{"real.local"}},
		},
		Modes: []Mode{{
			ID: "main",
			Bindings: []RuleBinding{
				{RuleSetID: "nonexistent-ruleset", LineID: "my-vpn"},
				{RuleSetID: "real", LineID: "nonexistent-line"},
				{RuleSetID: "real", LineID: "my-vpn"},
			},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "main",
	}

	r := newSmokeRunner(t, profile)
	defer r.stop()

	r.requestAndAssert("real.local", "vpn")
}

// --- 订阅分流烟雾测试 ---

func TestSmoke_SubscribeBasic(t *testing.T) {
	// 规则绑定到订阅（无策略组），验证流量走订阅节点
	profile := &Profile{
		Lines: []Line{
			{ID: "my-vpn", Type: LineTypeVPN, Enabled: true, VPNServer: "vpn.example.com"},
		},
		RuleSets: []RuleSet{
			{ID: "gfw", Name: "GFW", Type: RuleSetTypeManual, Enabled: true,
				Domains: []string{"google.com", "youtube.com"}},
		},
		Subscriptions: []Subscription{{
			ID: "sub1", Name: "MySub", URL: "https://example.com/sub",
			Format: "surge", Enabled: true, Strategy: "selector",
			Lines: []Line{
				{ID: "n1", Name: "HK 01", Type: LineTypeTrojan, Enabled: true,
					TrojanServer: "hk1.example.com", TrojanPort: 443,
					TrojanPassword: "p1", TrojanSNI: "hk1.example.com"},
				{ID: "n2", Name: "US 01", Type: LineTypeTrojan, Enabled: true,
					TrojanServer: "us1.example.com", TrojanPort: 443,
					TrojanPassword: "p2", TrojanSNI: "us1.example.com"},
			},
		}},
		Modes: []Mode{{
			ID: "main",
			Bindings: []RuleBinding{
				{RuleSetID: "gfw", SubscriptionID: "sub1"},
			},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "main",
	}

	r := newSmokeRunner(t, profile)
	defer r.stop()

	// 订阅 group 默认为 selector，默认选第一个节点
	r.requestAndAssert("google.com", "proxy-sub1-n1")
	r.requestAndAssert("youtube.com", "proxy-sub1-n1")
	r.requestAndAssert("baidu.com", "direct")
}

func TestSmoke_SubscribeWithGroups(t *testing.T) {
	// 订阅带策略组，验证流量通过策略组路由到正确节点
	profile := &Profile{
		Lines: []Line{
			{ID: "my-vpn", Type: LineTypeVPN, Enabled: true, VPNServer: "vpn.example.com"},
		},
		RuleSets: []RuleSet{
			{ID: "gfw", Name: "GFW", Type: RuleSetTypeManual, Enabled: true,
				Domains: []string{"google.com"}},
			{ID: "streaming", Name: "流媒体", Type: RuleSetTypeManual, Enabled: true,
				Domains: []string{"netflix.com"}},
		},
		Subscriptions: []Subscription{{
			ID: "sub1", Name: "MySub", URL: "https://example.com/sub",
			Format: "surge", Enabled: true, Strategy: "urltest",
			Lines: []Line{
				{ID: "n1", Name: "HK 01", Type: LineTypeTrojan, Enabled: true,
					TrojanServer: "hk1.example.com", TrojanPort: 443,
					TrojanPassword: "p1", TrojanSNI: "hk1.example.com"},
				{ID: "n2", Name: "US 01", Type: LineTypeTrojan, Enabled: true,
					TrojanServer: "us1.example.com", TrojanPort: 443,
					TrojanPassword: "p2", TrojanSNI: "us1.example.com"},
				{ID: "n3", Name: "JP 01", Type: LineTypeTrojan, Enabled: true,
					TrojanServer: "jp1.example.com", TrojanPort: 443,
					TrojanPassword: "p3", TrojanSNI: "jp1.example.com"},
			},
			ProxyGroups: []ProxyGroup{
				{Name: "Proxies", Type: "select", Proxies: []string{"HK 01", "US 01", "JP 01"}},
				{Name: "Streaming", Type: "select", Proxies: []string{"US 01", "JP 01"}},
			},
			Rules: []SubscriptionRule{
				{Type: "DOMAIN-SUFFIX", Value: "netflix.com", Group: "Streaming"},
				{Type: "DOMAIN-SUFFIX", Value: "google.com", Group: "Proxies"},
			},
		}},
		Modes: []Mode{{
			ID: "main",
			Bindings: []RuleBinding{
				{RuleSetID: "gfw", SubscriptionID: "sub1"},
				{RuleSetID: "streaming", SubscriptionID: "sub1"},
			},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "main",
	}

	r := newSmokeRunner(t, profile)
	defer r.stop()

	// google → Proxies 策略组 → 默认第一个节点 HK 01
	r.requestAndAssert("google.com", "proxy-sub1-n1")
	// netflix → Streaming 策略组 → 默认第一个节点 US 01
	r.requestAndAssert("netflix.com", "proxy-sub1-n2")
}

func TestSmoke_SubscribeMixed(t *testing.T) {
	// 同一模式混用手动线路和订阅
	profile := &Profile{
		Lines: []Line{
			{ID: "my-vpn", Type: LineTypeVPN, Enabled: true, VPNServer: "vpn.example.com"},
			{ID: "my-ss", Type: LineTypeShadowsocks, Enabled: true,
				SSServer: "ss.example.com", SSPort: 8388, SSMethod: "aes-256-gcm", SSPass: "secret"},
		},
		RuleSets: []RuleSet{
			{ID: "corp", Name: "公司", Type: RuleSetTypeManual, Enabled: true,
				Domains: []string{"corp.example.com"}},
			{ID: "gfw", Name: "GFW", Type: RuleSetTypeManual, Enabled: true,
				Domains: []string{"google.com"}},
		},
		Subscriptions: []Subscription{{
			ID: "sub1", Name: "MySub", URL: "https://example.com/sub",
			Format: "surge", Enabled: true, Strategy: "selector",
			Lines: []Line{
				{ID: "n1", Name: "HK 01", Type: LineTypeTrojan, Enabled: true,
					TrojanServer: "hk1.example.com", TrojanPort: 443,
					TrojanPassword: "p1", TrojanSNI: "hk1.example.com"},
			},
		}},
		Modes: []Mode{{
			ID: "main",
			Bindings: []RuleBinding{
				{RuleSetID: "corp", LineID: "my-vpn"},      // 手动线路
				{RuleSetID: "gfw", SubscriptionID: "sub1"}, // 订阅
			},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "main",
	}

	r := newSmokeRunner(t, profile)
	defer r.stop()

	// corp 走手动 VPN
	r.requestAndAssert("corp.example.com", "vpn")
	// gfw 走订阅节点
	r.requestAndAssert("google.com", "proxy-sub1-n1")
	// 未匹配走 direct
	r.requestAndAssert("baidu.com", "direct")
}

func TestSmoke_SubscribeDefault(t *testing.T) {
	// 默认出口指向订阅
	profile := &Profile{
		Lines: []Line{
			{ID: "my-vpn", Type: LineTypeVPN, Enabled: true, VPNServer: "vpn.example.com"},
		},
		RuleSets: []RuleSet{
			{ID: "corp", Name: "公司", Type: RuleSetTypeManual, Enabled: true,
				Domains: []string{"corp.example.com"}},
		},
		Subscriptions: []Subscription{{
			ID: "sub1", Name: "MySub", URL: "https://example.com/sub",
			Format: "surge", Enabled: true, Strategy: "selector",
			Lines: []Line{
				{ID: "n1", Name: "HK 01", Type: LineTypeTrojan, Enabled: true,
					TrojanServer: "hk1.example.com", TrojanPort: 443,
					TrojanPassword: "p1", TrojanSNI: "hk1.example.com"},
			},
		}},
		Modes: []Mode{{
			ID: "main",
			Bindings: []RuleBinding{
				{RuleSetID: "corp", LineID: "my-vpn"},
			},
			DefaultSubscriptionID: "sub1",
		}},
		ActiveModeID: "main",
	}

	r := newSmokeRunner(t, profile)
	defer r.stop()

	// 公司域名走 VPN
	r.requestAndAssert("corp.example.com", "vpn")
	// 其他域名默认走订阅
	r.requestAndAssert("google.com", "proxy-sub1-n1")
	r.requestAndAssert("twitter.com", "proxy-sub1-n1")
}

func TestSmoke_SubscribeDisabled(t *testing.T) {
	// 禁用的订阅不参与分流
	profile := &Profile{
		Lines: []Line{
			{ID: "my-vpn", Type: LineTypeVPN, Enabled: true, VPNServer: "vpn.example.com"},
		},
		RuleSets: []RuleSet{
			{ID: "gfw", Name: "GFW", Type: RuleSetTypeManual, Enabled: true,
				Domains: []string{"google.com"}},
		},
		Subscriptions: []Subscription{{
			ID: "sub1", Name: "DisabledSub", URL: "https://example.com/sub",
			Format: "surge", Enabled: false, Strategy: "selector",
			Lines: []Line{
				{ID: "n1", Name: "HK 01", Type: LineTypeTrojan, Enabled: true,
					TrojanServer: "hk1.example.com", TrojanPort: 443,
					TrojanPassword: "p1", TrojanSNI: "hk1.example.com"},
			},
		}},
		Modes: []Mode{{
			ID: "main",
			Bindings: []RuleBinding{
				{RuleSetID: "gfw", SubscriptionID: "sub1"},
			},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "main",
	}

	r := newSmokeRunner(t, profile)
	defer r.stop()

	// 订阅禁用，gfw 无法匹配，走 direct
	r.requestAndAssert("google.com", "direct")
}

func TestSmoke_SubscribeEmptyNodes(t *testing.T) {
	// 订阅无有效节点时回退到 direct
	profile := &Profile{
		Lines: []Line{
			{ID: "my-vpn", Type: LineTypeVPN, Enabled: true, VPNServer: "vpn.example.com"},
		},
		RuleSets: []RuleSet{
			{ID: "gfw", Name: "GFW", Type: RuleSetTypeManual, Enabled: true,
				Domains: []string{"google.com"}},
		},
		Subscriptions: []Subscription{{
			ID: "sub1", Name: "EmptySub", URL: "https://example.com/sub",
			Format: "surge", Enabled: true, Strategy: "urltest",
		}},
		Modes: []Mode{{
			ID: "main",
			Bindings: []RuleBinding{
				{RuleSetID: "gfw", SubscriptionID: "sub1"},
			},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "main",
	}

	r := newSmokeRunner(t, profile)
	defer r.stop()

	r.requestAndAssert("google.com", "direct")
}

func TestSmoke_SubscribeMultiSubscription(t *testing.T) {
	// 多个订阅共存，各自的绑定走各自的节点
	profile := &Profile{
		Lines: []Line{
			{ID: "my-vpn", Type: LineTypeVPN, Enabled: true, VPNServer: "vpn.example.com"},
		},
		RuleSets: []RuleSet{
			{ID: "gfw", Name: "GFW", Type: RuleSetTypeManual, Enabled: true,
				Domains: []string{"google.com"}},
			{ID: "streaming", Name: "流媒体", Type: RuleSetTypeManual, Enabled: true,
				Domains: []string{"netflix.com"}},
		},
		Subscriptions: []Subscription{
			{
				ID: "sub-a", Name: "SubA", URL: "https://a.example.com",
				Format: "surge", Enabled: true, Strategy: "selector",
				Lines: []Line{
					{ID: "n1", Name: "A-HK", Type: LineTypeTrojan, Enabled: true,
						TrojanServer: "a-hk.example.com", TrojanPort: 443,
						TrojanPassword: "p1", TrojanSNI: "a-hk.example.com"},
				},
			},
			{
				ID: "sub-b", Name: "SubB", URL: "https://b.example.com",
				Format: "surge", Enabled: true, Strategy: "selector",
				Lines: []Line{
					{ID: "n1", Name: "B-US", Type: LineTypeShadowsocks, Enabled: true,
						SSServer: "b-us.example.com", SSPort: 8388,
						SSMethod: "aes-256-gcm", SSPass: "secret"},
				},
			},
		},
		Modes: []Mode{{
			ID: "main",
			Bindings: []RuleBinding{
				{RuleSetID: "gfw", SubscriptionID: "sub-a"},
				{RuleSetID: "streaming", SubscriptionID: "sub-b"},
			},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "main",
	}

	r := newSmokeRunner(t, profile)
	defer r.stop()

	r.requestAndAssert("google.com", "proxy-sub-a-n1")
	r.requestAndAssert("netflix.com", "proxy-sub-b-n1")
	r.requestAndAssert("baidu.com", "direct")
}

func TestSmoke_SubscribeUrltest(t *testing.T) {
	// urltest 策略：烟雾测试中 urltest 被转为 selector，默认选第一个节点
	profile := &Profile{
		Lines: []Line{
			{ID: "my-vpn", Type: LineTypeVPN, Enabled: true, VPNServer: "vpn.example.com"},
		},
		RuleSets: []RuleSet{
			{ID: "gfw", Name: "GFW", Type: RuleSetTypeManual, Enabled: true,
				Domains: []string{"google.com"}},
		},
		Subscriptions: []Subscription{{
			ID: "sub1", Name: "UrlTest", URL: "https://example.com/sub",
			Format: "surge", Enabled: true, Strategy: "urltest",
			TestURL: "https://www.gstatic.com/generate_204", TestInterval: 300,
			Lines: []Line{
				{ID: "n1", Name: "HK 01", Type: LineTypeTrojan, Enabled: true,
					TrojanServer: "hk1.example.com", TrojanPort: 443,
					TrojanPassword: "p1", TrojanSNI: "hk1.example.com"},
				{ID: "n2", Name: "US 01", Type: LineTypeTrojan, Enabled: true,
					TrojanServer: "us1.example.com", TrojanPort: 443,
					TrojanPassword: "p2", TrojanSNI: "us1.example.com"},
			},
		}},
		Modes: []Mode{{
			ID: "main",
			Bindings: []RuleBinding{
				{RuleSetID: "gfw", SubscriptionID: "sub1"},
			},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "main",
	}

	r := newSmokeRunner(t, profile)
	defer r.stop()

	r.requestAndAssert("google.com", "proxy-sub1-n1")
}

func TestSmoke_SubscribeMultipleGroups(t *testing.T) {
	// 订阅带多层策略组引用
	profile := &Profile{
		Lines: []Line{
			{ID: "my-vpn", Type: LineTypeVPN, Enabled: true, VPNServer: "vpn.example.com"},
		},
		RuleSets: []RuleSet{
			{ID: "ai", Name: "AI服务", Type: RuleSetTypeManual, Enabled: true,
				Domains: []string{"openai.com", "claude.ai"}},
		},
		Subscriptions: []Subscription{{
			ID: "sub1", Name: "MultiGroup", URL: "https://example.com/sub",
			Format: "surge", Enabled: true, Strategy: "urltest",
			Lines: []Line{
				{ID: "n1", Name: "HK 01", Type: LineTypeTrojan, Enabled: true,
					TrojanServer: "hk1.example.com", TrojanPort: 443,
					TrojanPassword: "p1", TrojanSNI: "hk1.example.com"},
				{ID: "n2", Name: "US 01", Type: LineTypeTrojan, Enabled: true,
					TrojanServer: "us1.example.com", TrojanPort: 443,
					TrojanPassword: "p2", TrojanSNI: "us1.example.com"},
				{ID: "n3", Name: "JP 01", Type: LineTypeTrojan, Enabled: true,
					TrojanServer: "jp1.example.com", TrojanPort: 443,
					TrojanPassword: "p3", TrojanSNI: "jp1.example.com"},
			},
			ProxyGroups: []ProxyGroup{
				{Name: "Proxies", Type: "select", Proxies: []string{"HK 01", "US 01", "JP 01"}},
				{Name: "AI", Type: "url-test", Proxies: []string{"US 01", "JP 01"},
					URL: "https://www.gstatic.com/generate_204", Interval: 300},
				{Name: "Auto", Type: "url-test", Proxies: []string{"AI", "Proxies"}},
			},
		}},
		Modes: []Mode{{
			ID: "main",
			Bindings: []RuleBinding{
				{RuleSetID: "ai", SubscriptionID: "sub1"},
			},
			DefaultLineID: "direct",
		}},
		ActiveModeID: "main",
	}

	r := newSmokeRunner(t, profile)
	defer r.stop()

	// AI 规则绑定到订阅，订阅规则中没有 AI 域名 → 走订阅默认（第一个策略组 Proxies）
	// Proxies 默认 → HK 01
	r.requestAndAssert("openai.com", "proxy-sub1-n1")
	r.requestAndAssert("claude.ai", "proxy-sub1-n1")
}
