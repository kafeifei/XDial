import XCTest

final class ProviderDiagnosticsIPCTests: XCTestCase {
    func testLineProbeAcceptsOnlyLineCapabilityInput() throws {
        let request = ProviderDiagnosticsRequest(
            cmd: .probeLineOutboundAddress,
            transactionID: "transaction-1",
            lineID: "company"
        )
        let encoded = try ProviderDiagnosticsCodec.encodeRequest(request)
        XCTAssertEqual(
            try ProviderDiagnosticsCodec.decodeRequest(encoded),
            request
        )

        for forbidden in [
            """
            {"v":1,"cmd":"probe-line-outbound-address","transaction_id":"transaction-1","line_id":"company","outbound_tag":"vpn"}
            """,
            """
            {"v":1,"cmd":"probe-line-outbound-address","transaction_id":"transaction-1","line_id":"company","test_url":"https://example.com/"}
            """,
            """
            {"v":1,"cmd":"probe-line-outbound-address","transaction_id":"transaction-1"}
            """,
        ] {
            XCTAssertThrowsError(
                try ProviderDiagnosticsCodec.decodeRequest(Data(forbidden.utf8))
            ) {
                XCTAssertEqual(
                    $0 as? ProviderDiagnosticsCodecError,
                    .invalidRequest
                )
            }
        }
    }

    func testSnapshotRequiresExactVersionCommandAndTransaction() throws {
        let valid = Data(
            """
            {"v":1,"cmd":"routing-probe-snapshot","transaction_id":"transaction-1","probe_id":"probe-1"}
            """.utf8
        )
        XCTAssertEqual(
            try ProviderDiagnosticsCodec.decodeRequest(valid),
            ProviderDiagnosticsRequest(
                cmd: .routingProbeSnapshot,
                transactionID: "transaction-1",
                probeID: "probe-1"
            )
        )

        let cases: [(String, ProviderDiagnosticsCodecError)] = [
            (
                #"{"v":2,"cmd":"routing-probe-snapshot","transaction_id":"transaction-1"}"#,
                .unsupportedVersion
            ),
            (
                #"{"v":1,"cmd":"unknown","transaction_id":"transaction-1"}"#,
                .unknownCommand
            ),
            (
                #"{"v":1,"cmd":"routing-probe-snapshot"}"#,
                .invalidRequest
            ),
            (
                #"{"v":1,"cmd":"routing-probe-snapshot","transaction_id":"transaction-1"}"#,
                .invalidRequest
            ),
            (
                #"{"v":1,"cmd":"routing-probe-snapshot","transaction_id":"transaction-1","probe_id":"probe-1","host":"secret.example"}"#,
                .invalidRequest
            ),
        ]
        for (raw, expected) in cases {
            XCTAssertThrowsError(
                try ProviderDiagnosticsCodec.decodeRequest(Data(raw.utf8))
            ) {
                XCTAssertEqual(
                    $0 as? ProviderDiagnosticsCodecError,
                    expected
                )
            }
        }
    }

    func testBeginRouteProbeIsASCII443AndBoundedToFifteenSeconds() throws {
        let valid = ProviderDiagnosticsRequest(
            cmd: .beginRouteProbe,
            transactionID: "transaction-1",
            host: "probe.example",
            port: 443,
            timeoutMS: 15_000
        )
        XCTAssertEqual(
            try ProviderDiagnosticsCodec.decodeRequest(
                ProviderDiagnosticsCodec.encodeRequest(valid)
            ),
            valid
        )

        for invalid in [
            ProviderDiagnosticsRequest(
                cmd: .beginRouteProbe,
                transactionID: "transaction-1",
                host: "测试.example",
                port: 443,
                timeoutMS: 1_000
            ),
            ProviderDiagnosticsRequest(
                cmd: .beginRouteProbe,
                transactionID: "transaction-1",
                host: "192.0.2.1",
                port: 443,
                timeoutMS: 1_000
            ),
            ProviderDiagnosticsRequest(
                cmd: .beginRouteProbe,
                transactionID: "transaction-1",
                host: "probe.example",
                port: 80,
                timeoutMS: 1_000
            ),
            ProviderDiagnosticsRequest(
                cmd: .beginRouteProbe,
                transactionID: "transaction-1",
                host: "probe.example",
                port: 443,
                timeoutMS: 15_001
            ),
        ] {
            XCTAssertThrowsError(
                try ProviderDiagnosticsCodec.decodeRequest(
                    ProviderDiagnosticsCodec.encodeRequest(invalid)
                )
            )
        }
    }

