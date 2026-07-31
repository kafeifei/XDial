//go:build !windows

package libbox

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"go.uber.org/atomic"
	"sslcon/base"
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

type reconnectTestVPNClient struct {
	mu             sync.Mutex
	info           *engine.VPNInfo
	currentSession *session.ConnSession
	nextSession    *session.ConnSession
	connectErr     error
	connectStarted chan struct{}
	allowConnect   chan struct{}
	startOnce      sync.Once
}

func (c *reconnectTestVPNClient) Connect(
	engine.VPNConfig,
) (*engine.VPNInfo, error) {
	c.startOnce.Do(func() {
		if c.connectStarted != nil {
			close(c.connectStarted)
		}
	})
	if c.allowConnect != nil {
		<-c.allowConnect
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.connectErr != nil {
		return nil, c.connectErr
	}
	c.currentSession = c.nextSession
	return c.info, nil
}

func (c *reconnectTestVPNClient) Session() *session.ConnSession {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.currentSession
}

func (c *reconnectTestVPNClient) Disconnect() {
	c.mu.Lock()
	current := c.currentSession
	c.currentSession = nil
	c.mu.Unlock()
	if current == nil {
		return
	}
	select {
	case <-current.CloseChan:
	default:
		close(current.CloseChan)
	}
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
	bridge, err := engine.NewVPNBridge("10.0.0.2", 1400)
	if err != nil {
		panic(err)
	}
	runtimeCtx, runtimeCancel := context.WithCancel(context.Background())
	l.running = true
	l.dnsJSON = `["10.0.0.53"]`
	l.session = cSess
	l.bridge = bridge
	l.anyConnectLine = newAnyConnectLineRuntime(
		bridge,
		anyConnectDNSServers([]string{"10.0.0.53"}),
	)
	l.runtimeCtx = runtimeCtx
	l.runtimeCancel = runtimeCancel
	l.anyConnectConfig = engine.VPNConfig{
		Server:   "https://vpn.example.com",
		Username: "user",
		Password: "password",
	}
	l.anyConnectRetryDelays = []time.Duration{0, 0, 0}
	if l.vpn == nil {
		l.vpn = &startTestVPNClient{
			connectErr: errors.New("reconnect failed"),
		}
	}
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
	if len(events) != maxAnyConnectReconnectAttempts+2 {
		t.Fatalf("events = %#v, want retries then error and disconnected", events)
	}
	for attempt := 1; attempt <= maxAnyConnectReconnectAttempts; attempt++ {
		if events[attempt-1].kind != "status" ||
			!strings.Contains(
				events[attempt-1].message,
				`"status":"line_reconnecting"`,
			) {
			t.Fatalf("retry event %d = %#v", attempt, events[attempt-1])
		}
	}
	if events[len(events)-2] != (sessionMonitorEvent{kind: "error", code: ErrCodeNetwork, message: unexpectedSessionCloseError}) {
		t.Fatalf("fatal event = %#v", events[len(events)-2])
	}
	if events[len(events)-1] != (sessionMonitorEvent{kind: "status", message: `{"status":"disconnected"}`}) {
		t.Fatalf("final event = %#v", events[len(events)-1])
	}
}

func TestSessionMonitorReconnectsOnlyAnyConnectLine(t *testing.T) {
	oldSession := &session.ConnSession{CloseChan: make(chan struct{})}
	newSession := newStartTestSession()
	vpn := &reconnectTestVPNClient{
		info: &engine.VPNInfo{
			VPNAddress: "10.0.0.3",
			DNS:        []string{"10.0.0.54"},
			MTU:        1400,
		},
		nextSession:    newSession,
		connectStarted: make(chan struct{}),
		allowConnect:   make(chan struct{}),
	}
	cb := &sessionMonitorCallback{}
	l := &Libbox{
		cb:       cb,
		vpn:      vpn,
		platform: &xdPlatformInterface{},
	}
	generation := installMonitoredSession(l, oldSession)
	lockFile, err := os.CreateTemp(t.TempDir(), "tailscale-state-lock")
	if err != nil {
		t.Fatal(err)
	}
	l.mu.Lock()
	l.stateLocks = []*os.File{lockFile}
	line := l.anyConnectLine
	l.mu.Unlock()

	done := runSessionMonitor(l, generation, oldSession)
	close(oldSession.CloseChan)
	select {
	case <-vpn.connectStarted:
	case <-time.After(time.Second):
		t.Fatal("line reconnect did not start")
	}

	if line.available() {
		t.Fatal("failed AnyConnect line remained available while reconnecting")
	}
	if _, err := line.DialTCP(
		context.Background(),
		"192.0.2.1:443",
	); !errors.Is(err, errAnyConnectLineUnavailable) {
		t.Fatalf("unavailable line dial error = %v", err)
	}
	udpConn, err := line.DialUDP(
		nil,
		&net.UDPAddr{IP: net.IPv4(192, 0, 2, 53), Port: 53},
	)
	if udpConn != nil ||
		!errors.Is(err, errAnyConnectLineUnavailable) {
		t.Fatalf(
			"unavailable line UDP dial = (%v, %v), want nil and reconnecting error",
			udpConn,
			err,
		)
	}
	dnsTransport := &anyConnectDNSTransport{exchanger: line}
	dnsResponse, err := dnsTransport.Exchange(
		context.Background(),
		mobileDNSTestRequest("corp.example."),
	)
	if dnsResponse != nil || !errors.Is(err, errMobileDNSFailed) {
		t.Fatalf(
			"unavailable line DNS exchange = (%v, %v), want nil and explicit failure",
			dnsResponse,
			err,
		)
	}
	l.mu.Lock()
	runningDuringReconnect := l.running
	retainedLocks := len(l.stateLocks) == 1 &&
		l.stateLocks[0] == lockFile
	l.mu.Unlock()
	if !runningDuringReconnect {
		t.Fatal("sing-box generation stopped during line reconnect")
	}
	if !retainedLocks {
		t.Fatal("unrelated Tailscale state ownership was released")
	}

	close(vpn.allowConnect)
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("line reconnect did not finish")
	}

	l.mu.Lock()
	running := l.running
	currentSession := l.session
	currentGeneration := l.generation
	retainedLocks = len(l.stateLocks) == 1 &&
		l.stateLocks[0] == lockFile
	l.mu.Unlock()
	if !running || currentSession != newSession ||
		currentGeneration != generation {
		t.Fatalf(
			"line reconnect replaced the data-plane generation: running=%v session=%p generation=%d",
			running,
			currentSession,
			currentGeneration,
		)
	}
	if !line.available() {
		t.Fatal("AnyConnect line was not restored")
	}
	if !retainedLocks {
		t.Fatal("Tailscale state ownership changed after line reconnect")
	}

	events := cb.snapshot()
	if len(events) != 2 ||
		events[0].kind != "status" ||
		events[1].kind != "status" {
		t.Fatalf("events = %#v", events)
	}
	var reconnectingStatus, connectedStatus struct {
		Status  string `json:"status"`
		Attempt int    `json:"attempt"`
	}
	if err := json.Unmarshal(
		[]byte(events[0].message),
		&reconnectingStatus,
	); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(
		[]byte(events[1].message),
		&connectedStatus,
	); err != nil {
		t.Fatal(err)
	}
	if reconnectingStatus.Status != "line_reconnecting" ||
		reconnectingStatus.Attempt != 1 ||
		connectedStatus.Status != "line_connected" ||
		connectedStatus.Attempt != 1 {
		t.Fatalf("unexpected line recovery events: %#v", events)
	}

	if err := l.Stop(); err != nil {
		t.Fatal(err)
	}
}

