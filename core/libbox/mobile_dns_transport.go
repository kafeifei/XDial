//go:build !windows

package libbox

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/dns"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing/service"

	mDNS "github.com/miekg/dns"
)

const typeMobileDNS = "xdial-mobile"

var (
	errMobileDNSAmbiguous = errors.New("mobile DNS ownership is ambiguous")
	errMobileDNSFailed    = errors.New("mobile DNS query failed")
)

type mobileDNSServerOptions struct {
	Tailscale      []mobileTailscaleDNSBinding `json:"tailscale,omitempty"`
	PublicFallback string                      `json:"public_fallback,omitempty"`
}

type mobileTailscaleDNSBinding struct {
	Endpoint string `json:"endpoint"`
	Server   string `json:"server"`
}

type mobileDNSOwner interface {
	claimedSuffixes() []string
}

type runtimeMobileDNSBinding struct {
	owner     mobileDNSOwner
	transport adapter.DNSTransport
}

type mobileDNSExchanger interface {
	Exchange(context.Context, *mDNS.Msg) (*mDNS.Msg, error)
}

// mobileDNSTransport 在一个合成系统 DNS 入口后面合并三种解析来源：
// Tailscale 分域、AnyConnect 企业 DNS、standalone 公共 DNS。内部域一旦归属
// 某个 Tailscale endpoint，就绝不降级到其他 resolver。
type mobileDNSTransport struct {
	dns.TransportAdapter

	endpointManager  adapter.EndpointManager
	transportManager adapter.DNSTransportManager
	options          mobileDNSServerOptions

	bindings       []runtimeMobileDNSBinding
	publicFallback adapter.DNSTransport
	// enterpriseRequired 只由 VPNBridge 是否存在决定，不由握手是否下发 DNS
	// 决定。这样空 resolver 也会 fail closed，而不会落到公共 DNS。
	enterpriseRequired bool
	enterprise         mobileDNSExchanger
}

func registerMobileDNSTransport(registry *dns.TransportRegistry) {
	dns.RegisterTransport[mobileDNSServerOptions](registry, typeMobileDNS, newMobileDNSTransport)
}

func newMobileDNSTransport(
	ctx context.Context,
	_ log.ContextLogger,
	tag string,
	options mobileDNSServerOptions,
) (adapter.DNSTransport, error) {
	if strings.TrimSpace(options.PublicFallback) == "" {
		return nil, fmt.Errorf("mobile DNS public fallback is missing")
	}
	dependencies := make([]string, 0, len(options.Tailscale)+1)
	seenDependencies := make(map[string]bool)
	addDependency := func(value string) {
		if value == "" || seenDependencies[value] {
			return
		}
		seenDependencies[value] = true
		dependencies = append(dependencies, value)
	}
	addDependency(options.PublicFallback)
	for _, binding := range options.Tailscale {
		if strings.TrimSpace(binding.Endpoint) == "" || strings.TrimSpace(binding.Server) == "" {
			return nil, fmt.Errorf("mobile DNS Tailscale binding is incomplete")
		}
		addDependency(binding.Server)
	}

	endpointManager := service.FromContext[adapter.EndpointManager](ctx)
	transportManager := service.FromContext[adapter.DNSTransportManager](ctx)
	if endpointManager == nil || transportManager == nil {
		return nil, fmt.Errorf("mobile DNS runtime is unavailable")
	}

	transport := &mobileDNSTransport{
		TransportAdapter: dns.NewTransportAdapter(typeMobileDNS, tag, dependencies),
		endpointManager:  endpointManager,
		transportManager: transportManager,
		options:          options,
	}
	if line := service.FromContext[*anyConnectLineRuntime](ctx); line != nil {
		// Bridge 存在就保持企业 DNS 的 fail-closed 语义。即便服务端没有
		// 下发 resolver，也安装一个空 exchanger，让查询在运行时明确失败；
		// 不能因为 resolver 列表为空而旁路到公共 DNS。
		transport.enterpriseRequired = true
		transport.enterprise = line
	}
	return transport, nil
}

