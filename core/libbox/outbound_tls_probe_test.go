//go:build !windows

package libbox

import (
	"context"
	"crypto/x509"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	M "github.com/sagernet/sing/common/metadata"
	"github.com/sagernet/sing/service"
)

type outboundTLSProbeTestOutbound struct {
	dial         func(context.Context, string, M.Socksaddr) (net.Conn, error)
	mu           sync.Mutex
	destinations []M.Socksaddr
}

func (o *outboundTLSProbeTestOutbound) Type() string { return "test" }

func (o *outboundTLSProbeTestOutbound) Tag() string { return "test" }

func (o *outboundTLSProbeTestOutbound) Network() []string {
	return []string{"tcp"}
}

func (o *outboundTLSProbeTestOutbound) Dependencies() []string { return nil }

func (o *outboundTLSProbeTestOutbound) DialContext(
	ctx context.Context,
	network string,
	destination M.Socksaddr,
) (net.Conn, error) {
	o.mu.Lock()
	o.destinations = append(o.destinations, destination)
	o.mu.Unlock()
	return o.dial(ctx, network, destination)
}

func (o *outboundTLSProbeTestOutbound) ListenPacket(
	context.Context,
	M.Socksaddr,
) (net.PacketConn, error) {
	return nil, errors.New("packet connections are unsupported")
}

func (o *outboundTLSProbeTestOutbound) recordedDestinations() []M.Socksaddr {
	o.mu.Lock()
	defer o.mu.Unlock()
	return append([]M.Socksaddr(nil), o.destinations...)
}

type outboundTLSProbeTestCertificateStore struct {
	pool *x509.CertPool
}

func (s *outboundTLSProbeTestCertificateStore) Name() string { return "test" }

func (s *outboundTLSProbeTestCertificateStore) Start(adapter.StartStage) error {
	return nil
}

func (s *outboundTLSProbeTestCertificateStore) Close() error { return nil }

func (s *outboundTLSProbeTestCertificateStore) Pool() *x509.CertPool {
	return s.pool
}

func (s *outboundTLSProbeTestCertificateStore) ExclusiveAnchors() bool {
	return true
}

func newOutboundTLSProbeTestServer(
	t *testing.T,
) (*httptest.Server, string, *x509.CertPool) {
	t.Helper()
	server := httptest.NewUnstartedServer(
		http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}),
	)
	server.Config.ErrorLog = log.New(io.Discard, "", 0)
	server.StartTLS()
	t.Cleanup(server.Close)

	certificate := server.Certificate()
	serverName := ""
	if len(certificate.DNSNames) != 0 {
		serverName = certificate.DNSNames[0]
	} else if len(certificate.IPAddresses) != 0 {
		serverName = certificate.IPAddresses[0].String()
	}
	if serverName == "" {
		t.Fatal("test server certificate has no verifiable name")
	}
	pool := x509.NewCertPool()
	pool.AddCert(certificate)
	return server, serverName, pool
}

func redirectOutboundTLSProbeTo(
	t *testing.T,
	address string,
) *outboundTLSProbeTestOutbound {
	t.Helper()
	return &outboundTLSProbeTestOutbound{
		dial: func(
			ctx context.Context,
			network string,
			_ M.Socksaddr,
		) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, address)
		},
	}
}

func TestFixedOutboundTLSProbeTargetsMatchLineDoHTransports(t *testing.T) {
	if len(fixedOutboundTLSProbeTargets.ipv4) != 1 ||
		len(fixedOutboundTLSProbeTargets.ipv6) != 1 {
		t.Fatalf(
			"fixed target counts = IPv4 %d, IPv6 %d",
			len(fixedOutboundTLSProbeTargets.ipv4),
			len(fixedOutboundTLSProbeTargets.ipv6),
		)
	}
	if got := fixedOutboundTLSProbeTargets.ipv4[0]; got.address.String() != "1.1.1.1" || got.serverName != "one.one.one.one" {
		t.Fatalf("IPv4 probe target does not match Line DoH: %+v", got)
	}
	if got := fixedOutboundTLSProbeTargets.ipv6[0]; got.address.String() != "2606:4700:4700::1111" || got.serverName != "one.one.one.one" {
		t.Fatalf("IPv6 probe target does not match Line DoH: %+v", got)
	}
	for family, targets := range map[string][]outboundTLSProbeTarget{
		"ipv4": fixedOutboundTLSProbeTargets.ipv4,
		"ipv6": fixedOutboundTLSProbeTargets.ipv6,
	} {
		for _, target := range targets {
			if !target.address.IsValid() || target.port != 443 ||
				target.serverName == "" {
				t.Fatalf("invalid %s target: %+v", family, target)
			}
			if family == "ipv4" && !target.address.Is4() {
				t.Fatalf("IPv4 target is not IPv4: %s", target.address)
			}
			if family == "ipv6" && !target.address.Is6() {
				t.Fatalf("IPv6 target is not IPv6: %s", target.address)
			}
			destination := M.SocksaddrFrom(target.address, target.port)
			if !destination.IsIP() || destination.IsDomain() {
				t.Fatalf("target became a domain destination: %+v", destination)
			}
		}
	}
}

