struct TailscaleReadinessFacts: Equatable {
    let pathCandidate: String
    let exitNodeOnline: Bool
    let exitNodeSelected: Bool
    let controlGeneration: UInt64
    let controlObserved: Bool
    let controlClientPresent: Bool
    let netInfoResetForCurrentClient: Bool
    let netInfoSetForCurrentClient: Bool
    let preferredDERPRelation: String
    let derpObserved: Bool
    let homeDERPState: String
    let homeDERPKeyRelation: String
}

struct TailscalePeerRecoveryFacts: Equatable {
    let readiness: TailscaleReadinessFacts
    let homeDERPConfigured: Bool
    let controlSelfHomePresent: Bool
    let inNetworkMap: Bool
    let inMagicSock: Bool
    let inEngine: Bool
    let txBytes: Int64
    let rxBytes: Int64
    let hasHandshake: Bool
}

struct TailscalePeerDERPPath: Codable, Equatable {
    let observed: Bool
    let replyRouteState: String
    let lastWriteRouteState: String
    let lastWriteRouteKind: String
    let lastWriteClientState: String
    let lastWriteClientIdealKnown: Bool
    let lastWriteClientIdeal: Bool
    let lastSendConnectionGeneration: UInt64
    let currentConnectionGeneration: UInt64
    let connectionChangedSinceLastSend: Bool
    let lastSendWasDisco: Bool
    let sendAttemptSequence: UInt64
    let sendSuccessSequence: UInt64
    let sendErrorSequence: UInt64
    let receivePacketSequence: UInt64
    let routeInvalidationSequence: UInt64
    let routeInvalidationReason: String
    let readerErrorSequence: UInt64
    let readerErrorReason: String
    let serverInfoSequence: UInt64
    let serverChangeSequence: UInt64
    let clientCloseSequence: UInt64
    let clientCloseReason: String

    enum CodingKeys: String, CodingKey {
        case observed
        case replyRouteState = "reply_route_state"
        case lastWriteRouteState = "last_write_route_state"
        case lastWriteRouteKind = "last_write_route_kind"
        case lastWriteClientState = "last_write_client_state"
        case lastWriteClientIdealKnown =
            "last_write_client_ideal_known"
        case lastWriteClientIdeal = "last_write_client_ideal"
        case lastSendConnectionGeneration =
            "last_send_connection_generation"
        case currentConnectionGeneration =
            "current_connection_generation"
        case connectionChangedSinceLastSend =
            "connection_changed_since_last_send"
        case lastSendWasDisco = "last_send_was_disco"
        case sendAttemptSequence = "send_attempt_sequence"
        case sendSuccessSequence = "send_success_sequence"
        case sendErrorSequence = "send_error_sequence"
        case receivePacketSequence = "receive_packet_sequence"
        case routeInvalidationSequence =
            "route_invalidation_sequence"
        case routeInvalidationReason = "route_invalidation_reason"
        case readerErrorSequence = "reader_error_sequence"
        case readerErrorReason = "reader_error_reason"
        case serverInfoSequence = "server_info_sequence"
        case serverChangeSequence = "server_change_sequence"
        case clientCloseSequence = "client_close_sequence"
        case clientCloseReason = "client_close_reason"
    }

    var logSummary: String {
        "observed=\(observed) " +
            "replyRoute=\(replyRouteState) " +
            "lastWriteRoute=\(lastWriteRouteState) " +
            "lastWriteKind=\(lastWriteRouteKind) " +
            "lastWriteClient=\(lastWriteClientState) " +
            "lastWriteClientIdealKnown=\(lastWriteClientIdealKnown) " +
            "lastWriteClientIdeal=\(lastWriteClientIdeal) " +
            "lastSendGeneration=\(lastSendConnectionGeneration) " +
            "currentGeneration=\(currentConnectionGeneration) " +
            "connectionChanged=\(connectionChangedSinceLastSend) " +
            "lastSendWasDisco=\(lastSendWasDisco) " +
            "sendAttemptSeq=\(sendAttemptSequence) " +
            "sendSuccessSeq=\(sendSuccessSequence) " +
            "sendErrorSeq=\(sendErrorSequence) " +
            "receivePacketSeq=\(receivePacketSequence) " +
            "routeInvalidationSeq=\(routeInvalidationSequence) " +
            "routeInvalidationReason=\(routeInvalidationReason) " +
            "readerErrorSeq=\(readerErrorSequence) " +
            "readerErrorReason=\(readerErrorReason) " +
            "serverInfoSeq=\(serverInfoSequence) " +
            "serverChangeSeq=\(serverChangeSequence) " +
            "clientCloseSeq=\(clientCloseSequence) " +
            "clientCloseReason=\(clientCloseReason)"
    }
}

