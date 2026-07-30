import Foundation
import XCTest

final class TailscaleReadinessTests: XCTestCase {
    func testUnavailableDiagnosticsStayUnknown() {
        XCTAssertNil(classifyTailscaleReadinessFailure(facts(
            path: "relay",
            controlObserved: false,
            derpObserved: false
        )))
    }

    func testDirectCandidateDoesNotBlameDERP() {
        XCTAssertNil(classifyTailscaleReadinessFailure(facts(
            path: "direct",
            controlObserved: true,
            clientPresent: false,
            reset: false,
            set: false,
            preferred: "mismatch",
            derpObserved: true,
            homeState: "connecting",
            homeKey: "mismatch"
        )))
    }

    func testUnavailableExitNodeDoesNotUseStructuralAttribution() {
        XCTAssertNil(classifyTailscaleReadinessFailure(facts(
            path: "relay",
            online: false,
            selected: true,
            controlObserved: true,
            reset: false,
            derpObserved: true,
            homeState: "connecting"
        )))
        XCTAssertNil(classifyTailscaleReadinessFailure(facts(
            path: "relay",
            online: true,
            selected: false,
            controlObserved: true,
            reset: false,
            derpObserved: true,
            homeState: "connecting"
        )))
    }

    func testRelayFailureClassificationOrder() {
        XCTAssertEqual(
            classifyTailscaleReadinessFailure(facts(
                path: "relay",
                controlObserved: true,
                reset: false
            )),
            .netInfoResetMissing
        )
        XCTAssertEqual(
            classifyTailscaleReadinessFailure(facts(
                path: "relay",
                controlObserved: true,
                clientPresent: false,
                reset: false,
                set: false
            )),
            .controlClientMissing
        )
        XCTAssertEqual(
            classifyTailscaleReadinessFailure(facts(
                path: "relay",
                controlObserved: true,
                reset: true,
                set: false
            )),
            .netInfoSetMissing
        )
        XCTAssertEqual(
            classifyTailscaleReadinessFailure(facts(
                path: "relay",
                controlObserved: true,
                reset: true,
                set: true,
                preferred: "mismatch"
            )),
            .homeDERPReportMismatch
        )
        XCTAssertEqual(
            classifyTailscaleReadinessFailure(facts(
                path: "relay",
                controlObserved: true,
                reset: true,
                set: true,
                derpObserved: true,
                homeKey: "mismatch"
            )),
            .derpIdentityMismatch
        )
        XCTAssertEqual(
            classifyTailscaleReadinessFailure(facts(
                path: "relay",
                controlObserved: true,
                reset: true,
                set: true,
                derpObserved: true,
                homeState: "transport_connected"
            )),
            .homeDERPNotReady("transport_connected")
        )
    }

    func testRelayProtocolReadyHasNoStructuralFailure() {
        XCTAssertNil(classifyTailscaleReadinessFailure(facts(
            path: "relay",
            controlObserved: true,
            reset: true,
            set: true,
            derpObserved: true,
            homeState: "protocol_ready"
        )))
    }

    func testControlHomeRelationUsesIPNStateVocabulary() {
        XCTAssertTrue(tailscaleControlHomeRelationIsSame("same"))
        XCTAssertFalse(tailscaleControlHomeRelationIsSame("different"))
        XCTAssertFalse(tailscaleControlHomeRelationIsSame("unknown"))
        XCTAssertFalse(tailscaleControlHomeRelationIsSame("match"))
    }

    func testHomeDERPReselectionRequiresExactHealthyRelayNoReturnFacts() {
        XCTAssertTrue(shouldReselectTailscaleHomeDERP(
            previous: recoveryFacts(txBytes: 1),
            current: recoveryFacts(txBytes: 2)
        ))
    }

    func testHomeDERPReselectionRejectsNonRelayOrAnyReturnTraffic() {
        XCTAssertFalse(shouldReselectTailscaleHomeDERP(
            previous: recoveryFacts(path: "direct", txBytes: 1),
            current: recoveryFacts(txBytes: 2)
        ))
        XCTAssertFalse(shouldReselectTailscaleHomeDERP(
            previous: recoveryFacts(txBytes: 1),
            current: recoveryFacts(txBytes: 2, rxBytes: 1)
        ))
        XCTAssertFalse(shouldReselectTailscaleHomeDERP(
            previous: recoveryFacts(txBytes: 1),
            current: recoveryFacts(txBytes: 2, hasHandshake: true)
        ))
    }

