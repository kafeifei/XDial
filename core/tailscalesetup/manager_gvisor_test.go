//go:build darwin && with_gvisor

package tailscalesetup

import (
	"github.com/kafeifei/xdial/core/libbox"
	"strings"
	"testing"
	"time"
)

func TestTailscaleStatusSettled(t *testing.T) {
	tests := []struct {
		name       string
		statusJSON string
		want       bool
	}{
		{
			name:       "persisted identity is still starting",
			statusJSON: `{"backend_state":"NoState","auth_url":""}`,
		},
		{
			name:       "backend is starting",
			statusJSON: `{"backend_state":"Starting","auth_url":""}`,
		},
		{
			name:       "login has no usable URL yet",
			statusJSON: `{"backend_state":"NeedsLogin","auth_url":""}`,
		},
		{
			name:       "login URL is ready",
			statusJSON: `{"backend_state":"NeedsLogin","auth_url":"https://login.tailscale.com/a/test"}`,
			want:       true,
		},
		{
			name:       "persisted identity is running",
			statusJSON: `{"backend_state":"Running","auth_url":""}`,
			want:       true,
		},
		{
			name:       "machine approval is a terminal state",
			statusJSON: `{"backend_state":"NeedsMachineAuth","auth_url":""}`,
			want:       true,
		},
	}

	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			got, _, err := tailscaleStatusSettled(testCase.statusJSON)
			if err != nil {
				t.Fatalf("tailscaleStatusSettled: %v", err)
			}
			if got != testCase.want {
				t.Fatalf("settled = %v, want %v", got, testCase.want)
			}
		})
	}
}

func TestWaitForSettledStatusWaitsForPersistedIdentity(t *testing.T) {
	statuses := []string{
		`{"backend_state":"NoState","auth_url":""}`,
		`{"backend_state":"Starting","auth_url":""}`,
		`{"backend_state":"Running","auth_url":""}`,
	}
	calls := 0
	status, err := waitForSettledStatus(
		func() (string, error) {
			index := calls
			calls++
			if index >= len(statuses) {
				index = len(statuses) - 1
			}
			return statuses[index], nil
		},
		100*time.Millisecond,
		time.Millisecond,
	)
	if err != nil {
		t.Fatalf("waitForSettledStatus: %v", err)
	}
	if !strings.Contains(status, `"Running"`) {
		t.Fatalf("unexpected settled status: %s", status)
	}
	if calls != len(statuses) {
		t.Fatalf("status calls = %d, want %d", calls, len(statuses))
	}
}

func TestWaitForSettledStatusTimesOut(t *testing.T) {
	_, err := waitForSettledStatus(
		func() (string, error) {
			return `{"backend_state":"Starting","auth_url":""}`, nil
		},
		2*time.Millisecond,
		time.Millisecond,
	)
	if err == nil || !strings.Contains(err.Error(), "last state Starting") {
		t.Fatalf("unexpected timeout error: %v", err)
	}
}

func TestTailscaleStatusSettledRejectsMalformedStatus(t *testing.T) {
	if _, _, err := tailscaleStatusSettled(`{`); err == nil {
		t.Fatal("expected malformed status to fail")
	}
}

type fakeSetupRuntime struct{ reads, stops int }

func (f *fakeSetupRuntime) TailscaleStatus(string) (string, error) {
	f.reads++
	return `{"backend_state":"NeedsLogin","auth_url":"https://login.example/a/stable"}`, nil
}
func (f *fakeSetupRuntime) BeginTailscaleLogin(string) (string, error) { return f.TailscaleStatus("") }
func (f *fakeSetupRuntime) TailscaleLogout(string) error               { return nil }
func (f *fakeSetupRuntime) Stop() error                                { f.stops++; return nil }

func TestPrepareReusesLoginSessionAndURL(t *testing.T) {
	raw := `{"profile_id":"test","lines":[{"id":"ts","type":"tailscale"}]}`
	m := New(t.TempDir())
	configJSON, err := libbox.GenerateTailscaleSetupConfig(raw, "ts", m.basePath)
	if err != nil {
		t.Fatal(err)
	}
	runtime := &fakeSetupRuntime{}
	m.runtime, m.lineID, m.endpointTag, m.sessionConfig = runtime, "ts", "tailscale-ts", configJSON
	defer m.Stop()
	for i := 0; i < 3; i++ {
		result, err := m.Prepare(raw, "ts", "")
		if err != nil || !strings.Contains(result, "a/stable") {
			t.Fatalf("lost login session: %s %v", result, err)
		}
	}
	if runtime.reads != 3 || runtime.stops != 0 {
		t.Fatalf("refresh restarted runtime: %+v", runtime)
	}
	if err := m.StopLine("other"); err != nil || runtime.stops != 0 {
		t.Fatal("unrelated card stopped login")
	}
}