struct TailscalePeerDERPPathComparison: Equatable {
    let initial: TailscalePeerDERPPath
    let final: TailscalePeerDERPPath
    let sameExitNode: Bool

    var reportFacts: [String: Bool] {
        var facts: [String: Bool] = [
            "same_exit_node": sameExitNode,
            "initial_derp_path_observed": initial.observed,
            "final_derp_path_observed": final.observed,
            "reply_route_state_changed":
                sameExitNode &&
                initial.replyRouteState != final.replyRouteState,
            "last_write_route_state_changed":
                sameExitNode &&
                initial.lastWriteRouteState !=
                final.lastWriteRouteState,
            "last_write_route_kind_changed":
                sameExitNode &&
                initial.lastWriteRouteKind !=
                final.lastWriteRouteKind,
            "last_write_client_state_changed":
                sameExitNode &&
                initial.lastWriteClientState !=
                final.lastWriteClientState,
            "initial_last_write_client_ideal_known":
                initial.lastWriteClientIdealKnown,
            "final_last_write_client_ideal_known":
                final.lastWriteClientIdealKnown,
            "initial_last_write_client_ideal":
                initial.lastWriteClientIdeal,
            "final_last_write_client_ideal":
                final.lastWriteClientIdeal,
            "last_write_client_ideal_changed":
                sameExitNode &&
                initial.lastWriteClientIdealKnown &&
                final.lastWriteClientIdealKnown &&
                initial.lastWriteClientIdeal !=
                final.lastWriteClientIdeal,
            "last_send_connection_generation_changed":
                sameExitNode &&
                initial.lastSendConnectionGeneration !=
                final.lastSendConnectionGeneration,
            "current_connection_generation_changed":
                sameExitNode &&
                initial.currentConnectionGeneration !=
                final.currentConnectionGeneration,
            "final_connection_changed_since_last_send":
                final.connectionChangedSinceLastSend,
            "last_send_was_disco_changed":
                sameExitNode &&
                initial.lastSendWasDisco != final.lastSendWasDisco,
            "final_last_send_was_disco":
                final.lastSendWasDisco,
            "final_send_attempt_observed":
                final.sendAttemptSequence > 0,
            "final_send_success_observed":
                final.sendSuccessSequence > 0,
            "final_send_error_observed":
                final.sendErrorSequence > 0,
            "final_receive_packet_observed":
                final.receivePacketSequence > 0,
            "final_route_invalidation_observed":
                final.routeInvalidationSequence > 0,
            "final_reader_error_observed":
                final.readerErrorSequence > 0,
            "final_server_info_observed":
                final.serverInfoSequence > 0,
            "final_server_change_observed":
                final.serverChangeSequence > 0,
            "final_client_close_observed":
                final.clientCloseSequence > 0,
            "send_attempt_sequence_advanced":
                sequenceAdvanced(
                    initial.sendAttemptSequence,
                    final.sendAttemptSequence
                ),
            "send_success_sequence_advanced":
                sequenceAdvanced(
                    initial.sendSuccessSequence,
                    final.sendSuccessSequence
                ),
            "send_error_sequence_advanced":
                sequenceAdvanced(
                    initial.sendErrorSequence,
                    final.sendErrorSequence
                ),
            "receive_packet_sequence_advanced":
                sequenceAdvanced(
                    initial.receivePacketSequence,
                    final.receivePacketSequence
                ),
            "route_invalidation_sequence_advanced":
                sequenceAdvanced(
                    initial.routeInvalidationSequence,
                    final.routeInvalidationSequence
                ),
            "reader_error_sequence_advanced":
                sequenceAdvanced(
                    initial.readerErrorSequence,
                    final.readerErrorSequence
                ),
            "server_info_sequence_advanced":
                sequenceAdvanced(
                    initial.serverInfoSequence,
                    final.serverInfoSequence
                ),
            "server_change_sequence_advanced":
                sequenceAdvanced(
                    initial.serverChangeSequence,
                    final.serverChangeSequence
                ),
            "client_close_sequence_advanced":
                sequenceAdvanced(
                    initial.clientCloseSequence,
                    final.clientCloseSequence
                ),
            "any_sequence_regressed":
                anySequenceRegressed,
        ]
        addOneHot(
            prefix: "initial_reply_route",
            value: initial.replyRouteState,
            allowed: ["absent", "current", "stale", "unknown"],
            to: &facts
        )
        addOneHot(
            prefix: "final_reply_route",
            value: final.replyRouteState,
            allowed: ["absent", "current", "stale", "unknown"],
            to: &facts
        )
        addOneHot(
            prefix: "initial_last_write_route",
            value: initial.lastWriteRouteState,
            allowed: ["absent", "current", "stale", "unknown"],
            to: &facts
        )
        addOneHot(
            prefix: "final_last_write_route",
            value: final.lastWriteRouteState,
            allowed: ["absent", "current", "stale", "unknown"],
            to: &facts
        )
        addOneHot(
            prefix: "initial_last_write_kind",
            value: initial.lastWriteRouteKind,
            allowed: ["none", "requested", "reverse", "unknown"],
            to: &facts
        )
        addOneHot(
            prefix: "final_last_write_kind",
            value: final.lastWriteRouteKind,
            allowed: ["none", "requested", "reverse", "unknown"],
            to: &facts
        )
        addOneHot(
            prefix: "initial_last_write_client",
            value: initial.lastWriteClientState,
            allowed: [
                "missing",
                "current_not_ready",
                "current_protocol_ready",
                "stale",
                "closed",
                "unknown",
            ],
            to: &facts
        )
        addOneHot(
            prefix: "final_last_write_client",
            value: final.lastWriteClientState,
            allowed: [
                "missing",
                "current_not_ready",
                "current_protocol_ready",
                "stale",
                "closed",
                "unknown",
            ],
            to: &facts
        )
        return facts
    }

