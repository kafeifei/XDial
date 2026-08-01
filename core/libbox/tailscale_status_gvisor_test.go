//go:build !windows && with_gvisor && !mobile_no_tailscale

package libbox

import (
	"context"
	stdjson "encoding/json"
	"net/netip"
	"strings"
	"testing"
	"time"

	box "github.com/sagernet/sing-box"
	boxHosts "github.com/sagernet/sing-box/dns/transport/hosts"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	boxTailscale "github.com/sagernet/sing-box/protocol/tailscale"
	"github.com/sagernet/sing/common/json"
	"github.com/sagernet/tailscale/ipn/ipnstate"
	"github.com/sagernet/tailscale/types/key"
)

func TestEncodeTailscaleStatusAllowlist(t *testing.T) {
	onlineNodeKey := key.NewNode().Public()
	offlineNodeKey := key.NewNode().Public()
	ordinaryPeerKey := key.NewNode().Public()
	status := &ipnstate.Status{
		Version:        "must-not-leak-version",
		BackendState:   "NeedsLogin",
		AuthURL:        "https://login.tailscale.example/auth/required-token",
		Health:         []string{"must-not-leak-health"},
		MagicDNSSuffix: "must-not-leak-legacy-suffix",
		Self: &ipnstate.PeerStatus{
			Relay: "must-not-leak-self-relay-region",
		},
		CurrentTailnet: &ipnstate.TailnetStatus{
			Name:            "must-not-leak-tailnet",
			MagicDNSSuffix:  "private-tailnet.ts.net",
			MagicDNSEnabled: true,
		},
		Peer: map[key.NodePublic]*ipnstate.PeerStatus{
			onlineNodeKey: {
				ID:             "online-node",
				DNSName:        "home-mac.private-tailnet.ts.net.",
				OS:             "macOS",
				TailscaleIPs:   []netip.Addr{netip.MustParseAddr("fd7a:115c:a1e0::1"), netip.MustParseAddr("100.64.0.8")},
				Online:         true,
				ExitNodeOption: true,
				ExitNode:       true,
				Addrs:          []string{"must-not-leak-endpoint"},
				CurAddr:        "must-not-leak-current-address",
				Relay:          "must-not-leak-relay-region",
				Active:         true,
				TxBytes:        123,
				RxBytes:        456,
				LastHandshake:  time.Unix(1, 0),
				InNetworkMap:   true,
				InMagicSock:    true,
				InEngine:       true,
			},
			offlineNodeKey: {
				ID:             "offline-node",
				HostName:       "offline-host",
				OS:             "linux",
				TailscaleIPs:   []netip.Addr{netip.MustParseAddr("fd7a:115c:a1e0::2")},
				ExitNodeOption: true,
			},
			ordinaryPeerKey: {
				ID:           "ordinary-peer",
				DNSName:      "ordinary.private-tailnet.ts.net.",
				TailscaleIPs: []netip.Addr{netip.MustParseAddr("100.64.0.9")},
			},
		},
	}

	readiness := tailscaleReadinessPayload{
		DERP: tailscaleDERPReadinessPayload{
			Observed:                 true,
			ClientCount:              2,
			ProtocolReadyCount:       1,
			HomeConfigured:           true,
			HomeState:                "protocol_ready",
			HomeKeyRelation:          "match",
			HomeIdealKnown:           true,
			HomeIdeal:                false,
			HomeConnectionGeneration: 3,
			HomeServerChangeSequence: 4,
		},
		Control: tailscaleControlReadinessPayload{
			Observed:              true,
			ClientPresent:         true,
			ResetForCurrentClient: true,
			SetForCurrentClient:   true,
			PreferredDERPRelation: "match",
		},
	}
	queriedPeerKeys := make(map[key.NodePublic]int)
	encoded, err := encodeTailscaleStatus(
		status,
		readiness,
		func(peerPublicKey key.NodePublic) tailscalePeerDERPPathPayload {
			queriedPeerKeys[peerPublicKey]++
			if peerPublicKey != onlineNodeKey {
				return unavailableTailscalePeerDERPPath()
			}
			return tailscalePeerDERPPathPayload{
				Observed:                       true,
				ReplyRouteState:                "current",
				LastWriteRouteState:            "stale",
				LastWriteRouteKind:             "reverse",
				LastWriteClientState:           "current_protocol_ready",
				LastWriteClientIdealKnown:      true,
				LastWriteClientIdeal:           true,
				LastSendConnectionGeneration:   7,
				CurrentConnectionGeneration:    8,
				ConnectionChangedSinceLastSend: true,
				LastSendWasDisco:               true,
				SendAttemptSequence:            11,
				SendSuccessSequence:            10,
				SendErrorSequence:              1,
				ReceivePacketSequence:          4,
				RouteInvalidationSequence:      2,
				RouteInvalidationReason:        "reader_error",
				ReaderErrorSequence:            3,
				ReaderErrorReason:              "transport_error",
				ServerInfoSequence:             5,
				ServerChangeSequence:           7,
				ClientCloseSequence:            6,
				ClientCloseReason:              "network_down",
			}
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(queriedPeerKeys) != 2 ||
		queriedPeerKeys[onlineNodeKey] != 1 ||
		queriedPeerKeys[offlineNodeKey] != 1 ||
		queriedPeerKeys[ordinaryPeerKey] != 0 {
		t.Fatal("DERP path lookup was not exit-node-only")
	}
	var payload map[string]interface{}
	if err := stdjson.Unmarshal([]byte(encoded), &payload); err != nil {
		t.Fatal(err)
	}
	if len(payload) != 7 || payload["backend_state"] != "NeedsLogin" || payload["auth_url"] != status.AuthURL ||
		payload["health_count"] != float64(1) || payload["control_self_home_present"] != true ||
		payload["magic_dns_ready"] != true {
		t.Fatalf("unexpected status payload: %v", payload)
	}
	for _, misleading := range []string{
		"active_derp_connections",
		"self_home_configured",
	} {
		if _, found := payload[misleading]; found {
			t.Fatalf("status retained misleading field %q: %v", misleading, payload)
		}
	}
	readinessPayload, ok := payload["readiness"].(map[string]interface{})
	if !ok {
		t.Fatalf("unexpected readiness payload: %v", payload["readiness"])
	}
	derpReadiness, ok := readinessPayload["derp"].(map[string]interface{})
	if !ok || derpReadiness["observed"] != true ||
		derpReadiness["client_count"] != float64(2) ||
		derpReadiness["protocol_ready_count"] != float64(1) ||
		derpReadiness["home_configured"] != true ||
		derpReadiness["home_state"] != "protocol_ready" ||
		derpReadiness["home_key_relation"] != "match" ||
		derpReadiness["home_ideal_known"] != true ||
		derpReadiness["home_ideal"] != false ||
		derpReadiness["home_connection_generation"] != float64(3) ||
		derpReadiness["home_server_change_sequence"] != float64(4) {
		t.Fatalf("unexpected DERP readiness: %v", readinessPayload["derp"])
	}
	controlReadiness, ok := readinessPayload["control"].(map[string]interface{})
	if !ok || controlReadiness["generation"] != float64(0) ||
		controlReadiness["observed"] != true ||
		controlReadiness["client_present"] != true ||
		controlReadiness["reset_for_current_client"] != true ||
		controlReadiness["set_for_current_client"] != true ||
		controlReadiness["preferred_derp_relation"] != "match" {
		t.Fatalf("unexpected control readiness: %v", readinessPayload["control"])
	}
	nodes, ok := payload["exit_nodes"].([]interface{})
	if !ok || len(nodes) != 2 {
		t.Fatalf("unexpected exit nodes: %v", payload["exit_nodes"])
	}
	first := nodes[0].(map[string]interface{})
	if first["id"] != "online-node" || first["name"] != "home-mac" || first["ip"] != "100.64.0.8" || first["online"] != true || first["selected"] != true || first["os"] != "macOS" ||
		first["active"] != true || first["path_candidate"] != "direct" || first["tx_bytes"] != float64(123) || first["rx_bytes"] != float64(456) ||
		first["has_handshake"] != true || first["in_network_map"] != true || first["in_magic_sock"] != true || first["in_engine"] != true ||
		first["control_home_relation"] != "different" {
		t.Fatalf("unexpected first exit node: %v", first)
	}
	derpPath, ok := first["derp_path"].(map[string]interface{})
	if !ok ||
		derpPath["observed"] != true ||
		derpPath["reply_route_state"] != "current" ||
		derpPath["last_write_route_state"] != "stale" ||
		derpPath["last_write_route_kind"] != "reverse" ||
		derpPath["last_write_client_state"] != "current_protocol_ready" ||
		derpPath["last_write_client_ideal_known"] != true ||
		derpPath["last_write_client_ideal"] != true ||
		derpPath["last_send_connection_generation"] != float64(7) ||
		derpPath["current_connection_generation"] != float64(8) ||
		derpPath["connection_changed_since_last_send"] != true ||
		derpPath["last_send_was_disco"] != true ||
		derpPath["send_attempt_sequence"] != float64(11) ||
		derpPath["send_success_sequence"] != float64(10) ||
		derpPath["send_error_sequence"] != float64(1) ||
		derpPath["receive_packet_sequence"] != float64(4) ||
		derpPath["route_invalidation_sequence"] != float64(2) ||
		derpPath["route_invalidation_reason"] != "reader_error" ||
		derpPath["reader_error_sequence"] != float64(3) ||
		derpPath["reader_error_reason"] != "transport_error" ||
		derpPath["server_info_sequence"] != float64(5) ||
		derpPath["server_change_sequence"] != float64(7) ||
		derpPath["client_close_sequence"] != float64(6) ||
		derpPath["client_close_reason"] != "network_down" {
		t.Fatalf("unexpected DERP path payload: %v", first["derp_path"])
	}
	second := nodes[1].(map[string]interface{})
	unavailableDERPPath, ok := second["derp_path"].(map[string]interface{})
	if !ok ||
		unavailableDERPPath["observed"] != false ||
		unavailableDERPPath["reply_route_state"] != "unknown" ||
		unavailableDERPPath["last_write_route_state"] != "unknown" ||
		unavailableDERPPath["last_write_route_kind"] != "unknown" ||
		unavailableDERPPath["last_write_client_state"] != "unknown" ||
		unavailableDERPPath["route_invalidation_reason"] != "unknown" ||
		unavailableDERPPath["reader_error_reason"] != "unknown" ||
		unavailableDERPPath["client_close_reason"] != "unknown" {
		t.Fatalf(
			"unexpected unavailable DERP path payload: %v",
			second["derp_path"],
		)
	}
	for _, forbidden := range []string{
		"must-not-leak-version",
		"must-not-leak-health",
		"must-not-leak-tailnet",
		"must-not-leak-legacy-suffix",
		"must-not-leak-endpoint",
		"must-not-leak-current-address",
		"must-not-leak-relay-region",
		"must-not-leak-self-relay-region",
		"ordinary-peer",
		"private-tailnet.ts.net",
		onlineNodeKey.String(),
		offlineNodeKey.String(),
		ordinaryPeerKey.String(),
	} {
		if strings.Contains(encoded, forbidden) {
			t.Fatalf("status leaked %q: %s", forbidden, encoded)
		}
	}
}

func TestTailscalePeerDERPPathRejectsUnlistedText(t *testing.T) {
	const privateValue = "must-not-leak-derp-path-value"
	payload := sanitizeTailscalePeerDERPPath(
		tailscalePeerDERPPathPayload{
			ReplyRouteState:         privateValue,
			LastWriteRouteState:     privateValue,
			LastWriteRouteKind:      privateValue,
			LastWriteClientState:    privateValue,
			RouteInvalidationReason: privateValue,
			ReaderErrorReason:       privateValue,
			ClientCloseReason:       privateValue,
		},
	)
	if payload.ReplyRouteState != "unknown" ||
		payload.LastWriteRouteState != "unknown" ||
		payload.LastWriteRouteKind != "unknown" ||
		payload.LastWriteClientState != "unknown" ||
		payload.RouteInvalidationReason != "unknown" ||
		payload.ReaderErrorReason != "unknown" ||
		payload.ClientCloseReason != "unknown" {
		t.Fatalf("unlisted DERP path value escaped allowlist: %+v", payload)
	}
	encoded, err := stdjson.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), privateValue) {
		t.Fatalf("DERP path leaked unlisted text: %s", encoded)
	}
}