    func testHomeDERPReselectionRejectsIncompleteRuntimeViews() {
        XCTAssertFalse(shouldReselectTailscaleHomeDERP(
            previous: recoveryFacts(txBytes: 1),
            current: recoveryFacts(inMagicSock: false, txBytes: 2)
        ))
        XCTAssertFalse(shouldReselectTailscaleHomeDERP(
            previous: recoveryFacts(txBytes: 1),
            current: recoveryFacts(netInfoSet: false, txBytes: 2)
        ))
        XCTAssertFalse(shouldReselectTailscaleHomeDERP(
            previous: recoveryFacts(txBytes: 1),
            current: recoveryFacts(homeState: "connecting", txBytes: 2)
        ))
    }

    func testHomeDERPReselectionRequiresFreshTransmitProgress() {
        XCTAssertFalse(shouldReselectTailscaleHomeDERP(
            previous: recoveryFacts(txBytes: 2),
            current: recoveryFacts(txBytes: 2)
        ))
        XCTAssertFalse(shouldReselectTailscaleHomeDERP(
            previous: recoveryFacts(
                controlGeneration: 1,
                txBytes: 1
            ),
            current: recoveryFacts(
                controlGeneration: 2,
                txBytes: 2
            )
        ))
    }

    func testPeerDERPPathDecodesBoundedStatusPayload() throws {
        let data = Data(
            """
            {
              "observed": true,
              "reply_route_state": "current",
              "last_write_route_state": "stale",
              "last_write_route_kind": "reverse",
              "last_write_client_state": "current_protocol_ready",
              "last_write_client_ideal_known": true,
              "last_write_client_ideal": true,
              "last_send_connection_generation": 7,
              "current_connection_generation": 8,
              "connection_changed_since_last_send": true,
              "last_send_was_disco": true,
              "send_attempt_sequence": 11,
              "send_success_sequence": 10,
              "send_error_sequence": 1,
              "receive_packet_sequence": 4,
              "route_invalidation_sequence": 2,
              "route_invalidation_reason": "reader_error",
              "reader_error_sequence": 3,
              "reader_error_reason": "transport_error",
              "server_info_sequence": 5,
              "server_change_sequence": 7,
              "client_close_sequence": 6,
              "client_close_reason": "network_down"
            }
            """.utf8
        )

        let path = try JSONDecoder().decode(
            TailscalePeerDERPPath.self,
            from: data
        )

        XCTAssertEqual(path.replyRouteState, "current")
        XCTAssertEqual(path.lastWriteRouteState, "stale")
        XCTAssertEqual(path.lastWriteRouteKind, "reverse")
        XCTAssertEqual(
            path.lastWriteClientState,
            "current_protocol_ready"
        )
        XCTAssertTrue(path.lastWriteClientIdealKnown)
        XCTAssertTrue(path.lastWriteClientIdeal)
        XCTAssertEqual(path.lastSendConnectionGeneration, 7)
        XCTAssertEqual(path.currentConnectionGeneration, 8)
        XCTAssertTrue(path.connectionChangedSinceLastSend)
        XCTAssertTrue(path.lastSendWasDisco)
        XCTAssertEqual(path.sendAttemptSequence, 11)
        XCTAssertEqual(path.sendSuccessSequence, 10)
        XCTAssertEqual(path.sendErrorSequence, 1)
        XCTAssertEqual(path.receivePacketSequence, 4)
        XCTAssertEqual(path.routeInvalidationSequence, 2)
        XCTAssertEqual(path.routeInvalidationReason, "reader_error")
        XCTAssertEqual(path.readerErrorSequence, 3)
        XCTAssertEqual(path.readerErrorReason, "transport_error")
        XCTAssertEqual(path.serverInfoSequence, 5)
        XCTAssertEqual(path.serverChangeSequence, 7)
        XCTAssertEqual(path.clientCloseSequence, 6)
        XCTAssertEqual(path.clientCloseReason, "network_down")
    }