func TestOutboundTLSProbeAuthenticatesWithoutResolvingSNI(t *testing.T) {
	server, serverName, pool := newOutboundTLSProbeTestServer(t)
	outbound := redirectOutboundTLSProbeTo(t, server.Listener.Addr().String())
	targets := outboundTLSProbeTargetSet{
		ipv4: []outboundTLSProbeTarget{
			{address: netip.MustParseAddr("192.0.2.1"), port: 443, serverName: serverName},
			{address: netip.MustParseAddr("192.0.2.2"), port: 443, serverName: serverName},
		},
		ipv6: []outboundTLSProbeTarget{
			{address: netip.MustParseAddr("2001:db8::1"), port: 443, serverName: serverName},
			{address: netip.MustParseAddr("2001:db8::2"), port: 443, serverName: serverName},
		},
	}
	ctx := service.ContextWith[adapter.CertificateStore](
		context.Background(),
		&outboundTLSProbeTestCertificateStore{pool: pool},
	)
	capabilities := probeOutboundTLSCapabilitiesWithTargets(ctx, outbound, targets)
	for family, capability := range map[string]outboundTLSFamilyCapability{
		"ipv4": capabilities.IPv4,
		"ipv6": capabilities.IPv6,
	} {
		if !capability.Available || capability.Attempts != 2 ||
			capability.TCPConnected != 2 || capability.TLSAuthenticated != 2 ||
			len(capability.FailureCodes) != 0 {
			t.Fatalf("%s capability = %+v", family, capability)
		}
	}

	recorded := outbound.recordedDestinations()
	if len(recorded) != 4 {
		t.Fatalf("recorded destinations = %d", len(recorded))
	}
	wantAddresses := map[netip.Addr]bool{
		netip.MustParseAddr("192.0.2.1"):   true,
		netip.MustParseAddr("192.0.2.2"):   true,
		netip.MustParseAddr("2001:db8::1"): true,
		netip.MustParseAddr("2001:db8::2"): true,
	}
	for _, destination := range recorded {
		if destination.IsDomain() || !wantAddresses[destination.Addr] ||
			destination.Port != 443 {
			t.Fatalf("outbound received non-literal target: %+v", destination)
		}
		delete(wantAddresses, destination.Addr)
	}
	if len(wantAddresses) != 0 {
		t.Fatalf("outbound did not receive targets: %v", wantAddresses)
	}
}

