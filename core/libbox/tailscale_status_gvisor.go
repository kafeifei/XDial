//go:build !windows && with_gvisor && !mobile_no_tailscale

package libbox

import (
	"context"
	"encoding/json"
	"fmt"
	"net/netip"
	"sort"
	"strings"
	"time"

	"github.com/sagernet/sing-box/adapter"
	C "github.com/sagernet/sing-box/constant"
	boxTailscale "github.com/sagernet/sing-box/protocol/tailscale"
	"github.com/sagernet/sing/service"
	tailLocal "github.com/sagernet/tailscale/client/local"
	"github.com/sagernet/tailscale/ipn/ipnstate"
	"github.com/sagernet/tailscale/tailcfg"
	"github.com/sagernet/tailscale/types/key"
)

const tailscaleStatusTimeout = 5 * time.Second

type tailscaleStatusPayload struct {
	BackendState           string                    `json:"backend_state"`
	AuthURL                string                    `json:"auth_url"`
	HealthCount            int                       `json:"health_count"`
	ControlSelfHomePresent bool                      `json:"control_self_home_present"`
	MagicDNSReady          bool                      `json:"magic_dns_ready"`
	Readiness              tailscaleReadinessPayload `json:"readiness"`
	ExitNodes              []tailscaleStatusExitNode `json:"exit_nodes"`
}

type tailscaleDNSPreparationPayload struct {
	CaptureDomains []string `json:"capture_domains"`
	RecordCount    int      `json:"record_count"`
}

type tailscaleDNSMemoryTransport interface {
	ReplacePredefined(map[string][]netip.Addr, []string) error
}

type tailscaleReadinessPayload struct {
	DERP    tailscaleDERPReadinessPayload    `json:"derp"`
	Control tailscaleControlReadinessPayload `json:"control"`
}

type tailscaleDERPReadinessPayload struct {
	Observed                 bool   `json:"observed"`
	ClientCount              int    `json:"client_count"`
	ProtocolReadyCount       int    `json:"protocol_ready_count"`
	HomeConfigured           bool   `json:"home_configured"`
	HomeState                string `json:"home_state"`
	HomeKeyRelation          string `json:"home_key_relation"`
	HomeIdealKnown           bool   `json:"home_ideal_known"`
	HomeIdeal                bool   `json:"home_ideal"`
	HomeConnectionGeneration uint64 `json:"home_connection_generation"`
	HomeServerChangeSequence uint64 `json:"home_server_change_sequence"`
}

type tailscaleControlReadinessPayload struct {
	Generation            uint64 `json:"generation"`
	Observed              bool   `json:"observed"`
	ClientPresent         bool   `json:"client_present"`
	ResetForCurrentClient bool   `json:"reset_for_current_client"`
	SetForCurrentClient   bool   `json:"set_for_current_client"`
	PreferredDERPRelation string `json:"preferred_derp_relation"`
}

type tailscaleStatusExitNode struct {
	ID                  string                       `json:"id"`
	Name                string                       `json:"name"`
	IP                  string                       `json:"ip"`
	Online              bool                         `json:"online"`
	Selected            bool                         `json:"selected"`
	OS                  string                       `json:"os"`
	Active              bool                         `json:"active"`
	PathCandidate       string                       `json:"path_candidate"`
	TxBytes             int64                        `json:"tx_bytes"`
	RxBytes             int64                        `json:"rx_bytes"`
	HasHandshake        bool                         `json:"has_handshake"`
	InNetworkMap        bool                         `json:"in_network_map"`
	InMagicSock         bool                         `json:"in_magic_sock"`
	InEngine            bool                         `json:"in_engine"`
	ControlHomeRelation string                       `json:"control_home_relation"`
	DERPPath            tailscalePeerDERPPathPayload `json:"derp_path"`
}

