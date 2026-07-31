import XCTest

final class ReconnectIncidentHistoryTests: XCTestCase {
    func testIncidentKeepsDisconnectReasonAttemptsAndRecoveryOrder() {
        var history = ReconnectIncidentHistory()
        let disconnectedAt = Date(timeIntervalSince1970: 100)
        let incidentID = history.begin(
            at: disconnectedAt,
            trigger: .unexpectedDisconnect,
            report: report(),
            reasonCode: "provider-session-lost",
            reasonMessage: "Provider session lost"
        )
        history.append(
            incidentID: incidentID,
            type: "retry-scheduled",
            attempt: 1
        )
        history.append(
            incidentID: incidentID,
            type: "retry-started",
            attempt: 1,
            transactionID: "retry-transaction"
        )
        history.finish(
            incidentID: incidentID,
            outcome: "recovered",
            transactionID: "retry-transaction"
        )

        let incident = try! XCTUnwrap(history.incidents.first)
        XCTAssertEqual(incident.disconnectedAt, disconnectedAt)
        XCTAssertEqual(incident.reasonCode, "provider-session-lost")
        XCTAssertEqual(incident.outcome, "recovered")
        XCTAssertEqual(
            incident.events.map(\.type),
            [
                "disconnected",
                "retry-scheduled",
                "retry-started",
                "recovered",
            ]
        )
        XCTAssertEqual(
            incident.events.map(\.sequence),
            [1, 2, 3, 4]
        )
    }

    func testHistoryIsBounded() {
        var history = ReconnectIncidentHistory()
        for index in 0 ..< 4 {
            _ = history.begin(
                at: Date(timeIntervalSince1970: TimeInterval(index)),
                trigger: .unexpectedDisconnect,
                report: nil,
                reasonCode: "lost",
                reasonMessage: "lost",
                limit: 3
            )
        }

        XCTAssertEqual(history.incidents.count, 3)
        XCTAssertEqual(
            history.incidents.first?.disconnectedAt,
            Date(timeIntervalSince1970: 1)
        )
    }

    func testSystemDisconnectReasonDoesNotOverwriteRootCause() throws {
        var report = report()
        let evidence = try anyConnectEvidence()
        report.fail(
            code: "anyconnect-tls-read-timeout",
            message: "AnyConnect TLS 控制通道读取超时",
            taskID: "line:corp",
            evidence: ConnectionFailureEvidence(
                anyConnect: evidence
            )
        )
        var history = ReconnectIncidentHistory()
        let incidentID = history.begin(
            at: Date(timeIntervalSince1970: 100),
            trigger: .unexpectedDisconnect,
            report: report,
            reasonCode: report.error!.code,
            reasonMessage: report.error!.message
        )

        history.recordSystemDisconnectReason(
            incidentID: incidentID,
            code: "com.kafeifei.xdial.transparent-proxy:2",
            message: "The VPN session disconnected"
        )

        let incident = try XCTUnwrap(history.incidents.first)
        XCTAssertEqual(
            incident.reasonCode,
            "anyconnect-tls-read-timeout"
        )
        XCTAssertEqual(
            incident.reasonMessage,
            "AnyConnect TLS 控制通道读取超时"
        )
        XCTAssertEqual(
            incident.evidence?.anyConnect,
            evidence
        )
        XCTAssertEqual(
            incident.systemDisconnectCode,
            "com.kafeifei.xdial.transparent-proxy:2"
        )
        XCTAssertEqual(
            incident.systemDisconnectMessage,
            "The VPN session disconnected"
        )
        XCTAssertEqual(
            incident.events.last?.type,
            "system-disconnect-reason"
        )
    }

    func testIncidentWithoutEvidenceRoundTripsForOldReports() throws {
        var history = ReconnectIncidentHistory()
        _ = history.begin(
            at: Date(timeIntervalSince1970: 100),
            trigger: .unexpectedDisconnect,
            report: report(),
            reasonCode: "provider-session-lost",
            reasonMessage: "Provider session lost"
        )

        let data = try JSONEncoder().encode(history)
        let decoded = try JSONDecoder().decode(
            ReconnectIncidentHistory.self,
            from: data
        )

        XCTAssertNil(decoded.incidents.first?.evidence)
        XCTAssertNil(
            decoded.incidents.first?.systemDisconnectCode
        )
    }

    private func report() -> ConnectionReport {
        ConnectionReport(
            transactionID: "original-transaction",
            plan: ConnectionPlan(
                schemaVersion: 1,
                mode: ConnectionPlanMode(id: "mode", name: "Mode"),
                tasks: []
            )
        )
    }

    private func anyConnectEvidence() throws
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
            "dpd_requests_queued": 1,
            "dpd_requests_dropped": 0,
            "dpd_requests_written": 1,
            "dpd_responses_received": 0,
            "peer_dpd_requests_received": 0,
            "keepalives_received": 0
          },
          "dtls": {
            "effective_dpd_seconds": 5,
            "dpd_requests_queued": 0,
            "dpd_requests_dropped": 0,
            "dpd_requests_written": 0,
            "dpd_responses_received": 0,
            "peer_dpd_requests_received": 0,
            "keepalives_received": 0,
            "ever_connected": false,
            "currently_connected": false
          },
          "close": {
            "code": "tls-read-timeout",
            "channel": "tls",
            "operation": "read",
            "error_class": "timeout",
            "occurred_at_unix_milli": 1000
          }
        }
        """
        return try JSONDecoder().decode(
            AnyConnectFailureEvidence.self,
            from: Data(raw.utf8)
        )
    }
}
