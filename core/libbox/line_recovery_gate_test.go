//go:build !windows

package libbox

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/kafeifei/xdial/core/engine"
	"github.com/sagernet/sing-box/adapter"
	"sslcon/session"
)

// gatedRecoveryVPNClient scripts each AnyConnect connect. Connect n (1-based)
// returns results[n] when present, otherwise success.
type gatedRecoveryVPNClient struct {
	mu       sync.Mutex
	current  *session.ConnSession
	connects int
	results  map[int]error
	fallback error
	// hold blocks connect n until its channel is closed; entered[n] is closed
	// once that connect has started.
	hold    map[int]chan struct{}
	entered map[int]chan struct{}
}

func (c *gatedRecoveryVPNClient) Connect(engine.VPNConfig) (*engine.VPNInfo, error) {
	c.mu.Lock()
	c.connects++
	n := c.connects
	result, scripted := c.results[n]
	if !scripted {
		result = c.fallback
	}
	hold, entered := c.hold[n], c.entered[n]
	c.mu.Unlock()
	if entered != nil {
		close(entered)
	}
	if hold != nil {
		<-hold
	}
	if result != nil {
		return nil, result
	}
	c.mu.Lock()
	c.current = newStartTestSession()
	c.mu.Unlock()
	return &engine.VPNInfo{VPNAddress: "10.0.0.2", DNS: []string{"10.0.0.53"}, MTU: 1400}, nil
}

func (c *gatedRecoveryVPNClient) Session() *session.ConnSession {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.current
}

func (c *gatedRecoveryVPNClient) Disconnect() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.current != nil {
		select {
		case <-c.current.CloseChan:
		default:
			close(c.current.CloseChan)
		}
		c.current = nil
	}
}

func (c *gatedRecoveryVPNClient) count() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.connects
}

type gateTestCallback struct {
	mu     sync.Mutex
	status []string
	errors []string
}

func (c *gateTestCallback) OnStatusChanged(statusJSON string) {
	c.mu.Lock()
	c.status = append(c.status, statusJSON)
	c.mu.Unlock()
}

func (c *gateTestCallback) OnError(_ int, message string) {
	c.mu.Lock()
	c.errors = append(c.errors, message)
	c.mu.Unlock()
}

func (c *gateTestCallback) has(fragment string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, status := range c.status {
		if strings.Contains(status, fragment) {
			return true
		}
	}
	return false
}

func (c *gateTestCallback) errorCount() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.errors)
}

var gateTestSequence uint64

func setGate(t *testing.T, l *Libbox, asleep, usable bool, leaseMS int64) {
	t.Helper()
	gateTestSequence++
	data, _ := json.Marshal(lineRecoveryConditionsReport{
		Source:         "test-host",
		Sequence:       gateTestSequence,
		SystemAsleep:   asleep,
		UnderlayUsable: usable,
		LeaseMS:        leaseMS,
	})
	if err := l.SetLineRecoveryConditions(string(data)); err != nil {
		t.Fatal(err)
	}
}

func startGatedAnyConnect(t *testing.T, vpn *gatedRecoveryVPNClient) (*Libbox, *gateTestCallback) {
	t.Helper()
	cb := &gateTestCallback{}
	l := New(cb)
	l.vpn = vpn
	l.anyConnectRetryDelays = []time.Duration{0, 0, 0}
	l.probeOutboundTLSCapabilitiesFunc = successfulNetworkProof
	envelope := networkReadinessTestEnvelope(t, switchAnyConnectConfig, map[string]string{"company": "vpn"}, true)
	if err := l.StartForNetwork(envelope, networkReadinessTestContext("A"), "192.0.2.1"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = l.Stop() })
	return l, cb
}

// dropActiveSession closes the live sslcon session the way a DPD timeout does.
func dropActiveSession(t *testing.T, l *Libbox) {
	t.Helper()
	sess := l.activeAnyConnectCapability.snapshot().session
	if sess == nil {
		t.Fatal("no live AnyConnect session to drop")
	}
	close(sess.CloseChan)
}