type tailscalePeerDERPPathPayload struct {
	Observed                       bool   `json:"observed"`
	ReplyRouteState                string `json:"reply_route_state"`
	LastWriteRouteState            string `json:"last_write_route_state"`
	LastWriteRouteKind             string `json:"last_write_route_kind"`
	LastWriteClientState           string `json:"last_write_client_state"`
	LastWriteClientIdealKnown      bool   `json:"last_write_client_ideal_known"`
	LastWriteClientIdeal           bool   `json:"last_write_client_ideal"`
	LastSendConnectionGeneration   uint64 `json:"last_send_connection_generation"`
	CurrentConnectionGeneration    uint64 `json:"current_connection_generation"`
	ConnectionChangedSinceLastSend bool   `json:"connection_changed_since_last_send"`
	LastSendWasDisco               bool   `json:"last_send_was_disco"`
	SendAttemptSequence            uint64 `json:"send_attempt_sequence"`
	SendSuccessSequence            uint64 `json:"send_success_sequence"`
	SendErrorSequence              uint64 `json:"send_error_sequence"`
	ReceivePacketSequence          uint64 `json:"receive_packet_sequence"`
	RouteInvalidationSequence      uint64 `json:"route_invalidation_sequence"`
	RouteInvalidationReason        string `json:"route_invalidation_reason"`
	ReaderErrorSequence            uint64 `json:"reader_error_sequence"`
	ReaderErrorReason              string `json:"reader_error_reason"`
	ServerInfoSequence             uint64 `json:"server_info_sequence"`
	ServerChangeSequence           uint64 `json:"server_change_sequence"`
	ClientCloseSequence            uint64 `json:"client_close_sequence"`
	ClientCloseReason              string `json:"client_close_reason"`
}

func unavailableTailscalePeerDERPPath() tailscalePeerDERPPathPayload {
	return tailscalePeerDERPPathPayload{
		ReplyRouteState:         "unknown",
		LastWriteRouteState:     "unknown",
		LastWriteRouteKind:      "unknown",
		LastWriteClientState:    "unknown",
		RouteInvalidationReason: "unknown",
		ReaderErrorReason:       "unknown",
		ClientCloseReason:       "unknown",
	}
}

func sanitizeTailscalePeerDERPPath(
	payload tailscalePeerDERPPathPayload,
) tailscalePeerDERPPathPayload {
	payload.ReplyRouteState = allowlistedTailscaleDERPPathValue(
		payload.ReplyRouteState,
		"absent",
		"current",
		"stale",
	)
	payload.LastWriteRouteState = allowlistedTailscaleDERPPathValue(
		payload.LastWriteRouteState,
		"absent",
		"current",
		"stale",
	)
	payload.LastWriteRouteKind = allowlistedTailscaleDERPPathValue(
		payload.LastWriteRouteKind,
		"none",
		"requested",
		"reverse",
	)
	payload.LastWriteClientState = allowlistedTailscaleDERPPathValue(
		payload.LastWriteClientState,
		"missing",
		"current_not_ready",
		"current_protocol_ready",
		"stale",
		"closed",
		"unknown",
	)
	payload.RouteInvalidationReason = allowlistedTailscaleDERPPathValue(
		payload.RouteInvalidationReason,
		"none",
		"peer_gone_not_here",
		"peer_gone_disconnected",
		"peer_gone_unknown",
		"reader_error",
		"unknown",
	)
	payload.ReaderErrorReason = allowlistedTailscaleDERPPathValue(
		payload.ReaderErrorReason,
		"none",
		"client_closed",
		"network_down",
		"context_cancelled",
		"transport_error",
		"unknown",
	)
	payload.ClientCloseReason = allowlistedTailscaleDERPPathValue(
		payload.ClientCloseReason,
		"none",
		"derp_disabled",
		"derp_region_redefined",
		"debug_break",
		"network_down",
		"rebind_no_local_addr",
		"rebind_default_route_change",
		"rebind_ping_failed",
		"idle",
		"zero_private_key",
		"new_private_key",
		"conn_close",
		"set_homeless",
		"unknown",
	)
	return payload
}

func allowlistedTailscaleDERPPathValue(
	value string,
	allowed ...string,
) string {
	for _, candidate := range allowed {
		if value == candidate {
			return value
		}
	}
	return "unknown"
}

