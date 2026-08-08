//go:build !windows

package libbox

import (
	"errors"
	"fmt"
	"net/netip"
	"reflect"
	"sync"

	"github.com/kafeifei/xdial/core/engine"
	"sslcon/session"
)

type lineRuntimeGenerationState uint8

const (
	lineRuntimeGenerationCandidate lineRuntimeGenerationState = iota + 1
	lineRuntimeGenerationCommitted
)

type lineRuntimeCapabilityKind string

const lineRuntimeCapabilityAnyConnect lineRuntimeCapabilityKind = "anyconnect"

var (
	errLineRuntimeCandidateExists = errors.New("a Line runtime candidate already exists")
	errLineRuntimeExclusive       = errors.New("a different exclusive Line runtime is already leased")
	errLineRuntimeInvalidated     = errors.New("Line runtime preparation was invalidated")
)

// lineRuntimeCapability is deliberately narrower than a Line model. It is a
// live protocol capability whose lifetime is determined exclusively by pool
// leases; it must not inspect a Profile, Scenario, or startup-time Line list.
type lineRuntimeCapability interface {
	kind() lineRuntimeCapabilityKind
	stop()
}

type lineRuntimePoolEntry struct {
	capability lineRuntimeCapability
	exclusive  bool
	leases     map[uint64]lineRuntimeGenerationState
}

type lineRuntimePoolReservation struct {
	generation uint64
	kind       lineRuntimeCapabilityKind
	exclusive  bool
	done       chan struct{}
	doneOnce   sync.Once
	err        error
}

func (r *lineRuntimePoolReservation) finish() {
	r.doneOnce.Do(func() { close(r.done) })
}

// lineRuntimePool owns live Line capabilities by opaque configuration
// identity. A generation must first be registered as the sole candidate, then
// acquire every capability it needs. Commit promotes only that generation's
// leases; the source generation keeps its committed leases until Retire.
//
// The pool never receives Line IDs or configuration projection material. That
// keeps lifecycle decisions independent from the Scenario that happened to
// introduce a capability and makes generation leases the only ownership fact.
type lineRuntimePool struct {
	mu                  sync.Mutex
	entries             map[string]*lineRuntimePoolEntry
	reservations        map[string]*lineRuntimePoolReservation
	generations         map[uint64]lineRuntimeGenerationState
	candidateGeneration uint64
}