    func testPeerDERPPathComparisonReportsStatesAndSequenceDeltas() {
        let comparison = TailscalePeerDERPPathComparison(
            initial: derpPath(
                replyRouteState: "current",
                lastWriteRouteState: "current",
                lastWriteRouteKind: "requested",
                lastWriteClientState: "current_protocol_ready",
                lastWriteClientIdealKnown: true,
                lastWriteClientIdeal: true,
                lastSendConnectionGeneration: 3,
                currentConnectionGeneration: 3,
                sendAttemptSequence: 9,
                sendSuccessSequence: 7,
                sendErrorSequence: 1,
                receivePacketSequence: 4,
                routeInvalidationSequence: 0,
                readerErrorSequence: 0,
                serverInfoSequence: 2,
                serverChangeSequence: 1,
                clientCloseSequence: 0
            ),
            final: derpPath(
                replyRouteState: "stale",
                lastWriteRouteState: "stale",
                lastWriteRouteKind: "reverse",
                lastWriteClientState: "closed",
                lastWriteClientIdealKnown: true,
                lastWriteClientIdeal: false,
                lastSendConnectionGeneration: 4,
                currentConnectionGeneration: 5,
                connectionChangedSinceLastSend: true,
                lastSendWasDisco: true,
                sendAttemptSequence: 12,
                sendSuccessSequence: 9,
                sendErrorSequence: 2,
                receivePacketSequence: 6,
                routeInvalidationSequence: 1,
                routeInvalidationReason: "reader_error",
                readerErrorSequence: 1,
                readerErrorReason: "transport_error",
                serverInfoSequence: 3,
                serverChangeSequence: 2,
                clientCloseSequence: 1,
                clientCloseReason: "network_down"
            ),
            sameExitNode: true
        )
        let facts = comparison.reportFacts

        XCTAssertEqual(facts["initial_reply_route_current"], true)
        XCTAssertEqual(facts["initial_reply_route_stale"], false)
        XCTAssertEqual(facts["final_reply_route_current"], false)
        XCTAssertEqual(facts["final_reply_route_stale"], true)
        XCTAssertEqual(
            facts["initial_last_write_client_current_protocol_ready"],
            true
        )
        XCTAssertEqual(facts["final_last_write_client_closed"], true)
        XCTAssertEqual(
            facts["last_write_client_ideal_changed"],
            true
        )
        XCTAssertEqual(
            facts["last_send_connection_generation_changed"],
            true
        )
        XCTAssertEqual(
            facts["current_connection_generation_changed"],
            true
        )
        XCTAssertEqual(
            facts["final_connection_changed_since_last_send"],
            true
        )
        for key in [
            "send_attempt_sequence_advanced",
            "send_success_sequence_advanced",
            "send_error_sequence_advanced",
            "receive_packet_sequence_advanced",
            "route_invalidation_sequence_advanced",
            "reader_error_sequence_advanced",
            "server_info_sequence_advanced",
            "server_change_sequence_advanced",
            "client_close_sequence_advanced",
        ] {
            XCTAssertEqual(facts[key], true, key)
        }
        XCTAssertEqual(facts["any_sequence_regressed"], false)
        XCTAssertTrue(
            comparison.logSummary.contains("sendSuccessDelta=2")
        )
        XCTAssertTrue(
            comparison.logSummary.contains("receivePacketDelta=2")
        )
    }

    func testPeerDERPPathComparisonDoesNotCompareDifferentPeers() {
        let comparison = TailscalePeerDERPPathComparison(
            initial: derpPath(sendAttemptSequence: 1),
            final: derpPath(sendAttemptSequence: 2),
            sameExitNode: false
        )

        XCTAssertEqual(
            comparison.reportFacts["send_attempt_sequence_advanced"],
            false
        )
        XCTAssertEqual(
            comparison.reportFacts["any_sequence_regressed"],
            false
        )
        XCTAssertTrue(
            comparison.logSummary.contains(
                "sendAttemptDelta=not_comparable"
            )
        )
    }

    func testPeerDERPPathComparisonMarksSequenceRegression() {
        let comparison = TailscalePeerDERPPathComparison(
            initial: derpPath(sendSuccessSequence: 4),
            final: derpPath(sendSuccessSequence: 3),
            sameExitNode: true
        )

        XCTAssertEqual(
            comparison.reportFacts["send_success_sequence_advanced"],
            false
        )
        XCTAssertEqual(
            comparison.reportFacts["any_sequence_regressed"],
            true
        )
        XCTAssertTrue(
            comparison.logSummary.contains("sendSuccessDelta=regressed")
        )
    }

