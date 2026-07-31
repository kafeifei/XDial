import XCTest

final class AnyConnectFailureEvidenceTests: XCTestCase {
    func testDecodesAllowListedDiagnosticsShape() throws {
        let evidence = try decodeEvidence()

        XCTAssertEqual(evidence.schemaVersion, 1)
        XCTAssertEqual(evidence.forceDPDSeconds, 5)
        XCTAssertNil(evidence.sessionAgeMS)
        XCTAssertEqual(evidence.negotiated.tlsDPDSeconds, 30)
        XCTAssertNil(evidence.negotiated.cstpRekeySeconds)
        XCTAssertNil(evidence.negotiated.cstpRekeyMethod)
        XCTAssertNil(
            evidence.negotiated.cstpLeaseDurationSeconds
        )
        XCTAssertNil(
            evidence.negotiated.cstpSessionTimeoutSeconds
        )
        XCTAssertNil(
            evidence.negotiated
                .cstpSessionTimeoutRemainingSeconds
        )
        XCTAssertNil(
            evidence.negotiated.cstpIdleTimeoutSeconds
        )
        XCTAssertEqual(evidence.tls.dpdRequestsQueued, 24)
        XCTAssertEqual(evidence.tls.dpdRequestsWritten, 24)
        XCTAssertEqual(evidence.tls.dpdResponsesReceived, 23)
        XCTAssertNil(evidence.tls.dataFramesReceived)
        XCTAssertNil(evidence.tls.dataFramesWritten)
        XCTAssertEqual(evidence.tls.lastDPDResponseAgeMS, 132_000)
        XCTAssertNil(evidence.tls.lastDataReceivedAgeMS)
        XCTAssertNil(evidence.tls.lastDataWrittenAgeMS)
        XCTAssertTrue(evidence.dtls.everConnected)
        XCTAssertFalse(evidence.dtls.currentlyConnected)
        XCTAssertNil(evidence.dtls.dataFramesReceived)
        XCTAssertNil(evidence.dtls.dataFramesWritten)
        XCTAssertNil(evidence.dtls.lastDataReceivedAgeMS)
        XCTAssertNil(evidence.dtls.lastDataWrittenAgeMS)
        XCTAssertEqual(
            evidence.close?.occurredAtUnixMilli,
            1_722_395_228_429
        )
        XCTAssertEqual(
            evidence.reportCode,
            "anyconnect-tls-read-timeout"
        )
        XCTAssertEqual(
            evidence.publicFailureMessage,
            "AnyConnect TLS 控制通道读取超时"
        )
        XCTAssertNil(evidence.close?.peerPayloadLength)
        XCTAssertNil(evidence.close?.peerReasonCode)
        XCTAssertNil(evidence.close?.peerHasReasonText)
        XCTAssertNil(evidence.close?.peerReasonCategory)
    }

    func testDecodesSchemaV2SessionAndPeerEvidence() throws {
        let evidence = try decodeEvidenceV2()

        XCTAssertEqual(evidence.schemaVersion, 2)
        XCTAssertEqual(evidence.sessionAgeMS, 7_234_000)
        XCTAssertEqual(
            evidence.negotiated.cstpRekeySeconds,
            3_600
        )
        XCTAssertEqual(
            evidence.negotiated.cstpRekeyMethod,
            "new-tunnel"
        )
        XCTAssertEqual(
            evidence.negotiated.cstpLeaseDurationSeconds,
            28_800
        )
        XCTAssertEqual(
            evidence.negotiated.cstpSessionTimeoutSeconds,
            28_800
        )
        XCTAssertEqual(
            evidence.negotiated
                .cstpSessionTimeoutRemainingSeconds,
            21_566
        )
        XCTAssertEqual(
            evidence.negotiated.cstpIdleTimeoutSeconds,
            1_800
        )
        XCTAssertEqual(evidence.tls.dataFramesReceived, 91)
        XCTAssertEqual(evidence.tls.dataFramesWritten, 72)
        XCTAssertEqual(
            evidence.tls.lastDataReceivedAgeMS,
            4_200
        )
        XCTAssertEqual(
            evidence.tls.lastDataWrittenAgeMS,
            3_100
        )
        XCTAssertEqual(evidence.dtls.dataFramesReceived, 13)
        XCTAssertEqual(evidence.dtls.dataFramesWritten, 8)
        XCTAssertEqual(
            evidence.dtls.lastDataReceivedAgeMS,
            2_500
        )
        XCTAssertEqual(
            evidence.dtls.lastDataWrittenAgeMS,
            1_700
        )
        XCTAssertEqual(evidence.close?.peerPayloadLength, 18)
        XCTAssertEqual(evidence.close?.peerReasonCode, "12")
        XCTAssertEqual(evidence.close?.peerHasReasonText, true)
        XCTAssertEqual(
            evidence.close?.peerReasonCategory,
            "session-timeout"
        )
        XCTAssertEqual(
            evidence.publicFailureMessage,
            "AnyConnect 服务端因会话超时结束了当前会话"
        )
    }

