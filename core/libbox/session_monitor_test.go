//go:build !windows

package libbox

import (
	"encoding/json"
	"errors"
	"sync"
	"testing"
	"time"

	"go.uber.org/atomic"
	"sslcon/proto"
	"sslcon/session"

	"github.com/kafeifei/xdial/core/engine"
)

type sessionMonitorCallback struct {
	mu     sync.Mutex
	events []sessionMonitorEvent
}

type sessionMonitorEvent struct {
	kind    string
	code    int
	message string
}

type reentrantSessionMonitorCallback struct {
	libbox *Libbox
}

type startTestVPNClient struct {
	session        *session.ConnSession
	info           *engine.VPNInfo
	connectErr     error
	disconnectOnce sync.Once
}

func (c *startTestVPNClient) Connect(engine.VPNConfig) (*engine.VPNInfo, error) {
	if c.connectErr != nil {
		return nil, c.connectErr
	}
	return c.info, nil
}

func (c *startTestVPNClient) Session() *session.ConnSession {
	return c.session
}

func (c *startTestVPNClient) Disconnect() {
	if c.session == nil {
		return
	}
	c.disconnectOnce.Do(func() {
		close(c.session.CloseChan)
	})
}

type reentrantStartCallback struct {
	mu                   sync.Mutex
	libbox               *Libbox
	events               []sessionMonitorEvent
	connectedDiagnostics diagnostics
	failureDiagnostics   diagnostics
}

func (c *reentrantStartCallback) OnStatusChanged(statusJSON string) {
	var state diagnostics
	_ = json.Unmarshal([]byte(c.libbox.Diagnostics()), &state)
	c.mu.Lock()
	c.events = append(c.events, sessionMonitorEvent{kind: "status", message: statusJSON})
	if statusJSON == `{"status":"connected"}` {
		c.connectedDiagnostics = state
	}
	c.mu.Unlock()
	if statusJSON == `{"status":"connected"}` {
		_ = c.libbox.Stop()
	}
}

func (c *reentrantStartCallback) OnError(code int, message string) {
	var state diagnostics
	_ = json.Unmarshal([]byte(c.libbox.Diagnostics()), &state)
	c.mu.Lock()
	c.events = append(c.events, sessionMonitorEvent{kind: "error", code: code, message: message})
	c.failureDiagnostics = state
	c.mu.Unlock()
	_ = c.libbox.Stop()
}

func (c *reentrantStartCallback) snapshot() ([]sessionMonitorEvent, diagnostics, diagnostics) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]sessionMonitorEvent(nil), c.events...), c.connectedDiagnostics, c.failureDiagnostics
}

func newStartTestSession() *session.ConnSession {
	return &session.ConnSession{
		CloseChan:      make(chan struct{}),
		PayloadIn:      make(chan *proto.Payload, 1),
		PayloadOutTLS:  make(chan *proto.Payload, 1),
		PayloadOutDTLS: make(chan *proto.Payload, 1),
		DtlsConnected:  atomic.NewBool(false),
	}
}

func TestStartStandaloneDoesNotRequireAnyConnect(t *testing.T) {
	platform := &xdPlatformInterface{}
	platform.setDefaultInterface("test0", 1)
	l := &Libbox{
		vpn:      &startTestVPNClient{connectErr: errors.New("must not dial AnyConnect")},
		platform: platform,
	}
	configJSON := `{
		"log":{"disabled":true},
		"outbounds":[{"type":"direct","tag":"direct"}],
		"route":{"final":"direct"}
	}`

	if err := l.StartStandalone(configJSON); err != nil {
		t.Fatalf("StartStandalone: %v", err)
	}
	if !l.IsRunning() {
		t.Fatal("standalone engine is not running")
	}
	var state diagnostics
	if err := json.Unmarshal([]byte(l.Diagnostics()), &state); err != nil {
		t.Fatalf("decode diagnostics: %v", err)
	}
	if state.HandshakeCompleted {
		t.Fatal("standalone engine incorrectly reports an AnyConnect handshake")
	}
	if err := l.Stop(); err != nil {
		t.Fatalf("Stop: %v", err)
	}
}

func (c *reentrantSessionMonitorCallback) OnStatusChanged(string) {
	_ = c.libbox.Diagnostics()
}

func (c *reentrantSessionMonitorCallback) OnError(int, string) {
	_ = c.libbox.Diagnostics()
	_ = c.libbox.Stop()
}

func (c *sessionMonitorCallback) OnStatusChanged(statusJSON string) {
	c.mu.Lock()
	c.events = append(c.events, sessionMonitorEvent{kind: "status", message: statusJSON})
	c.mu.Unlock()
}