    private func derpPath(
        observed: Bool = true,
        replyRouteState: String = "current",
        lastWriteRouteState: String = "current",
        lastWriteRouteKind: String = "requested",
        lastWriteClientState: String = "current_protocol_ready",
        lastWriteClientIdealKnown: Bool = false,
        lastWriteClientIdeal: Bool = false,
        lastSendConnectionGeneration: UInt64 = 1,
        currentConnectionGeneration: UInt64 = 1,
        connectionChangedSinceLastSend: Bool = false,
        lastSendWasDisco: Bool = false,
        sendAttemptSequence: UInt64 = 0,
        sendSuccessSequence: UInt64 = 0,
        sendErrorSequence: UInt64 = 0,
        receivePacketSequence: UInt64 = 0,
        routeInvalidationSequence: UInt64 = 0,
        routeInvalidationReason: String = "none",
        readerErrorSequence: UInt64 = 0,
        readerErrorReason: String = "none",
        serverInfoSequence: UInt64 = 0,
        serverChangeSequence: UInt64 = 0,
        clientCloseSequence: UInt64 = 0,
        clientCloseReason: String = "none"
    ) -> TailscalePeerDERPPath {
        TailscalePeerDERPPath(
            observed: observed,
            replyRouteState: replyRouteState,
            lastWriteRouteState: lastWriteRouteState,
            lastWriteRouteKind: lastWriteRouteKind,
            lastWriteClientState: lastWriteClientState,
            lastWriteClientIdealKnown:
                lastWriteClientIdealKnown,
            lastWriteClientIdeal: lastWriteClientIdeal,
            lastSendConnectionGeneration:
                lastSendConnectionGeneration,
            currentConnectionGeneration:
                currentConnectionGeneration,
            connectionChangedSinceLastSend:
                connectionChangedSinceLastSend,
            lastSendWasDisco: lastSendWasDisco,
            sendAttemptSequence: sendAttemptSequence,
            sendSuccessSequence: sendSuccessSequence,
            sendErrorSequence: sendErrorSequence,
            receivePacketSequence: receivePacketSequence,
            routeInvalidationSequence: routeInvalidationSequence,
            routeInvalidationReason: routeInvalidationReason,
            readerErrorSequence: readerErrorSequence,
            readerErrorReason: readerErrorReason,
            serverInfoSequence: serverInfoSequence,
            serverChangeSequence: serverChangeSequence,
            clientCloseSequence: clientCloseSequence,
            clientCloseReason: clientCloseReason
        )
    }

    private func recoveryFacts(
        path: String = "relay",
        netInfoSet: Bool = true,
        homeState: String = "protocol_ready",
        inMagicSock: Bool = true,
        controlGeneration: UInt64 = 1,
        txBytes: Int64 = 1,
        rxBytes: Int64 = 0,
        hasHandshake: Bool = false
    ) -> TailscalePeerRecoveryFacts {
        TailscalePeerRecoveryFacts(
            readiness: facts(
                path: path,
                controlGeneration: controlGeneration,
                controlObserved: true,
                clientPresent: true,
                reset: true,
                set: netInfoSet,
                preferred: "match",
                derpObserved: true,
                homeState: homeState,
                homeKey: "match"
            ),
            homeDERPConfigured: true,
            controlSelfHomePresent: true,
            inNetworkMap: true,
            inMagicSock: inMagicSock,
            inEngine: true,
            txBytes: txBytes,
            rxBytes: rxBytes,
            hasHandshake: hasHandshake
        )
    }

    private func facts(
        path: String,
        online: Bool = true,
        selected: Bool = true,
        controlGeneration: UInt64 = 1,
        controlObserved: Bool = false,
        clientPresent: Bool = true,
        reset: Bool = false,
        set: Bool = false,
        preferred: String = "match",
        derpObserved: Bool = false,
        homeState: String = "protocol_ready",
        homeKey: String = "match"
    ) -> TailscaleReadinessFacts {
        TailscaleReadinessFacts(
            pathCandidate: path,
            exitNodeOnline: online,
            exitNodeSelected: selected,
            controlGeneration: controlGeneration,
            controlObserved: controlObserved,
            controlClientPresent: clientPresent,
            netInfoResetForCurrentClient: reset,
            netInfoSetForCurrentClient: set,
            preferredDERPRelation: preferred,
            derpObserved: derpObserved,
            homeDERPState: homeState,
            homeDERPKeyRelation: homeKey
        )
    }
}