func (t *mobileDNSTransport) Start(stage adapter.StartStage) error {
	if stage != adapter.StartStateInitialize {
		return nil
	}
	publicFallback, loaded := t.transportManager.Transport(t.options.PublicFallback)
	if !loaded {
		return fmt.Errorf("mobile DNS public fallback is unavailable")
	}
	bindings := make([]runtimeMobileDNSBinding, 0, len(t.options.Tailscale))
	for _, binding := range t.options.Tailscale {
		owner, err := newMobileDNSOwner(t.endpointManager, binding.Endpoint)
		if err != nil {
			return fmt.Errorf("mobile DNS Tailscale endpoint is unavailable")
		}
		dnsTransport, loaded := t.transportManager.Transport(binding.Server)
		if !loaded {
			return fmt.Errorf("mobile DNS Tailscale resolver is unavailable")
		}
		bindings = append(bindings, runtimeMobileDNSBinding{
			owner:     owner,
			transport: dnsTransport,
		})
	}
	t.publicFallback = publicFallback
	t.bindings = bindings
	return nil
}

func (t *mobileDNSTransport) Close() error {
	t.bindings = nil
	t.publicFallback = nil
	return nil
}

// 依赖 transport 由 sing-box 的 TransportManager 统一 reset，这里不重复关闭连接。
func (t *mobileDNSTransport) Reset() {}

func (t *mobileDNSTransport) Exchange(ctx context.Context, message *mDNS.Msg) (*mDNS.Msg, error) {
	if message == nil || len(message.Question) != 1 {
		return nil, os.ErrInvalid
	}
	selected, err := selectMobileDNSTransport(t.bindings, message.Question[0].Name)
	if err != nil {
		return nil, err
	}
	if selected != nil {
		response, exchangeErr := selected.Exchange(ctx, message)
		if exchangeErr != nil {
			return nil, errMobileDNSFailed
		}
		return response, nil
	}
	if t.enterpriseRequired || t.enterprise != nil {
		if t.enterprise == nil {
			return nil, errMobileDNSFailed
		}
		response, exchangeErr := t.enterprise.Exchange(ctx, message)
		if exchangeErr != nil {
			return nil, errMobileDNSFailed
		}
		return response, nil
	}
	if t.publicFallback == nil {
		return nil, errMobileDNSFailed
	}
	response, exchangeErr := t.publicFallback.Exchange(ctx, message)
	if exchangeErr != nil {
		return nil, errMobileDNSFailed
	}
	return response, nil
}

func (t *mobileDNSTransport) ExchangeAsync(
	ctx context.Context,
	message *mDNS.Msg,
	callback func(response *mDNS.Msg, err error),
) {
	go func() {
		response, err := t.Exchange(ctx, message)
		callback(response, err)
	}()
}

func selectMobileDNSTransport(
	bindings []runtimeMobileDNSBinding,
	queryName string,
) (adapter.DNSTransport, error) {
	queryName = normalizeMobileDNSName(queryName)
	if queryName == "" {
		return nil, nil
	}

	longestMatch := -1
	var selected adapter.DNSTransport
	var selectedOwner mobileDNSOwner
	for _, binding := range bindings {
		if binding.owner == nil || binding.transport == nil {
			continue
		}
		for _, suffix := range normalizeMobileDNSSuffixes(binding.owner.claimedSuffixes()) {
			if !mobileDNSNameMatchesSuffix(queryName, suffix) {
				continue
			}
			matchLength := len(suffix)
			switch {
			case matchLength > longestMatch:
				longestMatch = matchLength
				selected = binding.transport
				selectedOwner = binding.owner
			case matchLength == longestMatch && selectedOwner != binding.owner:
				return nil, errMobileDNSAmbiguous
			}
		}
	}
	return selected, nil
}

func normalizeMobileDNSSuffixes(values []string) []string {
	seen := make(map[string]bool)
	result := make([]string, 0, len(values))
	for _, value := range values {
		value = normalizeMobileDNSName(value)
		// 根域表示接管所有解析，会破坏企业 DNS 与 standalone fallback。
		if value == "" || value == "." || seen[value] {
			continue
		}
		seen[value] = true
		result = append(result, value)
	}
	return result
}

func normalizeMobileDNSName(value string) string {
	return strings.ToLower(strings.TrimSuffix(strings.TrimSpace(value), "."))
}

func mobileDNSNameMatchesSuffix(name, suffix string) bool {
	return name == suffix || strings.HasSuffix(name, "."+suffix)
}

var _ adapter.DNSTransport = (*mobileDNSTransport)(nil)