    func testPeerDisconnectMessageUsesOnlyKnownCategory() throws {
        let expectedMessages = [
            "idle-timeout":
                "AnyConnect 服务端因空闲超时结束了当前会话",
            "session-timeout":
                "AnyConnect 服务端因会话超时结束了当前会话",
            "duplicate-session":
                "AnyConnect 服务端因重复会话结束了当前会话",
            "authentication":
                "AnyConnect 服务端因认证失败结束了当前会话",
            "policy":
                "AnyConnect 服务端因策略限制结束了当前会话",
            "rekey":
                "AnyConnect 服务端在重新协商密钥时结束了当前会话",
            "server-error":
                "AnyConnect 服务端因内部错误结束了当前会话",
        ]
        for (category, expectedMessage) in expectedMessages {
            XCTAssertEqual(
                try decodeEvidenceV2(
                    peerReasonCategory: category
                ).publicFailureMessage,
                expectedMessage
            )
        }
        for category in ["other", "future-category"] {
            XCTAssertEqual(
                try decodeEvidenceV2(
                    peerReasonCategory: category
                ).publicFailureMessage,
                "AnyConnect 服务端结束了当前会话"
            )
        }
    }

    func testReportPersistsEvidenceOnExactVPNTask() throws {
        let evidence = ConnectionFailureEvidence(
            anyConnect: try decodeEvidenceV2()
        )
        var report = ConnectionReport(
            transactionID: "transaction",
            plan: ConnectionPlan(
                schemaVersion: 1,
                mode: ConnectionPlanMode(
                    id: "mode",
                    name: "Mode"
                ),
                tasks: [
                    ConnectionPlanTask(
                        id: "line:corp",
                        kind: "line",
                        name: "Corp",
                        preparation: "connect-and-probe",
                        resourceID: "corp",
                        resourceType: "vpn"
                    ),
                    ConnectionPlanTask(
                        id: "data-plane:sing-box",
                        kind: "data_plane",
                        name: "sing-box",
                        preparation: "start-and-probe"
                    ),
                ]
            )
        )

        report.fail(
            code: "anyconnect-tls-read-timeout",
            message: "AnyConnect TLS 控制通道读取超时",
            taskID: "line:corp",
            evidence: evidence
        )

        XCTAssertEqual(report.error?.taskID, "line:corp")
        XCTAssertEqual(
            report.tasks.first { $0.id == "line:corp" }?
                .error?.evidence,
            evidence
        )
        XCTAssertNil(
            report.tasks.first {
                $0.id == "data-plane:sing-box"
            }?.error
        )

        let decoded = try ConnectionReportCodec.decode(
            ConnectionReportCodec.encode(report)
        )
        XCTAssertEqual(decoded.error?.evidence, evidence)
        XCTAssertEqual(
            decoded.tasks.first { $0.id == "line:corp" }?
                .error?.evidence,
            evidence
        )
    }