type tailscalePeerProbePayload struct {
	Disco tailscalePeerProbeResult `json:"disco"`
	TSMP  tailscalePeerProbeResult `json:"tsmp"`
}

type tailscalePeerProbeResult struct {
	Success   bool   `json:"success"`
	Path      string `json:"path"`
	LatencyMS int64  `json:"latency_ms"`
	Error     string `json:"error,omitempty"`
}

type tailscaleDERPHomeReselectionPayload struct {
	ControlGeneration                   uint64 `json:"control_generation"`
	AlternatePrepared                   bool   `json:"alternate_prepared"`
	HomePromoted                        bool   `json:"home_promoted"`
	ControlClientNotified               bool   `json:"control_client_notified"`
	ControlUpdateObservable             bool   `json:"control_update_observable"`
	ControlUpdateQueued                 bool   `json:"control_update_queued"`
	ControlUpdateAttempted              bool   `json:"control_update_attempted"`
	ControlUpdateHTTPAccepted           bool   `json:"control_update_http_accepted"`
	ControlUpdateFailed                 bool   `json:"control_update_failed"`
	ControlUpdateSuperseded             bool   `json:"control_update_superseded"`
	ControlViewAligned                  bool   `json:"control_view_aligned"`
	FailureCode                         string `json:"failure_code,omitempty"`
	PrecommitBaselineChecked            bool   `json:"precommit_baseline_checked"`
	PlanNodeMatchesCurrent              bool   `json:"plan_node_matches_current"`
	ControlSelfPresent                  bool   `json:"control_self_present"`
	ControlSelfNodeMatchesCurrent       bool   `json:"control_self_node_matches_current"`
	ControlSelfHomeMatchesPlanOriginal  bool   `json:"control_self_home_matches_plan_original"`
	ControlSelfHomeMatchesPlanAlternate bool   `json:"control_self_home_matches_plan_alternate"`
	ControlNetInfoSetForCurrentClient   bool   `json:"control_netinfo_set_for_current_client"`
	ControlNetInfoMatchesPlanOriginal   bool   `json:"control_netinfo_matches_plan_original"`
	ControlNetInfoMatchesPlanAlternate  bool   `json:"control_netinfo_matches_plan_alternate"`
}

// TailscaleStatus 返回指定 sing-box endpoint 的脱敏状态。JSON 只包含登录所需
// 的状态、授权地址、可选出口节点和有限的连接诊断，不暴露 tailnet、用户、
// 健康详情、DERP 区域、真实 endpoint 或节点密钥。
func (l *Libbox) TailscaleStatus(endpointTag string) (string, error) {
	endpoint, client, runtimeCtx, err := l.tailscaleRuntime(endpointTag)
	if err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(runtimeCtx, tailscaleStatusTimeout)
	defer cancel()
	status, err := client.Status(ctx)
	if err != nil {
		return "", fmt.Errorf("Tailscale status is unavailable")
	}
	return encodeTailscaleStatus(
		status,
		tailscaleRuntimeReadiness(endpoint),
		tailscalePeerDERPPathLookup(endpoint),
	)
}

// TailscaleDNSCaptureDomains returns the current endpoint-owned DNS suffixes,
// exact hosts and single-label aliases for the Provider's ingress rules. It is
// deliberately separate from TailscaleStatus so setup/UI status stays redacted.
func (l *Libbox) TailscaleDNSCaptureDomains(endpointTag string) (string, error) {
	endpoint, _, _, err := l.tailscaleRuntime(endpointTag)
	if err != nil {
		return "", err
	}
	data, err := json.Marshal(endpoint.DNSCaptureDomains())
	if err != nil {
		return "", fmt.Errorf("Tailscale DNS capture domains are unavailable")
	}
	return string(data), nil
}

