//go:build !windows

package libbox

import (
	"context"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"net/http"
	"net/http/httptest"
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
