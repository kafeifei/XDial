//go:build !windows

package libbox

import (
	"context"
	stdjson "encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"
)

// A Line-local recovery owner may spend its bounded budget only on a network
// the host reports as usable. Sleep and Underlay usability are host facts: the
// Provider neither receives a full-wake signal (Dark Wake must not count as
// one) nor sees the unconstrained NWPath. The Provider applies the gate the
// host reports and adds no product policy of its own.
//
// Currently AnyConnect is the only Line with a local budget whose exhaustion
// escalates to a complete teardown. Tailscale recovers inside its endpoint
// (magicsock rebind on network observation) and never escalates, so it has no
// budget to protect.
const (
	lineRecoveryGateReasonAsleep   = "system-asleep"
	lineRecoveryGateReasonUnderlay = "underlay-unavailable"

	// A closed gate is a lease, never a permanent state. If the host vanishes
	// while it reported sleep or no Underlay, recovery resumes its normal
	// accounting once the lease runs out instead of waiting forever. Go's
	// monotonic clock (mach_absolute_time on darwin) does not advance while the
	// system sleeps, so only time this process actually runs (including Dark
	// Wake) consumes the lease; a live host renews it while the condition
	// persists.
	defaultLineRecoveryGateLease = 5 * time.Minute
	maxLineRecoveryGateLease     = 15 * time.Minute
	maxLineRecoveryGateSource    = 64
)

var errLineRecoveryBudgetExhausted = errors.New("Line-local recovery budget is exhausted")

type lineRecoveryConditionsReport struct {
	Source         string `json:"source"`
	Sequence       uint64 `json:"sequence"`
	SystemAsleep   bool   `json:"system_asleep"`
	UnderlayUsable bool   `json:"underlay_usable"`
	LeaseMS        int64  `json:"lease_ms"`
}

// lineRecoveryGate is safe for concurrent use and usable as a zero value: with
// no host report it is open, which preserves the platforms (iOS / tvOS) and
// tests that never send conditions.
type lineRecoveryGate struct {
	mu       sync.Mutex
	source   string
	sequence uint64
	reason   string
	deadline time.Time
	// closures counts open→closed transitions; an attempt that overlaps one
	// was not made on a usable network.
	closures uint64
	// reopenings counts host-reported closed→open transitions. A lease that
	// merely expired is not a new network condition and does not count.
	reopenings uint64
	changed    chan struct{}
}

type lineRecoveryGateState struct {
	open       bool
	reason     string
	closures   uint64
	reopenings uint64
	remaining  time.Duration
	changed    <-chan struct{}
}

func (g *lineRecoveryGate) stateLocked(now time.Time) lineRecoveryGateState {
	if g.changed == nil {
		g.changed = make(chan struct{})
	}
	state := lineRecoveryGateState{
		open:       true,
		closures:   g.closures,
		reopenings: g.reopenings,
		changed:    g.changed,
	}
	if g.reason != "" && now.Before(g.deadline) {
		state.open = false
		state.reason = g.reason
		state.remaining = g.deadline.Sub(now)
	}
	return state
}

func (g *lineRecoveryGate) state() lineRecoveryGateState {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.stateLocked(time.Now())
}

// report applies one host report. Reports from the same host instance are
// ordered by sequence; a new source (host relaunch) replaces the previous one.
// It returns false for a stale report that was ignored.
func (g *lineRecoveryGate) report(conditions lineRecoveryConditionsReport) bool {
	reason := ""
	switch {
	case conditions.SystemAsleep:
		reason = lineRecoveryGateReasonAsleep
	case !conditions.UnderlayUsable:
		reason = lineRecoveryGateReasonUnderlay
	}
	lease := time.Duration(conditions.LeaseMS) * time.Millisecond
	if lease <= 0 {
		lease = defaultLineRecoveryGateLease
	}
	if lease > maxLineRecoveryGateLease {
		lease = maxLineRecoveryGateLease
	}

	g.mu.Lock()
	defer g.mu.Unlock()
	if conditions.Source == g.source && conditions.Sequence <= g.sequence {
		return false
	}
	now := time.Now()
	before := g.stateLocked(now)
	g.source, g.sequence = conditions.Source, conditions.Sequence
	g.reason = reason
	g.deadline = time.Time{}
	if reason != "" {
		g.deadline = now.Add(lease)
	}
	after := g.stateLocked(now)
	if before.open && !after.open {
		g.closures++
	}
	if !before.open && after.open {
		g.reopenings++
	}
	// Every accepted report may move the deadline, so waiters re-arm.
	close(g.changed)
	g.changed = make(chan struct{})
	return true
}

