//go:build !windows

package libbox

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/sagernet/sing-box/adapter"
)

// Process-local hints survive engine replacement, but contain no observed IPs.
// Every call still borrows and verifies its own running generation.
var addressProbePolicy = newAddressProbePolicy()

type addressProbeServiceState struct {
	failures    int
	nextAttempt time.Time
}

type outboundAddressPolicy struct {
	mu        sync.Mutex
	preferred map[string]string
	services  map[string]addressProbeServiceState
	slots     chan struct{}
}

func newAddressProbePolicy() *outboundAddressPolicy {
	return &outboundAddressPolicy{
		preferred: make(map[string]string), services: make(map[string]addressProbeServiceState),
		slots: make(chan struct{}, 2),
	}
}

func (p *outboundAddressPolicy) preference(key string) string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.preferred[key]
}

func (p *outboundAddressPolicy) remember(key, endpoint string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if len(p.preferred) >= 256 {
		clear(p.preferred)
	}
	p.preferred[key] = endpoint
}

// At most one request per second per service/family across all Lines. After
// three failures, back off 30/60/120/240/300 seconds. Rejected admissions never
// extend the backoff; cancellation of a losing request is not a failure.
func (p *outboundAddressPolicy) admit(service string, now time.Time) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	state := p.services[service]
	if now.Before(state.nextAttempt) {
		return false
	}
	state.nextAttempt = now.Add(time.Second)
	p.services[service] = state
	return true
}

func (p *outboundAddressPolicy) finish(service string, failed bool, now time.Time) {
	p.mu.Lock()
	defer p.mu.Unlock()
	state := p.services[service]
	if !failed {
		state.failures = 0
	} else {
		state.failures++
		if state.failures >= 3 {
			delay := 30 * time.Second << min(state.failures-3, 4)
			state.nextAttempt = now.Add(min(delay, 5*time.Minute))
		}
	}
	p.services[service] = state
}

func addressProbeService(endpoint outboundAddressProbeEndpoint, family string) string {
	if strings.Contains(endpoint.url, "r.inews.qq.com") {
		return "tencent/" + family
	}
	return "cloudflare/" + family
}

type addressProbeFunc func(context.Context, adapter.Outbound, outboundAddressProbeEndpoint, int) (string, error)

// The caller owns a runtime lease until every worker exits, including losers.
func raceOutboundAddresses(ctx context.Context, outbound adapter.Outbound, endpoints []outboundAddressProbeEndpoint,
	family, preferred string, probe addressProbeFunc, policy *outboundAddressPolicy,
) (string, string, error) {
	ctx, cancel := context.WithCancel(ctx)
	var workers sync.WaitGroup
	defer func() { cancel(); workers.Wait() }()
	type result struct {
		index   int
		address string
		err     error
	}
	results := make(chan result, len(endpoints))
	order := make([]int, 0, len(endpoints))
	for i, endpoint := range endpoints {
		if endpoint.url == preferred {
			order = append(order, i)
		}
	}
	for i, endpoint := range endpoints {
		if endpoint.url != preferred {
			order = append(order, i)
		}
	}
	start := func(index int) {
		workers.Add(1)
		go func() {
			defer workers.Done()
			endpoint := endpoints[index]
			if policy != nil {
				select {
				case policy.slots <- struct{}{}:
				case <-ctx.Done():
					results <- result{index: index, err: ctx.Err()}
					return
				}
				defer func() { <-policy.slots }()
				if ctx.Err() != nil {
					results <- result{index: index, err: ctx.Err()}
					return
				}
				if !policy.admit(addressProbeService(endpoint, family), time.Now()) {
					results <- result{index: index, err: newOutboundAddressProbeError("service-backoff", fmt.Errorf("address service is cooling down"))}
					return
				}
			}
			// Each worker gets the remaining overall budget, not a sequential slice.
			address, err := probe(ctx, outbound, endpoint, 1)
			if err == nil && !addressMatchesFamily(address, family) {
				err = newOutboundAddressProbeError("wrong-family", fmt.Errorf("address family mismatch"))
			}
			if err == nil {
				if _, validationErr := validatePublicProbeAddress(address); validationErr != nil {
					err = newOutboundAddressProbeError("invalid-address", validationErr)
				}
			}
			if policy != nil && !errors.Is(ctx.Err(), context.Canceled) {
				policy.finish(addressProbeService(endpoint, family), err != nil, time.Now())
			}
			results <- result{index, address, err}
		}()
	}
	if len(order) == 0 {
		return "", "", fmt.Errorf("no address probe endpoints")
	}
	start(order[0])
	started, finished := 1, 0
	timer := time.NewTimer(500 * time.Millisecond)
	defer timer.Stop()
	errors := make([]string, len(endpoints))
	for finished < len(endpoints) {
		select {
		case <-ctx.Done():
			return "", "", ctx.Err()
		case <-timer.C:
			if started < len(order) {
				start(order[started])
				started++
				timer.Reset(500 * time.Millisecond)
			}
		case result := <-results:
			finished++
			if result.err == nil && ctx.Err() == nil {
				return result.address, endpoints[result.index].url, nil
			}
			errors[result.index] = familyProbeFailureCode(family, result.index, outboundAddressProbeSafeCode(result.err))
			if started < len(order) {
				start(order[started])
				started++
			}
		}
	}
	return "", "", fmt.Errorf("outbound address probe failed: %s", strings.Join(errors, "; "))
}