func TestOutboundTLSProbeClassifiesZeroBytePeerClose(t *testing.T) {
	outbound := &outboundTLSProbeTestOutbound{
		dial: func(
			context.Context,
			string,
			M.Socksaddr,
		) (net.Conn, error) {
			client, peer := net.Pipe()
			go func() {
				defer peer.Close()
				buffer := make([]byte, 4096)
				_, _ = peer.Read(buffer)
			}()
			return client, nil
		},
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	result := probeOutboundTLSAttempt(ctx, outbound, outboundTLSProbeTarget{
		address:    netip.MustParseAddr("192.0.2.1"),
		port:       443,
		serverName: "example.com",
	})
	if !result.tcpConnected || result.tlsAuthenticated ||
		result.failureCode != outboundTLSFailurePeerClosed {
		t.Fatalf("peer-close result = %+v", result)
	}
}

func TestOutboundTLSProbeClassifiesCertificateFailure(t *testing.T) {
	server, serverName, _ := newOutboundTLSProbeTestServer(t)
	outbound := redirectOutboundTLSProbeTo(t, server.Listener.Addr().String())
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	result := probeOutboundTLSAttempt(ctx, outbound, outboundTLSProbeTarget{
		address:    netip.MustParseAddr("192.0.2.1"),
		port:       443,
		serverName: serverName,
	})
	if !result.tcpConnected || result.tlsAuthenticated ||
		result.failureCode != outboundTLSFailureAuthentication {
		t.Fatalf("authentication-failure result = %+v", result)
	}
}

func TestOutboundTLSProbeDoesNotExposeDialError(t *testing.T) {
	outbound := &outboundTLSProbeTestOutbound{
		dial: func(
			context.Context,
			string,
			M.Socksaddr,
		) (net.Conn, error) {
			return nil, errors.New("secret upstream failure")
		},
	}
	targets := outboundTLSProbeTargetSet{
		ipv4: []outboundTLSProbeTarget{{
			address:    netip.MustParseAddr("192.0.2.1"),
			port:       443,
			serverName: "example.com",
		}},
		ipv6: []outboundTLSProbeTarget{{
			address:    netip.MustParseAddr("2001:db8::1"),
			port:       443,
			serverName: "example.com",
		}},
	}
	capabilities := probeOutboundTLSCapabilitiesWithTargets(
		context.Background(),
		outbound,
		targets,
	)
	encoded, err := marshalOutboundTLSCapabilities(capabilities)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(encoded, "secret") {
		t.Fatalf("probe leaked dial error: %s", encoded)
	}
	for family, capability := range map[string]outboundTLSFamilyCapability{
		"ipv4": capabilities.IPv4,
		"ipv6": capabilities.IPv6,
	} {
		if capability.FailureCodes[outboundTLSFailureTCPConnect] != 1 {
			t.Fatalf("%s capability = %+v", family, capability)
		}
	}
}

func TestProbeOutboundTLSCapabilitiesReturnsCurrentGenerationResult(
	t *testing.T,
) {
	instance := New(nil)
	instance.platform.setDefaultInterface("test0", 1)
	if err := instance.StartStandalone(outboundProbeTestConfig); err != nil {
		t.Fatal(err)
	}
	defer instance.Stop()
	want := outboundTLSCapabilities{
		IPv4: outboundTLSFamilyCapability{
			Available:        true,
			Attempts:         2,
			TCPConnected:     2,
			TLSAuthenticated: 1,
			FailureCodes: map[string]int{
				outboundTLSFailurePeerClosed: 1,
			},
		},
		IPv6: outboundTLSFamilyCapability{
			Attempts:     2,
			TCPConnected: 1,
			FailureCodes: map[string]int{
				outboundTLSFailurePeerClosed: 1,
				outboundTLSFailureTCPConnect: 1,
			},
		},
	}
	instance.probeOutboundTLSCapabilitiesFunc = func(
		context.Context,
		adapter.Outbound,
	) outboundTLSCapabilities {
		return want
	}

	encoded, err := instance.ProbeOutboundTLSCapabilities("direct", 500)
	if err != nil {
		t.Fatal(err)
	}
	var got outboundTLSCapabilities
	if err := json.Unmarshal([]byte(encoded), &got); err != nil {
		t.Fatalf("decode result: %v", err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("capabilities = %+v, want %+v", got, want)
	}
}

func TestProbeOutboundTLSCapabilitiesStopCancelsAndWaitsForLease(
	t *testing.T,
) {
	instance := New(nil)
	instance.platform.setDefaultInterface("test0", 1)
	if err := instance.StartStandalone(outboundProbeTestConfig); err != nil {
		t.Fatal(err)
	}
	defer instance.Stop()

	entered := make(chan struct{})
	cancelled := make(chan struct{})
	release := make(chan struct{})
	instance.probeOutboundTLSCapabilitiesFunc = func(
		ctx context.Context,
		_ adapter.Outbound,
	) outboundTLSCapabilities {
		close(entered)
		<-ctx.Done()
		close(cancelled)
		<-release
		return outboundTLSCapabilities{
			IPv4: newOutboundTLSFamilyCapability(2),
			IPv6: newOutboundTLSFamilyCapability(2),
		}
	}

	probeDone := make(chan error, 1)
	go func() {
		_, err := instance.ProbeOutboundTLSCapabilities("direct", 10_000)
		probeDone <- err
	}()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("outbound TLS probe did not start")
	}

	stopDone := make(chan error, 1)
	go func() { stopDone <- instance.Stop() }()
	select {
	case <-cancelled:
	case <-time.After(time.Second):
		t.Fatal("Stop did not cancel the outbound TLS probe")
	}
	select {
	case err := <-stopDone:
		t.Fatalf("Stop returned before the probe released its lease: %v", err)
	case <-time.After(50 * time.Millisecond):
	}

	close(release)
	select {
	case err := <-probeDone:
		if err == nil || !strings.Contains(err.Error(), "connection changed") {
			t.Fatalf("stale TLS probe result was accepted: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("stale outbound TLS probe did not finish")
	}
	select {
	case err := <-stopDone:
		if err != nil {
			t.Fatalf("Stop: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("Stop did not finish after the probe released its lease")
	}
}

func TestProbePreparedSwitchOutboundTLSCapabilitiesUsesCandidate(
	t *testing.T,
) {
	instance := New(nil)
	instance.platform.setDefaultInterface("test0", 1)
	if err := instance.StartStandalone(outboundProbeTestConfig); err != nil {
		t.Fatal(err)
	}
	defer instance.Stop()
	if err := prepareSwitchForTest(instance, outboundProbeTestConfig, ""); err != nil {
		t.Fatal(err)
	}
	defer instance.AbortPreparedSwitch()
	want := outboundTLSCapabilities{
		IPv4: newOutboundTLSFamilyCapability(2),
		IPv6: newOutboundTLSFamilyCapability(2),
	}
	want.IPv6.Available = true
	want.IPv6.TCPConnected = 2
	want.IPv6.TLSAuthenticated = 1
	want.IPv6.FailureCodes[outboundTLSFailurePeerClosed] = 1
	instance.probeOutboundTLSCapabilitiesFunc = func(
		context.Context,
		adapter.Outbound,
	) outboundTLSCapabilities {
		return want
	}

	encoded, err := instance.ProbePreparedSwitchOutboundTLSCapabilities(
		"direct",
		500,
	)
	if err != nil {
		t.Fatal(err)
	}
	var got outboundTLSCapabilities
	if err := json.Unmarshal([]byte(encoded), &got); err != nil {
		t.Fatalf("decode result: %v", err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("capabilities = %+v, want %+v", got, want)
	}
}
