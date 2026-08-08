//go:build !windows

package libbox

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/kafeifei/xdial/core/engine"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing/service"
	"sslcon/session"
)

const switchAnyConnectConfig = `{
	"log":{"disabled":true},
	"outbounds":[
		{"type":"vpn","tag":"vpn"},
		{"type":"direct","tag":"direct"}
	],
	"route":{"final":"vpn"}
}`

const switchNetworkInterfaces = `[{"name":"test0","index":1,"type":"wifi"}]`

func switchCacheConfig(path string, extraOptions string) string {
	return fmt.Sprintf(`{
		"log":{"disabled":true},
		"outbounds":[{"type":"direct","tag":"direct"}],
		"route":{"final":"direct"},
		"experimental":{"cache_file":{"enabled":true,"path":%q%s}}
	}`, path, extraOptions)
}

func prepareSwitchForTest(
	instance *Libbox,
	configJSON,
	identity string,
) error {
	return instance.PrepareSwitch(
		configJSON,
		identity,
		switchNetworkInterfaces,
		"test0",
		1,
	)
}

func prepareSwitchWithLineIDForTest(
	instance *Libbox,
	configJSON,
	lineID,
	identity string,
) error {
	return instance.PrepareSwitchWithLineID(
		configJSON,
		lineID,
		identity,
		switchNetworkInterfaces,
		"test0",
		1,
	)
}

type switchTestVPNClient struct {
	mu              sync.Mutex
	session         *session.ConnSession
	connectCount    int
	disconnectCount int
	disconnectOnce  sync.Once
}

type blockingStartVPNClient struct {
	mu              sync.Mutex
	session         *session.ConnSession
	started         chan struct{}
	release         chan struct{}
	startOnce       sync.Once
	connectCount    int
	disconnectCount int
}

func (c *blockingStartVPNClient) Connect(
	engine.VPNConfig,
) (*engine.VPNInfo, error) {
	c.mu.Lock()
	c.connectCount++
	c.mu.Unlock()
	c.startOnce.Do(func() { close(c.started) })
	<-c.release
	return &engine.VPNInfo{
		VPNAddress: "10.0.0.2",
		DNS:        []string{"10.0.0.53"},
		MTU:        1400,
	}, nil
}

func (c *blockingStartVPNClient) Session() *session.ConnSession {
	return c.session
}

func (c *blockingStartVPNClient) Disconnect() {
	c.mu.Lock()
	c.disconnectCount++
	c.mu.Unlock()
	select {
	case <-c.session.CloseChan:
	default:
		close(c.session.CloseChan)
	}
}

func (c *blockingStartVPNClient) counts() (int, int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.connectCount, c.disconnectCount
}

type blockingLineRuntimeCapability struct {
	started chan struct{}
	release chan struct{}
	once    sync.Once
}

func (c *blockingLineRuntimeCapability) kind() lineRuntimeCapabilityKind {
	return "blocking-test"
}

func (c *blockingLineRuntimeCapability) stop() {
	c.once.Do(func() {
		close(c.started)
		<-c.release
	})
}

func (c *switchTestVPNClient) Connect(
	engine.VPNConfig,
) (*engine.VPNInfo, error) {
	c.mu.Lock()
	c.connectCount++
	c.mu.Unlock()
	return &engine.VPNInfo{
		VPNAddress: "10.0.0.2",
		DNS:        []string{"10.0.0.53"},
		MTU:        1400,
	}, nil
}

func (c *switchTestVPNClient) Session() *session.ConnSession {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.session
}

func (c *switchTestVPNClient) Disconnect() {
	c.mu.Lock()
	c.disconnectCount++
	current := c.session
	c.mu.Unlock()
	if current != nil {
		c.disconnectOnce.Do(func() { close(current.CloseChan) })
	}
}

func (c *switchTestVPNClient) counts() (int, int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.connectCount, c.disconnectCount
}

func newAnyConnectSwitchTestLibbox(
	t *testing.T,
	identity string,
) (*Libbox, *switchTestVPNClient) {
	t.Helper()
	client := &switchTestVPNClient{session: newStartTestSession()}
	platform := &xdPlatformInterface{}
	platform.setDefaultInterface("test0", 1)
	instance := &Libbox{
		vpn:      client,
		platform: platform,
	}
	if err := instance.StartResolvedWithInsecureAndRuntimeIdentity(
		"vpn.example.com:443",
		"192.0.2.10",
		"employee",
		"secret",
		false,
		identity,
		switchAnyConnectConfig,
	); err != nil {
		t.Fatalf("start source generation: %v", err)
	}
	return instance, client
}