func TestTailscaleDERPGenerationRejectsNegativeValues(t *testing.T) {
	if got := tailscaleDERPGeneration(-1); got != 0 {
		t.Fatalf("negative generation escaped as %d", got)
	}
	if got := tailscaleDERPGeneration(0); got != 0 {
		t.Fatalf("zero generation changed to %d", got)
	}
	if got := tailscaleDERPGeneration(7); got != 7 {
		t.Fatalf("positive generation changed to %d", got)
	}
}

func TestTailscaleRuntimeReadinessPreservesUnknown(t *testing.T) {
	readiness := tailscaleRuntimeReadiness(nil)
	if readiness.DERP.Observed || readiness.Control.Observed {
		t.Fatalf("unavailable runtime reported observed readiness: %+v", readiness)
	}
	if readiness.DERP.HomeState != "unknown" ||
		readiness.DERP.HomeKeyRelation != "unknown" ||
		readiness.Control.PreferredDERPRelation != "unknown" {
		t.Fatalf("unavailable runtime lost unknown state: %+v", readiness)
	}
}

func TestTailscaleStatusErrorDoesNotEchoEndpointTag(t *testing.T) {
	engine := New(nil)
	_, err := engine.TailscaleStatus("private-endpoint-name")
	if err == nil {
		t.Fatal("expected stopped engine error")
	}
	if strings.Contains(err.Error(), "private-endpoint-name") {
		t.Fatalf("error leaked endpoint tag: %v", err)
	}
}

