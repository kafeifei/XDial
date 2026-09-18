//go:build !windows

package libbox

import (
	"context"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/urltest"
	"github.com/sagernet/sing-box/option"
	jsonext "github.com/sagernet/sing/common/json"
	"github.com/sagernet/sing/service"
)

func latencyTestBox(t *testing.T, certificate string) *Libbox {
	t.Helper()
	ctx := boxContext(context.Background())
	raw := `{"outbounds":[{"type":"direct","tag":"a"},{"type":"direct","tag":"b"},{"type":"selector","tag":"inner","outbounds":["a","b"],"default":"b"},{"type":"selector","tag":"outer","outbounds":["inner","a"],"default":"inner"}],"route":{"final":"outer"}}`
	var fields map[string]interface{}
	_ = json.Unmarshal([]byte(raw), &fields)
	if certificate != "" {
		fields["certificate"] = map[string]interface{}{"certificate": []string{certificate}}
	}
	encoded, _ := json.Marshal(fields)
	opts, err := jsonext.UnmarshalExtendedContext[option.Options](ctx, encoded)
	if err != nil {
		t.Fatal(err)
	}
	instance, err := box.New(box.Options{Options: opts, Context: ctx})
	if err != nil {
		t.Fatal(err)
	}
	if err = instance.Start(); err != nil {
		_ = instance.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = instance.Close() })
	return &Libbox{box: instance, running: true, runtimeCtx: ctx, boxGeneration: 1}
}

func TestLineLatencySnapshotUsesActualNestedChoiceAndIsolatesGenerations(t *testing.T) {
	runtime := latencyTestBox(t, "")
	history := service.PtrFromContext[urltest.HistoryStorage](runtime.runtimeCtx)
	history.StoreURLTestHistory("a", &adapter.URLTestHistory{Time: time.Now(), Delay: 10})
	history.StoreURLTestHistory("b", &adapter.URLTestHistory{Time: time.Now(), Delay: 80})
	result, err := runtime.LineLatencySnapshot(`{"line-a":"a","line-b":"b","group":"outer"}`)
	if err != nil {
		t.Fatal(err)
	}
	var facts []lineLatencyFact
	if err = json.Unmarshal([]byte(result), &facts); err != nil {
		t.Fatal(err)
	}
	if len(facts) != 3 || facts[0].SelectedLineID != "line-b" || *facts[0].Milliseconds != 80 {
		t.Fatalf("snapshot must reflect pinned B, not fastest A: %s", result)
	}
	other := service.PtrFromContext[urltest.HistoryStorage](boxContext(runtime.runtimeCtx))
	if history != service.PtrFromContext[urltest.HistoryStorage](runtime.runtimeCtx) {
		t.Fatal("candidate replaced active history")
	}
	if other.LoadURLTestHistory("b") != nil {
		t.Fatal("history leaked to a new generation")
	}
	result, err = runtime.LineLatencySnapshot(`{"only":"a","missing":"absent"}`)
	if err != nil || strings.Contains(result, "line-b") || strings.Contains(result, "missing") {
		t.Fatalf("capability leak: %s %v", result, err)
	}
	runtime.switchCommitInProgress = true
	if _, err = runtime.LineLatencySnapshot(`{"only":"a"}`); err == nil {
		t.Fatal("snapshot accepted during commit")
	}
}

func TestManualLineLatencyPreservesSelectionAndDoesNotHoldRuntimeLock(t *testing.T) {
	entered := make(chan struct{}, 1)
	release := make(chan struct{})
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		entered <- struct{}{}
		<-release
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	certificate := string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw}))
	runtime := latencyTestBox(t, certificate)
	done := make(chan error, 1)
	go func() { _, err := runtime.TestOutbound("outer", server.URL, 5000); done <- err }()
	select {
	case <-entered:
	case err := <-done:
		close(release)
		t.Fatalf("probe failed before local server: %v", err)
	case <-time.After(3 * time.Second):
		close(release)
		t.Fatal("probe did not reach local server")
	}
	snapshotDone := make(chan error, 1)
	go func() { _, err := runtime.LineLatencySnapshot(`{"outer":"outer","b":"b"}`); snapshotDone <- err }()
	select {
	case err := <-snapshotDone:
		if err != nil {
			t.Error(err)
		}
	case <-time.After(time.Second):
		close(release)
		t.Fatal("network probe held runtime lock")
	}
	close(release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	outbound, _ := runtime.box.Outbound().Outbound("inner")
	if outbound.(adapter.OutboundGroup).Now() != "b" {
		t.Fatal("manual test changed pinned selection")
	}
	history := service.PtrFromContext[urltest.HistoryStorage](runtime.runtimeCtx)
	if history.LoadURLTestHistory("b") == nil || history.LoadURLTestHistory("outer") != nil {
		t.Fatal("measurement must belong to concrete selected outbound")
	}
}
