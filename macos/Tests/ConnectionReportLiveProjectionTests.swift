import XCTest

final class ConnectionReportLiveProjectionTests: XCTestCase {
    func testColdLaunchDoesNotAdoptSafelySettledFailure() {
        let failed = report(
            id: "old-failure",
            state: .failed,
            rollbackComplete: true,
            systemTakeoverRemoved: true
        )

        XCTAssertFalse(
            ConnectionReportLiveProjection.shouldAdoptPersisted(
                failed,
                currentTransactionID: nil
            )
        )
    }

    func testColdLaunchDoesNotAdoptSafelySettledCancellation() {
        let cancelled = report(
            id: "old-cancellation",
            state: .cancelled,
            rollbackComplete: true,
            systemTakeoverRemoved: true
        )

        XCTAssertFalse(
            ConnectionReportLiveProjection.shouldAdoptPersisted(
                cancelled,
                currentTransactionID: nil
            )
        )
    }

    func testCurrentProcessKeepsItsOwnSettledFailureVisible() {
        let failed = report(
            id: "current",
            state: .failed,
            rollbackComplete: true,
            systemTakeoverRemoved: true
        )

        XCTAssertTrue(
            ConnectionReportLiveProjection.shouldAdoptPersisted(
                failed,
                currentTransactionID: "current"
            )
        )
        XCTAssertFalse(
            ConnectionReportLiveProjection.shouldAdoptPersisted(
                failed,
                currentTransactionID: "different"
            )
        )
    }

    func testUnsafeTerminalStillRequiresColdLaunchRecovery() {
        let incompleteRollback = report(
            id: "incomplete",
            state: .failed,
            rollbackComplete: false,
            systemTakeoverRemoved: false
        )
        let unconfirmedTakeoverRemoval = report(
            id: "unconfirmed",
            state: .cancelled,
            rollbackComplete: true,
            systemTakeoverRemoved: false
        )

        XCTAssertTrue(
            ConnectionReportLiveProjection.shouldAdoptPersisted(
                incompleteRollback,
                currentTransactionID: nil
            )
        )
        XCTAssertTrue(
            ConnectionReportLiveProjection.shouldAdoptPersisted(
                unconfirmedTakeoverRemoval,
                currentTransactionID: nil
            )
        )
    }

    func testCommittedAndInFlightReportsRemainRecoverable() {
        for state in [
            ConnectionTransactionState.planning,
            .preparing,
            .readyToCommit,
            .committing,
            .committed,
            .rollingBack,
            .rolledBack,
        ] {
            XCTAssertTrue(
                ConnectionReportLiveProjection.shouldAdoptPersisted(
                    report(
                        id: state.rawValue,
                        state: state,
                        rollbackComplete: false,
                        systemTakeoverRemoved: false
                    ),
                    currentTransactionID: nil
                ),
                "expected \(state.rawValue) to remain recoverable"
            )
        }
    }

    func testColdLaunchSettledFailureIsHiddenOnlyWhenDisconnected() {
        let failed = report(
            id: "old-failure",
            state: .failed,
            rollbackComplete: true,
            systemTakeoverRemoved: true
        )

        XCTAssertNil(
            ConnectionReportLiveProjection.presentedReport(
                failed,
                status: "disconnected",
                coldLaunchSettledTransactionID: "old-failure",
                explicitlyStoppedTransactionID: nil
            )
        )
        XCTAssertEqual(
            ConnectionReportLiveProjection.presentedReport(
                failed,
                status: "disconnecting",
                coldLaunchSettledTransactionID: "old-failure",
                explicitlyStoppedTransactionID: nil
            ),
            failed
        )
    }

    func testCurrentFailureRemainsVisibleUntilRelaunch() {
        let failed = report(
            id: "current-failure",
            state: .failed,
            rollbackComplete: true,
            systemTakeoverRemoved: true
        )

        XCTAssertEqual(
            ConnectionReportLiveProjection.presentedReport(
                failed,
                status: "disconnected",
                coldLaunchSettledTransactionID: nil,
                explicitlyStoppedTransactionID: nil
            ),
            failed
        )
    }

    func testExplicitDisconnectHidesOnlyProvenSafeTerminal() {
        let safelyStopped = report(
            id: "stopped",
            state: .cancelled,
            rollbackComplete: true,
            systemTakeoverRemoved: true
        )
        let unsafeStop = report(
            id: "stopped",
            state: .cancelled,
            rollbackComplete: false,
            systemTakeoverRemoved: false
        )

        XCTAssertNil(
            ConnectionReportLiveProjection.presentedReport(
                safelyStopped,
                status: "disconnected",
                coldLaunchSettledTransactionID: nil,
                explicitlyStoppedTransactionID: "stopped"
            )
        )
        XCTAssertEqual(
            ConnectionReportLiveProjection.presentedReport(
                unsafeStop,
                status: "disconnected",
                coldLaunchSettledTransactionID: nil,
                explicitlyStoppedTransactionID: "stopped"
            ),
            unsafeStop
        )
    }

    func testHiddenTransactionDoesNotHideNewReport() {
        let current = report(
            id: "new",
            state: .failed,
            rollbackComplete: true,
            systemTakeoverRemoved: true
        )

        XCTAssertEqual(
            ConnectionReportLiveProjection.presentedReport(
                current,
                status: "disconnected",
                coldLaunchSettledTransactionID: "old",
                explicitlyStoppedTransactionID: "older"
            ),
            current
        )
    }

    private func report(
        id: String,
        state: ConnectionTransactionState,
        rollbackComplete: Bool,
        systemTakeoverRemoved: Bool
    ) -> ConnectionReport {
        let plan = ConnectionPlan(
            schemaVersion: 1,
            mode: ConnectionPlanMode(id: "mode", name: "Mode"),
            tasks: []
        )
        var report = ConnectionReport(
            transactionID: id,
            plan: plan
        )
        report.state = state
        report.rollbackComplete = rollbackComplete
        report.systemTakeoverRemoved = systemTakeoverRemoved
        return report
    }
}