// awaitOpen blocks while the gate is closed. onWait is invoked once for each
// distinct closed reason observed while waiting.
func (g *lineRecoveryGate) awaitOpen(
	ctx context.Context,
	onWait func(reason string),
) (lineRecoveryGateState, error) {
	notified := ""
	for {
		state := g.state()
		if state.open {
			return state, nil
		}
		if onWait != nil && state.reason != notified {
			notified = state.reason
			onWait(state.reason)
		}
		timer := time.NewTimer(state.remaining)
		select {
		case <-ctx.Done():
			timer.Stop()
			return state, ctx.Err()
		case <-state.changed:
		case <-timer.C:
		}
		timer.Stop()
	}
}

// openSince reports whether the gate is open now and has not closed since
// start was observed.
func (g *lineRecoveryGate) openSince(start lineRecoveryGateState) bool {
	current := g.state()
	return current.open && current.closures == start.closures
}

func decodeLineRecoveryConditions(raw string) (lineRecoveryConditionsReport, error) {
	var conditions lineRecoveryConditionsReport
	if err := stdjson.Unmarshal([]byte(raw), &conditions); err != nil {
		return conditions, fmt.Errorf("decode Line recovery conditions: %w", err)
	}
	conditions.Source = strings.TrimSpace(conditions.Source)
	if conditions.Source == "" || len(conditions.Source) > maxLineRecoveryGateSource {
		return conditions, fmt.Errorf("Line recovery conditions source is invalid")
	}
	if conditions.Sequence == 0 {
		return conditions, fmt.Errorf("Line recovery conditions sequence is invalid")
	}
	if conditions.LeaseMS < 0 || conditions.LeaseMS > maxLineRecoveryGateLease.Milliseconds() {
		return conditions, fmt.Errorf("Line recovery conditions lease is out of range")
	}
	return conditions, nil
}

// SetLineRecoveryConditions applies the host's power lifecycle and Underlay
// usability facts to every Line-local recovery owner of this Libbox. While the
// host reports the system asleep or no usable Underlay, a recovering Line stays
// unavailable (its flows are rejected, its DNS answers SERVFAIL), attempts are
// neither made nor counted, and the transaction is never escalated to a
// complete teardown. The closed gate expires after its bounded lease.
func (l *Libbox) SetLineRecoveryConditions(conditionsJSON string) error {
	conditions, err := decodeLineRecoveryConditions(conditionsJSON)
	if err != nil {
		return err
	}
	l.recoveryGate.report(conditions)
	return nil
}

// lineRecoveryBudget counts only attempts that began and ended while the gate
// stayed open. A host-reported reopening (full wake, usable Underlay again)
// or a new network epoch is a new network condition and grants a fresh budget.
type lineRecoveryBudget struct {
	gate       *lineRecoveryGate
	max        int
	delay      func(int) time.Duration
	onWait     func(reason string, used int)
	freshEpoch func() bool
	used       int
	reopenings uint64
	window     lineRecoveryGateState
}

func newLineRecoveryBudget(
	gate *lineRecoveryGate,
	max int,
	delay func(int) time.Duration,
	onWait func(reason string, used int),
	freshEpoch func() bool,
) *lineRecoveryBudget {
	return &lineRecoveryBudget{
		gate:       gate,
		max:        max,
		delay:      delay,
		onWait:     onWait,
		freshEpoch: freshEpoch,
		reopenings: gate.state().reopenings,
	}
}

// next waits until the next attempt may start and returns its 1-based number.
// It returns errLineRecoveryBudgetExhausted once max attempts have been
// counted, or the context error.
func (b *lineRecoveryBudget) next(ctx context.Context) (int, error) {
	for {
		state, err := b.gate.awaitOpen(ctx, func(reason string) {
			if b.onWait != nil {
				b.onWait(reason, b.used)
			}
		})
		if err != nil {
			return 0, err
		}
		if state.reopenings != b.reopenings {
			b.reopenings = state.reopenings
			b.used = 0
		}
		if b.freshEpoch != nil && b.freshEpoch() {
			b.used = 0
		}
		if b.used >= b.max {
			return 0, errLineRecoveryBudgetExhausted
		}
		if !waitForAnyConnectReconnect(ctx, b.delay(b.used+1)) {
			if err := ctx.Err(); err != nil {
				return 0, err
			}
			return 0, context.Canceled
		}
		if !b.gate.openSince(state) {
			continue
		}
		b.window = state
		return b.used + 1, nil
	}
}

// settle records a failed attempt. It reports whether that attempt counts:
// one that overlapped a closed gate was not made on a usable network, so its
// failure neither consumes the budget nor classifies the Line as terminal.
func (b *lineRecoveryBudget) settle() bool {
	if !b.gate.openSince(b.window) {
		return false
	}
	b.used++
	return true
}
