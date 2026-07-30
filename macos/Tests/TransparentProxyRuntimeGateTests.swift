import XCTest

final class TransparentProxyRuntimeGateTests: XCTestCase {
    func testConnectedRequiresSameCommittedTransactionAndIngress() {
        let report = committedReport(transactionID: "current")

        XCTAssertEqual(
            TransparentProxyRuntimeGate.resolve(
                systemStatus: "connected",
                report: report,
                activeTransactionID: "current",
                previousStatus: "connecting"
            ),
            "connected"
        )
        XCTAssertEqual(
            TransparentProxyRuntimeGate.resolve(
                systemStatus: "connected",
                report: report,
                activeTransactionID: "stale",
                previousStatus: "connecting"
            ),
            "connecting"
        )

        var missingIngress = report
        missingIngress.updateTask(
            id: "ingress:transparent-proxy",
            state: .ready
        )
        XCTAssertEqual(
            TransparentProxyRuntimeGate.resolve(
                systemStatus: "connected",
                report: missingIngress,
                activeTransactionID: "current",
                previousStatus: "connecting"
            ),
            "connecting"
        )

        var removedTakeover = report
        removedTakeover.systemTakeoverRemoved = true
        XCTAssertEqual(
            TransparentProxyRuntimeGate.resolve(
                systemStatus: "connected",
                report: removedTakeover,
                activeTransactionID: "current",
                previousStatus: "connecting"
            ),
            "connecting"
        )
    }

    func testSystemStatusStillBoundsCommittedReport() {
        let report = committedReport(transactionID: "current")
        XCTAssertEqual(
            TransparentProxyRuntimeGate.resolve(
                systemStatus: "disconnected",
                report: report,
                activeTransactionID: "current",
                previousStatus: "connected"
            ),
            "disconnected"
        )

        var rollingBack = report
        rollingBack.setState(.rollingBack)
        XCTAssertEqual(
            TransparentProxyRuntimeGate.resolve(
                systemStatus: "connected",
                report: rollingBack,
                activeTransactionID: "current",
                previousStatus: "connected"
            ),
            "disconnecting"
        )
    }

    private func committedReport(
        transactionID: String
    ) -> ConnectionReport {
        let plan = ConnectionPlan(
            schemaVersion: 1,
            mode: ConnectionPlanMode(id: "mode", name: "Mode"),
            tasks: [
                ConnectionPlanTask(
                    id: "ingress:transparent-proxy",
                    kind: "ingress",
                    name: "Transparent Proxy",
                    preparation: "commit"
                ),
            ]
        )
        var report = ConnectionReport(
            transactionID: transactionID,
            plan: plan
        )
        report.updateTask(
            id: "ingress:transparent-proxy",
            state: .committed
        )
        report.systemTakeoverRemoved = false
        report.setState(.committed)
        return report
    }
}
