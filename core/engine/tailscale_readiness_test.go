package engine

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/kafeifei/xdial/core/config"
)

func TestRuntimeLineTagUsesGeneratedCatalog(t *testing.T) {
	profile := &config.Profile{
		Lines: []config.Line{
			{ID: "direct", Name: "Direct", Type: config.LineTypeDirect, Enabled: true},
			{ID: "tail", Name: "Tailnet", Type: config.LineTypeTailscale, Enabled: true},
		},
	}

	tag, ok := runtimeLineTag(profile, "tail")
	if !ok || tag != "tailscale-tail" {
		t.Fatalf("runtimeLineTag = %q, %v; want tailscale-tail, true", tag, ok)
	}
	if _, ok := runtimeLineTag(profile, "missing"); ok {
		t.Fatal("missing line unexpectedly has a runtime tag")
	}
}

func TestWaitForOutboundEgressRetriesUntilRealProbeSucceeds(t *testing.T) {
	var attempts atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/proxies/tailscale-tail/delay" {
			t.Errorf("path = %q", request.URL.Path)
		}
		if request.URL.Query().Get("url") != "https://www.gstatic.com/generate_204" {
			t.Errorf("url = %q", request.URL.Query().Get("url"))
		}
		if request.URL.Query().Get("timeout") != "50" {
			t.Errorf("timeout = %q", request.URL.Query().Get("timeout"))
		}
		if attempts.Add(1) < 3 {
			http.Error(w, "not ready", http.StatusServiceUnavailable)
			return
		}
		_, _ = fmt.Fprint(w, `{"delay":42}`)
	}))
	defer server.Close()

	err := waitForOutboundEgress(
		context.Background(),
		server.Client(),
		server.URL,
		"tailscale-tail",
		time.Second,
		50*time.Millisecond,
		time.Millisecond,
	)
	if err != nil {
		t.Fatalf("waitForOutboundEgress: %v", err)
	}
	if got := attempts.Load(); got != 3 {
		t.Fatalf("attempts = %d, want 3", got)
	}
}

func TestWaitForOutboundEgressRejectsMalformedSuccess(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = fmt.Fprint(w, `{"delay":0}`)
	}))
	defer server.Close()

	err := waitForOutboundEgress(
		context.Background(),
		server.Client(),
		server.URL,
		"tailscale-tail",
		25*time.Millisecond,
		5*time.Millisecond,
		time.Millisecond,
	)
	if err == nil {
		t.Fatal("malformed success unexpectedly became ready")
	}
}

func TestWaitForOutboundEgressHonorsCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	err := waitForOutboundEgress(
		ctx,
		http.DefaultClient,
		"http://127.0.0.1:1",
		"tailscale-tail",
		time.Second,
		50*time.Millisecond,
		time.Millisecond,
	)
	if err != context.Canceled {
		t.Fatalf("error = %v, want context.Canceled", err)
	}
}