    func testResponseExposesOnlyTypedBoundedEvidence() throws {
        let response = ProviderDiagnosticsResponse.success(
            transactionID: "transaction-1",
            data: ProviderDiagnosticsData(
                routingProbe: ProviderRoutingProbeSnapshot(
                    probeID: "probe-1",
                    matchCount: 2,
                    outboundTagCounts: ["tailscale-japan": 2],
                    ruleSetTag: "ruleset-cn"
                )
            )
        )
        let encoded = try ProviderDiagnosticsCodec.encodeResponse(response)
        XCTAssertEqual(
            try ProviderDiagnosticsCodec.decodeResponse(encoded),
            response
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        XCTAssertNil(object["message"])
        let raw = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(raw.contains("hostname"))
        XCTAssertFalse(raw.contains("target"))
        XCTAssertFalse(raw.contains("raw_rule"))
    }

    func testSnapshotAttributesOnlyUniqueActiveLineCapabilities() {
        let raw = ProviderRoutingProbeSnapshot(
            probeID: "probe-1",
            matchCount: 7,
            outboundTagCounts: [
                "tailscale-japan": 2,
                "shared-direct": 3,
                "unknown-runtime-tag": 2,
            ],
            ruleSetTag: "ruleset-cn"
        )
        let restricted = raw.restrictedToActiveCapabilities(
            lineOutbounds: [
                "japan": "tailscale-japan",
                "direct-a": "shared-direct",
                "direct-b": "shared-direct",
            ],
            ruleSetTags: ["ruleset-cn"]
        )

        XCTAssertEqual(restricted.matchCount, 7)
        XCTAssertEqual(restricted.outboundTagCounts, [
            "tailscale-japan": 2,
            "shared-direct": 3,
        ])
        XCTAssertEqual(restricted.lineIDCounts, ["japan": 2])
        XCTAssertEqual(restricted.ruleSetTag, "ruleset-cn")
        XCTAssertGreaterThan(
            restricted.matchCount,
            restricted.lineIDCounts.values.reduce(0, +)
        )
    }

    func testSnapshotDropsUnknownRuleSetAndOutboundTags() {
        let restricted = ProviderRoutingProbeSnapshot(
            probeID: "probe-1",
            matchCount: 1,
            outboundTagCounts: ["unknown-runtime-tag": 1],
            ruleSetTag: "ruleset-unreferenced"
        ).restrictedToActiveCapabilities(
            lineOutbounds: ["direct": "direct"],
            ruleSetTags: ["ruleset-active"]
        )

        XCTAssertEqual(restricted.matchCount, 1)
        XCTAssertTrue(restricted.outboundTagCounts.isEmpty)
        XCTAssertTrue(restricted.lineIDCounts.isEmpty)
        XCTAssertNil(restricted.ruleSetTag)
    }

    func testFailureResponseHasStableCodeAndNoData() throws {
        let response = ProviderDiagnosticsResponse.failure(
            transactionID: "transaction-1",
            code: "probe-failed"
        )
        XCTAssertEqual(
            try ProviderDiagnosticsCodec.decodeResponse(
                ProviderDiagnosticsCodec.encodeResponse(response)
            ),
            response
        )
        XCTAssertNil(response.data)
        XCTAssertEqual(response.code, "probe-failed")
    }

    func testSessionGateRequiresCurrentCommittedGeneration() {
        let committed = ProviderDiagnosticsSessionState(
            transactionID: "current",
            hasRuntime: true,
            hasSession: true,
            hasReporter: true,
            settingsCommitted: true,
            settingsCommitInFlight: false,
            rollbackInProgress: false
        )
        XCTAssertNil(
            ProviderDiagnosticsGate.rejectionCode(
                requestTransactionID: "current",
                state: committed
            )
        )
        XCTAssertEqual(
            ProviderDiagnosticsGate.rejectionCode(
                requestTransactionID: "old",
                state: committed
            ),
            "stale-session"
        )

        let rollingBack = ProviderDiagnosticsSessionState(
            transactionID: "current",
            hasRuntime: true,
            hasSession: true,
            hasReporter: true,
            settingsCommitted: true,
            settingsCommitInFlight: false,
            rollbackInProgress: true
        )
        XCTAssertEqual(
            ProviderDiagnosticsGate.rejectionCode(
                requestTransactionID: "current",
                state: rollingBack
            ),
            "session-not-committed"
        )
    }

    func testReleaseGateRejectsBothDebugRouteProbeCommands() {
        XCTAssertEqual(
            ProviderDiagnosticsGate.commandRejectionCode(
                .beginRouteProbe,
                debugCommandsEnabled: false
            ),
            "debug-command-unavailable"
        )
        XCTAssertEqual(
            ProviderDiagnosticsGate.commandRejectionCode(
                .routingProbeSnapshot,
                debugCommandsEnabled: false
            ),
            "debug-command-unavailable"
        )
        XCTAssertNil(
            ProviderDiagnosticsGate.commandRejectionCode(
                .probeLineOutboundAddress,
                debugCommandsEnabled: false
            )
        )
    }

    func testSnapshotMustMatchExpectedCurrentProbeID() {
        XCTAssertNil(
            ProviderDiagnosticsGate.routeProbeSnapshotRejectionCode(
                expectedProbeID: "current-probe",
                actualProbeID: "current-probe"
            )
        )
        XCTAssertEqual(
            ProviderDiagnosticsGate.routeProbeSnapshotRejectionCode(
                expectedProbeID: "current-probe",
                actualProbeID: "old-probe"
            ),
            "stale-probe"
        )
        XCTAssertEqual(
            ProviderDiagnosticsGate.routeProbeSnapshotRejectionCode(
                expectedProbeID: "current-probe",
                actualProbeID: ""
            ),
            "stale-probe"
        )
    }

    func testBlockingOperationGateInvalidatesOldProbeWithoutClearingNewOne() {
        let gate = ProviderDiagnosticsOperationGate()
        let old = gate.begin(transactionID: "old")
        XCTAssertNotNil(old)
        XCTAssertNil(gate.begin(transactionID: "old"))

        gate.invalidate()
        XCTAssertFalse(gate.isCurrent(try! XCTUnwrap(old)))

        let current = gate.begin(transactionID: "current")
        XCTAssertNotNil(current)
        gate.finish(try! XCTUnwrap(old))
        XCTAssertNil(gate.begin(transactionID: "current"))

        gate.finish(try! XCTUnwrap(current))
        XCTAssertNotNil(gate.begin(transactionID: "current"))
    }

    func testOversizedRequestIsRejectedBeforeParsing() {
        let oversized = Data(
            repeating: 0x61,
            count: ProviderDiagnosticsCodec.maximumRequestBytes + 1
        )
        XCTAssertThrowsError(
            try ProviderDiagnosticsCodec.decodeRequest(oversized)
        ) {
            XCTAssertEqual(
                $0 as? ProviderDiagnosticsCodecError,
                .requestTooLarge
            )
        }
    }
}
