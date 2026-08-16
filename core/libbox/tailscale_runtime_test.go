//go:build !windows

package libbox

import (
	"context"
	stdjson "encoding/json"
	"errors"
	"net"
	"sync"
	"testing"

	"github.com/sagernet/sing-box/adapter"
	boxOutbound "github.com/sagernet/sing-box/adapter/outbound"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
)

const tailscaleRuntimeTestConfig = `{
  "log":{"disabled":true},
  "dns":{"servers":[{
    "type":"udp","tag":"xdial-system-dns","server":"192.0.2.53","server_port":53
  }],"final":"xdial-system-dns"},
  "endpoints":[{
    "type":"tailscale",
    "tag":"tailscale-tail",
    "state_directory":"/tmp/xdial-tailscale-runtime-test",
    "exit_node":"100.64.0.1"
  }],
  "inbounds":[],
  "outbounds":[{"type":"direct","tag":"direct"}],
  "route":{"final":"tailscale-tail","default_domain_resolver":"xdial-system-dns"}
}`

func TestPrepareTailscaleRuntimeSpecSeparatesEndpointOwnership(t *testing.T) {
	spec, err := prepareTailscaleRuntimeSpec(
		tailscaleRuntimeTestConfig,
		"tail",
		"line-runtime-v1:test",
	)
	if err != nil {
		t.Fatalf("prepare Tailscale runtime spec: %v", err)
	}
	if spec.endpointTag != "tailscale-tail" || spec.lineID != "tail" ||
		spec.identity != "line-runtime-v1:test" {
		t.Fatalf("unexpected runtime spec: %+v", spec)
	}

	var consumer struct {
		Endpoints []stdjson.RawMessage `json:"endpoints"`
		Outbounds []struct {
			Type string `json:"type"`
			Tag  string `json:"tag"`
		} `json:"outbounds"`
	}
	if err := stdjson.Unmarshal(
		[]byte(spec.consumerConfigJSON),
		&consumer,
	); err != nil {
		t.Fatalf("decode consumer config: %v", err)
	}
	if len(consumer.Endpoints) != 0 {
		t.Fatalf("consumer retained Tailscale endpoint: %s", spec.consumerConfigJSON)
	}
	foundBorrowed := false
	for _, outbound := range consumer.Outbounds {
		if outbound.Tag == spec.endpointTag {
			foundBorrowed = outbound.Type == typeTailscaleRuntime
		}
	}
	if !foundBorrowed {
		t.Fatalf("consumer did not receive borrowed outbound: %s", spec.consumerConfigJSON)
	}

	var capability struct {
		DNS struct {
			Final   string `json:"final"`
			Servers []struct {
				Type   string `json:"type"`
				Tag    string `json:"tag"`
				Server string `json:"server"`
			} `json:"servers"`
		} `json:"dns"`
		Endpoints []struct {
			Type     string `json:"type"`
			Tag      string `json:"tag"`
			ExitNode string `json:"exit_node"`
		} `json:"endpoints"`
	}
	if err := stdjson.Unmarshal(
		[]byte(spec.capabilityConfigJSON),
		&capability,
	); err != nil {
		t.Fatalf("decode capability config: %v", err)
	}
	if len(capability.Endpoints) != 1 ||
		capability.Endpoints[0].Type != "tailscale" ||
		capability.Endpoints[0].Tag != spec.endpointTag ||
		capability.Endpoints[0].ExitNode != "100.64.0.1" {
		t.Fatalf("capability lost endpoint configuration: %+v", capability)
	}
	if capability.DNS.Final != "xdial-system-dns" ||
		len(capability.DNS.Servers) != 1 ||
		capability.DNS.Servers[0].Type != "udp" ||
		capability.DNS.Servers[0].Server != "192.0.2.53" {
		t.Fatalf("capability lost startup system DNS: %+v", capability.DNS)
	}
}

func TestPrepareTailscaleRuntimeSpecRequiresOneEndpoint(t *testing.T) {
	for name, configJSON := range map[string]string{
		"missing": `{"endpoints":[],"outbounds":[]}`,
		"multiple": `{
          "endpoints":[
            {"type":"tailscale","tag":"tailscale-a","state_directory":"/tmp/a"},
            {"type":"tailscale","tag":"tailscale-b","state_directory":"/tmp/b"}
          ],
          "outbounds":[]
        }`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := prepareTailscaleRuntimeSpec(
				configJSON,
				"tail",
				"line-runtime-v1:test",
			); err == nil {
				t.Fatal("expected invalid endpoint count to fail")
			}
		})
	}
}

type tailscaleRuntimeTestOutbound struct {
	boxOutbound.Adapter
}

