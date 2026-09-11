//go:build !windows && with_gvisor && !mobile_no_tailscale

package libbox

import (
	"context"
	stdjson "encoding/json"
	"fmt"
	"hash/fnv"
	"os"
	"sort"
	"sync"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/option"
	boxTailscale "github.com/sagernet/sing-box/protocol/tailscale"
	"github.com/sagernet/sing/common/json"
	"github.com/sagernet/sing/service"
)

type tailscaleRuntimeCapability struct {
	mu         sync.Mutex
	instance   *box.Box
	endpoint   *boxTailscale.Endpoint
	line       *tailscaleLineRuntime
	platform   *xdPlatformInterface
	runtimeCtx context.Context
	cancel     context.CancelFunc
	stateLocks []*os.File
	stopped    bool
	stopOnce   sync.Once
}

func (c *tailscaleRuntimeCapability) kind() lineRuntimeCapabilityKind {
	return lineRuntimeCapabilityTailscale
}

func (c *tailscaleRuntimeCapability) available() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return !c.stopped && c.instance != nil && c.endpoint != nil &&
		c.line != nil && c.platform != nil && c.runtimeCtx != nil &&
		c.runtimeCtx.Err() == nil
}

func (c *tailscaleRuntimeCapability) lineHandle() *tailscaleLineRuntime {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.stopped {
		return nil
	}
	return c.line
}

func (c *tailscaleRuntimeCapability) platformInterface() *xdPlatformInterface {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.platform
}

// Only causally relevant lifecycle facts form the stamp. Traffic counters,
// last-seen times and normal handshake refresh timestamps must not invalidate
// an otherwise current proof every time the Provider asks for status.
func (c *tailscaleRuntimeCapability) readinessRevision() uint64 {
	c.mu.Lock()
	endpoint, platform := c.endpoint, c.platform
	valid := !c.stopped && endpoint != nil && platform != nil && c.runtimeCtx != nil && c.runtimeCtx.Err() == nil
	c.mu.Unlock()
	if !valid || endpoint.Server() == nil {
		return 0
	}
	backend := endpoint.Server().ExportLocalBackend()
	if backend == nil {
		return 0
	}
	status := backend.Status()
	type selectedPeer struct {
		ID                                          string
		Online, InNetworkMap, InMagicSock, InEngine bool
	}
	stamp := struct {
		Platform   uint64
		Backend    string
		Runtime    tailscaleReadinessPayload
		ExitID     string
		ExitOnline bool
		Peers      []selectedPeer
	}{Platform: platform.lineNetworkRevision(), Backend: status.BackendState, Runtime: tailscaleRuntimeReadiness(endpoint)}
	if status.ExitNodeStatus != nil {
		stamp.ExitID = string(status.ExitNodeStatus.ID)
		stamp.ExitOnline = status.ExitNodeStatus.Online
	}
	for _, peer := range status.Peer {
		if peer.ExitNode {
			stamp.Peers = append(stamp.Peers, selectedPeer{string(peer.ID), peer.Online, peer.InNetworkMap, peer.InMagicSock, peer.InEngine})
		}
	}
	sort.Slice(stamp.Peers, func(i, j int) bool { return stamp.Peers[i].ID < stamp.Peers[j].ID })
	data, _ := stdjson.Marshal(stamp)
	digest := fnv.New64a()
	_, _ = digest.Write(data)
	return digest.Sum64()
}

func (c *tailscaleRuntimeCapability) runtimeEndpoint() (*boxTailscale.Endpoint, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.stopped || c.endpoint == nil || c.runtimeCtx == nil ||
		c.runtimeCtx.Err() != nil {
		return nil, false
	}
	return c.endpoint, true
}

func (c *tailscaleRuntimeCapability) stop() {
	c.stopOnce.Do(func() {
		c.mu.Lock()
		c.stopped = true
		instance := c.instance
		cancel := c.cancel
		stateLocks := c.stateLocks
		c.instance = nil
		c.endpoint = nil
		c.line = nil
		c.platform = nil
		c.runtimeCtx = nil
		c.cancel = nil
		c.stateLocks = nil
		c.mu.Unlock()
		if cancel != nil {
			cancel()
		}
		if instance != nil {
			_ = instance.Close()
		}
		releaseTailscaleStateLocks(stateLocks)
	})
}

func createTailscaleRuntimeCapability(
	parent context.Context,
	spec *tailscaleRuntimeSpec,
	platform *xdPlatformInterface,
) (pooledTailscaleRuntime, error) {
	if spec == nil || platform == nil {
		return nil, fmt.Errorf("Tailscale runtime preparation is unavailable")
	}
	stateLocks, err := acquireTailscaleStateLocks(spec.capabilityConfigJSON)
	if err != nil {
		return nil, err
	}
	preparation := newLineRuntimeCapabilityPreparation(parent)
	runtimeCtx := preparation.runtimeCtx
	cancel := preparation.cancel
	detached := false
	defer func() {
		if !detached {
			preparation.abort()
		}
	}()
	ctx := boxContext(runtimeCtx)
	ctx = service.ContextWith[adapter.PlatformInterface](
		ctx,
		adapter.PlatformInterface(platform),
	)
	options, err := json.UnmarshalExtendedContext[option.Options](
		ctx,
		[]byte(spec.capabilityConfigJSON),
	)
	if err != nil {
		cancel()
		releaseTailscaleStateLocks(stateLocks)
		return nil, fmt.Errorf("parse Tailscale capability config: %w", err)
	}
	instance, err := box.New(box.Options{Options: options, Context: ctx})
	if err != nil {
		cancel()
		releaseTailscaleStateLocks(stateLocks)
		return nil, fmt.Errorf("construct Tailscale capability: %w", err)
	}
	if err := instance.Start(); err != nil {
		_ = instance.Close()
		cancel()
		releaseTailscaleStateLocks(stateLocks)
		return nil, fmt.Errorf("start Tailscale capability: %w", err)
	}
	rawEndpoint, found := instance.Endpoint().Get(spec.endpointTag)
	endpoint, ok := rawEndpoint.(*boxTailscale.Endpoint)
	if !found || !ok {
		_ = instance.Close()
		cancel()
		releaseTailscaleStateLocks(stateLocks)
		return nil, fmt.Errorf("Tailscale capability endpoint is unavailable")
	}
	if err := preparation.detach(); err != nil {
		_ = instance.Close()
		releaseTailscaleStateLocks(stateLocks)
		return nil, fmt.Errorf("Tailscale capability preparation canceled: %w", err)
	}
	detached = true
	return &tailscaleRuntimeCapability{
		instance:   instance,
		endpoint:   endpoint,
		line:       &tailscaleLineRuntime{outbound: endpoint},
		platform:   platform,
		runtimeCtx: runtimeCtx,
		cancel:     cancel,
		stateLocks: stateLocks,
	}, nil
}