func eventually(t *testing.T, what string, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(time.Millisecond)
	}
}

func stays(t *testing.T, what string, duration time.Duration, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(duration)
	for time.Now().Before(deadline) {
		if !condition() {
			t.Fatalf("%s did not hold", what)
		}
		time.Sleep(time.Millisecond)
	}
}

func TestLineRecoveryConditionsDecodeRejectsMalformedReports(t *testing.T) {
	l := New(nil)
	for _, raw := range []string{
		``,
		`{"sequence":1}`,
		`{"source":"host","sequence":0}`,
		`{"source":"host","sequence":1,"lease_ms":-1}`,
		fmt.Sprintf(`{"source":"host","sequence":1,"lease_ms":%d}`, maxLineRecoveryGateLease.Milliseconds()+1),
		fmt.Sprintf(`{"source":%q,"sequence":1}`, strings.Repeat("x", maxLineRecoveryGateSource+1)),
	} {
		if err := l.SetLineRecoveryConditions(raw); err == nil {
			t.Fatalf("malformed report accepted: %s", raw)
		}
	}
	if !l.recoveryGate.state().open {
		t.Fatal("a rejected report changed the gate")
	}
}

func TestLineRecoveryGateOrdersReportsPerHostSource(t *testing.T) {
	var gate lineRecoveryGate
	if !gate.report(lineRecoveryConditionsReport{Source: "a", Sequence: 2, SystemAsleep: true}) {
		t.Fatal("first report ignored")
	}
	if gate.report(lineRecoveryConditionsReport{Source: "a", Sequence: 1, UnderlayUsable: true}) {
		t.Fatal("an older report from the same host reopened the gate")
	}
	if state := gate.state(); state.open || state.reason != lineRecoveryGateReasonAsleep {
		t.Fatalf("stale report changed state: %+v", state)
	}
	// A relaunched host restarts its sequence; its first report is authoritative.
	if !gate.report(lineRecoveryConditionsReport{Source: "b", Sequence: 1, UnderlayUsable: true}) {
		t.Fatal("new host source was ignored")
	}
	if state := gate.state(); !state.open || state.reopenings != 1 || state.closures != 1 {
		t.Fatalf("relaunched host did not reopen the gate: %+v", state)
	}
	gate.report(lineRecoveryConditionsReport{Source: "b", Sequence: 2, UnderlayUsable: false})
	if state := gate.state(); state.open || state.reason != lineRecoveryGateReasonUnderlay {
		t.Fatalf("unusable Underlay did not close the gate: %+v", state)
	}
}

func TestLineRecoveryBudgetCountsOnlyAttemptsOnUsableNetwork(t *testing.T) {
	var gate lineRecoveryGate
	budget := newLineRecoveryBudget(&gate, 3, func(int) time.Duration { return 0 }, nil, nil)
	ctx := context.Background()
	for want := 1; want <= 2; want++ {
		attempt, err := budget.next(ctx)
		if err != nil || attempt != want {
			t.Fatalf("attempt=%d err=%v want %d", attempt, err, want)
		}
		if !budget.settle() {
			t.Fatal("attempt on an open gate was not counted")
		}
	}
	attempt, err := budget.next(ctx)
	if err != nil || attempt != 3 {
		t.Fatalf("third attempt=%d err=%v", attempt, err)
	}
	gate.report(lineRecoveryConditionsReport{Source: "h", Sequence: 1, SystemAsleep: true})
	if budget.settle() {
		t.Fatal("an attempt that overlapped sleep consumed the budget")
	}
	waited := make(chan int, 1)
	go func() {
		attempt, _ := budget.next(ctx)
		waited <- attempt
	}()
	select {
	case attempt := <-waited:
		t.Fatalf("attempt %d started while the host reported sleep", attempt)
	case <-time.After(50 * time.Millisecond):
	}
	gate.report(lineRecoveryConditionsReport{Source: "h", Sequence: 2, UnderlayUsable: true})
	select {
	case attempt := <-waited:
		if attempt != 1 {
			t.Fatalf("full wake did not grant a fresh budget: attempt %d", attempt)
		}
	case <-time.After(time.Second):
		t.Fatal("budget did not resume after wake")
	}
}

