//go:build !windows

package libbox

import (
	"context"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	M "github.com/sagernet/sing/common/metadata"
)

const outboundProbeTestConfig = `{
	"log":{"disabled":true},
	"outbounds":[{"type":"direct","tag":"direct"}],
	"route":{"final":"direct"}
}`

func TestProbeOutboundIPStopCancelsAndWaitsForProbeLease(
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
	instance.probeOutboundAddressFunc = func(
		ctx context.Context,
		_ adapter.Outbound,
		_ outboundAddressProbeEndpoint,
		_ int,
	) (string, error) {
		close(entered)
		<-ctx.Done()
		close(cancelled)
		<-release
		// Deliberately return a seemingly valid old result after cancellation.
		// The generation gate, not this test double, must reject it.
		return "203.0.113.9", nil
	}

	probeDone := make(chan error, 1)
	go func() {
		_, err := instance.ProbeOutboundIP("direct", 10_000)
		probeDone <- err
	}()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("outbound probe did not start")
	}

	stopDone := make(chan error, 1)
	go func() {
		stopDone <- instance.Stop()
	}()
	select {
	case <-cancelled:
	case <-time.After(time.Second):
		t.Fatal("Stop did not cancel the running outbound probe")
	}
	select {
	case err := <-stopDone:
		t.Fatalf(
			"Stop returned before the borrowed outbound was released: %v",
			err,
		)
	case <-time.After(50 * time.Millisecond):
	}

	close(release)
	select {
	case err := <-probeDone:
		if err == nil ||
			!strings.Contains(err.Error(), "connection changed") {
			t.Fatalf("stale probe result was accepted: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("stale outbound probe did not finish")
	}
	select {
	case err := <-stopDone:
		if err != nil {
			t.Fatalf("Stop: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("Stop did not finish after the probe released its lease")
	}

	if err := instance.StartStandalone(outboundProbeTestConfig); err != nil {
		t.Fatalf("start next generation: %v", err)
	}
}

func TestProbeOutboundIPReturnsCurrentGenerationResult(t *testing.T) {
	instance := New(nil)
	instance.platform.setDefaultInterface("test0", 1)
	if err := instance.StartStandalone(outboundProbeTestConfig); err != nil {
		t.Fatal(err)
	}
	defer instance.Stop()
	instance.probeOutboundAddressFunc = func(
		context.Context,
		adapter.Outbound,
		outboundAddressProbeEndpoint,
		int,
	) (string, error) {
		return "203.0.113.9", nil
	}

	address, err := instance.ProbeOutboundIP("direct", 500)
	if err != nil {
		t.Fatal(err)
	}
	if address != "203.0.113.9" {
		t.Fatalf("probe address = %q", address)
	}
}

func TestProbeOutboundIPForFamilyEndpointContract(t *testing.T) {
	v4 := outboundAddressProbeEndpointsByFamily["ipv4"]
	if len(v4) != 2 || v4[0].destination.Addr != netip.MustParseAddr("1.1.1.1") ||
		v4[1].url != "https://r.inews.qq.com/api/ip2city" || v4[1].destination.Fqdn != "r.inews.qq.com" {
		t.Fatalf("unexpected IPv4 endpoints: %+v", v4)
	}
	for _, endpoint := range outboundAddressProbeEndpointsByFamily["ipv6"] {
		if !endpoint.destination.Addr.Is6() || endpoint.destination.Port != 443 {
			t.Fatalf("unverified IPv6 endpoint: %+v", endpoint)
		}
	}
}

func TestProbeOutboundIPForFamilyFallsBackAndRejectsWrongFamily(t *testing.T) {
	addressProbePolicy = newAddressProbePolicy()
	t.Cleanup(func() { addressProbePolicy = newAddressProbePolicy() })
	instance := New(nil)
	instance.platform.setDefaultInterface("test0", 1)
	if err := instance.StartStandalone(outboundProbeTestConfig); err != nil {
		t.Fatal(err)
	}
	defer instance.Stop()

	var attempts []string
	instance.probeOutboundAddressFunc = func(
		_ context.Context,
		_ adapter.Outbound,
		endpoint outboundAddressProbeEndpoint,
		_ int,
	) (string, error) {
		attempts = append(attempts, endpoint.url)
		if len(attempts) == 1 {
			return "", fmt.Errorf("temporary failure")
		}
		return "2606:4700:4700::1111", nil
	}

	address, _, err := raceOutboundAddresses(context.Background(), nil, outboundAddressProbeEndpointsByFamily["ipv6"], "ipv6", "", instance.probeOutboundAddressFunc, nil)
	if err != nil {
		t.Fatal(err)
	}
	if address != "2606:4700:4700::1111" || len(attempts) != 2 {
		t.Fatalf("fallback result = (%q, %d attempts)", address, len(attempts))
	}

	attempts = nil
	instance.probeOutboundAddressFunc = func(
		_ context.Context,
		_ adapter.Outbound,
		endpoint outboundAddressProbeEndpoint,
		_ int,
	) (string, error) {
		attempts = append(attempts, endpoint.url)
		return "8.8.8.8", nil
	}
	_, _, err = raceOutboundAddresses(context.Background(), nil, outboundAddressProbeEndpointsByFamily["ipv6"], "ipv6", "", instance.probeOutboundAddressFunc, nil)
	if err == nil || !strings.Contains(err.Error(), "ipv6-endpoint-1-wrong-family") {
		t.Fatalf("wrong-family result was accepted: %v", err)
	}
	if len(attempts) != 2 {
		t.Fatalf("wrong-family fallback attempts = %d", len(attempts))
	}
}

func TestProbeOutboundIPForFamilyAggregatesOnlySafeStageCodes(t *testing.T) {
	addressProbePolicy = newAddressProbePolicy()
	t.Cleanup(func() { addressProbePolicy = newAddressProbePolicy() })
	instance := New(nil)
	instance.platform.setDefaultInterface("test0", 1)
	if err := instance.StartStandalone(outboundProbeTestConfig); err != nil {
		t.Fatal(err)
	}
	defer instance.Stop()

	attempt := 0
	instance.probeOutboundAddressFunc = func(
		context.Context,
		adapter.Outbound,
		outboundAddressProbeEndpoint,
		int,
	) (string, error) {
		attempt++
		code := "dial-failed"
		if attempt == 2 {
			code = "http-status-403"
		}
		return "", newOutboundAddressProbeError(
			code,
			fmt.Errorf("sensitive underlying detail %d", attempt),
		)
	}

	_, err := instance.ProbeOutboundIPForFamily("direct", "ipv4", 500)
	if err == nil {
		t.Fatal("family probe unexpectedly succeeded")
	}
	want := "outbound address probe failed: ipv4-endpoint-1-dial-failed; ipv4-endpoint-2-http-status-403"
	if err.Error() != want {
		t.Fatalf("family probe error = %q, want %q", err, want)
	}
	if strings.Contains(err.Error(), "sensitive") {
		t.Fatalf("family probe leaked underlying error: %v", err)
	}
}

func TestProbeOutboundIPLegacyKeepsDetailedErrors(t *testing.T) {
	instance := New(nil)
	instance.platform.setDefaultInterface("test0", 1)
	if err := instance.StartStandalone(outboundProbeTestConfig); err != nil {
		t.Fatal(err)
	}
	defer instance.Stop()
	instance.probeOutboundAddressFunc = func(
		context.Context,
		adapter.Outbound,
		outboundAddressProbeEndpoint,
		int,
	) (string, error) {
		return "", fmt.Errorf("legacy detailed error")
	}

	_, err := instance.ProbeOutboundIP("direct", 500)
	if err == nil || !strings.Contains(err.Error(), "legacy detailed error") {
		t.Fatalf("legacy probe error changed: %v", err)
	}
}

func TestProbeOutboundIPForFamilyRejectsUnknownFamily(t *testing.T) {
	instance := New(nil)
	_, err := instance.ProbeOutboundIPForFamily("direct", "IPv4", 500)
	if err == nil || !strings.Contains(err.Error(), "must be ipv4 or ipv6") {
		t.Fatalf("unknown family error = %v", err)
	}
}

func TestProbeOutboundIPForFamilyStopCancelsAndWaitsForProbeLease(t *testing.T) {
	addressProbePolicy = newAddressProbePolicy()
	t.Cleanup(func() { addressProbePolicy = newAddressProbePolicy() })
	instance := New(nil)
	instance.platform.setDefaultInterface("test0", 1)
	if err := instance.StartStandalone(outboundProbeTestConfig); err != nil {
		t.Fatal(err)
	}

	entered := make(chan struct{})
	release := make(chan struct{})
	instance.probeOutboundAddressFunc = func(
		ctx context.Context,
		_ adapter.Outbound,
		_ outboundAddressProbeEndpoint,
		_ int,
	) (string, error) {
		close(entered)
		<-ctx.Done()
		<-release
		return "8.8.8.8", nil
	}

	probeDone := make(chan error, 1)
	go func() {
		_, err := instance.ProbeOutboundIPForFamily("direct", "ipv4", 10_000)
		probeDone <- err
	}()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("family probe did not start")
	}

	stopDone := make(chan error, 1)
	go func() { stopDone <- instance.Stop() }()
	select {
	case err := <-stopDone:
		t.Fatalf("Stop returned before the family probe released its lease: %v", err)
	case <-time.After(50 * time.Millisecond):
	}
	close(release)
	select {
	case err := <-probeDone:
		if err == nil || !strings.Contains(err.Error(), "connection changed") {
			t.Fatalf("stale family probe result was accepted: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("family probe did not finish")
	}
	select {
	case err := <-stopDone:
		if err != nil {
			t.Fatalf("Stop: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("Stop did not finish after the family probe released its lease")
	}
}

func TestProbeOutboundIPRealDirectHTTPSCancelsBeforeBoxClose(
	t *testing.T,
) {
	requestEntered := make(chan struct{})
	releaseHandler := make(chan struct{})
	var releaseOnce sync.Once
	server := httptest.NewUnstartedServer(
		http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
			select {
			case <-requestEntered:
			default:
				close(requestEntered)
			}
			<-releaseHandler
			writer.WriteHeader(http.StatusOK)
			_, _ = fmt.Fprintln(writer, "203.0.113.9")
		}),
	)
	server.StartTLS()
	defer func() {
		releaseOnce.Do(func() { close(releaseHandler) })
		server.Close()
	}()

	certificatePEM := pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE",
		Bytes: server.Certificate().Raw,
	})
	configJSON, err := json.Marshal(map[string]any{
		"log": map[string]any{"disabled": true},
		"certificate": map[string]any{
			"store":       "none",
			"certificate": string(certificatePEM),
		},
		"outbounds": []map[string]any{
			{"type": "direct", "tag": "direct"},
		},
		"route": map[string]any{"final": "direct"},
	})
	if err != nil {
		t.Fatal(err)
	}

	originalEndpoints := outboundAddressProbeEndpoints
	outboundAddressProbeEndpoints = []outboundAddressProbeEndpoint{{
		url:         server.URL,
		destination: M.ParseSocksaddr(server.Listener.Addr().String()),
	}}
	defer func() {
		outboundAddressProbeEndpoints = originalEndpoints
	}()

	instance := New(nil)
	instance.platform.setDefaultInterface("test0", 1)
	if err := instance.StartStandalone(string(configJSON)); err != nil {
		t.Fatal(err)
	}

	probeDone := make(chan error, 1)
	go func() {
		_, err := instance.ProbeOutboundIP("direct", 10_000)
		probeDone <- err
	}()
	select {
	case <-requestEntered:
	case <-time.After(2 * time.Second):
		t.Fatal("real direct outbound did not reach the local HTTPS server")
	}

	stopDone := make(chan error, 1)
	go func() {
		stopDone <- instance.Stop()
	}()
	select {
	case err := <-probeDone:
		if err == nil ||
			!strings.Contains(err.Error(), "connection changed") {
			t.Fatalf("cancelled direct probe returned %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("runtime cancellation did not stop the direct HTTPS probe")
	}
	select {
	case err := <-stopDone:
		if err != nil {
			t.Fatalf("Stop: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Stop did not finish after the direct probe was cancelled")
	}
	releaseOnce.Do(func() { close(releaseHandler) })
}