func newTailscaleRuntimeTestOutbound() *tailscaleRuntimeTestOutbound {
	return &tailscaleRuntimeTestOutbound{Adapter: boxOutbound.NewAdapter(
		typeTailscaleRuntime,
		"tailscale-tail",
		[]string{N.NetworkTCP, N.NetworkUDP},
		nil,
	)}
}

func (o *tailscaleRuntimeTestOutbound) DialContext(
	context.Context,
	string,
	M.Socksaddr,
) (net.Conn, error) {
	return nil, errors.New("test outbound does not dial")
}

func (o *tailscaleRuntimeTestOutbound) ListenPacket(
	context.Context,
	M.Socksaddr,
) (net.PacketConn, error) {
	return nil, errors.New("test outbound does not dial")
}

type tailscaleRuntimeTestCapability struct {
	mu       sync.Mutex
	line     *tailscaleLineRuntime
	platform *xdPlatformInterface
	stops    int
}

func (c *tailscaleRuntimeTestCapability) kind() lineRuntimeCapabilityKind {
	return lineRuntimeCapabilityTailscale
}

func (c *tailscaleRuntimeTestCapability) available() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.stops == 0 && c.line != nil
}

func (c *tailscaleRuntimeTestCapability) lineHandle() *tailscaleLineRuntime {
	return c.line
}

func (c *tailscaleRuntimeTestCapability) platformInterface() *xdPlatformInterface {
	return c.platform
}

func (c *tailscaleRuntimeTestCapability) stop() {
	c.mu.Lock()
	c.stops++
	c.mu.Unlock()
}

func (c *tailscaleRuntimeTestCapability) stopCount() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.stops
}

func TestPreparedSwitchReusesTailscaleCapabilityUntilFinalLease(t *testing.T) {
	instance := New(nil)
	if err := instance.SetNetworkInterfaces(
		`[{"name":"en0","index":7,"type":"wifi"}]`,
	); err != nil {
		t.Fatalf("set source interfaces: %v", err)
	}
	instance.SetDefaultInterface("en0", 7)
	capability := &tailscaleRuntimeTestCapability{
		line: &tailscaleLineRuntime{outbound: newTailscaleRuntimeTestOutbound()},
	}
	created := 0
	instance.createTailscaleRuntimeCapabilityFunc = func(
		_ context.Context,
		_ *tailscaleRuntimeSpec,
		platform *xdPlatformInterface,
	) (pooledTailscaleRuntime, error) {
		created++
		capability.platform = platform
		return capability, nil
	}
	if err := instance.StartStandaloneWithTailscaleLineID(
		"tail",
		"line-runtime-v1:test",
		tailscaleRuntimeTestConfig,
	); err != nil {
		t.Fatalf("start source generation: %v", err)
	}
	if created != 1 {
		t.Fatalf("created %d Tailscale capabilities, want 1", created)
	}
	if capability.platform == instance.platform {
		t.Fatal("Tailscale capability shared PlatformInterface ownership with source Box")
	}

	if err := instance.PrepareSwitchWithLineRuntimeIDs(
		tailscaleRuntimeTestConfig,
		"",
		"",
		"tail",
		"line-runtime-v1:test",
		`[{"name":"en0","index":7,"type":"wifi"}]`,
		"en0",
		7,
	); err != nil {
		t.Fatalf("prepare candidate generation: %v", err)
	}
	if created != 1 {
		t.Fatalf("candidate created a second Tailscale capability")
	}
	reused, err := instance.PreparedSwitchReusedLineIDs()
	if err != nil {
		t.Fatalf("read reused Line evidence: %v", err)
	}
	if reused != `["tail"]` {
		t.Fatalf("reused Line evidence = %s, want [\"tail\"]", reused)
	}
	if err := instance.CommitPreparedSwitch(); err != nil {
		t.Fatalf("commit candidate generation: %v", err)
	}
	if err := instance.RetireCommittedSwitch(); err != nil {
		t.Fatalf("retire source generation: %v", err)
	}
	if capability.stopCount() != 0 {
		t.Fatal("retiring source stopped capability still leased by candidate")
	}

	if err := instance.PrepareSwitchWithLineRuntimeIDs(
		tailscaleRuntimeTestConfig,
		"",
		"",
		"tail",
		"line-runtime-v1:test",
		`[{"name":"en1","index":8,"type":"wifi"}]`,
		"en1",
		8,
	); err != nil {
		t.Fatalf("prepare second candidate generation: %v", err)
	}
	if created != 1 {
		t.Fatal("second switch created another Tailscale capability")
	}
	if diagnostics := capability.platform.diagnostics(); diagnostics.DefaultInterfaceName != "en1" ||
		diagnostics.DefaultInterfaceIndex != 8 {
		t.Fatalf("shared capability kept stale Underlay: %+v", diagnostics)
	}
	if err := instance.CommitPreparedSwitch(); err != nil {
		t.Fatalf("commit second candidate generation: %v", err)
	}
	if err := instance.RetireCommittedSwitch(); err != nil {
		t.Fatalf("retire second source generation: %v", err)
	}
	if capability.stopCount() != 0 {
		t.Fatal("second retirement stopped capability still leased by active generation")
	}
	if err := instance.Stop(); err != nil {
		t.Fatalf("stop active generation: %v", err)
	}
	if capability.stopCount() != 1 {
		t.Fatalf("capability stop count = %d, want 1", capability.stopCount())
	}
}