    var logSummary: String {
        "sameExitNode=\(sameExitNode) " +
            "observed=\(initial.observed)->\(final.observed) " +
            "replyRoute=\(initial.replyRouteState)->\(final.replyRouteState) " +
            "lastWriteRoute=\(initial.lastWriteRouteState)->\(final.lastWriteRouteState) " +
            "lastWriteKind=\(initial.lastWriteRouteKind)->\(final.lastWriteRouteKind) " +
            "lastWriteClient=\(initial.lastWriteClientState)->\(final.lastWriteClientState) " +
            "lastWriteClientIdealKnown=\(initial.lastWriteClientIdealKnown)->\(final.lastWriteClientIdealKnown) " +
            "lastWriteClientIdeal=\(initial.lastWriteClientIdeal)->\(final.lastWriteClientIdeal) " +
            "lastSendGeneration=\(initial.lastSendConnectionGeneration)->\(final.lastSendConnectionGeneration) " +
            "currentGeneration=\(initial.currentConnectionGeneration)->\(final.currentConnectionGeneration) " +
            "connectionChanged=\(final.connectionChangedSinceLastSend) " +
            "lastSendWasDisco=\(initial.lastSendWasDisco)->\(final.lastSendWasDisco) " +
            "sendAttemptDelta=\(formattedDelta(initial.sendAttemptSequence, final.sendAttemptSequence)) " +
            "sendSuccessDelta=\(formattedDelta(initial.sendSuccessSequence, final.sendSuccessSequence)) " +
            "sendErrorDelta=\(formattedDelta(initial.sendErrorSequence, final.sendErrorSequence)) " +
            "receivePacketDelta=\(formattedDelta(initial.receivePacketSequence, final.receivePacketSequence)) " +
            "routeInvalidationDelta=\(formattedDelta(initial.routeInvalidationSequence, final.routeInvalidationSequence)) " +
            "routeInvalidationReason=\(final.routeInvalidationReason) " +
            "readerErrorDelta=\(formattedDelta(initial.readerErrorSequence, final.readerErrorSequence)) " +
            "readerErrorReason=\(final.readerErrorReason) " +
            "serverInfoDelta=\(formattedDelta(initial.serverInfoSequence, final.serverInfoSequence)) " +
            "serverChangeDelta=\(formattedDelta(initial.serverChangeSequence, final.serverChangeSequence)) " +
            "clientCloseDelta=\(formattedDelta(initial.clientCloseSequence, final.clientCloseSequence)) " +
            "clientCloseReason=\(final.clientCloseReason)"
    }

    private var anySequenceRegressed: Bool {
        guard sameExitNode else {
            return false
        }
        return [
            (initial.sendAttemptSequence, final.sendAttemptSequence),
            (initial.sendSuccessSequence, final.sendSuccessSequence),
            (initial.sendErrorSequence, final.sendErrorSequence),
            (initial.receivePacketSequence, final.receivePacketSequence),
            (
                initial.routeInvalidationSequence,
                final.routeInvalidationSequence
            ),
            (initial.readerErrorSequence, final.readerErrorSequence),
            (initial.serverInfoSequence, final.serverInfoSequence),
            (initial.serverChangeSequence, final.serverChangeSequence),
            (initial.clientCloseSequence, final.clientCloseSequence),
        ].contains { $0.1 < $0.0 }
    }

