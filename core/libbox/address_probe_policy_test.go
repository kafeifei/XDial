//go:build !windows

package libbox

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
)

func TestAddressRaceHedgesAndCancelsLoser(t *testing.T) {
	endpoints := outboundAddressProbeEndpointsByFamily["ipv4"]
	var cancelled atomic.Bool
	start := time.Now()
	probe := func(ctx context.Context, _ adapter.Outbound, endpoint outboundAddressProbeEndpoint, _ int) (string, error) {
		if endpoint.url == endpoints[0].url {
			<-ctx.Done()
			cancelled.Store(true)
			return "", ctx.Err()
		}
		if time.Since(start) < 450*time.Millisecond {
			t.Error("hedge launched before 500ms delay")
		}
		return "8.8.8.8", nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	ip, winner, err := raceOutboundAddresses(ctx, nil, endpoints, "ipv4", "", probe, nil)
	if err != nil || ip != "8.8.8.8" || winner != endpoints[1].url || !cancelled.Load() {
		t.Fatalf("race = %s %s %v, loser stopped=%v", ip, winner, err, cancelled.Load())
	}
}

func TestAddressRaceImmediateFailureAndPreferredFastSuccess(t *testing.T) {
	endpoints := outboundAddressProbeEndpointsByFamily["ipv4"]
	var calls []string
	probe := func(_ context.Context, _ adapter.Outbound, e outboundAddressProbeEndpoint, _ int) (string, error) {
		calls = append(calls, e.url)
		if e.url == endpoints[0].url {
			return "", fmt.Errorf("failed")
		}
		return "8.8.8.8", nil
	}
	started := time.Now()
	_, winner, err := raceOutboundAddresses(context.Background(), nil, endpoints, "ipv4", "", probe, nil)
	if err != nil || len(calls) != 2 || time.Since(started) > 400*time.Millisecond {
		t.Fatalf("failure did not fall back immediately: %v %v", calls, err)
	}
	policy := newAddressProbePolicy()
	policy.remember("direct/ipv4", winner)
	if policy.preference("other/ipv4") != "" || policy.preference("direct/ipv6") != "" {
		t.Fatal("preference leaked between Lines/families")
	}
	calls = nil
	_, _, err = raceOutboundAddresses(context.Background(), nil, endpoints, "ipv4", policy.preference("direct/ipv4"), probe, nil)
	if err != nil || len(calls) != 1 || calls[0] != endpoints[1].url {
		t.Fatalf("preferred service not reused: %v %v", calls, err)
	}
}

func TestAddressServiceRateAndCircuitBounds(t *testing.T) {
	p := newAddressProbePolicy()
	now := time.Now()
	service := "tencent/ipv4"
	for i := 0; i < 3; i++ {
		at := now.Add(time.Duration(i) * time.Second)
		if !p.admit(service, at) || p.admit(service, at.Add(999*time.Millisecond)) {
			t.Fatal("one-second rate gate failed")
		}
		p.finish(service, true, at)
	}
	if p.admit(service, now.Add(31*time.Second)) {
		t.Fatal("circuit reopened too soon")
	}
	if !p.admit(service, now.Add(32*time.Second)) {
		t.Fatal("circuit did not recover")
	}
	p.finish(service, false, now.Add(32*time.Second))
	if !p.admit(service, now.Add(33*time.Second)) {
		t.Fatal("success did not reset failure history")
	}
	if !p.admit("cloudflare/ipv4", now) {
		t.Fatal("Tencent failure blocked Cloudflare")
	}
	for i := 0; i < 20; i++ {
		p.finish(service, true, now)
	}
	if p.admit(service, now.Add(299*time.Second)) || !p.admit(service, now.Add(300*time.Second)) {
		t.Fatal("backoff must cap at five minutes")
	}
}

func TestAddressRaceGlobalConcurrencyAndNoCancelledFailure(t *testing.T) {
	p := newAddressProbePolicy()
	var active, peak atomic.Int32
	var wg sync.WaitGroup
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	timer := time.AfterFunc(650*time.Millisecond, cancel)
	defer timer.Stop()
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, _, _ = raceOutboundAddresses(ctx, nil, outboundAddressProbeEndpointsByFamily["ipv4"], "ipv4", "", func(ctx context.Context, _ adapter.Outbound, _ outboundAddressProbeEndpoint, _ int) (string, error) {
				n := active.Add(1)
				defer active.Add(-1)
				for old := peak.Load(); n > old; old = peak.Load() {
					if peak.CompareAndSwap(old, n) {
						break
					}
				}
				<-ctx.Done()
				return "", ctx.Err()
			}, p)
		}()
	}
	wg.Wait()
	if peak.Load() > 2 || active.Load() != 0 {
		t.Fatalf("concurrency peak=%d active=%d", peak.Load(), active.Load())
	}
	for _, state := range p.services {
		if state.failures != 0 {
			t.Fatal("cancellation counted as provider failure")
		}
	}
}

func TestTencentProbeResponseValidation(t *testing.T) {
	ip, err := parseTencentProbeAddress([]byte(`{"ret":0,"ip":"8.8.8.8"}`))
	if err != nil || ip != "8.8.8.8" {
		t.Fatalf("valid response = %q %v", ip, err)
	}
	for _, body := range []string{`{}`, `{"ip":"8.8.8.8"}`, `{"ret":1,"ip":"8.8.8.8"}`, `{"ret":0,"ip":"127.0.0.1"}`, `{"ret":0,"ip":"192.168.1.1"}`, `<html>error</html>`} {
		if _, err := parseTencentProbeAddress([]byte(body)); err == nil {
			t.Fatalf("accepted %s", body)
		}
	}
}

func TestAddressRaceRejectsWrongFamilyBeforeWinner(t *testing.T) {
	_, _, err := raceOutboundAddresses(context.Background(), nil, outboundAddressProbeEndpointsByFamily["ipv4"], "ipv4", "", func(context.Context, adapter.Outbound, outboundAddressProbeEndpoint, int) (string, error) {
		return "2606:4700::1111", nil
	}, nil)
	if err == nil || !strings.Contains(err.Error(), "wrong-family") {
		t.Fatalf("accepted wrong family: %v", err)
	}
}

func TestAddressRaceTimeoutCountsTowardCircuit(t *testing.T) {
	p := newAddressProbePolicy()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	_, _, _ = raceOutboundAddresses(ctx, nil, outboundAddressProbeEndpointsByFamily["ipv4"], "ipv4", "", func(ctx context.Context, _ adapter.Outbound, _ outboundAddressProbeEndpoint, _ int) (string, error) {
		<-ctx.Done()
		return "", ctx.Err()
	}, p)
	if p.services["cloudflare/ipv4"].failures != 1 {
		t.Fatal("timeout did not count as service failure")
	}
}
