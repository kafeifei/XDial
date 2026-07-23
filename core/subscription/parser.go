package subscription

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/kafeifei/xdial/core/config"
)

const maxRemoteContentBytes int64 = 10 * 1024 * 1024

var remoteHTTPClient = &http.Client{Timeout: 30 * time.Second}

type ParseResult struct {
	Lines       []config.Line             `json:"lines"`
	ProxyGroups []config.ProxyGroup       `json:"proxy_groups,omitempty"`
	Rules       []config.SubscriptionRule `json:"rules,omitempty"`
}

func Parse(url, content, format string) (*ParseResult, error) {
	if content == "" && url != "" {
		var err error
		content, err = fetch(url)
		if err != nil {
			return nil, fmt.Errorf("fetch: %w", err)
		}
	}
	if content == "" {
		return nil, fmt.Errorf("empty subscription content")
	}

	if format == "" || format == "auto" {
		format = detect(content)
	}

	switch format {
	case "clash":
		return parseClash(content)
	case "surge":
		return parseSurge(content)
	case "base64":
		lines, err := parseBase64(content)
		if err != nil {
			return nil, err
		}
		return &ParseResult{Lines: lines}, nil
	default:
		return nil, fmt.Errorf("unknown format: %s", format)
	}
}

// ParseStrict 用于移动端远程导入。它只替换下载链路，解析语义仍复用 Parse，
// 因此不会改变 macOS/CLI 现有允许的本地测试和兼容行为。
func ParseStrict(url, content, format string) (*ParseResult, error) {
	if content == "" && url != "" {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		var err error
		content, err = fetchStrictWithContext(ctx, url)
		if err != nil {
			return nil, fmt.Errorf("fetch: %w", err)
		}
	}
	return Parse("", content, format)
}

func fetch(url string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	return fetchWithContext(ctx, url)
}

func fetchWithContext(ctx context.Context, url string) (string, error) {
	return fetchWithClient(ctx, url, remoteHTTPClient)
}

func fetchWithClient(ctx context.Context, url string, client *http.Client) (string, error) {
	return fetchWithClientLimit(ctx, url, client, maxRemoteContentBytes)
}

func fetchWithClientLimit(ctx context.Context, url string, client *http.Client, maxBytes int64) (string, error) {
	if maxBytes < 0 || maxBytes > maxRemoteContentBytes {
		maxBytes = maxRemoteContentBytes
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("HTTP %d", resp.StatusCode)
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxBytes+1))
	if err != nil {
		return "", err
	}
	if int64(len(body)) > maxBytes {
		return "", fmt.Errorf("remote content exceeds allowed size")
	}
	return string(body), nil
}

func detect(content string) string {
	trimmed := strings.TrimSpace(content)
	if strings.Contains(trimmed, "proxies:") {
		return "clash"
	}
	if strings.Contains(trimmed, "[Proxy]") {
		return "surge"
	}
	return "base64"
}