// PrepareTailscaleDNS atomically reads one immutable DNS Config snapshot from
// the running endpoint and installs it into a memory-only hosts transport. The
// returned metadata intentionally excludes every host address; the snapshot
// itself never leaves this process and is never persisted.
func (l *Libbox) PrepareTailscaleDNS(endpointTag string, dnsServerTag string) (string, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if !l.running || l.box == nil || l.runtimeCtx == nil || l.runtimeCtx.Err() != nil {
		return "", fmt.Errorf("connection is not running")
	}
	rawEndpoint, found := l.box.Endpoint().Get(strings.TrimSpace(endpointTag))
	endpoint, ok := rawEndpoint.(*boxTailscale.Endpoint)
	if !found || !ok {
		return "", fmt.Errorf("Tailscale endpoint is unavailable")
	}
	snapshot, err := endpoint.DNSMemorySnapshot()
	if err != nil {
		return "", err
	}
	transportManager := service.FromContext[adapter.DNSTransportManager](l.runtimeCtx)
	if transportManager == nil {
		return "", fmt.Errorf("Tailscale DNS memory transport is unavailable")
	}
	rawTransport, found := transportManager.Transport(strings.TrimSpace(dnsServerTag))
	if !found {
		return "", fmt.Errorf("Tailscale DNS memory transport is unavailable")
	}
	metadata, err := installTailscaleDNSMemorySnapshot(snapshot, rawTransport)
	if err != nil {
		return "", err
	}
	if l.routingProbe != nil {
		l.routingProbe.replaceDNSSnapshotAddresses(snapshot.Hosts)
	}
	return metadata, nil
}

func installTailscaleDNSMemorySnapshot(snapshot boxTailscale.DNSMemorySnapshot, rawTransport adapter.DNSTransport) (string, error) {
	if len(snapshot.CaptureDomains) == 0 || len(snapshot.CaptureDomains) > 2_048 ||
		snapshot.RecordCount < 1 || snapshot.RecordCount > 4_096 {
		return "", fmt.Errorf("Tailscale DNS snapshot is invalid")
	}
	transport, ok := rawTransport.(tailscaleDNSMemoryTransport)
	if !ok || rawTransport.Type() != C.DNSTypeHosts {
		return "", fmt.Errorf("Tailscale DNS memory transport is unavailable")
	}
	if err := transport.ReplacePredefined(snapshot.Hosts, snapshot.OwnedDomains); err != nil {
		return "", fmt.Errorf("Tailscale DNS memory snapshot could not be installed")
	}
	payload, err := json.Marshal(tailscaleDNSPreparationPayload{
		CaptureDomains: snapshot.CaptureDomains,
		RecordCount:    snapshot.RecordCount,
	})
	if err != nil {
		return "", fmt.Errorf("Tailscale DNS preparation status is unavailable")
	}
	return string(payload), nil
}

// ProbeTailscalePeer distinguishes path discovery from authenticated
// WireGuard traffic to one exact peer. It deliberately returns only path
// class, latency and a bounded error class; public endpoints, DERP regions,
// node names and identity material never cross the platform boundary.
func (l *Libbox) ProbeTailscalePeer(endpointTag string, peerIP string, timeoutMS int) (string, error) {
	_, client, runtimeCtx, err := l.tailscaleRuntime(endpointTag)
	if err != nil {
		return "", err
	}
	address, err := netip.ParseAddr(strings.TrimSpace(peerIP))
	if err != nil || !address.IsValid() {
		return "", fmt.Errorf("Tailscale peer address is invalid")
	}
	if timeoutMS < 500 {
		timeoutMS = 500
	}
	if timeoutMS > 5_000 {
		timeoutMS = 5_000
	}
	timeout := time.Duration(timeoutMS) * time.Millisecond
	payload := tailscalePeerProbePayload{
		Disco: probeTailscalePeerLayer(runtimeCtx, client, address, tailcfg.PingDisco, timeout),
		TSMP:  probeTailscalePeerLayer(runtimeCtx, client, address, tailcfg.PingTSMP, timeout),
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return "", fmt.Errorf("Tailscale peer probe encoding failed")
	}
	return string(encoded), nil
}

