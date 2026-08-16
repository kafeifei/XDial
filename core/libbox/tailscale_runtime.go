//go:build !windows

package libbox

import (
	"context"
	stdjson "encoding/json"
	"fmt"
	"net"
	"net/netip"
	"strings"
	"sync"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/adapter/outbound"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/sing/service"
)

const typeTailscaleRuntime = "xdial-tailscale-runtime"

type tailscaleRuntimeSpec struct {
	lineID               string
	identity             string
	endpointTag          string
	consumerConfigJSON   string
	capabilityConfigJSON string
}

// lineRuntimeCapabilityPreparation lets a blocking factory observe candidate
// cancellation only while it is preparing. Once detach succeeds, the runtime
// context is owned solely by the capability pool and retiring the generation
// that first requested it cannot cancel later borrowers.
type lineRuntimeCapabilityPreparation struct {
	parent      context.Context
	runtimeCtx  context.Context
	cancel      context.CancelFunc
	prepared    chan struct{}
	watcherDone chan struct{}
	finishOnce  sync.Once
}

func newLineRuntimeCapabilityPreparation(
	parent context.Context,
) *lineRuntimeCapabilityPreparation {
	if parent == nil {
		parent = context.Background()
	}
	runtimeCtx, cancel := context.WithCancel(context.Background())
	preparation := &lineRuntimeCapabilityPreparation{
		parent:      parent,
		runtimeCtx:  runtimeCtx,
		cancel:      cancel,
		prepared:    make(chan struct{}),
		watcherDone: make(chan struct{}),
	}
	go func() {
		defer close(preparation.watcherDone)
		select {
		case <-parent.Done():
			cancel()
		case <-preparation.prepared:
		}
	}()
	return preparation
}

func (p *lineRuntimeCapabilityPreparation) detach() error {
	p.finishOnce.Do(func() { close(p.prepared) })
	<-p.watcherDone
	if err := p.parent.Err(); err != nil {
		p.cancel()
		return err
	}
	return nil
}

func (p *lineRuntimeCapabilityPreparation) abort() {
	p.cancel()
	p.finishOnce.Do(func() { close(p.prepared) })
	<-p.watcherDone
}

// pooledTailscaleRuntime is the process-owned Tailscale endpoint capability.
// A source and candidate Box may borrow its stable outbound handle at the same
// time; the pool stops the endpoint only after the final generation lease is
// released.
type pooledTailscaleRuntime interface {
	lineRuntimeCapability
	available() bool
	lineHandle() *tailscaleLineRuntime
	platformInterface() *xdPlatformInterface
}

type tailscaleLineRuntime struct {
	outbound adapter.Outbound
}

// tailscaleRuntimeOutbound gives an immutable consumer Box the same outbound
// tag that its generated Tailscale endpoint had, while all endpoint state and
// LocalAPI ownership remain in the process-level capability Box.
type tailscaleRuntimeOutbound struct {
	outbound.Adapter
	line *tailscaleLineRuntime
}

var (
	_ adapter.Outbound                    = (*tailscaleRuntimeOutbound)(nil)
	_ adapter.OutboundWithPreferredRoutes = (*tailscaleRuntimeOutbound)(nil)
)

func registerTailscaleRuntimeOutbound(registry *outbound.Registry) {
	outbound.Register[option.StubOptions](
		registry,
		typeTailscaleRuntime,
		newTailscaleRuntimeOutbound,
	)
}

func newTailscaleRuntimeOutbound(
	ctx context.Context,
	_ adapter.Router,
	_ log.ContextLogger,
	tag string,
	_ option.StubOptions,
) (adapter.Outbound, error) {
	line := service.FromContext[*tailscaleLineRuntime](ctx)
	if line == nil || line.outbound == nil {
		return nil, fmt.Errorf("Tailscale runtime outbound is unavailable")
	}
	return &tailscaleRuntimeOutbound{
		Adapter: outbound.NewAdapter(
			typeTailscaleRuntime,
			tag,
			[]string{N.NetworkTCP, N.NetworkUDP},
			nil,
		),
		line: line,
	}, nil
}

