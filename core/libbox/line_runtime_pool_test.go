//go:build !windows

package libbox

import (
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type lineRuntimePoolTestCapability struct {
	kindValue lineRuntimeCapabilityKind
	stops     atomic.Int32
}

func (c *lineRuntimePoolTestCapability) kind() lineRuntimeCapabilityKind {
	return c.kindValue
}

func (c *lineRuntimePoolTestCapability) stop() {
	c.stops.Add(1)
}

func TestLineRuntimePoolReusesIdentityAcrossGenerations(t *testing.T) {
	var pool lineRuntimePool
	const identity = "opaque-same-capability"
	const sourceGeneration = 1
	const candidateGeneration = 2
	if err := pool.beginCandidate(sourceGeneration); err != nil {
		t.Fatal(err)
	}
	created := &lineRuntimePoolTestCapability{
		kindValue: lineRuntimeCapabilityAnyConnect,
	}
	capability, reused, err := pool.acquireCandidate(
		sourceGeneration,
		identity,
		lineRuntimeCapabilityAnyConnect,
		true,
		func() (lineRuntimeCapability, error) { return created, nil },
	)
	if err != nil || reused || capability != created {
		t.Fatalf("source acquire = (%p, %v, %v)", capability, reused, err)
	}
	if err := pool.promoteCandidate(sourceGeneration); err != nil {
		t.Fatal(err)
	}

	if err := pool.beginCandidate(candidateGeneration); err != nil {
		t.Fatal(err)
	}
	capability, reused, err = pool.acquireCandidate(
		candidateGeneration,
		identity,
		lineRuntimeCapabilityAnyConnect,
		true,
		func() (lineRuntimeCapability, error) {
			t.Fatal("same identity constructed a second capability")
			return nil, nil
		},
	)
	if err != nil || !reused || capability != created {
		t.Fatalf("candidate acquire = (%p, %v, %v)", capability, reused, err)
	}
	if !pool.committedIs(sourceGeneration, identity, created) ||
		!pool.candidateIs(candidateGeneration, identity, created) {
		t.Fatal("source and candidate leases do not share one capability")
	}
	pool.releaseCandidate(candidateGeneration)
	if created.stops.Load() != 0 ||
		!pool.committedIs(sourceGeneration, identity, created) {
		t.Fatal("aborting a shared candidate released the source capability")
	}
}

func TestLineRuntimePoolCommitRetainsSourceUntilRetire(t *testing.T) {
	var pool lineRuntimePool
	const identity = "opaque-commit-retain"
	created := &lineRuntimePoolTestCapability{
		kindValue: lineRuntimeCapabilityAnyConnect,
	}
	if err := pool.beginCandidate(1); err != nil {
		t.Fatal(err)
	}
	if _, _, err := pool.acquireCandidate(
		1,
		identity,
		lineRuntimeCapabilityAnyConnect,
		true,
		func() (lineRuntimeCapability, error) { return created, nil },
	); err != nil {
		t.Fatal(err)
	}
	if err := pool.promoteCandidate(1); err != nil {
		t.Fatal(err)
	}
	if err := pool.beginCandidate(2); err != nil {
		t.Fatal(err)
	}
	if _, reused, err := pool.acquireCandidate(
		2,
		identity,
		lineRuntimeCapabilityAnyConnect,
		true,
		nil,
	); err != nil || !reused {
		t.Fatalf("candidate reuse = (%v, %v)", reused, err)
	}
	if err := pool.promoteCandidate(2); err != nil {
		t.Fatal(err)
	}
	pool.releaseCommitted(1)
	if created.stops.Load() != 0 || !pool.committedIs(2, identity, created) {
		t.Fatal("retiring the source released the committed target capability")
	}
	pool.releaseCommitted(2)
	if created.stops.Load() != 1 {
		t.Fatalf("last committed release stopped capability %d times", created.stops.Load())
	}
}

func TestLineRuntimePoolAbortStopsCandidateOnlyCapability(t *testing.T) {
	var pool lineRuntimePool
	source := &lineRuntimePoolTestCapability{kindValue: "shareable"}
	candidate := &lineRuntimePoolTestCapability{kindValue: "shareable"}
	if err := pool.beginCandidate(1); err != nil {
		t.Fatal(err)
	}
	if _, _, err := pool.acquireCandidate(
		1,
		"opaque-source",
		"shareable",
		false,
		func() (lineRuntimeCapability, error) { return source, nil },
	); err != nil {
		t.Fatal(err)
	}
	if err := pool.promoteCandidate(1); err != nil {
		t.Fatal(err)
	}
	if err := pool.beginCandidate(2); err != nil {
		t.Fatal(err)
	}
	if _, _, err := pool.acquireCandidate(
		2,
		"opaque-candidate",
		"shareable",
		false,
		func() (lineRuntimeCapability, error) { return candidate, nil },
	); err != nil {
		t.Fatal(err)
	}
	pool.releaseCandidate(2)
	if candidate.stops.Load() != 1 || source.stops.Load() != 0 {
		t.Fatalf(
			"abort stops = candidate %d, source %d",
			candidate.stops.Load(),
			source.stops.Load(),
		)
	}
}

func TestLineRuntimePoolRejectsDifferentExclusiveIdentity(t *testing.T) {
	var pool lineRuntimePool
	if err := pool.beginCandidate(1); err != nil {
		t.Fatal(err)
	}
	source := &lineRuntimePoolTestCapability{
		kindValue: lineRuntimeCapabilityAnyConnect,
	}
	if _, _, err := pool.acquireCandidate(
		1,
		"opaque-source",
		lineRuntimeCapabilityAnyConnect,
		true,
		func() (lineRuntimeCapability, error) { return source, nil },
	); err != nil {
		t.Fatal(err)
	}
	if err := pool.promoteCandidate(1); err != nil {
		t.Fatal(err)
	}
	if err := pool.beginCandidate(2); err != nil {
		t.Fatal(err)
	}
	created := false
	_, _, err := pool.acquireCandidate(
		2,
		"opaque-different",
		lineRuntimeCapabilityAnyConnect,
		true,
		func() (lineRuntimeCapability, error) {
			created = true
			return &lineRuntimePoolTestCapability{
				kindValue: lineRuntimeCapabilityAnyConnect,
			}, nil
		},
	)
	if !errors.Is(err, errLineRuntimeExclusive) || created {
		t.Fatalf("exclusive conflict = (%v, factory called %v)", err, created)
	}
	pool.releaseCandidate(2)
	if source.stops.Load() != 0 {
		t.Fatal("exclusive conflict disturbed the committed capability")
	}
}

func TestLineRuntimePoolStopAllClearsEveryLeaseOnce(t *testing.T) {
	var pool lineRuntimePool
	source := &lineRuntimePoolTestCapability{kindValue: "shareable"}
	candidate := &lineRuntimePoolTestCapability{kindValue: "shareable"}
	if err := pool.beginCandidate(1); err != nil {
		t.Fatal(err)
	}
	if _, _, err := pool.acquireCandidate(
		1,
		"opaque-source",
		"shareable",
		false,
		func() (lineRuntimeCapability, error) { return source, nil },
	); err != nil {
		t.Fatal(err)
	}
	if err := pool.promoteCandidate(1); err != nil {
		t.Fatal(err)
	}
	if err := pool.beginCandidate(2); err != nil {
		t.Fatal(err)
	}
	if _, _, err := pool.acquireCandidate(
		2,
		"opaque-candidate",
		"shareable",
		false,
		func() (lineRuntimeCapability, error) { return candidate, nil },
	); err != nil {
		t.Fatal(err)
	}
	pool.stopAll()
	pool.stopAll()
	if source.stops.Load() != 1 || candidate.stops.Load() != 1 {
		t.Fatalf(
			"StopAll stops = source %d, candidate %d",
			source.stops.Load(),
			candidate.stops.Load(),
		)
	}
	if err := pool.beginCandidate(3); err != nil {
		t.Fatalf("pool retained stale generation after StopAll: %v", err)
	}
	pool.releaseCandidate(3)
}

func TestLineRuntimePoolConcurrentStopAllAndRelease(t *testing.T) {
	for iteration := 0; iteration < 100; iteration++ {
		var pool lineRuntimePool
		capability := &lineRuntimePoolTestCapability{kindValue: "shareable"}
		if err := pool.beginCandidate(1); err != nil {
			t.Fatal(err)
		}
		if _, _, err := pool.acquireCandidate(
			1,
			"opaque-race",
			"shareable",
			false,
			func() (lineRuntimeCapability, error) { return capability, nil },
		); err != nil {
			t.Fatal(err)
		}
		if err := pool.promoteCandidate(1); err != nil {
			t.Fatal(err)
		}
		var wait sync.WaitGroup
		wait.Add(2)
		go func() {
			defer wait.Done()
			pool.releaseCommitted(1)
		}()
		go func() {
			defer wait.Done()
			pool.stopAll()
		}()
		wait.Wait()
		if capability.stops.Load() != 1 {
			t.Fatalf("iteration %d stopped capability %d times", iteration, capability.stops.Load())
		}
	}
}

func TestLineRuntimePoolStopAllInvalidatesBlockedFactory(t *testing.T) {
	var pool lineRuntimePool
	if err := pool.beginCandidate(1); err != nil {
		t.Fatal(err)
	}
	factoryStarted := make(chan struct{})
	factoryRelease := make(chan struct{})
	created := &lineRuntimePoolTestCapability{kindValue: "shareable"}
	result := make(chan error, 1)
	go func() {
		_, _, err := pool.acquireCandidate(
			1,
			"opaque-blocked-factory",
			"shareable",
			false,
			func() (lineRuntimeCapability, error) {
				close(factoryStarted)
				<-factoryRelease
				return created, nil
			},
		)
		result <- err
	}()
	<-factoryStarted

	stopDone := make(chan struct{})
	go func() {
		pool.stopAll()
		close(stopDone)
	}()
	select {
	case <-stopDone:
	case <-time.After(time.Second):
		t.Fatal("StopAll blocked behind the capability factory")
	}
	if err := pool.beginCandidate(2); err != nil {
		t.Fatalf("StopAll did not invalidate the old generation: %v", err)
	}
	pool.releaseCandidate(2)
	close(factoryRelease)
	if err := <-result; !errors.Is(err, errLineRuntimeInvalidated) {
		t.Fatalf("late factory result = %v", err)
	}
	if created.stops.Load() != 1 {
		t.Fatalf("late capability stopped %d times", created.stops.Load())
	}
}

func TestLineRuntimePoolConcurrentSameIdentityConstructsOnce(t *testing.T) {
	var pool lineRuntimePool
	if err := pool.beginCandidate(1); err != nil {
		t.Fatal(err)
	}
	factoryStarted := make(chan struct{})
	factoryRelease := make(chan struct{})
	created := &lineRuntimePoolTestCapability{kindValue: "shareable"}
	var factoryCalls atomic.Int32
	type acquireResult struct {
		capability lineRuntimeCapability
		reused     bool
		err        error
	}
	results := make(chan acquireResult, 2)
	factory := func() (lineRuntimeCapability, error) {
		if factoryCalls.Add(1) == 1 {
			close(factoryStarted)
		}
		<-factoryRelease
		return created, nil
	}
	go func() {
		capability, reused, err := pool.acquireCandidate(
			1,
			"opaque-deduplicated",
			"shareable",
			false,
			factory,
		)
		results <- acquireResult{capability, reused, err}
	}()
	<-factoryStarted
	go func() {
		capability, reused, err := pool.acquireCandidate(
			1,
			"opaque-deduplicated",
			"shareable",
			false,
			factory,
		)
		results <- acquireResult{capability, reused, err}
	}()
	close(factoryRelease)
	first := <-results
	second := <-results
	if first.err != nil || second.err != nil ||
		first.capability != created || second.capability != created {
		t.Fatalf("same identity results = %+v, %+v", first, second)
	}
	if first.reused == second.reused {
		t.Fatalf("one caller must publish and one reuse: %+v, %+v", first, second)
	}
	if factoryCalls.Load() != 1 {
		t.Fatalf("factory called %d times", factoryCalls.Load())
	}
	pool.stopAll()
	if created.stops.Load() != 1 {
		t.Fatalf("deduplicated capability stopped %d times", created.stops.Load())
	}
}