func TestPrepareSwitchDoesNotOpenActiveCacheFile(t *testing.T) {
	cachePath := filepath.Join(t.TempDir(), "cache.db")
	configJSON := switchCacheConfig(cachePath, "")
	instance := New(nil)
	instance.platform.setDefaultInterface("test0", 1)
	if err := instance.StartStandalone(configJSON); err != nil {
		t.Fatalf("start source generation: %v", err)
	}
	defer instance.Stop()

	instance.mu.Lock()
	sourceBox := instance.box
	sourceCache := service.FromContext[adapter.CacheFile](
		instance.runtimeCtx,
	)
	instance.mu.Unlock()
	if sourceCache == nil {
		t.Fatal("source generation did not open its configured cache file")
	}

	// Both generated configurations name the same persistent cache.db. Before
	// candidate isolation, sing-box retried the active bbolt lock for about ten
	// seconds and returned "initialize cache-file: timeout" here.
	if err := prepareSwitchForTest(instance, configJSON, ""); err != nil {
		t.Fatalf("prepare candidate sharing configured path: %v", err)
	}
	instance.mu.Lock()
	firstCandidate := instance.preparedSwitch
	instance.mu.Unlock()
	if firstCandidate == nil || firstCandidate.box == nil {
		t.Fatal("cache-isolated candidate was not prepared")
	}
	if candidateCache := service.FromContext[adapter.CacheFile](
		firstCandidate.runtimeCtx,
	); candidateCache != nil {
		t.Fatal("candidate opened a cache service beside the active generation")
	}
	if err := instance.CommitPreparedSwitch(); err != nil {
		t.Fatalf("commit cache-isolated candidate: %v", err)
	}
	instance.mu.Lock()
	activeBox := instance.box
	activeCache := service.FromContext[adapter.CacheFile](instance.runtimeCtx)
	retired := instance.retiredSwitch
	instance.mu.Unlock()
	if activeBox != firstCandidate.box || activeCache != nil {
		t.Fatal("committed candidate did not remain the cache-isolated Box")
	}
	if retired == nil || retired.box != sourceBox {
		t.Fatal("source generation was not retained for bounded drain")
	}
	if err := instance.RetireCommittedSwitch(); err != nil {
		t.Fatalf("retire source generation: %v", err)
	}

	// A cache-less committed generation must remain a complete active Box and
	// support the next immutable Switch; cache_file was not required runtime
	// state for the generated Transparent Proxy contract.
	if err := prepareSwitchForTest(instance, configJSON, ""); err != nil {
		t.Fatalf("prepare second candidate: %v", err)
	}
	if err := instance.CommitPreparedSwitch(); err != nil {
		t.Fatalf("commit second candidate: %v", err)
	}
	if err := instance.RetireCommittedSwitch(); err != nil {
		t.Fatalf("retire first candidate: %v", err)
	}
	if status := instance.Status(); status != `{"running":true}` {
		t.Fatalf("status after two switches = %s", status)
	}
	if _, err := os.Stat(cachePath); err != nil {
		t.Fatalf("persistent source cache was removed: %v", err)
	}
}

func TestPrepareSwitchRejectsPersistentCacheState(t *testing.T) {
	cachePath := filepath.Join(t.TempDir(), "cache.db")
	sourceConfig := switchCacheConfig(cachePath, "")
	instance := New(nil)
	instance.platform.setDefaultInterface("test0", 1)
	if err := instance.StartStandalone(sourceConfig); err != nil {
		t.Fatalf("start source generation: %v", err)
	}
	defer instance.Stop()

	instance.mu.Lock()
	sourceBox := instance.box
	instance.mu.Unlock()
	err := prepareSwitchForTest(
		instance,
		switchCacheConfig(cachePath, `,"store_dns":true`),
		"",
	)
	if err == nil || !strings.Contains(
		err.Error(),
		"persistence requires generation-scoped ownership",
	) {
		t.Fatalf("persistent candidate cache error = %v", err)
	}
	instance.mu.Lock()
	unchanged := instance.running && instance.box == sourceBox &&
		instance.preparedSwitch == nil
	instance.mu.Unlock()
	if !unchanged {
		t.Fatal("rejected persistent cache candidate disturbed the source")
	}
}

func TestStopInvalidatesBlockedColdStartAndCleansLateCapability(
	t *testing.T,
) {
	client := &blockingStartVPNClient{
		session: newStartTestSession(),
		started: make(chan struct{}),
		release: make(chan struct{}),
	}
	callback := &sessionMonitorCallback{}
	platform := &xdPlatformInterface{}
	platform.setDefaultInterface("test0", 1)
	instance := &Libbox{vpn: client, cb: callback, platform: platform}

	startResult := make(chan error, 1)
	go func() {
		startResult <- instance.StartResolvedWithInsecureAndRuntimeIdentity(
			"vpn.example.com:443",
			"192.0.2.10",
			"employee",
			"secret",
			false,
			"line-runtime-v1:blocked-cold-start",
			switchAnyConnectConfig,
		)
	}()
	select {
	case <-client.started:
	case <-time.After(time.Second):
		t.Fatal("cold Start did not reach the blocked capability factory")
	}
	instance.mu.Lock()
	preparationID := instance.startPreparationID
	preparing := instance.startPreparing
	instance.mu.Unlock()
	if !preparing {
		t.Fatal("cold Start did not publish its preparation reservation")
	}

	stopResult := make(chan error, 1)
	go func() { stopResult <- instance.Stop() }()
	deadline := time.Now().Add(time.Second)
	for {
		instance.mu.Lock()
		invalidated := instance.cleaning &&
			instance.startPreparationID != preparationID
		instance.mu.Unlock()
		if invalidated {
			break
		}
		if time.Now().After(deadline) {
			close(client.release)
			<-startResult
			<-stopResult
			t.Fatal("Stop could not invalidate the blocked cold Start")
		}
		runtime.Gosched()
	}
	if status := instance.Status(); status != `{"running":false}` {
		t.Fatalf("status after cold Start invalidation = %s", status)
	}
	select {
	case err := <-stopResult:
		close(client.release)
		<-startResult
		t.Fatalf("Stop returned before late factory cleanup: %v", err)
	case <-time.After(20 * time.Millisecond):
	}

	close(client.release)
	if err := <-startResult; !errors.Is(err, context.Canceled) {
		t.Fatalf("invalidated cold Start error = %v", err)
	}
	if err := <-stopResult; err != nil {
		t.Fatalf("Stop blocked cold Start: %v", err)
	}
	instance.mu.Lock()
	closed := !instance.running && !instance.cleaning &&
		!instance.startPreparing && instance.box == nil
	instance.mu.Unlock()
	if !closed || !instance.lineRuntimes.empty() {
		t.Fatal("blocked cold Start left lifecycle or pool state behind")
	}
	if connects, disconnects := client.counts(); connects != 1 || disconnects != 1 {
		t.Fatalf(
			"late capability lifecycle = connects %d, disconnects %d",
			connects,
			disconnects,
		)
	}
	if events := callback.snapshot(); len(events) != 0 {
		t.Fatalf("explicit Stop emitted stale cold Start callbacks: %#v", events)
	}
}

