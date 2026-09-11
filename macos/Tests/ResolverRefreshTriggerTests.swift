import XCTest

final class ResolverRefreshTriggerTests: XCTestCase {
    func testCommitNudgesOncePerTransaction() {
        var trigger = ResolverRefreshTrigger()

        XCTAssertNil(
            trigger.noteConnectionReport(
                transactionID: "tx-1",
                state: .committing
            )
        )
        XCTAssertEqual(
            trigger.noteConnectionReport(
                transactionID: "tx-1",
                state: .committed
            ),
            .transactionCommitted
        )
        XCTAssertNil(
            trigger.noteConnectionReport(
                transactionID: "tx-1",
                state: .committed
            )
        )
    }

    /// A Scenario or epoch switch commits a new transaction inside the same
    /// session; its flows are new, so it needs its own nudge.
    func testEverySwitchNudges() {
        var trigger = ResolverRefreshTrigger()

        XCTAssertEqual(
            trigger.noteConnectionReport(
                transactionID: "tx-1",
                state: .committed
            ),
            .transactionCommitted
        )
        XCTAssertEqual(
            trigger.noteConnectionReport(
                transactionID: "tx-2",
                state: .committed
            ),
            .transactionCommitted
        )
    }

    func testFailedTransactionDoesNotNudgeOnCommitPath() {
        var trigger = ResolverRefreshTrigger()

        XCTAssertNil(
            trigger.noteConnectionReport(
                transactionID: "tx-1",
                state: .rolledBack
            )
        )
        XCTAssertNil(
            trigger.noteConnectionReport(
                transactionID: "tx-1",
                state: .failed
            )
        )
    }

    func testStopNudgesOnceWhenRuntimeSettlesDisconnected() {
        var trigger = ResolverRefreshTrigger()

        XCTAssertNil(trigger.noteRuntimeStatus("connecting"))
        XCTAssertNil(trigger.noteRuntimeStatus("connected"))
        XCTAssertNil(trigger.noteRuntimeStatus("disconnecting"))
        XCTAssertEqual(
            trigger.noteRuntimeStatus("disconnected"),
            .proxyStopped
        )
        XCTAssertNil(trigger.noteRuntimeStatus("disconnected"))
    }

    /// A cold launch starts out disconnected; that is not a transition and must
    /// not be mistaken for a stop.
    func testColdDisconnectedStatusDoesNotNudge() {
        var trigger = ResolverRefreshTrigger()

        XCTAssertNil(trigger.noteRuntimeStatus("disconnected"))
    }

    func testLaunchNudgesExactlyOnce() {
        var trigger = ResolverRefreshTrigger()

        XCTAssertEqual(trigger.noteHostLaunch(), .hostLaunch)
        XCTAssertNil(trigger.noteHostLaunch())
    }

    func testReasonsAreStableWireStrings() {
        XCTAssertEqual(
            ResolverRefreshReason.transactionCommitted.rawValue,
            "transaction-committed"
        )
        XCTAssertEqual(
            ResolverRefreshReason.proxyStopped.rawValue,
            "proxy-stopped"
        )
        XCTAssertEqual(
            ResolverRefreshReason.hostLaunch.rawValue,
            "host-launch"
        )
    }
}