func (p *lineRuntimePool) beginCandidate(generation uint64) error {
	if generation == 0 {
		return fmt.Errorf("Line runtime generation is unavailable")
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.initializeLocked()
	if _, exists := p.generations[generation]; exists {
		return fmt.Errorf("Line runtime generation already exists")
	}
	if p.candidateGeneration != 0 {
		return errLineRuntimeCandidateExists
	}
	p.generations[generation] = lineRuntimeGenerationCandidate
	p.candidateGeneration = generation
	return nil
}

// acquireCandidate returns the capability for identity and records one lease
// for the candidate generation. The factory runs at most once for a new
// identity. An exclusive capability kind (currently AnyConnect) cannot be
// constructed beside a differently configured live instance.
func (p *lineRuntimePool) acquireCandidate(
	generation uint64,
	identity string,
	kind lineRuntimeCapabilityKind,
	exclusive bool,
	factory func() (lineRuntimeCapability, error),
) (lineRuntimeCapability, bool, error) {
	if identity == "" {
		return nil, false, fmt.Errorf("Line runtime identity is unavailable")
	}
	if kind == "" {
		return nil, false, fmt.Errorf("Line runtime capability kind is unavailable")
	}

	for {
		p.mu.Lock()
		p.initializeLocked()
		if p.generations[generation] != lineRuntimeGenerationCandidate ||
			p.candidateGeneration != generation {
			p.mu.Unlock()
			return nil, false, fmt.Errorf(
				"Line runtime generation is not the candidate",
			)
		}
		if entry := p.entries[identity]; entry != nil {
			if entry.capability == nil || entry.capability.kind() != kind ||
				entry.exclusive != exclusive {
				p.mu.Unlock()
				return nil, false, fmt.Errorf(
					"Line runtime identity kind does not match",
				)
			}
			entry.leases[generation] = lineRuntimeGenerationCandidate
			capability := entry.capability
			p.mu.Unlock()
			return capability, true, nil
		}
		if reservation := p.reservations[identity]; reservation != nil {
			if reservation.generation != generation ||
				reservation.kind != kind || reservation.exclusive != exclusive {
				p.mu.Unlock()
				return nil, false, fmt.Errorf(
					"Line runtime identity preparation does not match",
				)
			}
			done := reservation.done
			p.mu.Unlock()
			<-done
			p.mu.Lock()
			reservationErr := reservation.err
			p.mu.Unlock()
			if reservationErr != nil {
				return nil, false, reservationErr
			}
			// Publication and invalidation both close done. Re-entering the loop
			// consumes the resulting entry or the invalidated generation without
			// reading reservation fields outside the pool lock.
			continue
		}
		if exclusive {
			for _, entry := range p.entries {
				if entry != nil && entry.capability != nil &&
					entry.capability.kind() == kind && len(entry.leases) != 0 {
					p.mu.Unlock()
					return nil, false, errLineRuntimeExclusive
				}
			}
			for _, reservation := range p.reservations {
				if reservation != nil && reservation.kind == kind {
					p.mu.Unlock()
					return nil, false, errLineRuntimeExclusive
				}
			}
		}
		if factory == nil {
			p.mu.Unlock()
			return nil, false, fmt.Errorf(
				"Line runtime capability requires preparation",
			)
		}
		reservation := &lineRuntimePoolReservation{
			generation: generation,
			kind:       kind,
			exclusive:  exclusive,
			done:       make(chan struct{}),
		}
		p.reservations[identity] = reservation
		p.mu.Unlock()

		// Protocol setup may block on network I/O. It must never hold the pool
		// mutex, otherwise StopAll could not invalidate this preparation.
		capability, factoryErr := factory()
		if lineRuntimeCapabilityIsNil(capability) {
			capability = nil
		}
		if factoryErr == nil && capability == nil {
			factoryErr = fmt.Errorf("Line runtime capability is unavailable")
		}
		if factoryErr == nil && capability.kind() != kind {
			factoryErr = fmt.Errorf("Line runtime capability kind does not match")
		}

		p.mu.Lock()
		current := p.reservations[identity] == reservation
		valid := current && factoryErr == nil &&
			p.candidateGeneration == generation &&
			p.generations[generation] == lineRuntimeGenerationCandidate
		if current {
			delete(p.reservations, identity)
		}
		if valid {
			p.entries[identity] = &lineRuntimePoolEntry{
				capability: capability,
				exclusive:  exclusive,
				leases: map[uint64]lineRuntimeGenerationState{
					generation: lineRuntimeGenerationCandidate,
				},
			}
			reservation.err = nil
		} else if reservation.err == nil {
			if factoryErr != nil {
				reservation.err = factoryErr
			} else {
				reservation.err = errLineRuntimeInvalidated
			}
		}
		resultErr := reservation.err
		reservation.finish()
		p.mu.Unlock()

		if !valid && capability != nil {
			capability.stop()
		}
		if valid {
			return capability, false, nil
		}
		return nil, false, resultErr
	}
}

func lineRuntimeCapabilityIsNil(capability lineRuntimeCapability) bool {
	if capability == nil {
		return true
	}
	value := reflect.ValueOf(capability)
	switch value.Kind() {
	case reflect.Chan, reflect.Func, reflect.Interface, reflect.Map,
		reflect.Pointer, reflect.Slice:
		return value.IsNil()
	default:
		return false
	}
}

func (p *lineRuntimePool) promoteCandidate(generation uint64) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.initializeLocked()
	if p.candidateGeneration != generation ||
		p.generations[generation] != lineRuntimeGenerationCandidate {
		return fmt.Errorf("Line runtime generation is not the candidate")
	}
	for _, reservation := range p.reservations {
		if reservation != nil && reservation.generation == generation {
			return fmt.Errorf("Line runtime candidate is still preparing")
		}
	}
	for _, entry := range p.entries {
		if entry.leases[generation] == lineRuntimeGenerationCandidate {
			entry.leases[generation] = lineRuntimeGenerationCommitted
		}
	}
	p.generations[generation] = lineRuntimeGenerationCommitted
	p.candidateGeneration = 0
	return nil
}