func TestPrepareSwitchReusesExactAnyConnectCapabilityWithoutRedial(
	t *testing.T,
) {
	const identity = "line-runtime-v1:exact"
	instance, client := newAnyConnectSwitchTestLibbox(t, identity)
	defer instance.Stop()

	instance.mu.Lock()
	oldBox := instance.box
	oldBridge := instance.bridge
	oldLine := instance.anyConnectLine
	oldSession := instance.session
	oldAnyConnectGeneration := instance.generation
	oldBoxGeneration := instance.boxGeneration
	oldLineRuntimeGeneration := instance.activeLineRuntimeGeneration
	oldCapability := instance.activeAnyConnectCapability
	instance.mu.Unlock()

	if err := prepareSwitchForTest(instance,
		switchAnyConnectConfig,
		"line-runtime-v1:different",
	); err == nil {
		t.Fatal("mismatched AnyConnect identity was accepted")
	}
	instance.mu.Lock()
	if instance.box != oldBox || instance.preparedSwitch != nil {
		instance.mu.Unlock()
		t.Fatal("identity mismatch changed the active generation")
	}
	instance.mu.Unlock()

	if err := prepareSwitchForTest(instance, `{"invalid"`, identity); err == nil {
		t.Fatal("invalid candidate configuration was accepted")
	}
	instance.mu.Lock()
	if instance.box != oldBox || instance.bridge != oldBridge ||
		instance.session != oldSession || instance.preparedSwitch != nil {
		instance.mu.Unlock()
		t.Fatal("failed candidate preparation disturbed the source session")
	}
	instance.mu.Unlock()

	if err := prepareSwitchWithLineIDForTest(instance,
		switchAnyConnectConfig,
		"company",
		identity,
	); err != nil {
		t.Fatalf("prepare switch: %v", err)
	}
	instance.mu.Lock()
	candidate := instance.preparedSwitch
	if candidate == nil || candidate.box == nil {
		instance.mu.Unlock()
		t.Fatal("prepared candidate is missing")
	}
	if instance.box != oldBox || instance.bridge != oldBridge ||
		instance.anyConnectLine != oldLine || instance.session != oldSession {
		instance.mu.Unlock()
		t.Fatal("preparation published the candidate before commit")
	}
	candidateOutbound, loaded := candidate.box.Outbound().Outbound("vpn")
	instance.mu.Unlock()
	if !loaded {
		t.Fatal("candidate AnyConnect outbound is missing")
	}
	vpnOutbound, ok := candidateOutbound.(*vpnOutbound)
	if !ok || vpnOutbound.line != oldLine {
		t.Fatal("candidate Box did not borrow the stable AnyConnect capability")
	}
	if connects, _ := client.counts(); connects != 1 {
		t.Fatalf("AnyConnect was redialed during prepare: connects=%d", connects)
	}
	if evidence, err := instance.PreparedSwitchReusedLineIDs(); err != nil ||
		evidence != `["company"]` {
		t.Fatalf("prepared reuse evidence = (%q, %v)", evidence, err)
	} else if strings.Contains(evidence, identity) ||
		strings.Contains(evidence, "secret") {
		t.Fatalf("prepared reuse evidence leaked private material: %s", evidence)
	}

	instance.probeOutboundAddressFunc = func(
		context.Context,
		adapter.Outbound,
		outboundAddressProbeEndpoint,
		int,
	) (string, error) {
		return "203.0.113.9", nil
	}
	if address, err := instance.ProbePreparedSwitchOutboundIP(
		"vpn",
		500,
	); err != nil || address != "203.0.113.9" {
		t.Fatalf("probe prepared switch = (%q, %v)", address, err)
	}

	if err := instance.CommitPreparedSwitch(); err != nil {
		t.Fatalf("commit switch: %v", err)
	}
	instance.mu.Lock()
	if instance.box != candidate.box || instance.preparedSwitch != nil {
		instance.mu.Unlock()
		t.Fatal("candidate did not become the active immutable generation")
	}
	if instance.bridge != oldBridge || instance.anyConnectLine != oldLine ||
		instance.session != oldSession {
		instance.mu.Unlock()
		t.Fatal("commit replaced the reusable AnyConnect session")
	}
	if instance.generation != oldAnyConnectGeneration {
		instance.mu.Unlock()
		t.Fatal("Box switch invalidated the AnyConnect monitor generation")
	}
	if instance.boxGeneration != oldBoxGeneration+1 {
		instance.mu.Unlock()
		t.Fatal("Box switch did not advance the immutable generation")
	}
	retired := instance.retiredSwitch
	if retired == nil || retired.box != oldBox ||
		retired.lineRuntimeGeneration != oldLineRuntimeGeneration ||
		!instance.lineRuntimes.committedIs(
			retired.lineRuntimeGeneration,
			identity,
			oldCapability,
		) {
		instance.mu.Unlock()
		t.Fatal("commit did not retain the source Box with a shared Line lease")
	}
	instance.mu.Unlock()
	if _, loaded := oldBox.Outbound().Outbound("vpn"); !loaded {
		t.Fatal("commit closed the retained source Box before relay drain")
	}
	if err := prepareSwitchForTest(
		instance,
		switchAnyConnectConfig,
		identity,
	); err == nil {
		t.Fatal("a third generation was prepared before source retirement")
	}
	if connects, disconnects := client.counts(); connects != 1 || disconnects != 0 {
		t.Fatalf(
			"switch touched sslcon lifecycle: connects=%d disconnects=%d",
			connects,
			disconnects,
		)
	}
	if err := instance.RetireCommittedSwitch(); err != nil {
		t.Fatalf("retire committed switch: %v", err)
	}
	if err := instance.RetireCommittedSwitch(); err != nil {
		t.Fatalf("second Retire must be idempotent: %v", err)
	}
	instance.mu.Lock()
	if instance.retiredSwitch != nil || instance.bridge != oldBridge ||
		instance.session != oldSession || instance.anyConnectLine != oldLine {
		instance.mu.Unlock()
		t.Fatal("retiring shared source disturbed the active AnyConnect capability")
	}
	instance.mu.Unlock()
	if err := oldBox.Close(); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("retired Box remained open after Retire: %v", err)
	}
	if connects, disconnects := client.counts(); connects != 1 || disconnects != 0 {
		t.Fatalf(
			"retiring shared source touched sslcon: connects=%d disconnects=%d",
			connects,
			disconnects,
		)
	}
	if err := prepareSwitchWithLineIDForTest(
		instance,
		switchAnyConnectConfig,
		"company",
		identity,
	); err != nil {
		t.Fatalf("prepare A→B→A reuse: %v", err)
	}
	if evidence, err := instance.PreparedSwitchReusedLineIDs(); err != nil ||
		evidence != `["company"]` {
		t.Fatalf("A→B→A reuse evidence = (%q, %v)", evidence, err)
	}
	if err := instance.AbortPreparedSwitch(); err != nil {
		t.Fatal(err)
	}
	if connects, disconnects := client.counts(); connects != 1 || disconnects != 0 {
		t.Fatalf(
			"A→B→A evidence redialed AnyConnect: connects=%d disconnects=%d",
			connects,
			disconnects,
		)
	}
}