func (o *tailscaleRuntimeOutbound) DialContext(
	ctx context.Context,
	network string,
	destination M.Socksaddr,
) (net.Conn, error) {
	return o.line.outbound.DialContext(ctx, network, destination)
}

func (o *tailscaleRuntimeOutbound) ListenPacket(
	ctx context.Context,
	destination M.Socksaddr,
) (net.PacketConn, error) {
	return o.line.outbound.ListenPacket(ctx, destination)
}

func (o *tailscaleRuntimeOutbound) PreferredDomain(
	metadata *adapter.InboundContext,
	domain string,
) bool {
	preferred, ok := o.line.outbound.(adapter.OutboundWithPreferredRoutes)
	return ok && preferred.PreferredDomain(metadata, domain)
}

func (o *tailscaleRuntimeOutbound) PreferredAddress(
	metadata *adapter.InboundContext,
	address netip.Addr,
) bool {
	preferred, ok := o.line.outbound.(adapter.OutboundWithPreferredRoutes)
	return ok && preferred.PreferredAddress(metadata, address)
}

type tailscaleRuntimeConfigEndpoint struct {
	Type string `json:"type"`
	Tag  string `json:"tag"`
}

type tailscaleRuntimeConfigOutbound struct {
	Tag string `json:"tag"`
}

type tailscaleRuntimeDNSDocument struct {
	Servers []stdjson.RawMessage `json:"servers"`
}

type tailscaleRuntimeDNSServer struct {
	Tag string `json:"tag"`
}

type tailscaleRuntimeRouteDocument struct {
	DefaultDomainResolver stdjson.RawMessage `json:"default_domain_resolver"`
}

// prepareTailscaleRuntimeSpec separates one generated Tailscale endpoint from
// the immutable consumer configuration. The capability Box owns the real
// endpoint and state directory; the consumer receives a same-tag borrowed
// outbound, so Scenario rules do not need a product-specific rewrite.
func prepareTailscaleRuntimeSpec(
	configJSON,
	lineID,
	identity string,
) (*tailscaleRuntimeSpec, error) {
	lineID = strings.TrimSpace(lineID)
	identity = strings.TrimSpace(identity)
	if lineID == "" {
		return nil, fmt.Errorf("Tailscale Line ID is required")
	}
	if identity == "" {
		return nil, fmt.Errorf("Tailscale runtime identity is required")
	}

	var document map[string]stdjson.RawMessage
	if err := stdjson.Unmarshal([]byte(configJSON), &document); err != nil {
		return nil, fmt.Errorf("inspect Tailscale runtime config: %w", err)
	}
	var endpoints []stdjson.RawMessage
	if raw := document["endpoints"]; len(raw) != 0 {
		if err := stdjson.Unmarshal(raw, &endpoints); err != nil {
			return nil, fmt.Errorf("inspect Tailscale endpoints: %w", err)
		}
	}

	remainingEndpoints := make([]stdjson.RawMessage, 0, len(endpoints))
	var tailscaleEndpoint stdjson.RawMessage
	var endpointTag string
	for _, rawEndpoint := range endpoints {
		var endpoint tailscaleRuntimeConfigEndpoint
		if err := stdjson.Unmarshal(rawEndpoint, &endpoint); err != nil {
			return nil, fmt.Errorf("inspect Tailscale endpoint: %w", err)
		}
		if endpoint.Type != "tailscale" {
			remainingEndpoints = append(remainingEndpoints, rawEndpoint)
			continue
		}
		if tailscaleEndpoint != nil {
			return nil, fmt.Errorf("multiple Tailscale runtime endpoints are unavailable")
		}
		endpointTag = strings.TrimSpace(endpoint.Tag)
		if endpointTag == "" {
			return nil, fmt.Errorf("Tailscale runtime endpoint tag is unavailable")
		}
		tailscaleEndpoint = append(stdjson.RawMessage(nil), rawEndpoint...)
	}
	if tailscaleEndpoint == nil {
		return nil, fmt.Errorf("Tailscale runtime endpoint is unavailable")
	}
	capabilityDNS, capabilityResolver := tailscaleRuntimeCapabilityDNS(document)

	var outbounds []stdjson.RawMessage
	if raw := document["outbounds"]; len(raw) != 0 {
		if err := stdjson.Unmarshal(raw, &outbounds); err != nil {
			return nil, fmt.Errorf("inspect Tailscale runtime outbounds: %w", err)
		}
	}
	for _, rawOutbound := range outbounds {
		var outboundDocument tailscaleRuntimeConfigOutbound
		if err := stdjson.Unmarshal(rawOutbound, &outboundDocument); err != nil {
			return nil, fmt.Errorf("inspect Tailscale runtime outbound: %w", err)
		}
		if strings.TrimSpace(outboundDocument.Tag) == endpointTag {
			return nil, fmt.Errorf("Tailscale runtime outbound tag is duplicated")
		}
	}
	borrowedOutbound, err := stdjson.Marshal(map[string]string{
		"type": typeTailscaleRuntime,
		"tag":  endpointTag,
	})
	if err != nil {
		return nil, fmt.Errorf("encode Tailscale runtime outbound: %w", err)
	}
	outbounds = append(outbounds, borrowedOutbound)
	encodedEndpoints, err := stdjson.Marshal(remainingEndpoints)
	if err != nil {
		return nil, fmt.Errorf("encode Tailscale consumer endpoints: %w", err)
	}
	encodedOutbounds, err := stdjson.Marshal(outbounds)
	if err != nil {
		return nil, fmt.Errorf("encode Tailscale consumer outbounds: %w", err)
	}
	document["endpoints"] = encodedEndpoints
	document["outbounds"] = encodedOutbounds
	consumerConfig, err := stdjson.Marshal(document)
	if err != nil {
		return nil, fmt.Errorf("encode Tailscale consumer config: %w", err)
	}

	capabilityConfig, err := stdjson.Marshal(map[string]any{
		"log":       map[string]any{"disabled": true},
		"dns":       capabilityDNS,
		"endpoints": []stdjson.RawMessage{tailscaleEndpoint},
		"inbounds":  []any{},
		"outbounds": []map[string]any{{"type": "direct", "tag": "direct"}},
		"route": map[string]any{
			"final":                   "direct",
			"default_domain_resolver": capabilityResolver,
		},
	})
	if err != nil {
		return nil, fmt.Errorf("encode Tailscale capability config: %w", err)
	}
	return &tailscaleRuntimeSpec{
		lineID:               lineID,
		identity:             identity,
		endpointTag:          endpointTag,
		consumerConfigJSON:   string(consumerConfig),
		capabilityConfigJSON: string(capabilityConfig),
	}, nil
}

