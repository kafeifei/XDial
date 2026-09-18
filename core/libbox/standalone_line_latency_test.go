//go:build !windows

package libbox

import (
	"context"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"net"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/kafeifei/xdial/core/config"
	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/adapter/inbound"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing-box/protocol/trojan"
	jsonext "github.com/sagernet/sing/common/json"
	"github.com/sagernet/sing/service"
)

func TestStandaloneLatencyTraversesAuthenticatedProxyAndHTTPS(t *testing.T) {
	var hits atomic.Int32
	target := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodHead {
			t.Error("expected HEAD")
		}
		hits.Add(1)
		time.Sleep(60 * time.Millisecond)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer target.Close()
	cert := string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: target.Certificate().Raw}))
	key, err := x509.MarshalPKCS8PrivateKey(target.TLS.Certificates[0].PrivateKey)
	if err != nil {
		t.Fatal(err)
	}
	keyPEM := string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: key}))
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	_ = listener.Close()
	ctx := boxContext(context.Background())
	// The production host registers outbounds only. This test-only peer is a real
	// native Trojan server on loopback, not a delay stub or a TCP ping responder.
	registry := service.FromContext[adapter.InboundRegistry](ctx)
	trojan.RegisterInbound(registry.(*inbound.Registry))
	proxyConfig := map[string]interface{}{
		"log": map[string]interface{}{"disabled": true},
		"inbounds": []interface{}{map[string]interface{}{
			"type": "trojan", "tag": "peer", "listen": "127.0.0.1", "listen_port": port,
			"users": []interface{}{map[string]interface{}{"name": "fixture", "password": "correct-test-password"}},
			"tls":   map[string]interface{}{"enabled": true, "certificate": []string{cert}, "key": []string{keyPEM}},
		}},
		"outbounds": []interface{}{map[string]interface{}{"type": "direct", "tag": "target"}},
		"route":     map[string]interface{}{"final": "target"},
	}
	raw, _ := json.Marshal(proxyConfig)
	opts, err := jsonext.UnmarshalExtendedContext[option.Options](ctx, raw)
	if err != nil {
		t.Fatal(err)
	}
	peer, err := box.New(box.Options{Options: opts, Context: ctx})
	if err != nil {
		t.Fatal(err)
	}
	defer peer.Close()
	if err = peer.Start(); err != nil {
		t.Fatal(err)
	}
	line := config.Line{ID: "proxy", Type: config.LineTypeTrojan, Enabled: true,
		TrojanServer: "127.0.0.1", TrojanPort: port, TrojanPassword: "correct-test-password", AllowInsecure: true}
	document, err := standaloneLineProbeOptions(&line)
	if err != nil {
		t.Fatal(err)
	}
	document["certificate"] = map[string]interface{}{"certificate": []string{cert}}
	measured, err := probeStandaloneLineLatency(&line, document, target.URL, 2000)
	if err != nil {
		t.Fatal(err)
	}
	var fact lineLatencyFact
	if json.Unmarshal([]byte(measured), &fact) != nil || fact.Milliseconds == nil || *fact.Milliseconds < 60 || fact.ObservedAt == 0 || hits.Load() != 1 {
		t.Fatalf("not a measured HTTPS result: %s hits=%d", measured, hits.Load())
	}
	// A bypass, fabricated success, or a plain TCP port check would succeed with
	// the wrong proxy password; the HTTPS request must not reach the target.
	line.TrojanPassword = "wrong-test-password"
	document, _ = standaloneLineProbeOptions(&line)
	document["certificate"] = map[string]interface{}{"certificate": []string{cert}}
	measured, err = probeStandaloneLineLatency(&line, document, target.URL, 500)
	if err == nil || measured != "" || hits.Load() != 1 {
		t.Fatalf("bad credentials produced a latency: %s, %v", measured, err)
	}
}

func TestStandaloneLatencyHasNoIngressOrOtherResourceSession(t *testing.T) {
	for _, kind := range []config.LineType{config.LineTypeVPN, config.LineTypeTailscale, config.LineTypeSelector, config.LineTypeURLTest} {
		if _, err := standaloneLineProbeOptions(&config.Line{Type: kind}); err == nil {
			t.Fatalf("unexpected capability %s", kind)
		}
	}
	document, err := standaloneLineProbeOptions(&config.Line{ID: "direct", Type: config.LineTypeDirect})
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"inbounds", "endpoints", "experimental", "services"} {
		if document[key] != nil {
			t.Fatalf("standalone test created %s", key)
		}
	}
	route := document["route"].(map[string]interface{})
	if len(route) != 2 || route["final"] != "measurement" {
		t.Fatal("unexpected routing surface")
	}
	if _, err = ProbeStandaloneLineLatency(`{"id":"invalid","type":"anytls"}`, 500); err == nil {
		t.Fatal("incomplete proxy got a result")
	}
}

func TestStandaloneLatencyTimeoutDoesNotProduceMilliseconds(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	done := make(chan struct{})
	defer close(done)
	go func() {
		connection, err := listener.Accept()
		if err != nil {
			return
		}
		defer connection.Close()
		<-done
	}()
	line := config.Line{ID: "direct", Type: config.LineTypeDirect}
	document, _ := standaloneLineProbeOptions(&line)
	start := time.Now()
	value, err := probeStandaloneLineLatency(&line, document, "https://"+listener.Addr().String(), 500)
	if err == nil || value != "" {
		t.Fatalf("timeout produced success: %s %v", value, err)
	}
	if time.Since(start) > 2*time.Second {
		t.Fatal("probe ignored deadline")
	}
}
