//go:build !windows

package libbox

import (
	"context"
	"fmt"

	"github.com/kafeifei/xdial/core/engine"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/dns"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing/service"

	mDNS "github.com/miekg/dns"
)

const typeAnyConnectDNS = "xdial-anyconnect"

type anyConnectDNSServerOptions struct{}

// anyConnectDNSTransport 只承载显式绑定到 AnyConnect Line 的域名。
// 它没有公共或系统 fallback：企业 resolver 不可用时必须明确失败。
type anyConnectDNSTransport struct {
	dns.TransportAdapter
	exchanger mobileDNSExchanger
}

func registerAnyConnectDNSTransport(registry *dns.TransportRegistry) {
	dns.RegisterTransport[anyConnectDNSServerOptions](
		registry,
		typeAnyConnectDNS,
		newAnyConnectDNSTransport,
	)
}

func newAnyConnectDNSTransport(
	ctx context.Context,
	_ log.ContextLogger,
	tag string,
	_ anyConnectDNSServerOptions,
) (adapter.DNSTransport, error) {
	bridge := service.FromContext[*engine.VPNBridge](ctx)
	servers := snapshotTunnelDNS()
	if bridge == nil || len(servers) == 0 {
		return nil, fmt.Errorf("AnyConnect DNS transport is unavailable")
	}
	return &anyConnectDNSTransport{
		TransportAdapter: dns.NewTransportAdapter(typeAnyConnectDNS, tag, nil),
		exchanger:        newBridgeDNSExchanger(bridge, servers),
	}, nil
}

func (t *anyConnectDNSTransport) Start(adapter.StartStage) error {
	return nil
}

func (t *anyConnectDNSTransport) Close() error {
	t.exchanger = nil
	return nil
}

func (t *anyConnectDNSTransport) Reset() {}

func (t *anyConnectDNSTransport) Exchange(
	ctx context.Context,
	message *mDNS.Msg,
) (*mDNS.Msg, error) {
	if t.exchanger == nil {
		return nil, errMobileDNSFailed
	}
	response, err := t.exchanger.Exchange(ctx, message)
	if err != nil {
		return nil, errMobileDNSFailed
	}
	return response, nil
}

func (t *anyConnectDNSTransport) ExchangeAsync(
	ctx context.Context,
	message *mDNS.Msg,
	callback func(response *mDNS.Msg, err error),
) {
	go func() {
		response, err := t.Exchange(ctx, message)
		callback(response, err)
	}()
}

var _ adapter.DNSTransport = (*anyConnectDNSTransport)(nil)
