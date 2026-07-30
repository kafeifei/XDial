package engine

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/kafeifei/xdial/core/config"
)

const (
	tailscaleEgressReadyBudget  = 20 * time.Second
	tailscaleEgressProbeTimeout = 2500 * time.Millisecond
	tailscaleEgressPollInterval = 200 * time.Millisecond
	clashAPIBaseURL             = "http://127.0.0.1:9090"
)

type outboundDelayResponse struct {
	Delay int `json:"delay"`
}

// waitForActiveTailscaleEgress keeps the Engine in Connecting until the external
// sing-box process proves that its freshly restored Tailscale endpoint can carry
// real traffic through the selected Exit Node.
//
// The setup session and the data-plane process use the same persistent identity
// sequentially, but they are two different tsnet runtimes. A Running setup
// session therefore does not imply that the subsequent sing-box endpoint has
// already restored its overlay address. Treating process spawn as readiness used
// to produce "Connected" while every matching request failed with no Tailscale
// address.
//
// Clash API's delay endpoint is a structured sing-box interface and performs the
// request through the named outbound itself. Do not replace this with log-text
// matching: logs are diagnostic evidence, not a lifecycle protocol.
func waitForActiveTailscaleEgress(ctx context.Context, profile *config.Profile) error {
	line, err := config.ActiveTailscaleLine(profile)
	if err != nil {
		return fmt.Errorf("检查 Tailscale 线路失败: %w", err)
	}
	if line == nil {
		return nil
	}

	tag, ok := runtimeLineTag(profile, line.ID)
	if !ok {
		return fmt.Errorf("Tailscale 线路缺少运行时出口")
	}

	client := &http.Client{
		Transport: &http.Transport{Proxy: nil},
	}
	if err := waitForOutboundEgress(
		ctx,
		client,
		clashAPIBaseURL,
		tag,
		tailscaleEgressReadyBudget,
		tailscaleEgressProbeTimeout,
		tailscaleEgressPollInterval,
	); err != nil {
		return fmt.Errorf("Tailscale 出口未就绪，请检查 Exit Node 是否在线: %w", err)
	}
	return nil
}

func runtimeLineTag(profile *config.Profile, lineID string) (string, bool) {
	for _, member := range config.BuildLineRuntimeCatalog(profile).Lines {
		if member.ID == lineID {
			return member.Tag, true
		}
	}
	return "", false
}

func waitForOutboundEgress(
	ctx context.Context,
	client *http.Client,
	baseURL string,
	tag string,
	budget time.Duration,
	probeTimeout time.Duration,
	pollInterval time.Duration,
) error {
	waitCtx, cancel := context.WithTimeout(ctx, budget)
	defer cancel()

	var lastErr error
	for {
		if err := probeOutboundEgress(waitCtx, client, baseURL, tag, probeTimeout); err == nil {
			slog.Info("outbound egress ready", "tag", tag)
			return nil
		} else {
			lastErr = err
		}

		timer := time.NewTimer(pollInterval)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-waitCtx.Done():
			timer.Stop()
			if ctx.Err() != nil {
				return ctx.Err()
			}
			slog.Warn("outbound egress readiness timed out", "tag", tag, "last_error", lastErr)
			return fmt.Errorf("%s 内没有通过真实流量探测", budget.Round(time.Second))
		case <-timer.C:
		}
	}
}

func probeOutboundEgress(
	ctx context.Context,
	client *http.Client,
	baseURL string,
	tag string,
	timeout time.Duration,
) error {
	endpoint, err := url.Parse(strings.TrimRight(baseURL, "/") + "/proxies/" + url.PathEscape(tag) + "/delay")
	if err != nil {
		return err
	}
	query := endpoint.Query()
	query.Set("url", "https://www.gstatic.com/generate_204")
	query.Set("timeout", fmt.Sprintf("%d", timeout.Milliseconds()))
	endpoint.RawQuery = query.Encode()

	requestCtx, cancel := context.WithTimeout(ctx, timeout+500*time.Millisecond)
	defer cancel()
	request, err := http.NewRequestWithContext(requestCtx, http.MethodGet, endpoint.String(), nil)
	if err != nil {
		return err
	}
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
		return fmt.Errorf("Clash API 返回 HTTP %d", response.StatusCode)
	}

	var payload outboundDelayResponse
	if err := json.NewDecoder(io.LimitReader(response.Body, 4096)).Decode(&payload); err != nil {
		return fmt.Errorf("解析就绪应答: %w", err)
	}
	if payload.Delay <= 0 {
		return fmt.Errorf("就绪应答缺少有效延迟")
	}
	return nil
}