    func testRuntimeFailureUsesStructuredTaskIDOrGenericDataPlane() {
        let structured = ConnectionRuntimeFailure(
            code: "line-failed",
            message: "line failed",
            taskID: "line:structured",
            evidence: nil
        )
        let unattributed = ConnectionRuntimeFailure(
            code: "data-plane-failed",
            message: "data plane failed",
            taskID: "",
            evidence: nil
        )

        XCTAssertEqual(
            structured.attributedTaskID,
            "line:structured"
        )
        XCTAssertEqual(
            unattributed.attributedTaskID,
            ConnectionRuntimeFailure.dataPlaneTaskID
        )
    }

    func testOldReportWithoutEvidenceStillDecodes() throws {
        var report = ConnectionReport(
            transactionID: "legacy",
            plan: ConnectionPlan(
                schemaVersion: 1,
                mode: ConnectionPlanMode(
                    id: "mode",
                    name: "Mode"
                ),
                tasks: []
            )
        )
        report.fail(
            code: "data-plane-failed",
            message: "legacy",
            taskID: ""
        )

        let encoded = try ConnectionReportCodec.encode(report)
        let decoded = try ConnectionReportCodec.decode(encoded)

        XCTAssertEqual(decoded.error?.code, "data-plane-failed")
        XCTAssertNil(decoded.error?.evidence)
    }

    func testRejectsUnboundedCloseCodeForReportClassification() throws {
        let raw = """
        {
          "code": "TLS READ / vpn.example.com",
          "channel": "tls",
          "operation": "read",
          "error_class": "timeout",
          "occurred_at_unix_milli": 1
        }
        """
        let close = try JSONDecoder().decode(
            AnyConnectCloseEvidence.self,
            from: Data(raw.utf8)
        )

        XCTAssertNil(close.reportCode)
    }

    func testCallbackGateArmsOnStructuredConnectedStatus() {
        var gate = EngineCallbackRuntimeGate()

        XCTAssertFalse(gate.consumeFatalError())
        gate.beginStart()
        gate.consumeStatus("{\"status\":\"connecting\"}")
        XCTAssertEqual(gate.phase, .starting)
        gate.consumeStatus("{\"status\":\"connected\"}")
        XCTAssertEqual(gate.phase, .running)
        XCTAssertTrue(gate.consumeFatalError())
        XCTAssertEqual(gate.phase, .stopped)
        XCTAssertFalse(gate.consumeFatalError())
    }

    func testCallbackGateSuppressesExplicitStop() {
        var gate = EngineCallbackRuntimeGate()
        gate.consumeStatus("{\"status\":\"connected\"}")
        gate.stop()
        gate.consumeStatus("{\"status\":\"connected\"}")

        XCTAssertFalse(gate.consumeFatalError())
        XCTAssertEqual(gate.phase, .stopped)
    }

    func testCallbackGateKeepsDataPlaneRunningDuringLineReconnect() {
        var gate = EngineCallbackRuntimeGate()
        gate.consumeStatus("{\"status\":\"connected\"}")
        gate.consumeStatus(
            """
            {"status":"line_reconnecting","line_type":"vpn","attempt":1,"max_attempts":3}
            """
        )

        XCTAssertEqual(gate.phase, .running)
        XCTAssertTrue(gate.consumeFatalError())
    }

    func testDecodesAnyConnectLineReconnectStatus() throws {
        let raw = """
        {
          "status": "line_reconnecting",
          "line_type": "vpn",
          "attempt": 2,
          "max_attempts": 3
        }
        """

        let status = try JSONDecoder().decode(
            AnyConnectLineRuntimeStatus.self,
            from: Data(raw.utf8)
        )

        XCTAssertEqual(status.state, .reconnecting)
        XCTAssertTrue(status.isAnyConnect)
        XCTAssertEqual(status.attempt, 2)
        XCTAssertEqual(status.maxAttempts, 3)
    }