func TestAbortPreparedSwitchPreservesSourceGeneration(t *testing.T) {
	const identity = "line-runtime-v1:exact"
	instance, client := newAnyConnectSwitchTestLibbox(t, identity)
	defer instance.Stop()

	instance.mu.Lock()
	oldBox := instance.box
	oldBridge := instance.bridge
	oldSession := instance.session
	instance.mu.Unlock()
	if err := prepareSwitchForTest(instance,
		switchAnyConnectConfig,
		identity,
	); err != nil {
		t.Fatal(err)
	}
	instance.mu.Lock()
	candidateBox := instance.preparedSwitch.box
	instance.mu.Unlock()

	if err := instance.AbortPreparedSwitch(); err != nil {
		t.Fatal(err)
	}
	if evidence, err := instance.PreparedSwitchReusedLineIDs(); err == nil ||
		evidence != "" {
		t.Fatalf("aborted candidate retained reuse evidence = (%q, %v)", evidence, err)
	}
	instance.mu.Lock()
	unchanged := instance.box == oldBox &&
		instance.bridge == oldBridge &&
		instance.session == oldSession &&
		instance.preparedSwitch == nil && instance.running
	instance.mu.Unlock()
	if !unchanged {
		t.Fatal("aborting candidate changed the source generation")
	}
	if err := candidateBox.Close(); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("aborted candidate Box remained open: %v", err)
	}
	if connects, disconnects := client.counts(); connects != 1 || disconnects != 0 {
		t.Fatalf(
			"abort touched sslcon lifecycle: connects=%d disconnects=%d",
			connects,
			disconnects,
		)
	}
}