func (p *lineRuntimePool) releaseCandidate(generation uint64) {
	p.releaseGeneration(generation, lineRuntimeGenerationCandidate)
}

func (p *lineRuntimePool) releaseCommitted(generation uint64) {
	p.releaseGeneration(generation, lineRuntimeGenerationCommitted)
}

func (p *lineRuntimePool) releaseGeneration(
	generation uint64,
	want lineRuntimeGenerationState,
) {
	var stopped []lineRuntimeCapability
	p.mu.Lock()
	if p.generations[generation] != want {
		p.mu.Unlock()
		return
	}
	delete(p.generations, generation)
	if want == lineRuntimeGenerationCandidate &&
		p.candidateGeneration == generation {
		p.candidateGeneration = 0
	}
	for identity, reservation := range p.reservations {
		if reservation.generation != generation {
			continue
		}
		delete(p.reservations, identity)
		reservation.err = errLineRuntimeInvalidated
		reservation.finish()
	}
	for identity, entry := range p.entries {
		if entry.leases[generation] != want {
			continue
		}
		delete(entry.leases, generation)
		if len(entry.leases) == 0 {
			delete(p.entries, identity)
			stopped = append(stopped, entry.capability)
		}
	}
	p.mu.Unlock()
	stopLineRuntimeCapabilities(stopped)
}

// detachAll is the invalidation half of the teardown boundary for a complete
// Libbox lifecycle. Callers invoke it under their state lock, close every Box
// borrower outside that lock, then stop the returned capabilities. It also
// invalidates in-flight factories so a late product can never enter the pool.
func (p *lineRuntimePool) detachAll() []lineRuntimeCapability {
	p.mu.Lock()
	stopped := make([]lineRuntimeCapability, 0, len(p.entries))
	for _, entry := range p.entries {
		if entry != nil && entry.capability != nil {
			stopped = append(stopped, entry.capability)
		}
	}
	for _, reservation := range p.reservations {
		if reservation != nil {
			reservation.err = errLineRuntimeInvalidated
			reservation.finish()
		}
	}
	p.entries = nil
	p.reservations = nil
	p.generations = nil
	p.candidateGeneration = 0
	p.mu.Unlock()
	return stopped
}

func (p *lineRuntimePool) stopAll() {
	stopLineRuntimeCapabilities(p.detachAll())
}

func stopLineRuntimeCapabilities(capabilities []lineRuntimeCapability) {
	for _, capability := range capabilities {
		if capability != nil {
			capability.stop()
		}
	}
}

func (p *lineRuntimePool) candidateIs(
	generation uint64,
	identity string,
	capability lineRuntimeCapability,
) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	entry := p.entries[identity]
	return p.candidateGeneration == generation &&
		p.generations[generation] == lineRuntimeGenerationCandidate &&
		entry != nil && entry.capability == capability &&
		entry.leases[generation] == lineRuntimeGenerationCandidate
}

func (p *lineRuntimePool) generationIsCandidate(generation uint64) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.candidateGeneration == generation &&
		p.generations[generation] == lineRuntimeGenerationCandidate
}

func (p *lineRuntimePool) generationIsCommitted(generation uint64) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.generations[generation] == lineRuntimeGenerationCommitted
}

