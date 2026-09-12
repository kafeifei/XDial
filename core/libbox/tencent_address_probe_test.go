//go:build !windows

package libbox

import (
	"context"
	"crypto/x509"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	C "github.com/sagernet/sing-box/constant"
	M "github.com/sagernet/sing/common/metadata"
	"github.com/sagernet/sing/service"
)

type addressTestDNSRouter struct {
	adapter.DNSRouter
	transport adapter.DNSTransport
}

func (r *addressTestDNSRouter) Lookup(_ context.Context, domain string, opts adapter.DNSQueryOptions) ([]netip.Addr, error) {
	if domain != "r.inews.qq.com" || opts.Transport != r.transport || opts.Strategy != C.DomainStrategyIPv4Only {
		return nil, fmt.Errorf("wrong Line DNS contract")
	}
	return []netip.Addr{netip.MustParseAddr("192.0.2.20")}, nil
}

type addressTestDNSManager struct {
	adapter.DNSTransportManager
	transport adapter.DNSTransport
}

func (m *addressTestDNSManager) Transport(tag string) (adapter.DNSTransport, bool) {
	return m.transport, tag == m.transport.Tag()
}

type addressTestOutbound struct {
	adapter.Outbound
	tag, target string
	dialed      bool
}

func (o *addressTestOutbound) Tag() string { return o.tag }
func (o *addressTestOutbound) DialContext(ctx context.Context, network string, target M.Socksaddr) (net.Conn, error) {
	if target.Addr != netip.MustParseAddr("192.0.2.20") || target.Port != 443 {
		return nil, fmt.Errorf("wrong resolved target")
	}
	o.dialed = true
	return (&net.Dialer{}).DialContext(ctx, network, o.target)
}

func TestTencentProbeUsesSelectedLineDNSAndHTTPS(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("_t") == "" || r.Header.Get("Cache-Control") != "no-cache" {
			t.Error("missing cache isolation")
		}
		fmt.Fprint(w, `{"ret":0,"ip":"8.8.8.8"}`)
	}))
	defer server.Close()
	pool := x509.NewCertPool()
	pool.AddCert(server.Certificate())
	for tag, resolver := range map[string]string{"direct": "xdial-native-dns", "node-a": "proxy-dns-node-a"} {
		t.Run(tag, func(t *testing.T) {
			transport := newFakeMobileDNSTransport(resolver)
			ctx := service.ContextWith[adapter.DNSRouter](context.Background(), &addressTestDNSRouter{transport: transport})
			ctx = service.ContextWith[adapter.DNSTransportManager](ctx, &addressTestDNSManager{transport: transport})
			ctx = service.ContextWith[adapter.CertificateStore](ctx, &outboundTLSProbeTestCertificateStore{pool: pool})
			ctx, cancel := context.WithTimeout(ctx, time.Second)
			defer cancel()
			outbound := &addressTestOutbound{tag: tag, target: server.Listener.Addr().String()}
			endpoint := outboundAddressProbeEndpoint{url: server.URL, destination: M.ParseSocksaddrHostPortStr("r.inews.qq.com", "443")}
			ip, err := probeOutboundAddress(ctx, outbound, endpoint, 1)
			if err != nil || ip != "8.8.8.8" || !outbound.dialed {
				t.Fatalf("probe=%q %v dialed=%v", ip, err, outbound.dialed)
			}
			// A resolver belonging to another Line must never be borrowed as fallback.
			outbound.tag = "other-line"
			outbound.dialed = false
			_, err = probeOutboundAddress(ctx, outbound, endpoint, 1)
			if outboundProbeCode := outboundAddressProbeSafeCode(err); outboundProbeCode != "dns-unavailable" || outbound.dialed {
				t.Fatalf("cross-Line DNS fallback: %v, dialed=%v", err, outbound.dialed)
			}
		})
	}
}