// ReselectTailscaleHomeDERP performs one bounded, protocol-native HomeDERP
// change for a running endpoint. It changes no identity, login state,
// preference, route, DNS, or system network configuration. The returned JSON
// exposes only bounded relations; real egress remains the sole success gate.
func (l *Libbox) ReselectTailscaleHomeDERP(endpointTag string, timeoutMS int) (string, error) {
	endpoint, _, runtimeCtx, err := l.tailscaleRuntime(endpointTag)
	if err != nil {
		return "", err
	}
	if timeoutMS < 2_000 {
		timeoutMS = 2_000
	}
	if timeoutMS > 8_000 {
		timeoutMS = 8_000
	}
	ctx, cancel := context.WithTimeout(
		runtimeCtx,
		time.Duration(timeoutMS)*time.Millisecond,
	)
	defer cancel()
	backend := endpoint.Server().ExportLocalBackend()
	if backend == nil {
		return "", fmt.Errorf("Tailscale HomeDERP reselection is unavailable")
	}
	result, err := backend.XDialReselectHomeDERP(ctx)
	if err != nil {
		return "", fmt.Errorf("Tailscale HomeDERP reselection failed: %w", err)
	}
	payload := tailscaleDERPHomeReselectionPayload{
		ControlGeneration:                   result.ControlGeneration,
		AlternatePrepared:                   result.AlternatePrepared,
		HomePromoted:                        result.HomePromoted,
		ControlClientNotified:               result.ControlClientNotified,
		ControlUpdateObservable:             result.ControlUpdateObservable,
		ControlUpdateQueued:                 result.ControlUpdateQueued,
		ControlUpdateAttempted:              result.ControlUpdateAttempted,
		ControlUpdateHTTPAccepted:           result.ControlUpdateHTTPAccepted,
		ControlUpdateFailed:                 result.ControlUpdateFailed,
		ControlUpdateSuperseded:             result.ControlUpdateSuperseded,
		ControlViewAligned:                  result.ControlViewAligned,
		FailureCode:                         result.FailureCode,
		PrecommitBaselineChecked:            result.PrecommitBaselineChecked,
		PlanNodeMatchesCurrent:              result.PlanNodeMatchesCurrent,
		ControlSelfPresent:                  result.ControlSelfPresent,
		ControlSelfNodeMatchesCurrent:       result.ControlSelfNodeMatchesCurrent,
		ControlSelfHomeMatchesPlanOriginal:  result.ControlSelfHomeMatchesPlanOriginal,
		ControlSelfHomeMatchesPlanAlternate: result.ControlSelfHomeMatchesPlanAlternate,
		ControlNetInfoSetForCurrentClient:   result.ControlNetInfoSetForCurrentClient,
		ControlNetInfoMatchesPlanOriginal:   result.ControlNetInfoMatchesPlanOriginal,
		ControlNetInfoMatchesPlanAlternate:  result.ControlNetInfoMatchesPlanAlternate,
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return "", fmt.Errorf("Tailscale HomeDERP reselection encoding failed")
	}
	return string(encoded), nil
}

func probeTailscalePeerLayer(
	parent context.Context,
	client *tailLocal.Client,
	address netip.Addr,
	pingType tailcfg.PingType,
	timeout time.Duration,
) tailscalePeerProbeResult {
	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()
	result, err := client.Ping(ctx, address, pingType)
	if err != nil {
		errorClass := "request_failed"
		if ctx.Err() != nil {
			errorClass = "timeout"
		}
		return tailscalePeerProbeResult{Path: "none", Error: errorClass}
	}
	if result == nil {
		return tailscalePeerProbeResult{Path: "none", Error: "empty_result"}
	}
	if result.Err != "" {
		return tailscalePeerProbeResult{Path: "none", Error: "peer_unreachable"}
	}
	path := "wireguard"
	if pingType == tailcfg.PingDisco {
		switch {
		case result.Endpoint != "":
			path = "direct"
		case result.PeerRelay != "":
			path = "peer_relay"
		case result.DERPRegionID != 0:
			path = "derp"
		default:
			path = "unknown"
		}
	}
	return tailscalePeerProbeResult{
		Success:   true,
		Path:      path,
		LatencyMS: int64(result.LatencySeconds * 1_000),
	}
}