func TestLineRecoveryBudgetExpiredLeaseResumesNormalAccounting(t *testing.T) {
	var gate lineRecoveryGate
	budget := newLineRecoveryBudget(&gate, 3, func(int) time.Duration { return 0 }, nil, nil)
	ctx := context.Background()
	if _, err := budget.next(ctx); err != nil {
		t.Fatal(err)
	}
	budget.settle()
	gate.report(lineRecoveryConditionsReport{Source: "h", Sequence: 1, SystemAsleep: true, LeaseMS: 30})
	started := time.Now()
	attempt, err := budget.next(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if elapsed := time.Since(started); elapsed < 25*time.Millisecond {
		t.Fatalf("closed gate did not hold until its lease ended: %v", elapsed)
	}
	if attempt != 2 {
		t.Fatalf("an expired lease is not a host-reported wake; attempt=%d want 2", attempt)
	}
}

func TestLineRecoveryWhileAsleepKeepsTransactionAndResumesOnWake(t *testing.T) {
	vpn := &gatedRecoveryVPNClient{}
	l, cb := startGatedAnyConnect(t, vpn)
	line := l.activeAnyConnectCapability.snapshot().line
	setGate(t, l, true, true, 0)

	dropActiveSession(t, l)
	eventually(t, "waiting status", func() bool {
		return cb.has(`"status":"line_waiting"`) && cb.has(lineRecoveryGateReasonAsleep)
	})
	stays(t, "asleep recovery holds", 100*time.Millisecond, func() bool {
		return vpn.count() == 1 && l.IsRunning() && cb.errorCount() == 0
	})
	if line.available() {
		t.Fatal("unavailable AnyConnect Line kept accepting traffic")
	}
	if _, err := line.DialTCP(context.Background(), "192.0.2.10:443"); !errors.Is(err, errAnyConnectLineUnavailable) {
		t.Fatalf("waiting Line dial=%v, want explicit unavailability (no Direct fallback)", err)
	}

	setGate(t, l, false, true, 0)
	eventually(t, "recovery after wake", func() bool {
		return vpn.count() == 2 && line.available()
	})
	if !l.IsRunning() || cb.errorCount() != 0 {
		t.Fatal("wake recovery replaced the transaction")
	}
}

func TestLineRecoveryWithoutUsableUnderlayDoesNotExhaustThenCountsOnUsableNetwork(t *testing.T) {
	vpn := &gatedRecoveryVPNClient{fallback: syscall.ENETUNREACH, results: map[int]error{1: nil}}
	l, cb := startGatedAnyConnect(t, vpn)
	setGate(t, l, false, false, 0)

	dropActiveSession(t, l)
	eventually(t, "waiting status", func() bool { return cb.has(lineRecoveryGateReasonUnderlay) })
	stays(t, "offline recovery holds", 100*time.Millisecond, func() bool {
		return vpn.count() == 1 && l.IsRunning() && cb.errorCount() == 0
	})

	// Exhaustion on a usable network still escalates to complete recovery.
	setGate(t, l, false, true, 0)
	eventually(t, "escalation after usable exhaustion", func() bool { return !l.IsRunning() })
	if got := vpn.count(); got != 1+maxAnyConnectReconnectAttempts {
		t.Fatalf("connects=%d want %d (only usable-network attempts)", got, 1+maxAnyConnectReconnectAttempts)
	}
	if cb.errorCount() != 1 {
		t.Fatalf("escalation errors=%d", cb.errorCount())
	}
}

func TestLineRecoveryAttemptOverlappingSleepIsNotCountedNorTerminal(t *testing.T) {
	entered, hold := make(chan struct{}), make(chan struct{})
	vpn := &gatedRecoveryVPNClient{
		results: map[int]error{2: errors.New("authentication rejected")},
		hold:    map[int]chan struct{}{2: hold},
		entered: map[int]chan struct{}{2: entered},
	}
	l, cb := startGatedAnyConnect(t, vpn)
	dropActiveSession(t, l)
	<-entered
	// The system goes to sleep while the attempt is in flight. Its failure,
	// even an untyped one, says nothing about the usable network.
	setGate(t, l, true, true, 0)
	close(hold)
	stays(t, "overlapping attempt is ignored", 100*time.Millisecond, func() bool {
		return vpn.count() == 2 && l.IsRunning() && cb.errorCount() == 0
	})
	setGate(t, l, false, true, 0)
	eventually(t, "recovery after wake", func() bool {
		return vpn.count() == 3 && l.activeAnyConnectCapability.available()
	})
}

func TestLineRecoveryUntypedFailureOnUsableNetworkStaysTerminal(t *testing.T) {
	vpn := &gatedRecoveryVPNClient{fallback: errors.New("authentication rejected"), results: map[int]error{1: nil}}
	l, cb := startGatedAnyConnect(t, vpn)
	setGate(t, l, false, true, 0)
	dropActiveSession(t, l)
	eventually(t, "terminal escalation", func() bool { return !l.IsRunning() })
	if vpn.count() != 2 || cb.errorCount() != 1 {
		t.Fatalf("untyped failure retried: connects=%d errors=%d", vpn.count(), cb.errorCount())
	}
}

func TestLineRecoveryClosedGateExpiresAfterBoundedLease(t *testing.T) {
	vpn := &gatedRecoveryVPNClient{fallback: syscall.ECONNRESET, results: map[int]error{1: nil}}
	l, cb := startGatedAnyConnect(t, vpn)
	// The host reports sleep and then disappears without a wake.
	setGate(t, l, true, true, 40)
	dropActiveSession(t, l)
	eventually(t, "normal accounting after the lease", func() bool { return !l.IsRunning() })
	if vpn.count() != 1+maxAnyConnectReconnectAttempts || cb.errorCount() != 1 {
		t.Fatalf("expired lease: connects=%d errors=%d", vpn.count(), cb.errorCount())
	}
}

func TestLineRecoveryStopCancelsGatedWait(t *testing.T) {
	vpn := &gatedRecoveryVPNClient{}
	l, cb := startGatedAnyConnect(t, vpn)
	setGate(t, l, true, true, 0)
	dropActiveSession(t, l)
	eventually(t, "waiting status", func() bool { return cb.has(`"status":"line_waiting"`) })
	stopped := make(chan error, 1)
	go func() { stopped <- l.Stop() }()
	select {
	case err := <-stopped:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("Stop waited on a gated recovery")
	}
	if vpn.count() != 1 || cb.errorCount() != 0 || !l.lineRuntimes.empty() {
		t.Fatalf("stop during gated wait: connects=%d errors=%d", vpn.count(), cb.errorCount())
	}
}

const (
	gateBothNetworkInterfaces = `[{"name":"test0","index":1,"type":"wifi"},{"name":"test1","index":2,"type":"ethernet"}]`
	gateDockOnlyInterfaces    = `[{"name":"test1","index":2,"type":"ethernet"}]`
)

func gateNetworkContext(epoch, defaultName string, defaultIndex int, interfaces string) string {
	data, _ := json.Marshal(lineNetworkContext{Epoch: epoch, Interfaces: json.RawMessage(interfaces), DefaultName: defaultName, DefaultIndex: defaultIndex, SystemDNS: []string{"192.0.2.53"}})
	return string(data)
}

func TestLineNetworkUnderlayUnknownInterfaceSetNeverProvesTransportDead(t *testing.T) {
	for _, interfaces := range []string{`[]`, `{}`, `[{"name":"","index":1}]`, `[{"name":"x","index":0}]`} {
		network := lineNetworkContext{Interfaces: json.RawMessage(interfaces), DefaultName: "test1", DefaultIndex: 2}
		underlay := decodeLineNetworkUnderlay(&network)
		c := &anyConnectRuntimeCapability{networkManaged: true, session: newStartTestSession(), sessionInterface: "1:test0"}
		c.observeNetwork("A", underlay, nil)
		if c.transportCarrierGoneLocked() {
			t.Fatalf("unreadable interface set %s proved the session dead", interfaces)
		}
	}
}

// Wi-Fi carries the AnyConnect session; an Ethernet dock that cannot reach the
// VPN becomes the default route. The committed generation keeps carrying
// traffic on Wi-Fi: no proactive reconnect, no teardown.
func TestLineRecoveryMovedDefaultRouteKeepsCommittedSession(t *testing.T) {
	vpn := &gatedRecoveryVPNClient{results: map[int]error{1: nil}, fallback: syscall.ECONNREFUSED}
	l, cb := startGatedAnyConnect(t, vpn)
	capability := l.activeAnyConnectCapability
	original := capability.snapshot().session
	line := capability.snapshot().line
	envelope := networkReadinessTestEnvelope(t, switchAnyConnectConfig, map[string]string{"company": "vpn"}, true)

	// Another member joined the interface set; the default route is unchanged.
	if err := l.PrepareSwitchForNetwork(envelope, gateNetworkContext("B", "test0", 1, gateBothNetworkInterfaces), "192.0.2.1"); err != nil {
		t.Fatal(err)
	}
	if _, err := l.EnsurePreparedSwitchLinesReady(1000); err != nil {
		t.Fatal(err)
	}
	if err := l.CommitPreparedSwitch(); err != nil {
		t.Fatal(err)
	}
	if err := l.RetireCommittedSwitch(); err != nil {
		t.Fatal(err)
	}

	// The dock becomes the default route while Wi-Fi stays in the Underlay.
	if err := l.PrepareSwitchForNetwork(envelope, gateNetworkContext("C", "test1", 2, gateBothNetworkInterfaces), "192.0.2.1"); err != nil {
		t.Fatal(err)
	}
	if _, err := l.EnsurePreparedSwitchLinesReady(1000); err != nil {
		t.Fatal(err)
	}
	if err := capability.ensureTransport(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	stays(t, "committed session untouched", 50*time.Millisecond, func() bool {
		return vpn.count() == 1 && capability.snapshot().session == original &&
			line.available() && l.IsRunning() && cb.errorCount() == 0
	})
	if err := l.CommitPreparedSwitch(); err != nil {
		t.Fatal(err)
	}
	if vpn.count() != 1 || capability.snapshot().session != original {
		t.Fatal("moving the default route replaced the working session")
	}
}

// The interface the session was established on left the Underlay: the session
// is provably dead and is re-established once, by the single owner.
func TestLineRecoveryVanishedCarrierReestablishesSessionOnceThroughOwner(t *testing.T) {
	entered, hold := make(chan struct{}), make(chan struct{})
	vpn := &gatedRecoveryVPNClient{hold: map[int]chan struct{}{2: hold}, entered: map[int]chan struct{}{2: entered}}
	l, _ := startGatedAnyConnect(t, vpn)
	capability := l.activeAnyConnectCapability
	original := capability.snapshot().session
	envelope := networkReadinessTestEnvelope(t, switchAnyConnectConfig, map[string]string{"company": "vpn"}, true)

	if err := l.PrepareSwitchForNetwork(envelope, gateNetworkContext("B", "test1", 2, gateDockOnlyInterfaces), "192.0.2.1"); err != nil {
		t.Fatal(err)
	}
	probeDone := make(chan error, 1)
	go func() { _, err := l.EnsurePreparedSwitchLinesReady(2000); probeDone <- err }()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("vanished carrier did not re-establish the session")
	}
	// A concurrent waiter (the committed generation noticing the closed
	// session) joins the same owner instead of starting a second handshake.
	joined := make(chan error, 1)
	go func() { joined <- capability.ensureTransport(context.Background(), false) }()
	time.Sleep(20 * time.Millisecond)
	close(hold)
	if err := <-probeDone; err != nil {
		t.Fatal(err)
	}
	if err := <-joined; err != nil {
		t.Fatal(err)
	}
	if vpn.count() != 2 || capability.snapshot().session == original || !capability.available() {
		t.Fatalf("vanished carrier connects=%d want exactly one reconnect", vpn.count())
	}
	if err := l.CommitPreparedSwitch(); err != nil {
		t.Fatal(err)
	}
	if err := l.RetireCommittedSwitch(); err != nil {
		t.Fatal(err)
	}
	// The new session rides the dock. Wi-Fi returning as the default route
	// while the dock stays present is again no reason to replace it.
	if err := l.PrepareSwitchForNetwork(envelope, gateNetworkContext("C", "test0", 1, gateBothNetworkInterfaces), "192.0.2.1"); err != nil {
		t.Fatal(err)
	}
	if _, err := l.EnsurePreparedSwitchLinesReady(1000); err != nil {
		t.Fatal(err)
	}
	if vpn.count() != 2 {
		t.Fatalf("re-established session was replaced again: connects=%d", vpn.count())
	}
}

// Same interface name and index on a new network (e.g. Wi-Fi joined another
// SSID and changed address): the snapshot cannot prove the session dead, so
// only the readiness probe through the existing session may force a reconnect,
// and only on a structured transient failure.
func TestLineRecoveryReaddressedInterfaceReliesOnReadinessProbe(t *testing.T) {
	vpn := &gatedRecoveryVPNClient{}
	l, _ := startGatedAnyConnect(t, vpn)
	capability := l.activeAnyConnectCapability
	original := capability.snapshot().session
	l.probeOutboundTLSCapabilitiesFunc = func(ctx context.Context, outbound adapter.Outbound) outboundTLSCapabilities {
		if capability.snapshot().session == original {
			return outboundTLSCapabilities{IPv4: outboundTLSFamilyCapability{FailureClass: lineReadinessTransient}}
		}
		return successfulNetworkProof(ctx, outbound)
	}
	envelope := networkReadinessTestEnvelope(t, switchAnyConnectConfig, map[string]string{"company": "vpn"}, true)
	if err := l.PrepareSwitchForNetwork(envelope, networkReadinessTestContext("B"), "192.0.2.1"); err != nil {
		t.Fatal(err)
	}
	capability.mu.Lock()
	carrierGone := capability.transportCarrierGoneLocked()
	capability.mu.Unlock()
	if carrierGone {
		t.Fatal("an unchanged interface identity was treated as a vanished carrier")
	}
	if _, err := l.EnsurePreparedSwitchLinesReady(2000); err != nil {
		t.Fatal(err)
	}
	if vpn.count() != 2 || capability.snapshot().session == original {
		t.Fatalf("transient probe failure connects=%d want one forced reconnect", vpn.count())
	}
}

func TestLineRecoveryVanishedCarrierKeepsSessionWhileGateClosed(t *testing.T) {
	vpn := &gatedRecoveryVPNClient{}
	l, _ := startGatedAnyConnect(t, vpn)
	capability := l.activeAnyConnectCapability
	original := capability.snapshot().session
	envelope := networkReadinessTestEnvelope(t, switchAnyConnectConfig, map[string]string{"company": "vpn"}, true)
	if err := l.PrepareSwitchForNetwork(envelope, gateNetworkContext("B", "test1", 2, gateDockOnlyInterfaces), "192.0.2.1"); err != nil {
		t.Fatal(err)
	}
	setGate(t, l, false, false, 0)
	if err := capability.ensureTransport(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	if vpn.count() != 1 || capability.snapshot().session != original {
		t.Fatal("a session was replaced while no usable network was reported")
	}
}