    private func decodeEvidence() throws
        -> AnyConnectFailureEvidence
    {
        let raw = """
        {
          "schema_version": 1,
          "force_dpd_seconds": 5,
          "negotiated": {
            "tls_dpd_seconds": 30,
            "tls_keepalive_seconds": 20,
            "dtls_dpd_seconds": 30,
            "dtls_keepalive_seconds": 20
          },
          "tls": {
            "effective_dpd_seconds": 5,
            "dpd_requests_queued": 24,
            "dpd_requests_dropped": 0,
            "dpd_requests_written": 24,
            "dpd_responses_received": 23,
            "peer_dpd_requests_received": 2,
            "keepalives_received": 1,
            "last_frame_age_ms": 132000,
            "last_dpd_written_age_ms": 2000,
            "last_dpd_response_age_ms": 132000
          },
          "dtls": {
            "effective_dpd_seconds": 5,
            "dpd_requests_queued": 4,
            "dpd_requests_dropped": 1,
            "dpd_requests_written": 3,
            "dpd_responses_received": 3,
            "peer_dpd_requests_received": 0,
            "keepalives_received": 0,
            "last_frame_age_ms": null,
            "last_dpd_written_age_ms": null,
            "last_dpd_response_age_ms": null,
            "ever_connected": true,
            "currently_connected": false
          },
          "close": {
            "code": "tls-read-timeout",
            "channel": "tls",
            "operation": "read",
            "error_class": "timeout",
            "occurred_at_unix_milli": 1722395228429
          }
        }
        """
        return try JSONDecoder().decode(
            AnyConnectFailureEvidence.self,
            from: Data(raw.utf8)
        )
    }

    private func decodeEvidenceV2(
        peerReasonCategory: String = "session-timeout"
    ) throws
        -> AnyConnectFailureEvidence
    {
        let raw = """
        {
          "schema_version": 2,
          "force_dpd_seconds": 5,
          "session_age_ms": 7234000,
          "negotiated": {
            "tls_dpd_seconds": 30,
            "tls_keepalive_seconds": 20,
            "dtls_dpd_seconds": 30,
            "dtls_keepalive_seconds": 20,
            "cstp_rekey_seconds": 3600,
            "cstp_rekey_method": "new-tunnel",
            "cstp_lease_duration_seconds": 28800,
            "cstp_session_timeout_seconds": 28800,
            "cstp_session_timeout_remaining_seconds": 21566,
            "cstp_idle_timeout_seconds": 1800
          },
          "tls": {
            "effective_dpd_seconds": 5,
            "dpd_requests_queued": 24,
            "dpd_requests_dropped": 0,
            "dpd_requests_written": 24,
            "dpd_responses_received": 23,
            "peer_dpd_requests_received": 2,
            "keepalives_received": 1,
            "data_frames_received": 91,
            "data_frames_written": 72,
            "last_frame_age_ms": 3100,
            "last_dpd_written_age_ms": 2000,
            "last_dpd_response_age_ms": 4000,
            "last_data_received_age_ms": 4200,
            "last_data_written_age_ms": 3100
          },
          "dtls": {
            "effective_dpd_seconds": 5,
            "dpd_requests_queued": 0,
            "dpd_requests_dropped": 0,
            "dpd_requests_written": 0,
            "dpd_responses_received": 0,
            "peer_dpd_requests_received": 0,
            "keepalives_received": 0,
            "data_frames_received": 13,
            "data_frames_written": 8,
            "last_data_received_age_ms": 2500,
            "last_data_written_age_ms": 1700,
            "ever_connected": false,
            "currently_connected": false
          },
          "close": {
            "code": "peer-disconnect",
            "channel": "tls",
            "operation": "peer",
            "error_class": "peer",
            "occurred_at_unix_milli": 1722395228429,
            "peer_payload_length": 18,
            "peer_reason_code": "12",
            "peer_has_reason_text": true,
            "peer_reason_category": "\(peerReasonCategory)"
          }
        }
        """
        return try JSONDecoder().decode(
            AnyConnectFailureEvidence.self,
            from: Data(raw.utf8)
        )
    }
}
