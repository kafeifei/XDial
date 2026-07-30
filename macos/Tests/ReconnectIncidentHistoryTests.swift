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
}
