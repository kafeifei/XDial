//go:build !windows

package libbox

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/urltest"
	"github.com/sagernet/sing-box/option"
	jsonext "github.com/sagernet/sing/common/json"
	"github.com/sagernet/sing/service"
)

func TestOfflineGroupChoiceUsesNativeSelectionWithoutProbes(t *testing.T) {
	lines := `[{"id":"a","type":"anytls"},{"id":"b","type":"trojan"},{"id":"pin","type":"selector","group_members":["a","b"],"group_default":"a"},{"id":"auto","type":"urltest","group_members":["a","b"]},{"id":"outer","type":"urltest","group_members":["pin","auto"]},{"id":"draft","type":"urltest","group_members":[]}]`
	for _, tc := range []struct{ name, facts, expected string }{
		{"better", `[{"line_id":"a","milliseconds":300,"observed_at":100},{"line_id":"b","milliseconds":40,"observed_at":100}]`, "b"},
		{"native-tolerance", `[{"line_id":"a","milliseconds":70,"observed_at":100},{"line_id":"b","milliseconds":40,"observed_at":100}]`, "a"},
		{"failed-member-excluded", `[{"line_id":"b","milliseconds":40,"observed_at":100}]`, "b"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			raw, err := EvaluateLineGroupLatencies(lines, tc.facts)
			if err != nil {
				t.Fatal(err)
			}
			var values []lineLatencyFact
			if err := json.Unmarshal([]byte(raw), &values); err != nil {
				t.Fatal(err)
			}
			facts := map[string]lineLatencyFact{}
			for _, value := range values {
				facts[value.LineID] = value
			}
			if facts["auto"].SelectedLineID != tc.expected || facts["outer"].SelectedLineID != tc.expected {
				t.Fatalf("native choice mismatch: %s", raw)
			}
			if facts["pin"].SelectedLineID != "a" {
				t.Fatalf("manual choice changed: %s", raw)
			}
		})
	}
	// There are deliberately no proxy credentials or servers. Selection cannot
	// dial any of these entries, and never fabricates a latency on total failure.
	raw, err := EvaluateLineGroupLatencies(lines, `[]`)
	if err != nil {
		t.Fatal(err)
	}
	var values []lineLatencyFact
	_ = json.Unmarshal([]byte(raw), &values)
	for _, value := range values {
		if value.Milliseconds != nil {
			t.Fatalf("invented latency: %s", raw)
		}
	}
}

func TestManualProbeRefreshesNativeChoiceUsesGroupURLAndPreservesPinned(t *testing.T) {
	hits := 0
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodHead {
			t.Error("not a HEAD probe")
		}
		hits++
		time.Sleep(10 * time.Millisecond)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer target.Close()
	ctx := boxContext(context.Background())
	raw, _ := json.Marshal(map[string]interface{}{
		"log": map[string]interface{}{"disabled": true},
		"outbounds": []interface{}{
			map[string]interface{}{"type": "direct", "tag": "a"},
			map[string]interface{}{"type": "direct", "tag": "b"},
			map[string]interface{}{"type": "urltest", "tag": "auto", "outbounds": []string{"a", "b"}, "url": target.URL},
			map[string]interface{}{"type": "selector", "tag": "pin", "outbounds": []string{"a", "b"}, "default": "a"},
		},
	})
	opts, err := jsonext.UnmarshalExtendedContext[option.Options](ctx, raw)
	if err != nil {
		t.Fatal(err)
	}
	instance, err := box.New(box.Options{Options: opts, Context: ctx})
	if err != nil {
		t.Fatal(err)
	}
	defer instance.Close()
	if err = instance.Outbound().Start(adapter.StartStateStart); err != nil {
		t.Fatal(err)
	}
	runtime := &Libbox{box: instance, running: true, runtimeCtx: ctx, boxGeneration: 1}
	history := service.PtrFromContext[urltest.HistoryStorage](ctx)
	history.StoreURLTestHistory("a", &adapter.URLTestHistory{Time: time.Now(), Delay: 500})
	refreshNativeGroupSelections(instance)
	auto, _ := instance.Outbound().Outbound("auto")
	pin, _ := instance.Outbound().Outbound("pin")
	if auto.(adapter.OutboundGroup).Now() != "a" {
		t.Fatal("fixture initial choice incorrect")
	}
	if _, err = runtime.TestLineLatency("b", "auto", 1000); err != nil {
		t.Fatal(err)
	}
	if hits != 1 || auto.(adapter.OutboundGroup).Now() != "b" {
		t.Fatal("real manual group probe did not update native selection")
	}
	if pin.(adapter.OutboundGroup).Now() != "a" {
		t.Fatal("manual pinned selector changed")
	}
	if _, err = runtime.TestLineLatency("b", "missing", 1000); err == nil {
		t.Fatal("unknown group capability accepted")
	}
	if _, err = runtime.TestLineLatency("pin", "auto", 1000); err == nil {
		t.Fatal("nonmember accepted")
	}
	target.Close()
	if _, err = runtime.TestLineLatency("b", "auto", 500); err == nil {
		t.Fatal("offline endpoint succeeded")
	}
	if history.LoadURLTestHistory("b") != nil || auto.(adapter.OutboundGroup).Now() != "a" {
		t.Fatal("failed probe left stale winner")
	}
}