func (c *sessionMonitorCallback) OnError(code int, message string) {
	c.mu.Lock()
	c.events = append(c.events, sessionMonitorEvent{kind: "error", code: code, message: message})
	c.mu.Unlock()
}

func (c *sessionMonitorCallback) snapshot() []sessionMonitorEvent {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]sessionMonitorEvent(nil), c.events...)
}

func installMonitoredSession(l *Libbox, cSess *session.ConnSession) uint64 {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.running = true
	l.dnsJSON = `["10.0.0.53"]`
	l.session = cSess
	l.generation++
	return l.generation
}

func runSessionMonitor(l *Libbox, generation uint64, cSess *session.ConnSession) <-chan struct{} {
	done := make(chan struct{})
	go func() {
		l.monitorSession(generation, cSess)
		close(done)
	}()
	return done
}

func TestSessionMonitorUnexpectedCloseCleansStateAndReportsInOrder(t *testing.T) {
	cb := &sessionMonitorCallback{}
	l := &Libbox{cb: cb, platform: &xdPlatformInterface{}}
	cSess := &session.ConnSession{CloseChan: make(chan struct{})}
	generation := installMonitoredSession(l, cSess)
	done := runSessionMonitor(l, generation, cSess)

	close(cSess.CloseChan)
	<-done

	if l.IsRunning() {
		t.Fatal("unexpectedly closed session must not remain running")
	}
	if got := l.TunnelNameServers(); got != "[]" {
		t.Fatalf("DNS state was not cleared: %s", got)
	}

	var diagnosticState diagnostics
	if err := json.Unmarshal([]byte(l.Diagnostics()), &diagnosticState); err != nil {
		t.Fatalf("decode diagnostics: %v", err)
	}
	if diagnosticState.LastError != unexpectedSessionCloseError {
		t.Fatalf("last error = %q, want %q", diagnosticState.LastError, unexpectedSessionCloseError)
	}

	events := cb.snapshot()
	if len(events) != 2 {
		t.Fatalf("events = %#v, want error then disconnected", events)
	}
	if events[0] != (sessionMonitorEvent{kind: "error", code: ErrCodeNetwork, message: unexpectedSessionCloseError}) {
		t.Fatalf("first event = %#v", events[0])
	}
	if events[1] != (sessionMonitorEvent{kind: "status", message: `{"status":"disconnected"}`}) {
		t.Fatalf("second event = %#v", events[1])
	}
}

func TestSessionMonitorActiveStopDoesNotReportError(t *testing.T) {
	cb := &sessionMonitorCallback{}
	l := &Libbox{cb: cb, platform: &xdPlatformInterface{}}
	cSess := &session.ConnSession{CloseChan: make(chan struct{})}
	generation := installMonitoredSession(l, cSess)
	done := runSessionMonitor(l, generation, cSess)

	if err := l.Stop(); err != nil {
		t.Fatalf("Stop: %v", err)
	}
	close(cSess.CloseChan)
	<-done

	events := cb.snapshot()
	if len(events) != 1 || events[0] != (sessionMonitorEvent{kind: "status", message: `{"status":"disconnected"}`}) {
		t.Fatalf("events = %#v, want one disconnected status without error", events)
	}
	if got := l.Diagnostics(); json.Valid([]byte(got)) == false {
		t.Fatalf("invalid diagnostics JSON: %s", got)
	}
}

func TestSessionMonitorStaleCloseCannotAffectNewSession(t *testing.T) {
	cb := &sessionMonitorCallback{}
	l := &Libbox{cb: cb, platform: &xdPlatformInterface{}}
	oldSession := &session.ConnSession{CloseChan: make(chan struct{})}
	oldGeneration := installMonitoredSession(l, oldSession)
	done := runSessionMonitor(l, oldGeneration, oldSession)

	newSession := &session.ConnSession{CloseChan: make(chan struct{})}
	newGeneration := installMonitoredSession(l, newSession)
	close(oldSession.CloseChan)
	<-done

	l.mu.Lock()
	running := l.running
	currentSession := l.session
	currentGeneration := l.generation
	dnsJSON := l.dnsJSON
	l.mu.Unlock()
	if !running || currentSession != newSession || currentGeneration != newGeneration {
		t.Fatalf("stale close changed current session: running=%v session=%p generation=%d", running, currentSession, currentGeneration)
	}
	if dnsJSON != `["10.0.0.53"]` {
		t.Fatalf("stale close cleared DNS: %s", dnsJSON)
	}
	if events := cb.snapshot(); len(events) != 0 {
		t.Fatalf("stale close emitted callbacks: %#v", events)
	}
}