    private func sequenceAdvanced(
        _ initialValue: UInt64,
        _ finalValue: UInt64
    ) -> Bool {
        sameExitNode && finalValue > initialValue
    }

    private func formattedDelta(
        _ initialValue: UInt64,
        _ finalValue: UInt64
    ) -> String {
        guard sameExitNode else {
            return "not_comparable"
        }
        guard finalValue >= initialValue else {
            return "regressed"
        }
        return String(finalValue - initialValue)
    }

    private func addOneHot(
        prefix: String,
        value: String,
        allowed: [String],
        to facts: inout [String: Bool]
    ) {
        let normalized = allowed.contains(value) ? value : "unknown"
        for candidate in allowed {
            facts["\(prefix)_\(candidate)"] =
                candidate == normalized
        }
    }
}

enum TailscaleReadinessFailure: Equatable {
    case controlClientMissing
    case netInfoResetMissing
    case netInfoSetMissing
    case homeDERPReportMismatch
    case derpIdentityMismatch
    case homeDERPNotReady(String)
}

// ipnstate describes the control-view relationship between the local node and
// a peer as same/different/unknown. Keep that vocabulary at the report
// boundary; comparing it with the separate match/mismatch readiness vocabulary
// makes the diagnostic permanently false.
func tailscaleControlHomeRelationIsSame(_ relation: String) -> Bool {
    relation == "same"
}

// These facts explain a failed real-egress probe; they never replace it as the
// success gate. Home DERP state is causal enough to classify only when the
// selected peer currently has no direct candidate and therefore depends on a
// relay path. An unavailable diagnostic stays unknown instead of becoming a
// confirmed failure.
func classifyTailscaleReadinessFailure(
    _ facts: TailscaleReadinessFacts
) -> TailscaleReadinessFailure? {
    guard facts.exitNodeOnline,
        facts.exitNodeSelected,
        facts.pathCandidate == "relay"
    else {
        return nil
    }
    if facts.controlObserved &&
        !facts.controlClientPresent
    {
        return .controlClientMissing
    }
    if facts.controlObserved &&
        !facts.netInfoResetForCurrentClient
    {
        return .netInfoResetMissing
    }
    if facts.controlObserved &&
        !facts.netInfoSetForCurrentClient
    {
        return .netInfoSetMissing
    }
    if facts.controlObserved &&
        facts.preferredDERPRelation == "mismatch"
    {
        return .homeDERPReportMismatch
    }
    if facts.derpObserved &&
        facts.homeDERPKeyRelation == "mismatch"
    {
        return .derpIdentityMismatch
    }
    if facts.derpObserved &&
        facts.homeDERPState != "protocol_ready"
    {
        return .homeDERPNotReady(facts.homeDERPState)
    }
    return nil
}

// HomeDERP reselection is a bounded recovery for one exact chronology:
// control and the local relay stay ready across two fresh failed real-egress
// samples, the selected peer remains in every data-plane view, authenticated
// traffic keeps being sent, but no byte ever returns. The caller must also
// enforce a single attempt during Prepare.
func shouldReselectTailscaleHomeDERP(
    previous: TailscalePeerRecoveryFacts,
    current: TailscalePeerRecoveryFacts
) -> Bool {
    isTailscalePeerRecoveryCandidate(previous) &&
        isTailscalePeerRecoveryCandidate(current) &&
        previous.readiness.controlGeneration ==
            current.readiness.controlGeneration &&
        current.txBytes > previous.txBytes
}

private func isTailscalePeerRecoveryCandidate(
    _ facts: TailscalePeerRecoveryFacts
) -> Bool {
    let readiness = facts.readiness
    return readiness.pathCandidate == "relay" &&
        readiness.exitNodeOnline &&
        readiness.exitNodeSelected &&
        readiness.controlGeneration != 0 &&
        readiness.controlObserved &&
        readiness.controlClientPresent &&
        readiness.netInfoResetForCurrentClient &&
        readiness.netInfoSetForCurrentClient &&
        readiness.preferredDERPRelation == "match" &&
        readiness.derpObserved &&
        facts.homeDERPConfigured &&
        readiness.homeDERPState == "protocol_ready" &&
        readiness.homeDERPKeyRelation == "match" &&
        facts.controlSelfHomePresent &&
        facts.inNetworkMap &&
        facts.inMagicSock &&
        facts.inEngine &&
        facts.txBytes > 0 &&
        facts.rxBytes == 0 &&
        !facts.hasHandshake
}