// tailscaleRuntimeCapabilityDNS preserves the startup system resolver chosen
// by the generated Transparent Proxy config. A pooled endpoint can reconnect
// after system interception is committed, so replacing that resolver with a
// fresh local lookup would lose the captured Underlay DNS view.
func tailscaleRuntimeCapabilityDNS(
	document map[string]stdjson.RawMessage,
) (map[string]any, string) {
	const fallbackTag = "xdial-tailscale-runtime-system-dns"
	fallback := map[string]any{
		"servers": []map[string]any{{
			"type": "local",
			"tag":  fallbackTag,
		}},
		"final": fallbackTag,
	}
	var route tailscaleRuntimeRouteDocument
	if stdjson.Unmarshal(document["route"], &route) != nil ||
		len(route.DefaultDomainResolver) == 0 {
		return fallback, fallbackTag
	}
	var resolverTag string
	if stdjson.Unmarshal(route.DefaultDomainResolver, &resolverTag) != nil {
		return fallback, fallbackTag
	}
	resolverTag = strings.TrimSpace(resolverTag)
	if resolverTag == "" {
		return fallback, fallbackTag
	}
	var dnsDocument tailscaleRuntimeDNSDocument
	if stdjson.Unmarshal(document["dns"], &dnsDocument) != nil {
		return fallback, fallbackTag
	}
	for _, rawServer := range dnsDocument.Servers {
		var server tailscaleRuntimeDNSServer
		if stdjson.Unmarshal(rawServer, &server) != nil ||
			strings.TrimSpace(server.Tag) != resolverTag {
			continue
		}
		return map[string]any{
			"servers": []stdjson.RawMessage{rawServer},
			"final":   resolverTag,
		}, resolverTag
	}
	return fallback, fallbackTag
}
