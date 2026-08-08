import XCTest

final class ScenarioSwitchIPCTests: XCTestCase {
    func testSwitchRequestRoundTripsAllTransactionIdentities() throws {
        let request = ProviderScenarioSwitchRequest.switchScenario(
            requestID: "request-1",
            expectedTransactionID: "source-1",
            targetTransactionID: "target-1",
            profileJSON: "{\"active_scenario_id\":\"hotel\"}",
            connectionReportJSON:
                "{\"transaction_id\":\"target-1\"}",
            underlayInterfacesJSON:
                "[{\"name\":\"en0\",\"index\":7,\"type\":\"wifi\"}]",
            underlayDefaultName: "en0",
            underlayDefaultIndex: 7,
            systemDNSJSON: "[\"192.0.2.53\"]"
        )

        XCTAssertEqual(
            try ProviderScenarioSwitchCodec.decodeRequest(
                ProviderScenarioSwitchCodec.encodeRequest(request)
            ),
            request
        )
    }

    func testCancelRequestCannotCarryCandidateConfiguration() throws {
        let malformed = Data(
            """
            {
              "v":1,
              "cmd":"cancel-switch",
              "request_id":"request-1",
              "expected_transaction_id":"source-1",
              "profile_json":"{}"
            }
            """.utf8
        )

        XCTAssertThrowsError(
            try ProviderScenarioSwitchCodec.decodeRequest(malformed)
        )
    }

    func testReconcileRequestIsReadOnlyAndCarriesBothTransactions() throws {
        let request = ProviderScenarioSwitchRequest.reconcileSwitch(
            requestID: "request-1",
            expectedTransactionID: "source-1",
            targetTransactionID: "target-1"
        )

        XCTAssertEqual(
            try ProviderScenarioSwitchCodec.decodeRequest(
                ProviderScenarioSwitchCodec.encodeRequest(request)
            ),
            request
        )

        let withConfiguration = Data(
            """
            {
              "v":1,
              "cmd":"reconcile-switch",
              "request_id":"request-1",
              "expected_transaction_id":"source-1",
              "target_transaction_id":"target-1",
              "profile_json":"{}"
            }
            """.utf8
        )
        XCTAssertThrowsError(
            try ProviderScenarioSwitchCodec.decodeRequest(withConfiguration)
        )
    }

    func testReconcileRequestRequiresDistinctTargetTransaction() {
        let malformed = ProviderScenarioSwitchRequest.reconcileSwitch(
            requestID: "request-1",
            expectedTransactionID: "same-1",
            targetTransactionID: "same-1"
        )
        XCTAssertThrowsError(
            try ProviderScenarioSwitchCodec.decodeRequest(
                ProviderScenarioSwitchCodec.encodeRequest(malformed)
            )
        )
    }

    func testSwitchRequestRequiresCompleteUnderlaySnapshot() {
        let malformed = Data(
            """
            {
              "v":1,
              "cmd":"switch-scenario",
              "request_id":"request-1",
              "expected_transaction_id":"source-1",
              "target_transaction_id":"target-1",
              "profile_json":"{}",
              "connection_report_json":"{}"
            }
            """.utf8
        )

        XCTAssertThrowsError(
            try ProviderScenarioSwitchCodec.decodeRequest(malformed)
        )
    }

    func testSuccessfulSwitchResponseRequiresCommittedReportPayload() {
        let response = ProviderScenarioSwitchResponse(
            v: 1,
            cmd: .switchScenario,
            requestID: "request-1",
            ok: true,
            sourceTransactionID: "source-1",
            activeTransactionID: "target-1",
            code: nil,
            message: nil,
            reportJSON: nil
        )

        XCTAssertThrowsError(
            try ProviderScenarioSwitchCodec.decodeResponse(
                ProviderScenarioSwitchCodec.encodeResponse(response)
            )
        )
    }

    func testFailedSwitchCannotSmuggleCandidateReport() {
        let response = ProviderScenarioSwitchResponse(
            v: 1,
            cmd: .switchScenario,
            requestID: "request-1",
            ok: false,
            sourceTransactionID: "source-1",
            activeTransactionID: "source-1",
            code: "switch-prepare-failed",
            message: "candidate failed",
            reportJSON: "{}"
        )

        XCTAssertThrowsError(
            try ProviderScenarioSwitchCodec.decodeResponse(
                ProviderScenarioSwitchCodec.encodeResponse(response)
            )
        )
    }

    func testFailedSwitchMustLeaveSourceTransactionActive() {
        let response = ProviderScenarioSwitchResponse(
            v: 1,
            cmd: .switchScenario,
            requestID: "request-1",
            ok: false,
            sourceTransactionID: "source-1",
            activeTransactionID: "target-1",
            code: "switch-commit-failed",
            message: "candidate failed",
            reportJSON: nil
        )

        XCTAssertThrowsError(
            try ProviderScenarioSwitchCodec.decodeResponse(
                ProviderScenarioSwitchCodec.encodeResponse(response)
            )
        )
    }

    func testSuccessfulCancellationMustLeaveSourceTransactionActive() {
        let response = ProviderScenarioSwitchResponse(
            v: 1,
            cmd: .cancelSwitch,
            requestID: "request-1",
            ok: true,
            sourceTransactionID: "source-1",
            activeTransactionID: "target-1",
            code: nil,
            message: nil,
            reportJSON: nil
        )

        XCTAssertThrowsError(
            try ProviderScenarioSwitchCodec.decodeResponse(
                ProviderScenarioSwitchCodec.encodeResponse(response)
            )
        )
    }