// BeginTailscaleLogin explicitly refreshes the interactive login flow and waits
// for LocalAPI to publish the current authorization URL. The endpoint also
// starts this flow automatically on first boot, but an explicit entry point is
// required when that URL has expired or was not yet available to the app.
func (l *Libbox) BeginTailscaleLogin(endpointTag string) (string, error) {
	client, runtimeCtx, err := l.tailscaleLocalClient(endpointTag)
	if err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(runtimeCtx, tailscaleStatusTimeout)
	defer cancel()
	if err := client.StartLoginInteractive(ctx); err != nil {
		return "", fmt.Errorf("Tailscale sign-in could not be started")
	}

	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	for {
		status, statusErr := client.Status(ctx)
		if statusErr != nil {
			return "", fmt.Errorf("Tailscale status is unavailable")
		}
		if status.BackendState == "Running" || strings.TrimSpace(status.AuthURL) != "" {
			return encodeTailscaleStatus(
				status,
				tailscaleReadinessPayload{
					DERP: tailscaleDERPReadinessPayload{
						HomeState:       "unknown",
						HomeKeyRelation: "unknown",
					},
					Control: tailscaleControlReadinessPayload{
						PreferredDERPRelation: "unknown",
					},
				},
				nil,
			)
		}
		select {
		case <-ctx.Done():
			return "", fmt.Errorf("Tailscale sign-in URL is unavailable")
		case <-ticker.C:
		}
	}
}

// TailscaleLogout 清除指定 endpoint 的登录状态，并保留 LocalAPI 返回的错误原因。
func (l *Libbox) TailscaleLogout(endpointTag string) error {
	client, runtimeCtx, err := l.tailscaleLocalClient(endpointTag)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(runtimeCtx, tailscaleStatusTimeout)
	defer cancel()
	if err := client.Logout(ctx); err != nil {
		return fmt.Errorf("Tailscale logout failed: %w", err)
	}
	return nil
}

func (l *Libbox) tailscaleRuntime(endpointTag string) (*boxTailscale.Endpoint, *tailLocal.Client, context.Context, error) {
	l.mu.Lock()
	if !l.running || l.box == nil || l.runtimeCtx == nil {
		l.mu.Unlock()
		return nil, nil, nil, fmt.Errorf("connection is not running")
	}
	endpoint, found := l.box.Endpoint().Get(strings.TrimSpace(endpointTag))
	runtimeCtx := l.runtimeCtx
	l.mu.Unlock()

	tailscaleEndpoint, ok := endpoint.(*boxTailscale.Endpoint)
	if !found || !ok {
		return nil, nil, nil, fmt.Errorf("Tailscale endpoint is unavailable")
	}
	client, err := tailscaleEndpoint.Server().LocalClient()
	if err != nil {
		return nil, nil, nil, fmt.Errorf("Tailscale status is unavailable")
	}
	return tailscaleEndpoint, client, runtimeCtx, nil
}

func (l *Libbox) tailscaleLocalClient(endpointTag string) (*tailLocal.Client, context.Context, error) {
	_, client, runtimeCtx, err := l.tailscaleRuntime(endpointTag)
	return client, runtimeCtx, err
}

func tailscaleRuntimeReadiness(endpoint *boxTailscale.Endpoint) tailscaleReadinessPayload {
	payload := tailscaleReadinessPayload{
		DERP: tailscaleDERPReadinessPayload{
			HomeState:       "unknown",
			HomeKeyRelation: "unknown",
		},
		Control: tailscaleControlReadinessPayload{
			PreferredDERPRelation: "unknown",
		},
	}
	if endpoint == nil || endpoint.Server() == nil {
		return payload
	}
	server := endpoint.Server()
	if server.Sys() != nil {
		magicSock, loaded := server.Sys().MagicSock.GetOK()
		if loaded && magicSock != nil {
			state := magicSock.XDialDERPConnectionState()
			payload.DERP = tailscaleDERPReadinessPayload{
				Observed:                 true,
				ClientCount:              state.ClientCount,
				ProtocolReadyCount:       state.ProtocolReadyCount,
				HomeConfigured:           state.HomeConfigured,
				HomeState:                state.HomeState,
				HomeKeyRelation:          state.HomeKeyRelation,
				HomeIdealKnown:           state.HomeIdealKnown,
				HomeIdeal:                state.HomeIdeal,
				HomeConnectionGeneration: tailscaleDERPGeneration(state.HomeConnectionGeneration),
				HomeServerChangeSequence: state.HomeServerChangeSequence,
			}
		}
	}
	if backend := server.ExportLocalBackend(); backend != nil {
		state := backend.XDialControlNetInfoState()
		payload.Control = tailscaleControlReadinessPayload{
			Generation:            state.Generation,
			Observed:              true,
			ClientPresent:         state.ClientPresent,
			ResetForCurrentClient: state.ResetForCurrentClient,
			SetForCurrentClient:   state.SetForCurrentClient,
			PreferredDERPRelation: state.PreferredDERPRelation,
		}
	}
	return payload
}