func TestPrepareSwitchKeepsTargetUnderlayIsolatedUntilCommit(t *testing.T) {
	instance := New(nil)
	instance.platform.setDefaultInterface("test0", 1)
	if err := instance.StartStandalone(outboundProbeTestConfig); err != nil {
		t.Fatal(err)
	}
	defer instance.Stop()

	instance.mu.Lock()
	sourcePlatform := instance.platform
	instance.mu.Unlock()
	const targetInterfaces = `[{"name":"test1","index":2,"type":"ethernet"}]`
	if err := instance.PrepareSwitch(
		outboundProbeTestConfig,
		"",
		targetInterfaces,
		"test1",
		2,
	); err != nil {
		t.Fatal(err)
	}
	instance.mu.Lock()
	candidate := instance.preparedSwitch
	if instance.platform != sourcePlatform || candidate == nil ||
		candidate.platform == sourcePlatform {
		instance.mu.Unlock()
		t.Fatal("candidate Underlay mutated or reused the active platform")
	}
	activeUnderlay := instance.platform.diagnostics()
	targetUnderlay := candidate.platform.diagnostics()
	instance.mu.Unlock()
	if activeUnderlay.DefaultInterfaceName != "test0" ||
		activeUnderlay.DefaultInterfaceIndex != 1 ||
		targetUnderlay.DefaultInterfaceName != "test1" ||
		targetUnderlay.DefaultInterfaceIndex != 2 {
		t.Fatalf(
			"Underlay snapshots = active %+v, target %+v",
			activeUnderlay,
			targetUnderlay,
		)
	}
	if err := instance.CommitPreparedSwitch(); err != nil {
		t.Fatal(err)
	}
	instance.mu.Lock()
	committedPlatform := instance.platform
	instance.mu.Unlock()
	if committedPlatform != candidate.platform {
		t.Fatal("target Underlay did not become active at commit")
	}
	if err := instance.RetireCommittedSwitch(); err != nil {
		t.Fatal(err)
	}
}

func TestSwitchFromStandaloneToNewAnyConnectAndBack(t *testing.T) {
	const identity = "line-runtime-v1:new-capability"
	client := &switchTestVPNClient{session: newStartTestSession()}
	instance := New(nil)
	instance.vpn = client
	instance.platform.setDefaultInterface("test0", 1)
	if err := instance.StartStandalone(outboundProbeTestConfig); err != nil {
		t.Fatal(err)
	}
	defer instance.Stop()

	instance.mu.Lock()
	standaloneBox := instance.box
	standalonePlatform := instance.platform
	standaloneAnyConnectGeneration := instance.generation
	instance.mu.Unlock()

	if err := instance.PrepareSwitchWithAnyConnectAndLineID(
		"vpn.example.com:443",
		"192.0.2.10",
		"employee",
		"secret",
		false,
		"company",
		identity,
		switchAnyConnectConfig,
		switchNetworkInterfaces,
		"test0",
		1,
	); err != nil {
		t.Fatalf("prepare new AnyConnect capability: %v", err)
	}
	if evidence, err := instance.PreparedSwitchReusedLineIDs(); err != nil ||
		evidence != `[]` {
		t.Fatalf("new capability reuse evidence = (%q, %v)", evidence, err)
	}
	instance.mu.Lock()
	candidate := instance.preparedSwitch
	if candidate == nil || candidate.anyConnectCapability == nil {
		instance.mu.Unlock()
		t.Fatal("prepared generation does not own its new AnyConnect capability")
	}
	candidateSnapshot := candidate.anyConnectCapability.snapshot()
	if candidateSnapshot.bridge == nil || candidateSnapshot.session == nil ||
		candidateSnapshot.line == nil || !instance.lineRuntimes.candidateIs(
		candidate.lineRuntimeGeneration,
		identity,
		candidate.anyConnectCapability,
	) {
		instance.mu.Unlock()
		t.Fatal("prepared generation has no candidate capability lease")
	}
	if instance.box != standaloneBox || instance.platform != standalonePlatform ||
		instance.bridge != nil || instance.session != nil ||
		instance.anyConnectLine != nil {
		instance.mu.Unlock()
		t.Fatal("preparing new AnyConnect changed the active standalone generation")
	}
	newBridge := candidateSnapshot.bridge
	newSession := candidateSnapshot.session
	newLine := candidateSnapshot.line
	newCapability := candidate.anyConnectCapability
	newPlatform := candidate.platform
	instance.mu.Unlock()

	if err := instance.CommitPreparedSwitch(); err != nil {
		t.Fatalf("commit new AnyConnect capability: %v", err)
	}
	instance.mu.Lock()
	if instance.bridge != newBridge || instance.session != newSession ||
		instance.anyConnectLine != newLine || instance.platform != newPlatform ||
		instance.anyConnectRuntimeIdentity != identity {
		instance.mu.Unlock()
		t.Fatal("new AnyConnect capability was not adopted at commit")
	}
	if instance.generation != standaloneAnyConnectGeneration+1 {
		instance.mu.Unlock()
		t.Fatal("new AnyConnect capability did not create a monitor generation")
	}
	instance.mu.Unlock()
	if connects, disconnects := client.counts(); connects != 1 || disconnects != 0 {
		t.Fatalf(
			"new AnyConnect lifecycle before removal = (%d, %d)",
			connects,
			disconnects,
		)
	}
	instance.mu.Lock()
	firstRetired := instance.retiredSwitch
	instance.mu.Unlock()
	if firstRetired == nil || firstRetired.box != standaloneBox {
		t.Fatal("standalone source generation was not retained")
	}
	if err := instance.RetireCommittedSwitch(); err != nil {
		t.Fatalf("retire standalone source: %v", err)
	}
	if err := standaloneBox.Close(); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("standalone source remained open after Retire: %v", err)
	}

	if err := prepareSwitchForTest(instance, outboundProbeTestConfig, ""); err != nil {
		t.Fatalf("prepare switch back to standalone: %v", err)
	}
	if err := instance.CommitPreparedSwitch(); err != nil {
		t.Fatalf("commit switch back to standalone: %v", err)
	}
	instance.mu.Lock()
	isStandalone := instance.running && instance.bridge == nil &&
		instance.session == nil && instance.anyConnectLine == nil &&
		instance.anyConnectRuntimeIdentity == ""
	instance.mu.Unlock()
	if !isStandalone {
		t.Fatal("switch back to standalone retained AnyConnect capability")
	}
	instance.mu.Lock()
	secondRetired := instance.retiredSwitch
	oldLineStillAvailable := secondRetired != nil &&
		instance.lineRuntimes.committedIs(
			secondRetired.lineRuntimeGeneration,
			identity,
			newCapability,
		) && newLine.available()
	instance.mu.Unlock()
	if !oldLineStillAvailable {
		t.Fatal("commit stopped the old-only AnyConnect capability before drain")
	}
	if connects, disconnects := client.counts(); connects != 1 || disconnects != 0 {
		t.Fatalf(
			"commit retired AnyConnect too early = (%d, %d)",
			connects,
			disconnects,
		)
	}
	if err := instance.RetireCommittedSwitch(); err != nil {
		t.Fatalf("retire AnyConnect source: %v", err)
	}
	if newLine.available() {
		t.Fatal("old-only AnyConnect Line remained available after Retire")
	}
	if connects, disconnects := client.counts(); connects != 1 || disconnects != 1 {
		t.Fatalf(
			"AnyConnect lifecycle after Retire = (%d, %d)",
			connects,
			disconnects,
		)
	}
}

