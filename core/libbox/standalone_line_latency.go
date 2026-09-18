//go:build !windows

package libbox

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/kafeifei/xdial/core/config"
	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/common/urltest"
	"github.com/sagernet/sing-box/option"
	jsonext "github.com/sagernet/sing/common/json"
)

const lineLatencyTestURL = "https://www.gstatic.com/generate_204"

// ProbeStandaloneLineLatency is an explicit, bounded diagnostic session. It has
// no ingress, routing rules, persistent cache, VPN/Tailscale identity, or access
// to the running Libbox. Only the selected proxy and one HTTP(S) request exist.
func ProbeStandaloneLineLatency(lineJSON string, timeoutMS int) (string, error) {
	return ProbeStandaloneLineLatencyAtURL(lineJSON, lineLatencyTestURL, timeoutMS)
}

// ProbeStandaloneLineLatencyAtURL uses the group test target when invoked there.
func ProbeStandaloneLineLatencyAtURL(lineJSON, target string, timeoutMS int) (string, error) {
	if target == "" {
		target = lineLatencyTestURL
	}
	if !validLatencyTestURL(target) {
		return "", fmt.Errorf("测速地址必须是有效的 HTTP 或 HTTPS URL")
	}
	if len(lineJSON) > 1024*1024 {
		return "", fmt.Errorf("线路配置过大")
	}
	var line config.Line
	if json.Unmarshal([]byte(lineJSON), &line) != nil {
		return "", fmt.Errorf("线路配置无效")
	}
	options, err := standaloneLineProbeOptions(&line)
	if err != nil {
		return "", err
	}
	return probeStandaloneLineLatency(&line, options, target, timeoutMS)
}

func standaloneLineProbeOptions(line *config.Line) (map[string]interface{}, error) {
	var outbound map[string]interface{}
	switch line.Type {
	case config.LineTypeDirect:
		outbound = map[string]interface{}{"type": "direct"}
	case config.LineTypeTrojan, config.LineTypeShadowsocks, config.LineTypeVMess, config.LineTypeAnyTLS:
		outbound = config.LineOutbound(line)
	default:
		return nil, fmt.Errorf("此线路需要使用已连接场景测速")
	}
	if outbound == nil {
		return nil, fmt.Errorf("线路配置不完整，无法测速")
	}
	outbound["tag"] = "measurement"
	return map[string]interface{}{
		"log":       map[string]interface{}{"disabled": true},
		"dns":       map[string]interface{}{"servers": []interface{}{map[string]interface{}{"type": "local", "tag": "underlay"}}},
		"outbounds": []interface{}{outbound},
		"route":     map[string]interface{}{"final": "measurement", "default_domain_resolver": "underlay"},
	}, nil
}

func probeStandaloneLineLatency(line *config.Line, document map[string]interface{}, target string, timeoutMS int) (string, error) {
	if timeoutMS < 500 {
		timeoutMS = 500
	}
	if timeoutMS > 10000 {
		timeoutMS = 10000
	}
	parent, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMS)*time.Millisecond)
	defer cancel()
	ctx := boxContext(parent)
	raw, err := json.Marshal(document)
	if err != nil {
		return "", fmt.Errorf("线路配置无效")
	}
	options, err := jsonext.UnmarshalExtendedContext[option.Options](ctx, raw)
	if err != nil {
		return "", fmt.Errorf("线路配置无法用于测速")
	}
	instance, err := box.New(box.Options{Options: options, Context: ctx})
	if err != nil {
		return "", fmt.Errorf("无法创建线路测速会话")
	}
	defer instance.Close()
	if err = instance.Start(); err != nil {
		return "", fmt.Errorf("无法启动线路测速会话")
	}
	outbound, exists := instance.Outbound().Outbound("measurement")
	if !exists {
		return "", fmt.Errorf("测速线路不可用")
	}
	delay, err := urltest.URLTest(ctx, target, outbound)
	if err != nil {
		if ctx.Err() != nil {
			return "", fmt.Errorf("测速超时")
		}
		return "", fmt.Errorf("线路连接或测速请求失败")
	}
	ms := int(delay)
	raw, err = json.Marshal(lineLatencyFact{LineID: line.ID, Milliseconds: &ms, ObservedAt: time.Now().UnixMilli()})
	return string(raw), err
}
