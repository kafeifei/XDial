package subscription

import (
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/kafeifei/xdial/core/config"
)

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

func fetch(url string) (string, error) {
	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("HTTP %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
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
