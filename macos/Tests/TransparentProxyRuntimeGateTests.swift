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

    func testAutomaticRecoveryRejectsLostCommittedSession() {
        let oldReport = committedReport(transactionID: "old")
        let proofTransactionID =
            TransparentProxyRuntimeGate
                .connectionProofTransactionID(
                    currentTransactionID: "old",
                    automaticReconnectInProgress: true,
                    reconnectTransactionID: nil,
                    networkExtensionSessionTransactionID: nil
                )

        XCTAssertNil(proofTransactionID)
        XCTAssertEqual(
            TransparentProxyRuntimeGate.resolve(
                systemStatus: "connected",
                report: oldReport,
                activeTransactionID: proofTransactionID,
                previousStatus: "reconnecting"
            ),
            "reconnecting"
        )
    }

    func testRecoveryRequiresRetryReportAndCurrentNESession() {
        let retryReport = committedReport(transactionID: "retry")
        let staleSessionProof =
            TransparentProxyRuntimeGate
                .connectionProofTransactionID(
                    currentTransactionID: "retry",
                    automaticReconnectInProgress: true,
                    reconnectTransactionID: "retry",
                    networkExtensionSessionTransactionID: "old"
                )

        XCTAssertNil(staleSessionProof)
        XCTAssertEqual(
            TransparentProxyRuntimeGate.resolve(
                systemStatus: "connected",
                report: retryReport,
                activeTransactionID: staleSessionProof,
                previousStatus: "reconnecting"
            ),
            "reconnecting"
        )

        let currentSessionProof =
            TransparentProxyRuntimeGate
                .connectionProofTransactionID(
                    currentTransactionID: "retry",
                    automaticReconnectInProgress: true,
                    reconnectTransactionID: "retry",
                    networkExtensionSessionTransactionID: "retry"
                )
        XCTAssertEqual(currentSessionProof, "retry")
        XCTAssertEqual(
            TransparentProxyRuntimeGate.resolve(
                systemStatus: "connected",
                report: committedReport(transactionID: "old"),
                activeTransactionID: currentSessionProof,
                previousStatus: "reconnecting"
            ),
            "reconnecting"
        )
        XCTAssertEqual(
            TransparentProxyRuntimeGate.resolve(
                systemStatus: "connected",
                report: retryReport,
                activeTransactionID: currentSessionProof,
                previousStatus: "reconnecting"
            ),
            "connected"
        )
    }

    private func committedReport(
        transactionID: String
    ) -> ConnectionReport {
        let plan = ConnectionPlan(
            schemaVersion: 3,
            scenario: ConnectionPlanScenario(id: "scenario", name: "Scenario"),
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
