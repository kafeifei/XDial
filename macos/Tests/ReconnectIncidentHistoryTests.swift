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

    func testRetryScheduleRecordsEachFailedAttemptsStructuredCode() throws {
        var history = ReconnectIncidentHistory()
        let incidentID = history.begin(
            at: Date(timeIntervalSince1970: 100),
            trigger: .automaticConnection,
            report: report(),
            reasonCode: "line-address-family-unavailable",
            reasonMessage: "线路 IPv4 / IPv6 出口均不可用"
        )
        history.recordRetryScheduled(
            incidentID: incidentID,
            attempt: 1,
            failedTransactionID: "original-transaction",
            failureCode: "line-address-family-unavailable",
            delay: 2
        )
        history.recordRetryScheduled(
            incidentID: incidentID,
            attempt: 2,
            failedTransactionID: "retry-transaction-1",
            failureCode: "underlay-egress-unavailable",
            delay: 5
        )

        let scheduled = try XCTUnwrap(history.incidents.first)
            .events.filter { $0.type == "retry-scheduled" }
        XCTAssertEqual(
            scheduled.map(\.code),
            [
                "line-address-family-unavailable",
                "underlay-egress-unavailable",
            ]
        )
        XCTAssertEqual(
            scheduled.map(\.transactionID),
            ["original-transaction", "retry-transaction-1"]
        )
        XCTAssertEqual(scheduled.map(\.attempt), [1, 2])
        XCTAssertEqual(
            scheduled.map(\.message),
            ["Retry scheduled after 2.0s", "Retry scheduled after 5.0s"]
        )
    }

    func testRecordedFailureCodeNeverCarriesFreeText() {
        XCTAssertEqual(
            ReconnectIncidentFailureCode.recordable(
                "anyconnect-tls-dpd-timeout"
            ),
            "anyconnect-tls-dpd-timeout"
        )
        XCTAssertEqual(ReconnectIncidentFailureCode.recordable(nil), "")
        XCTAssertEqual(ReconnectIncidentFailureCode.recordable(""), "")
        for raw in [
            "dial tcp4 192.0.2.1:8443: connect: network is unreachable",
            "vpn.example.com",
            "Bearer token",
            String(repeating: "a", count: 65),
        ] {
            XCTAssertEqual(
                ReconnectIncidentFailureCode.recordable(raw),
                ReconnectIncidentFailureCode.unstructured,
                raw
            )
        }
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
        let decoded = try JSONDecoder().decode(
            ReconnectIncidentHistory.self,
            from: JSONEncoder().encode(history)
        )
        XCTAssertEqual(
            decoded.incidents.first?.evidence?.anyConnect?
                .tls.deadPeerTimeoutSeconds,
            60
        )
        XCTAssertEqual(
            decoded.incidents.first?.evidence?.anyConnect?
                .tls.effectiveDPDSeconds,
            5
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

    func testParkedIncidentStaysOpenThroughGrantsDeferralsAndSingleAttempts()
        throws
    {
        var history = ReconnectIncidentHistory()
        let incidentID = history.begin(
            at: Date(timeIntervalSince1970: 100),
            trigger: .automaticConnection,
            report: report(),
            reasonCode: "line-address-family-unavailable",
            reasonMessage: "线路 IPv4 / IPv6 出口均不可用"
        )
        history.recordParked(
            incidentID: incidentID,
            attemptsUsed: 5,
            transactionID: "t5",
            failureCode: "line-address-family-unavailable"
        )
        XCTAssertEqual(
            history.incidents.first?.outcome,
            ReconnectIncidentOutcome.parked
        )
        history.recordGrantDeferred(
            incidentID: incidentID,
            reason: .connectivityRestored,
            until: Date(timeIntervalSince1970: 400)
        )
        history.recordSingleAttemptStarted(
            incidentID: incidentID,
            kind: .tail(1),
            transactionID: "tail-1"
        )
        history.recordAttemptFailed(
            incidentID: incidentID,
            attempt: 1,
            transactionID: "tail-1",
            failureCode: "server 203.0.113.5 timed out"
        )
        XCTAssertEqual(
            history.incidents.first?.outcome,
            ReconnectIncidentOutcome.parked
        )
        history.recordBudgetGranted(
            incidentID: incidentID,
            reason: .underlayChanged
        )

        let incident = try XCTUnwrap(history.incidents.first)
        XCTAssertEqual(incident.outcome, ReconnectIncidentOutcome.recovering)
        XCTAssertEqual(
            incident.events.map(\.type),
            [
                "disconnected",
                "parked",
                "grant-deferred",
                "tail-attempt-started",
                "attempt-failed",
                "budget-granted",
            ]
        )
        XCTAssertEqual(incident.events[1].attempt, 5)
        XCTAssertEqual(incident.events[2].code, "connectivity-restored")
        XCTAssertEqual(incident.events[3].attempt, 1)
        // Failure text never reaches the journal.
        XCTAssertEqual(
            incident.events[4].code,
            ReconnectIncidentFailureCode.unstructured
        )
        XCTAssertEqual(incident.events[5].code, "underlay-changed")
        XCTAssertFalse(incident.events.contains { $0.type == "exhausted" })
    }

    func testParkedEventsRoundTripAndLegacyRecordsDecode() throws {
        var history = ReconnectIncidentHistory()
        let incidentID = history.begin(
            at: Date(timeIntervalSince1970: 100),
            trigger: .underlayChange,
            report: report(),
            reasonCode: "provider-session-lost",
            reasonMessage: "Provider session lost"
        )
        history.recordParked(
            incidentID: incidentID,
            attemptsUsed: 5,
            transactionID: "t5",
            failureCode: "provider-session-lost"
        )
        let data = try JSONEncoder().encode(history)
        XCTAssertEqual(
            try JSONDecoder().decode(
                ReconnectIncidentHistory.self,
                from: data
            ),
            history
        )

        // Written before parking existed (and before 2026-08-16, when
        // "underlay-change" named the removed rebuild path). Unknown future
        // event types and outcomes are plain strings and decode too.
        let legacy = """
        {"schema_version":1,"incidents":[{"id":"legacy",
        "disconnected_at":0,"trigger":"underlay-change",
        "original_transaction_id":"t0","reason_code":"underlay-egress-unavailable",
        "reason_message":"m","outcome":"exhausted","events":[
        {"sequence":1,"timestamp":0,"type":"disconnected","attempt":0,
        "transaction_id":"t0","code":"","message":""},
        {"sequence":2,"timestamp":1,"type":"some-future-event","attempt":0,
        "transaction_id":"","code":"","message":""}]}]}
        """
        let decoded = try JSONDecoder().decode(
            ReconnectIncidentHistory.self,
            from: Data(legacy.utf8)
        )
        let incident = try XCTUnwrap(decoded.incidents.first)
        XCTAssertEqual(incident.trigger, .underlayChange)
        XCTAssertEqual(incident.scenarioID, "")
        XCTAssertEqual(incident.events.last?.type, "some-future-event")
    }

    func testLongParkedIncidentKeepsOpeningEventAndBoundsHistory() throws {
        var history = ReconnectIncidentHistory()
        let incidentID = history.begin(
            at: Date(timeIntervalSince1970: 100),
            trigger: .automaticConnection,
            report: report(),
            reasonCode: "line-address-family-unavailable",
            reasonMessage: "m"
        )
        for attempt in 0 ..< 400 {
            history.recordAttemptFailed(
                incidentID: incidentID,
                attempt: 0,
                transactionID: "wake-\(attempt)",
                failureCode: "line-address-family-unavailable"
            )
        }

        let events = try XCTUnwrap(history.incidents.first).events
        XCTAssertEqual(events.count, ReconnectIncident.eventLimit)
        XCTAssertEqual(events.first?.type, "disconnected")
        XCTAssertEqual(events.last?.transactionID, "wake-399")
        XCTAssertEqual(events.last?.sequence, 401)
    }

    private func report() -> ConnectionReport {
        ConnectionReport(
            transactionID: "original-transaction",
            plan: ConnectionPlan(
                schemaVersion: 3,
                scenario: ConnectionPlanScenario(id: "scenario", name: "Scenario"),
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
            "tls_dpd_seconds": 60,
            "tls_keepalive_seconds": 20,
            "dtls_dpd_seconds": 30,
            "dtls_keepalive_seconds": 20
          },
          "tls": {
            "effective_dpd_seconds": 5,
            "dead_peer_timeout_seconds": 60,
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