func TestLineRuntimeCapabilityPreparationDetachesFromFirstBorrower(t *testing.T) {
	parent, cancelParent := context.WithCancel(context.Background())
	preparation := newLineRuntimeCapabilityPreparation(parent)
	if err := preparation.detach(); err != nil {
		t.Fatalf("detach live capability preparation: %v", err)
	}
	cancelParent()
	select {
	case <-preparation.runtimeCtx.Done():
		t.Fatal("retiring first borrower canceled detached capability")
	default:
	}
	preparation.cancel()
}

func TestLineRuntimeCapabilityPreparationCancelsBeforePublication(t *testing.T) {
	parent, cancelParent := context.WithCancel(context.Background())
	preparation := newLineRuntimeCapabilityPreparation(parent)
	cancelParent()
	if err := preparation.detach(); err == nil {
		t.Fatal("canceled preparation detached successfully")
	}
	select {
	case <-preparation.runtimeCtx.Done():
	default:
		t.Fatal("canceled preparation left runtime context alive")
	}
}

func TestTailscaleSwitchFailureAndAbortPreserveCommittedCapability(t *testing.T) {
	instance := New(nil)
	if err := instance.SetNetworkInterfaces(
		`[{"name":"en0","index":7,"type":"wifi"}]`,
	); err != nil {
		t.Fatalf("set source interfaces: %v", err)
	}
	instance.SetDefaultInterface("en0", 7)
	capability := &tailscaleRuntimeTestCapability{
		line: &tailscaleLineRuntime{outbound: newTailscaleRuntimeTestOutbound()},
	}
	created := 0
	instance.createTailscaleRuntimeCapabilityFunc = func(
		_ context.Context,
		_ *tailscaleRuntimeSpec,
		platform *xdPlatformInterface,
	) (pooledTailscaleRuntime, error) {
		created++
		capability.platform = platform
		return capability, nil
	}
	if err := instance.StartStandaloneWithTailscaleLineID(
		"tail",
		"line-runtime-v1:source",
		tailscaleRuntimeTestConfig,
	); err != nil {
		t.Fatalf("start source generation: %v", err)
	}

	err := instance.PrepareSwitchWithLineRuntimeIDs(
		tailscaleRuntimeTestConfig,
		"",
		"",
		"tail",
		"line-runtime-v1:different",
		`[{"name":"en0","index":7,"type":"wifi"}]`,
		"en0",
		7,
	)
	if err == nil || err.Error() != "Tailscale runtime identity is not reusable" {
		t.Fatalf("different identity error = %v", err)
	}
	if !instance.IsRunning() || !capability.available() ||
		capability.stopCount() != 0 || created != 1 {
		t.Fatal("failed candidate disturbed committed Tailscale capability")
	}

	if err := instance.PrepareSwitchWithLineRuntimeIDs(
		tailscaleRuntimeTestConfig,
		"",
		"",
		"tail",
		"line-runtime-v1:source",
		`[{"name":"en0","index":7,"type":"wifi"}]`,
		"en0",
		7,
	); err != nil {
		t.Fatalf("prepare abortable candidate: %v", err)
	}
	if err := instance.AbortPreparedSwitch(); err != nil {
		t.Fatalf("abort candidate: %v", err)
	}
	if !instance.IsRunning() || !capability.available() ||
		capability.stopCount() != 0 || created != 1 {
		t.Fatal("aborted candidate disturbed committed Tailscale capability")
	}
	if err := instance.Stop(); err != nil {
		t.Fatalf("stop committed generation: %v", err)
	}
	if capability.stopCount() != 1 {
		t.Fatalf("capability stop count = %d, want 1", capability.stopCount())
	}
}

var _ adapter.Outbound = (*tailscaleRuntimeTestOutbound)(nil)
var _ pooledTailscaleRuntime = (*tailscaleRuntimeTestCapability)(nil)