func TestSessionMonitorConcurrentStopAndCloseLeavesConsistentState(t *testing.T) {
	for i := 0; i < 100; i++ {
		cb := &sessionMonitorCallback{}
		l := &Libbox{cb: cb, platform: &xdPlatformInterface{}}
		cSess := &session.ConnSession{CloseChan: make(chan struct{})}
		generation := installMonitoredSession(l, cSess)
		done := runSessionMonitor(l, generation, cSess)

		var stopWG sync.WaitGroup
		stopWG.Add(1)
		go func() {
			defer stopWG.Done()
			if err := l.Stop(); err != nil {
				t.Errorf("Stop: %v", err)
			}
		}()
		close(cSess.CloseChan)
		stopWG.Wait()
		<-done

		if l.IsRunning() {
			t.Fatalf("iteration %d remained running", i)
		}
		if got := l.TunnelNameServers(); got != "[]" {
			t.Fatalf("iteration %d retained DNS: %s", i, got)
		}
		events := cb.snapshot()
		var errors, disconnected int
		for _, event := range events {
			switch event.kind {
			case "error":
				errors++
			case "status":
				disconnected++
			}
		}
		if disconnected != 1 || errors > 1 {
			t.Fatalf("iteration %d events = %#v", i, events)
		}
	}
}

func TestSessionMonitorCallbackCanReadStateAndStop(t *testing.T) {
	l := &Libbox{platform: &xdPlatformInterface{}}
	l.cb = &reentrantSessionMonitorCallback{libbox: l}
	cSess := &session.ConnSession{CloseChan: make(chan struct{})}
	generation := installMonitoredSession(l, cSess)
	done := runSessionMonitor(l, generation, cSess)

	close(cSess.CloseChan)
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("callback re-entry deadlocked session cleanup")
	}
}

func TestStartSuccessCallbackCanReadDiagnosticsAndStop(t *testing.T) {
	cSess := newStartTestSession()
	vpn := &startTestVPNClient{
		session: cSess,
		info: &engine.VPNInfo{
			VPNAddress: "10.0.0.2",
			DNS:        []string{"10.0.0.53"},
			MTU:        1400,
		},
	}
	platform := &xdPlatformInterface{}
	platform.setDefaultInterface("test0", 1)
	l := &Libbox{vpn: vpn, platform: platform}
	cb := &reentrantStartCallback{libbox: l}
	l.cb = cb
	result := make(chan error, 1)
	go func() {
		result <- l.Start("https://connect.example.com", "user", "password", `{
			"log":{"disabled":true},
			"outbounds":[{"type":"direct","tag":"direct"}],
			"route":{"final":"direct"}
		}`)
	}()

	select {
	case err := <-result:
		if err != nil {
			t.Fatalf("Start: %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("successful Start callback re-entry deadlocked")
	}

	events, connectedState, _ := cb.snapshot()
	if len(events) != 2 || events[0].message != `{"status":"connected"}` || events[1].message != `{"status":"disconnected"}` {
		t.Fatalf("events = %#v, want connected then callback-triggered disconnected", events)
	}
	if !connectedState.Running || !connectedState.HandshakeCompleted {
		t.Fatalf("connected callback observed uncommitted state: %#v", connectedState)
	}
	if l.IsRunning() {
		t.Fatal("callback-triggered Stop did not stop engine")
	}
}

func TestStartFailureCallbackCanReadDiagnosticsAndStop(t *testing.T) {
	l := &Libbox{
		vpn:      &startTestVPNClient{connectErr: errors.New("dial failed")},
		platform: &xdPlatformInterface{},
	}
	cb := &reentrantStartCallback{libbox: l}
	l.cb = cb
	result := make(chan error, 1)
	go func() {
		result <- l.Start("https://connect.example.com", "user", "password", `{}`)
	}()

	select {
	case err := <-result:
		if err == nil || err.Error() != "anyconnect dial: dial failed" {
			t.Fatalf("Start error = %v, want wrapped dial error", err)
		}
	case <-time.After(time.Second):
		t.Fatal("failed Start callback re-entry deadlocked")
	}

	events, _, failureState := cb.snapshot()
	if len(events) != 1 || events[0] != (sessionMonitorEvent{kind: "error", code: ErrCodeNetwork, message: "anyconnect dial: dial failed"}) {
		t.Fatalf("events = %#v, want one network error", events)
	}
	if failureState.LastError != "anyconnect dial: dial failed" {
		t.Fatalf("failure callback observed last error %q", failureState.LastError)
	}
	if l.IsRunning() {
		t.Fatal("failure callback-triggered Stop did not stop engine")
	}
}