func tailscalePeerDERPPathLookup(
	endpoint *boxTailscale.Endpoint,
) func(key.NodePublic) tailscalePeerDERPPathPayload {
	if endpoint == nil || endpoint.Server() == nil ||
		endpoint.Server().Sys() == nil {
		return nil
	}
	magicSock, loaded := endpoint.Server().Sys().MagicSock.GetOK()
	if !loaded || magicSock == nil {
		return nil
	}
	return func(peerPublicKey key.NodePublic) tailscalePeerDERPPathPayload {
		state := magicSock.XDialPeerDERPState(peerPublicKey)
		return tailscalePeerDERPPathPayload{
			Observed: state.Observed,
			ReplyRouteState: fmt.Sprint(
				state.ReplyRouteState,
			),
			LastWriteRouteState: fmt.Sprint(
				state.LastWriteRouteState,
			),
			LastWriteRouteKind: fmt.Sprint(
				state.LastWriteRouteKind,
			),
			LastWriteClientState: fmt.Sprint(
				state.LastWriteClientState,
			),
			LastWriteClientIdealKnown: state.LastWriteClientIdealKnown,
			LastWriteClientIdeal:      state.LastWriteClientIdeal,
			LastSendConnectionGeneration: tailscaleDERPGeneration(
				state.LastSendConnectionGeneration,
			),
			CurrentConnectionGeneration: tailscaleDERPGeneration(
				state.CurrentConnectionGeneration,
			),
			ConnectionChangedSinceLastSend: state.ConnectionChangedSinceLastSend,
			LastSendWasDisco:               state.LastSendWasDisco,
			SendAttemptSequence: uint64(
				state.SendAttemptSequence,
			),
			SendSuccessSequence: uint64(
				state.SendSuccessSequence,
			),
			SendErrorSequence: uint64(
				state.SendErrorSequence,
			),
			ReceivePacketSequence: uint64(
				state.ReceivePacketSequence,
			),
			RouteInvalidationSequence: uint64(
				state.RouteInvalidationSequence,
			),
			RouteInvalidationReason: fmt.Sprint(
				state.RouteInvalidationReason,
			),
			ReaderErrorSequence: uint64(
				state.ReaderErrorSequence,
			),
			ReaderErrorReason: fmt.Sprint(
				state.ReaderErrorReason,
			),
			ServerInfoSequence: uint64(
				state.ServerInfoSequence,
			),
			ServerChangeSequence: uint64(
				state.ServerChangeSequence,
			),
			ClientCloseSequence: uint64(
				state.ClientCloseSequence,
			),
			ClientCloseReason: fmt.Sprint(
				state.ClientCloseReason,
			),
		}
	}
}

func tailscaleDERPGeneration(value int) uint64 {
	if value <= 0 {
		return 0
	}
	return uint64(value)
}