func TestSessionMonitorPublishesStructuredAnyConnectFailure(t *testing.T) {
	configurator, ok := any(base.Cfg).(interface {
		SetXDialForceDPD(int)
	})
	if !ok {
		t.Skip("pristine sslcon source does not include the staged XDial patch")
	}
	configurator.SetXDialForceDPD(5)
	cSess := (&session.Session{}).NewConnSession(&http.Header{})
	closer, ok := any(cSess).(interface {
		XDialCloseWithReason(string, string, string, string)
	})
	if !ok {
		t.Fatal("patched session lacks structured close support")
	}

	cb := &sessionMonitorCallback{}
	l := &Libbox{cb: cb, platform: &xdPlatformInterface{}}
	generation := installMonitoredSession(l, cSess)
	done := runSessionMonitor(l, generation, cSess)
	closer.XDialCloseWithReason(
		"tls-read-timeout",
		"tls",
		"read",
		"timeout",
	)
	<-done

	var diagnosticState diagnostics
	if err := json.Unmarshal(
		[]byte(l.Diagnostics()),
		&diagnosticState,
	); err != nil {
		t.Fatalf("decode diagnostics: %v", err)
	}
	if diagnosticState.LastError !=
		"AnyConnect TLS control channel read timed out" {
		t.Fatalf("last error = %q", diagnosticState.LastError)
	}
	var snapshot struct {
		ForceDPDSeconds int `json:"force_dpd_seconds"`
		Close           *struct {
			Code string `json:"code"`
		} `json:"close"`
	}
	if err := json.Unmarshal(
		diagnosticState.AnyConnect,
		&snapshot,
	); err != nil {
		t.Fatalf("decode AnyConnect diagnostics: %v", err)
	}
	if snapshot.ForceDPDSeconds != 5 ||
		snapshot.Close == nil ||
		snapshot.Close.Code != "tls-read-timeout" {
		t.Fatalf("unexpected AnyConnect diagnostics: %#v", snapshot)
	}

	events := cb.snapshot()
	if len(events) != maxAnyConnectReconnectAttempts+2 ||
		events[len(events)-2].message !=
			"AnyConnect TLS control channel read timed out" {
		t.Fatalf("events = %#v", events)
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
				if event.message == `{"status":"disconnected"}` {
					disconnected++
				}
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