func TestInstallTailscaleDNSMemorySnapshotReturnsOnlyBoundedMetadata(t *testing.T) {
	rawTransport, err := boxHosts.NewTransport(
		context.Background(),
		log.NewNOPFactory().NewLogger("test"),
		"tailscale-memory",
		option.HostsDNSServerOptions{MemoryOnly: true},
	)
	if err != nil {
		t.Fatal(err)
	}
	privateAddress := netip.MustParseAddr("100.64.0.8")
	metadata, err := installTailscaleDNSMemorySnapshot(
		boxTailscale.DNSMemorySnapshot{
			Hosts: map[string][]netip.Addr{
				"mba32k": {privateAddress},
			},
			CaptureDomains: []string{"mba32k", "example-tailnet.ts.net"},
			OwnedDomains:   []string{"example-tailnet.ts.net"},
			RecordCount:    1,
		},
		rawTransport,
	)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(metadata, privateAddress.String()) {
		t.Fatalf("preparation metadata leaked a Tailnet address: %s", metadata)
	}
	var payload tailscaleDNSPreparationPayload
	if err := stdjson.Unmarshal([]byte(metadata), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.RecordCount != 1 || len(payload.CaptureDomains) != 2 {
		t.Fatalf("unexpected preparation metadata: %+v", payload)
	}
	preferred := rawTransport.(interface{ PreferredDomain(string) bool })
	if !preferred.PreferredDomain("mba32k.") ||
		!preferred.PreferredDomain("unknown.example-tailnet.ts.net.") {
		t.Fatal("installed hosts transport did not expose exact and authoritative ownership")
	}
}

func TestTailscaleDERPHomeReselectionRequiresRunningEndpoint(t *testing.T) {
	engine := New(nil)
	_, err := engine.ReselectTailscaleHomeDERP(
		"private-endpoint-name",
		5_000,
	)
	if err == nil {
		t.Fatal("expected stopped engine error")
	}
	if strings.Contains(err.Error(), "private-endpoint-name") {
		t.Fatalf("error leaked endpoint tag: %v", err)
	}
}

func TestBoxContextRegistersTailscale(t *testing.T) {
	configJSON := []byte(`{
		"log":{"disabled":true},
		"dns":{"servers":[
			{"type":"udp","tag":"xdial-public-dns","server":"1.1.1.1","server_port":53},
			{"type":"tailscale","tag":"tailscale-dns","endpoint":"tailscale-test","accept_default_resolvers":false},
			{"type":"xdial-mobile","tag":"xdial-mobile-dns","public_fallback":"xdial-public-dns",
				"tailscale":[{"endpoint":"tailscale-test","server":"tailscale-dns"}]}
		],"final":"xdial-mobile-dns"},
		"endpoints":[{
			"type":"tailscale",
			"tag":"tailscale-test",
			"state_directory":"` + t.TempDir() + `"
		}],
		"inbounds":[],
		"outbounds":[{"type":"direct","tag":"direct"}],
		"route":{"final":"direct","default_domain_resolver":"xdial-public-dns"}
	}`)
	ctx := boxContext(context.Background())
	opts, err := json.UnmarshalExtendedContext[option.Options](ctx, configJSON)
	if err != nil {
		t.Fatalf("parse Tailscale config: %v", err)
	}
	instance, err := box.New(box.Options{Options: opts, Context: ctx})
	if err != nil {
		t.Fatalf("construct box with Tailscale endpoint: %v", err)
	}
	if _, found := instance.Endpoint().Get("tailscale-test"); !found {
		t.Fatal("registered Tailscale endpoint missing from box")
	}
	_ = instance.Close()
}