func (p *lineRuntimePool) empty() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.entries) == 0 && len(p.reservations) == 0 &&
		len(p.generations) == 0 && p.candidateGeneration == 0
}

func (p *lineRuntimePool) committedIs(
	generation uint64,
	identity string,
	capability lineRuntimeCapability,
) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	entry := p.entries[identity]
	return p.generations[generation] == lineRuntimeGenerationCommitted &&
		entry != nil && entry.capability == capability &&
		entry.leases[generation] == lineRuntimeGenerationCommitted
}

func (p *lineRuntimePool) initializeLocked() {
	if p.entries == nil {
		p.entries = make(map[string]*lineRuntimePoolEntry)
	}
	if p.reservations == nil {
		p.reservations = make(map[string]*lineRuntimePoolReservation)
	}
	if p.generations == nil {
		p.generations = make(map[uint64]lineRuntimeGenerationState)
	}
}

type anyConnectRuntimeSnapshot struct {
	line    *anyConnectLineRuntime
	bridge  *engine.VPNBridge
	session *session.ConnSession
	config  engine.VPNConfig
	dnsJSON string
	stopped bool
}

// anyConnectRuntimeCapability is the concrete process-global sslcon capability
// stored in lineRuntimePool. Its stable Line handle can be borrowed by two Box
// generations while a switch drains the source generation.
type anyConnectRuntimeCapability struct {
	mu       sync.Mutex
	vpn      vpnClient
	line     *anyConnectLineRuntime
	bridge   *engine.VPNBridge
	session  *session.ConnSession
	config   engine.VPNConfig
	dnsJSON  string
	stopped  bool
	stopOnce sync.Once
}

func (c *anyConnectRuntimeCapability) kind() lineRuntimeCapabilityKind {
	return lineRuntimeCapabilityAnyConnect
}

func (c *anyConnectRuntimeCapability) snapshot() anyConnectRuntimeSnapshot {
	c.mu.Lock()
	defer c.mu.Unlock()
	return anyConnectRuntimeSnapshot{
		line:    c.line,
		bridge:  c.bridge,
		session: c.session,
		config:  c.config,
		dnsJSON: c.dnsJSON,
		stopped: c.stopped,
	}
}

func (c *anyConnectRuntimeCapability) available() bool {
	snapshot := c.snapshot()
	return !snapshot.stopped && snapshot.line != nil &&
		snapshot.line.available() && snapshot.bridge != nil &&
		preparedAnyConnectSessionAlive(snapshot.session)
}

func (c *anyConnectRuntimeCapability) deactivate(
	expectedBridge *engine.VPNBridge,
	expectedSession *session.ConnSession,
) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.stopped || c.bridge != expectedBridge || c.session != expectedSession {
		return false
	}
	if c.line != nil {
		c.line.deactivate(expectedBridge)
	}
	c.bridge = nil
	c.session = nil
	c.dnsJSON = "[]"
	return true
}

func (c *anyConnectRuntimeCapability) activate(
	bridge *engine.VPNBridge,
	cSess *session.ConnSession,
	dnsServersJSON string,
	dnsServers []netip.Addr,
) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.stopped || c.line == nil || c.bridge != nil || c.session != nil {
		return false
	}
	c.line.activate(bridge, dnsServers)
	c.bridge = bridge
	c.session = cSess
	c.dnsJSON = dnsServersJSON
	return true
}

func (c *anyConnectRuntimeCapability) stop() {
	c.stopOnce.Do(func() {
		c.mu.Lock()
		c.stopped = true
		bridge := c.bridge
		cSess := c.session
		if c.line != nil && bridge != nil {
			c.line.deactivate(bridge)
		}
		c.bridge = nil
		c.session = nil
		c.dnsJSON = "[]"
		c.mu.Unlock()

		if bridge != nil {
			bridge.Close()
		}
		if (bridge != nil || cSess != nil) && c.vpn != nil {
			c.vpn.Disconnect()
		}
	})
}