    func testCancellationThatLosesCommitRaceIdentifiesTarget() throws {
        let response = ProviderScenarioSwitchResponse(
            v: 1,
            cmd: .cancelSwitch,
            requestID: "request-1",
            ok: false,
            sourceTransactionID: "source-1",
            activeTransactionID: "target-1",
            code: "switch-already-committed",
            message: "target committed",
            reportJSON: nil
        )

        XCTAssertEqual(
            try ProviderScenarioSwitchCodec.decodeResponse(
                ProviderScenarioSwitchCodec.encodeResponse(response)
            ),
            response
        )
    }

    func testOtherCancellationFailureCannotChangeActiveTransaction() {
        let response = ProviderScenarioSwitchResponse(
            v: 1,
            cmd: .cancelSwitch,
            requestID: "request-1",
            ok: false,
            sourceTransactionID: "source-1",
            activeTransactionID: "target-1",
            code: "switch-not-active",
            message: "not active",
            reportJSON: nil
        )

        XCTAssertThrowsError(
            try ProviderScenarioSwitchCodec.decodeResponse(
                ProviderScenarioSwitchCodec.encodeResponse(response)
            )
        )
    }

    func testSuccessfulResponsePreservesSourceAndActiveTransactions() throws {
        let response = ProviderScenarioSwitchResponse(
            v: 1,
            cmd: .switchScenario,
            requestID: "request-1",
            ok: true,
            sourceTransactionID: "source-1",
            activeTransactionID: "target-1",
            code: nil,
            message: nil,
            reportJSON: "{\"transaction_id\":\"target-1\"}"
        )

        XCTAssertEqual(
            try ProviderScenarioSwitchCodec.decodeResponse(
                ProviderScenarioSwitchCodec.encodeResponse(response)
            ),
            response
        )
    }

    func testReconcileResponseCanProveSourceStillInProgress() throws {
        let response = ProviderScenarioSwitchResponse(
            v: 1,
            cmd: .reconcileSwitch,
            requestID: "request-1",
            ok: true,
            sourceTransactionID: "source-1",
            activeTransactionID: "source-1",
            code: nil,
            message: nil,
            reportJSON: "{\"transaction_id\":\"source-1\"}",
            candidateReportJSON:
                "{\"transaction_id\":\"target-1\"}",
            switchInProgress: true
        )

        XCTAssertEqual(
            try ProviderScenarioSwitchCodec.decodeResponse(
                ProviderScenarioSwitchCodec.encodeResponse(response)
            ),
            response
        )
    }

    func testSettledReconcileResponseCannotCarryCandidateProgress() {
        let response = ProviderScenarioSwitchResponse(
            v: 1,
            cmd: .reconcileSwitch,
            requestID: "request-1",
            ok: true,
            sourceTransactionID: "source-1",
            activeTransactionID: "target-1",
            code: nil,
            message: nil,
            reportJSON: "{\"transaction_id\":\"target-1\"}",
            candidateReportJSON:
                "{\"transaction_id\":\"target-1\"}",
            switchInProgress: false
        )

        XCTAssertThrowsError(
            try ProviderScenarioSwitchCodec.decodeResponse(
                ProviderScenarioSwitchCodec.encodeResponse(response)
            )
        )
    }

    func testReconcileSuccessRequiresProgressFact() {
        let response = ProviderScenarioSwitchResponse(
            v: 1,
            cmd: .reconcileSwitch,
            requestID: "request-1",
            ok: true,
            sourceTransactionID: "source-1",
            activeTransactionID: "target-1",
            code: nil,
            message: nil,
            reportJSON: "{\"transaction_id\":\"target-1\"}"
        )

        XCTAssertThrowsError(
            try ProviderScenarioSwitchCodec.decodeResponse(
                ProviderScenarioSwitchCodec.encodeResponse(response)
            )
        )
    }

    func testSwitchResponseCannotSmuggleReconciliationState() {
        let response = ProviderScenarioSwitchResponse(
            v: 1,
            cmd: .switchScenario,
            requestID: "request-1",
            ok: true,
            sourceTransactionID: "source-1",
            activeTransactionID: "target-1",
            code: nil,
            message: nil,
            reportJSON: "{\"transaction_id\":\"target-1\"}",
            switchInProgress: false
        )

        XCTAssertThrowsError(
            try ProviderScenarioSwitchCodec.decodeResponse(
                ProviderScenarioSwitchCodec.encodeResponse(response)
            )
        )
    }

    func testReconciliationResolutionNeverAssumesSource() {
        XCTAssertEqual(
            ProviderScenarioSwitchReconciliation.resolve(
                sourceTransactionID: "source-1",
                targetTransactionID: "target-1",
                activeTransactionID: "source-1",
                switchInProgress: true
            ),
            .sourceInProgress
        )
        XCTAssertEqual(
            ProviderScenarioSwitchReconciliation.resolve(
                sourceTransactionID: "source-1",
                targetTransactionID: "target-1",
                activeTransactionID: "source-1",
                switchInProgress: false
            ),
            .sourceRestored
        )
        XCTAssertEqual(
            ProviderScenarioSwitchReconciliation.resolve(
                sourceTransactionID: "source-1",
                targetTransactionID: "target-1",
                activeTransactionID: "target-1",
                switchInProgress: false
            ),
            .targetCommitted
        )
        XCTAssertEqual(
            ProviderScenarioSwitchReconciliation.resolve(
                sourceTransactionID: "source-1",
                targetTransactionID: "target-1",
                activeTransactionID: "other-1",
                switchInProgress: false
            ),
            .unrelatedTransaction
        )
    }
}