func TestFailedNewAnyConnectCandidatePreservesStandalone(t *testing.T) {
	client := &switchTestVPNClient{session: newStartTestSession()}
	instance := New(nil)
	instance.vpn = client
	instance.platform.setDefaultInterface("test0", 1)
	if err := instance.StartStandalone(outboundProbeTestConfig); err != nil {
		t.Fatal(err)
	}
	defer instance.Stop()

	instance.mu.Lock()
	oldBox := instance.box
	oldPlatform := instance.platform
	instance.mu.Unlock()
	err := instance.PrepareSwitchWithAnyConnect(
		"vpn.example.com:443",
		"192.0.2.10",
		"employee",
		"secret",
		false,
		"line-runtime-v1:new-capability",
		`{"outbounds":"invalid"}`,
		switchNetworkInterfaces,
		"test0",
		1,
	)
	if err == nil {
		t.Fatal("invalid candidate configuration was accepted")
	}
	instance.mu.Lock()
	unchanged := instance.box == oldBox && instance.platform == oldPlatform &&
		instance.bridge == nil && instance.session == nil &&
		instance.anyConnectLine == nil && instance.preparedSwitch == nil &&
		instance.running
	instance.mu.Unlock()
	if !unchanged {
		t.Fatal("failed new AnyConnect candidate disturbed standalone source")
	}
	if connects, disconnects := client.counts(); connects != 1 || disconnects != 1 {
		t.Fatalf(
			"failed candidate leaked AnyConnect: connects=%d disconnects=%d",
			connects,
			disconnects,
		)
	}
}

func TestStopClosesActiveAndRetainedGenerations(t *testing.T) {
	const identity = "line-runtime-v1:retained-stop"
	instance, client := newAnyConnectSwitchTestLibbox(t, identity)
	instance.mu.Lock()
	oldBox := instance.box
	oldLine := instance.anyConnectLine
	oldCapability := instance.activeAnyConnectCapability
	instance.mu.Unlock()

	if err := prepareSwitchForTest(instance, outboundProbeTestConfig, ""); err != nil {
		t.Fatal(err)
	}
	instance.mu.Lock()
	newBox := instance.preparedSwitch.box
	instance.mu.Unlock()
	if err := instance.CommitPreparedSwitch(); err != nil {
		t.Fatal(err)
	}
	instance.mu.Lock()
	retained := instance.retiredSwitch
	retainedOwnsLine := retained != nil && retained.box == oldBox &&
		instance.lineRuntimes.committedIs(
			retained.lineRuntimeGeneration,
			identity,
			oldCapability,
		)
	instance.mu.Unlock()
	if !retainedOwnsLine || !oldLine.available() {
		t.Fatal("source AnyConnect generation was not retained after commit")
	}

	if err := instance.Stop(); err != nil {
		t.Fatal(err)
	}
	instance.mu.Lock()
	stopped := !instance.running && instance.box == nil &&
		instance.retiredSwitch == nil && instance.preparedSwitch == nil
	instance.mu.Unlock()
	if !stopped {
		t.Fatal("Stop left an active or retained generation")
	}
	if oldLine.available() {
		t.Fatal("Stop left the retained AnyConnect Line available")
	}
	if err := oldBox.Close(); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("Stop left retained Box open: %v", err)
	}
	if err := newBox.Close(); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("Stop left active Box open: %v", err)
	}
	if connects, disconnects := client.counts(); connects != 1 || disconnects != 1 {
		t.Fatalf(
			"Stop retained lifecycle = connects %d, disconnects %d",
			connects,
			disconnects,
		)
	}
	if err := instance.RetireCommittedSwitch(); err != nil {
		t.Fatalf("Retire after Stop must be idempotent: %v", err)
	}
}