func encodeTailscaleStatus(
	status *ipnstate.Status,
	readiness tailscaleReadinessPayload,
	peerDERPPath func(key.NodePublic) tailscalePeerDERPPathPayload,
) (string, error) {
	if status == nil {
		return "", fmt.Errorf("Tailscale status is unavailable")
	}
	payload := tailscaleStatusPayload{
		BackendState:           status.BackendState,
		AuthURL:                status.AuthURL,
		HealthCount:            len(status.Health),
		ControlSelfHomePresent: status.Self != nil && status.Self.Relay != "",
		MagicDNSReady: status.CurrentTailnet != nil &&
			status.CurrentTailnet.MagicDNSEnabled &&
			strings.TrimSpace(status.CurrentTailnet.MagicDNSSuffix) != "",
		Readiness: readiness,
		ExitNodes: make([]tailscaleStatusExitNode, 0),
	}
	for peerPublicKey, peer := range status.Peer {
		if peer == nil || !peer.ExitNodeOption {
			continue
		}
		ip := preferredTailscaleStatusIP(peer.TailscaleIPs)
		if ip == "" {
			continue
		}
		derpPath := unavailableTailscalePeerDERPPath()
		if peerDERPPath != nil {
			derpPath = sanitizeTailscalePeerDERPPath(
				peerDERPPath(peerPublicKey),
			)
		}
		payload.ExitNodes = append(payload.ExitNodes, tailscaleStatusExitNode{
			ID:                  string(peer.ID),
			Name:                tailscaleStatusPeerName(peer, status.CurrentTailnet),
			IP:                  ip,
			Online:              peer.Online,
			Selected:            peer.ExitNode,
			OS:                  peer.OS,
			Active:              peer.Active,
			PathCandidate:       tailscaleStatusPathCandidate(peer),
			TxBytes:             peer.TxBytes,
			RxBytes:             peer.RxBytes,
			HasHandshake:        !peer.LastHandshake.IsZero(),
			InNetworkMap:        peer.InNetworkMap,
			InMagicSock:         peer.InMagicSock,
			InEngine:            peer.InEngine,
			ControlHomeRelation: tailscaleHomeRelation(status.Self, peer),
			DERPPath:            derpPath,
		})
	}
	sort.Slice(payload.ExitNodes, func(i, j int) bool {
		if payload.ExitNodes[i].Online != payload.ExitNodes[j].Online {
			return payload.ExitNodes[i].Online
		}
		leftName := strings.ToLower(payload.ExitNodes[i].Name)
		rightName := strings.ToLower(payload.ExitNodes[j].Name)
		if leftName != rightName {
			return leftName < rightName
		}
		return payload.ExitNodes[i].ID < payload.ExitNodes[j].ID
	})
	data, err := json.Marshal(payload)
	if err != nil {
		return "", fmt.Errorf("Tailscale status encoding failed")
	}
	return string(data), nil
}

func tailscaleHomeRelation(self, peer *ipnstate.PeerStatus) string {
	if self == nil || peer == nil || self.Relay == "" || peer.Relay == "" {
		return "unknown"
	}
	if self.Relay == peer.Relay {
		return "same"
	}
	return "different"
}

// tailscaleStatusPathCandidate deliberately reports only the currently known
// candidate class. A peer Home DERP is not proof that a packet crossed DERP;
// only a successful Disco probe can confirm the response path.
func tailscaleStatusPathCandidate(peer *ipnstate.PeerStatus) string {
	if peer == nil {
		return "none"
	}
	if peer.CurAddr != "" {
		return "direct"
	}
	if peer.Relay != "" {
		return "relay"
	}
	return "none"
}

func preferredTailscaleStatusIP(addresses []netip.Addr) string {
	for _, address := range addresses {
		if address.Is4() {
			return address.String()
		}
	}
	if len(addresses) > 0 {
		return addresses[0].String()
	}
	return ""
}

func tailscaleStatusPeerName(peer *ipnstate.PeerStatus, tailnet *ipnstate.TailnetStatus) string {
	name := strings.TrimSuffix(peer.DNSName, ".")
	if tailnet != nil && tailnet.MagicDNSSuffix != "" {
		name = strings.TrimSuffix(name, "."+strings.TrimSuffix(tailnet.MagicDNSSuffix, "."))
	}
	if name == "" {
		name = peer.HostName
	}
	if name == "" {
		name = preferredTailscaleStatusIP(peer.TailscaleIPs)
	}
	return name
}
