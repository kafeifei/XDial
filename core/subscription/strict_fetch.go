package subscription

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strings"
	"time"
)

type strictLookupFunc func(context.Context, string, string) ([]netip.Addr, error)
type strictDialFunc func(context.Context, string, string) (net.Conn, error)

var carrierGradeNAT = netip.MustParsePrefix("100.64.0.0/10")

var strictRemoteHTTPClient = newStrictRemoteHTTPClient()

func newStrictRemoteHTTPClient() *http.Client {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	// 严格链路必须直接校验并拨目标地址；经过环境代理会把校验对象变成代理本身。
	transport.Proxy = nil
	transport.DialContext = newStrictDialContext(
		net.DefaultResolver.LookupNetIP,
		(&net.Dialer{Timeout: 15 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
	)
	return &http.Client{
		Transport:     transport,
		Timeout:       30 * time.Second,
		CheckRedirect: strictRedirectPolicy,
	}
}

func strictRedirectPolicy(req *http.Request, via []*http.Request) error {
	if len(via) >= 10 {
		return fmt.Errorf("too many redirects")
	}
	return validateStrictRemoteURL(req.URL.String())
}

func fetchStrictWithContext(ctx context.Context, rawURL string) (string, error) {
	return fetchStrictWithContextLimit(ctx, rawURL, maxRemoteContentBytes)
}

func fetchStrictWithContextLimit(ctx context.Context, rawURL string, maxBytes int64) (string, error) {
	if err := validateStrictRemoteURL(rawURL); err != nil {
		return "", err
	}
	return fetchWithClientLimit(ctx, rawURL, strictRemoteHTTPClient, maxBytes)
}

// FetchStrictBytes 给移动配置生成器复用同一套 HTTPS、逐跳重定向、DNS 全结果和
// 数值地址固定拨号边界。string 在 Go 中可无损承载任意字节，这里再转回 []byte，
// 因而同时适用于 JSON 与二进制 SRS。
func FetchStrictBytes(rawURL string, maxBytes int64) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	content, err := fetchStrictWithContextLimit(ctx, rawURL, maxBytes)
	if err != nil {
		return nil, err
	}
	return []byte(content), nil
}

func validateStrictRemoteURL(rawURL string) error {
	parsed, err := url.Parse(rawURL)
	if err != nil || parsed.Scheme != "https" || parsed.Hostname() == "" {
		return fmt.Errorf("remote address must use HTTPS")
	}
	host := strings.ToLower(parsed.Hostname())
	if host == "localhost" || strings.HasSuffix(host, ".localhost") || strings.HasSuffix(host, ".local") {
		return fmt.Errorf("remote address is not allowed")
	}
	if ip, err := netip.ParseAddr(host); err == nil && forbiddenRemoteIP(ip) {
		return fmt.Errorf("remote address is not allowed")
	}
	return nil
}

func newStrictDialContext(lookup strictLookupFunc, dial strictDialFunc) strictDialFunc {
	return func(ctx context.Context, network, address string) (net.Conn, error) {
		host, port, err := net.SplitHostPort(address)
		if err != nil {
			return nil, fmt.Errorf("remote address is invalid")
		}
		addresses, err := lookup(ctx, "ip", host)
		if err != nil || len(addresses) == 0 {
			return nil, fmt.Errorf("remote host could not be resolved")
		}

		for _, address := range addresses {
			if forbiddenRemoteIP(address) {
				return nil, fmt.Errorf("remote address is not allowed")
			}
		}

		var lastError error
		for _, resolved := range addresses {
			resolved = resolved.Unmap()
			if strings.HasSuffix(network, "4") && !resolved.Is4() {
				continue
			}
			if strings.HasSuffix(network, "6") && !resolved.Is6() {
				continue
			}
			connection, dialError := dial(ctx, network, net.JoinHostPort(resolved.String(), port))
			if dialError == nil {
				return connection, nil
			}
			lastError = dialError
		}
		if lastError != nil {
			return nil, fmt.Errorf("remote host could not be reached")
		}
		return nil, fmt.Errorf("remote host has no compatible address")
	}
}

func forbiddenRemoteIP(address netip.Addr) bool {
	address = address.Unmap()
	return !address.IsValid() || !address.IsGlobalUnicast() || address.IsPrivate() || carrierGradeNAT.Contains(address)
}