func TestStopWaitsForCommitThenClosesActiveAndRetained(t *testing.T) {
	instance := New(nil)
	instance.platform.setDefaultInterface("test0", 1)
	if err := instance.StartStandalone(outboundProbeTestConfig); err != nil {
		t.Fatal(err)
	}
	instance.mu.Lock()
	oldBox := instance.box
	instance.mu.Unlock()
	if err := prepareSwitchForTest(instance, outboundProbeTestConfig, ""); err != nil {
		t.Fatal(err)
	}
	instance.mu.Lock()
	newBox := instance.preparedSwitch.box
	// Model a bounded active-manager borrower issued before Commit. Commit must
	// drain it, while an explicit Stop arriving in that interval must wait and
	// then reclaim both adopted and retained generations.
	instance.runtimeUsers.Add(1)
	instance.mu.Unlock()

	commitResult := make(chan error, 1)
	go func() { commitResult <- instance.CommitPreparedSwitch() }()
	deadline := time.Now().Add(time.Second)
	for {
		instance.mu.Lock()
		committing := instance.switchCommitInProgress
		instance.mu.Unlock()
		if committing {
			break
		}
		if time.Now().After(deadline) {
			instance.runtimeUsers.Done()
			t.Fatal("Commit did not enter its bounded adoption barrier")
		}
		runtime.Gosched()
	}

	stopResult := make(chan error, 1)
	go func() { stopResult <- instance.Stop() }()
	instance.runtimeUsers.Done()
	if err := <-commitResult; err != nil {
		t.Fatalf("Commit: %v", err)
	}
	if err := <-stopResult; err != nil {
		t.Fatalf("Stop during Commit: %v", err)
	}
	if err := oldBox.Close(); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("Stop left retained Box open: %v", err)
	}
	if err := newBox.Close(); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("Stop left adopted Box open: %v", err)
	}
}

func TestCommitRevalidatesCandidateAfterBorrowerDrain(t *testing.T) {
	const identity = "line-runtime-v1:commit-revalidation"
	client := &switchTestVPNClient{session: newStartTestSession()}
	instance := New(nil)
	instance.vpn = client
	instance.platform.setDefaultInterface("test0", 1)
	if err := instance.StartStandalone(outboundProbeTestConfig); err != nil {
		t.Fatal(err)
	}
	defer instance.Stop()

	instance.mu.Lock()
	sourceBox := instance.box
	sourceLineRuntimeGeneration := instance.activeLineRuntimeGeneration
	instance.mu.Unlock()
	if err := instance.PrepareSwitchWithAnyConnect(
		"vpn.example.com:443",
		"192.0.2.10",
		"employee",
		"secret",
		false,
		identity,
		switchAnyConnectConfig,
		switchNetworkInterfaces,
		"test0",
		1,
	); err != nil {
		t.Fatal(err)
	}
	instance.mu.Lock()
	candidate := instance.preparedSwitch
	if candidate == nil || candidate.anyConnectCapability == nil {
		instance.mu.Unlock()
		t.Fatal("AnyConnect candidate is unavailable")
	}
	candidateSession := candidate.anyConnectCapability.snapshot().session
	instance.runtimeUsers.Add(1)
	instance.mu.Unlock()

	commitResult := make(chan error, 1)
	go func() { commitResult <- instance.CommitPreparedSwitch() }()
	deadline := time.Now().Add(time.Second)
	for {
		instance.mu.Lock()
		committing := instance.switchCommitInProgress
		instance.mu.Unlock()
		if committing {
			break
		}
		if time.Now().After(deadline) {
			instance.runtimeUsers.Done()
			t.Fatal("Commit did not reach the borrower drain barrier")
		}
		runtime.Gosched()
	}
	client.disconnectOnce.Do(func() { close(candidateSession.CloseChan) })
	instance.runtimeUsers.Done()
	if err := <-commitResult; err == nil ||
		!strings.Contains(err.Error(), "AnyConnect capability is unavailable") {
		t.Fatalf("Commit accepted a closed candidate session: %v", err)
	}

	instance.mu.Lock()
	sourcePreserved := instance.running && instance.box == sourceBox &&
		instance.activeLineRuntimeGeneration == sourceLineRuntimeGeneration &&
		instance.preparedSwitch == candidate &&
		instance.retiredSwitch == nil && !instance.switchCommitInProgress &&
		instance.lineRuntimes.candidateIs(
			candidate.lineRuntimeGeneration,
			identity,
			candidate.anyConnectCapability,
		)
	instance.mu.Unlock()
	if !sourcePreserved {
		t.Fatal("failed post-drain validation disturbed source or candidate leases")
	}
	if err := instance.AbortPreparedSwitch(); err != nil {
		t.Fatal(err)
	}
	if connects, disconnects := client.counts(); connects != 1 || disconnects != 1 {
		t.Fatalf(
			"candidate cleanup lifecycle = connects %d, disconnects %d",
			connects,
			disconnects,
		)
	}
}

