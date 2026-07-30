import XCTest

final class AutomaticReconnectRetryPolicyTests: XCTestCase {
    func testRetriesOnlyCompletedUnderlayEgressFailure() {
        let policy = AutomaticReconnectRetryPolicy(
            delays: [2, 5, 10]
        )
        let report = failedReport(
            code: ConnectionFailureCode.underlayEgressUnavailable
        )

        XCTAssertEqual(
            policy.delay(after: report, retryIndex: 0),
            2
        )
        XCTAssertEqual(
            policy.delay(after: report, retryIndex: 1),
            5
        )
        XCTAssertEqual(
            policy.delay(after: report, retryIndex: 2),
            10
        )
        XCTAssertNil(policy.delay(after: report, retryIndex: 3))
    }

    func testDoesNotRetryLineOrHandshakeFailures() {
        let policy = AutomaticReconnectRetryPolicy()

        XCTAssertNil(policy.delay(
            after: failedReport(
                code: "tailscale-peer-handshake-failed"
            ),
            retryIndex: 0
        ))
        XCTAssertNil(policy.delay(
            after: failedReport(
                code: "tailscale-exit-node-unavailable"
            ),
            retryIndex: 0
        ))
    }

    func testDoesNotRetryBeforeRollbackCompletes() {
        let policy = AutomaticReconnectRetryPolicy()
        var report = failedReport(
            code: ConnectionFailureCode.underlayEgressUnavailable
        )
        report.rollbackComplete = false

        XCTAssertNil(policy.delay(
            after: report,
            retryIndex: 0
        ))
    }

    private func failedReport(code: String) -> ConnectionReport {
        let plan = ConnectionPlan(
            schemaVersion: 1,
            mode: ConnectionPlanMode(id: "mode", name: "Mode"),
            tasks: [
                ConnectionPlanTask(
                    id: "underlay:system",
                    kind: "underlay",
                    name: "Underlay",
                    preparation: "capture"
                ),
            ]
        )
        var report = ConnectionReport(
            transactionID: "transaction",
            plan: plan
        )
        report.updateTask(
            id: "underlay:system",
            state: .running
        )
        report.fail(
            code: code,
            message: code,
            taskID: "underlay:system"
        )
        report.setState(.rollingBack)
        report.rollbackSessionTasks(
            systemTakeoverRemoved: true,
            cleanupComplete: true,
            finalState: .failed
        )
        return report
    }
}