func TestStopAllCapabilityTeardownDoesNotHoldLibboxLock(t *testing.T) {
	instance := New(nil)
	capability := &blockingLineRuntimeCapability{
		started: make(chan struct{}),
		release: make(chan struct{}),
	}
	instance.mu.Lock()
	runtimeGeneration := instance.nextLineRuntimeGenerationLocked()
	if err := instance.lineRuntimes.beginCandidate(runtimeGeneration); err != nil {
		instance.mu.Unlock()
		t.Fatal(err)
	}
	if _, _, err := instance.lineRuntimes.acquireCandidate(
		runtimeGeneration,
		"opaque-blocking-stop",
		capability.kind(),
		false,
		func() (lineRuntimeCapability, error) { return capability, nil },
	); err != nil {
		instance.mu.Unlock()
		t.Fatal(err)
	}
	if err := instance.lineRuntimes.promoteCandidate(runtimeGeneration); err != nil {
		instance.mu.Unlock()
		t.Fatal(err)
	}
	instance.running = true
	instance.activeLineRuntimeGeneration = runtimeGeneration
	instance.runtimeCtx, instance.runtimeCancel = context.WithCancel(
		context.Background(),
	)
	instance.mu.Unlock()

	stopResult := make(chan error, 1)
	go func() { stopResult <- instance.Stop() }()
	select {
	case <-capability.started:
	case <-time.After(time.Second):
		t.Fatal("Stop did not reach detached capability teardown")
	}
	statusResult := make(chan string, 1)
	go func() { statusResult <- instance.Status() }()
	select {
	case status := <-statusResult:
		if status != `{"running":false}` {
			t.Fatalf("status during detached teardown = %s", status)
		}
	case <-time.After(time.Second):
		t.Fatal("capability teardown held the Libbox lifecycle mutex")
	}
	close(capability.release)
	if err := <-stopResult; err != nil {
		t.Fatal(err)
	}
	if !instance.lineRuntimes.empty() {
		t.Fatal("Stop retained Line runtime generations")
	}
}

func TestConcurrentRetireAndStopCloseBothGenerations(t *testing.T) {
	const identity = "line-runtime-v1:retire-stop-race"
	instance, client := newAnyConnectSwitchTestLibbox(t, identity)
	instance.mu.Lock()
	oldBox := instance.box
	instance.mu.Unlock()

	if err := prepareSwitchForTest(instance, outboundProbeTestConfig, ""); err != nil {
		t.Fatal(err)
	}
	instance.mu.Lock()
	newBox := instance.preparedSwitch.box
	instance.mu.Unlock()
	if err := instance.CommitPreparedSwitch(); err != nil {
		t.Fatal(err)
	}

	// Hold cleanup ownership so Retire can publish its in-progress state before
	// Stop starts. Both calls must then serialize their concrete Close work and
	// leave neither active nor retained resources behind.
	instance.switchCleanupMu.Lock()
	retireResult := make(chan error, 1)
	go func() { retireResult <- instance.RetireCommittedSwitch() }()
	deadline := time.Now().Add(time.Second)
	for {
		instance.mu.Lock()
		retiring := instance.switchRetireInProgress
		instance.mu.Unlock()
		if retiring {
			break
		}
		if time.Now().After(deadline) {
			instance.switchCleanupMu.Unlock()
			t.Fatal("Retire did not publish its in-progress state")
		}
		runtime.Gosched()
	}
	stopResult := make(chan error, 1)
	go func() { stopResult <- instance.Stop() }()
	instance.switchCleanupMu.Unlock()

	if err := <-retireResult; err != nil {
		t.Fatalf("concurrent Retire: %v", err)
	}
	if err := <-stopResult; err != nil {
		t.Fatalf("concurrent Stop: %v", err)
	}
	instance.mu.Lock()
	closed := !instance.running && !instance.cleaning &&
		instance.box == nil && instance.retiredSwitch == nil &&
		instance.preparedSwitch == nil &&
		!instance.switchRetireInProgress
	instance.mu.Unlock()
	if !closed {
		t.Fatal("concurrent Retire and Stop left generation state behind")
	}
	if err := oldBox.Close(); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("concurrent Retire left old Box open: %v", err)
	}
	if err := newBox.Close(); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("concurrent Stop left active Box open: %v", err)
	}
	if connects, disconnects := client.counts(); connects != 1 || disconnects != 1 {
		t.Fatalf(
			"concurrent lifecycle = connects %d, disconnects %d",
			connects,
			disconnects,
		)
	}
}

func TestPrepareSwitchRejectsConcurrentTailscaleStateOwnership(
	t *testing.T,
) {
	instance := New(nil)
	instance.platform.setDefaultInterface("test0", 1)
	if err := instance.StartStandalone(outboundProbeTestConfig); err != nil {
		t.Fatal(err)
	}
	defer instance.Stop()

	stateDirectory := filepath.Join(t.TempDir(), "tailscale-state")
	lockConfig := `{"endpoints":[{"type":"tailscale","state_directory":"` +
		stateDirectory + `"}]}`
	locks, err := acquireTailscaleStateLocks(lockConfig)
	if err != nil {
		t.Fatal(err)
	}
	instance.mu.Lock()
	instance.stateLocks = locks
	oldBox := instance.box
	instance.mu.Unlock()

	err = prepareSwitchForTest(instance, lockConfig, "")
	if !errors.Is(err, errTailscaleStateInUse) {
		t.Fatalf("concurrent Tailscale candidate error = %v", err)
	}
	instance.mu.Lock()
	unchanged := instance.box == oldBox &&
		instance.preparedSwitch == nil && instance.running
	instance.mu.Unlock()
	if !unchanged {
		t.Fatal("Tailscale ownership rejection disturbed the source Box")
	}
}
