import XCTest

/// A full-recovery step may only be decided by the transaction it waits for.
/// Status callbacks (screen / session wake, `syncStatus`) re-read the journal
/// at any time; while an attempt is scheduled, preparing or capturing the
/// Underlay that journal still holds the previous failed transaction.
final class AutomaticRecoveryOutcomeGateTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 50_000)

    func testStrayDisconnectedDuringScheduledWakeAttemptDecidesNothing() {
        var gate = AutomaticRecoveryOutcomeGate()
        let previousFailure = settledReport("budget-5")
        XCTAssertEqual(
            gate.decide(
                recoveryInProgress: false,
                attemptPending: false,
                report: previousFailure,
                currentTransactionID: "budget-5"
            ),
            .notRecovering
        )

        // screens_did_wake right after didWake: the wake attempt is
        // scheduled, then captures the Underlay, then waits in AppState's
        // quiet window. None of that has a transaction yet.
        gate.attemptScheduled()
        for pending in [true, false] {
            XCTAssertEqual(
                gate.decide(
                    recoveryInProgress: true,
                    attemptPending: pending,
                    report: previousFailure,
                    currentTransactionID: "budget-5"
                ),
                .awaitOutcome
            )
        }

        gate.await("wake-1")
        XCTAssertEqual(
            gate.decide(
                recoveryInProgress: true,
                attemptPending: false,
                report: runningReport("wake-1"),
                currentTransactionID: "wake-1"
            ),
            .awaitOutcome
        )
        XCTAssertEqual(
            gate.decide(
                recoveryInProgress: true,
                attemptPending: false,
                report: settledReport("wake-1"),
                currentTransactionID: "wake-1"
            ),
            .attemptOutcome
        )
    }

    func testOverdueTailTimerAndSameWakeSyncStatusKeepTheTailAttempt() {
        var ledger = parkedLedger(on: "en0")
        var gate = AutomaticRecoveryOutcomeGate()
        let tailDue = start.addingTimeInterval(
            ledger.nextTailDelay ?? 0
        )
        // The machine slept through the due date; noteSystemWake arms the
        // overdue timer, which fires at once and schedules the tail attempt.
        let wake = tailDue.addingTimeInterval(3600)
        gate.attemptScheduled()

        // The same wake's syncStatus lands on top with the old report.
        XCTAssertEqual(
            gate.decide(
                recoveryInProgress: true,
                attemptPending: true,
                report: settledReport("budget-5"),
                currentTransactionID: "budget-5"
            ),
            .awaitOutcome
        )
        // Nothing re-parked: the tail attempt keeps its number and epoch.
        XCTAssertEqual(ledger.parking?.tailAttemptsUsed, 0)
        XCTAssertEqual(
            ledger.resume(
                .slowTail,
                observed: observed("en0"),
                systemAsleep: false,
                at: wake
            ),
            .singleAttempt(.tail(1))
        )
    }

    func testStaleJournalReportWithDifferentTransactionNeverDecides() {
        var gate = AutomaticRecoveryOutcomeGate()
        gate.await("attempt-2")

        XCTAssertEqual(
            gate.decide(
                recoveryInProgress: true,
                attemptPending: false,
                report: settledReport("attempt-1"),
                currentTransactionID: "attempt-2"
            ),
            .awaitOutcome
        )
        // The awaited transaction is no longer the host's current one.
        XCTAssertEqual(
            gate.decide(
                recoveryInProgress: true,
                attemptPending: false,
                report: settledReport("attempt-2"),
                currentTransactionID: "attempt-3"
            ),
            .awaitOutcome
        )
        XCTAssertEqual(
            gate.decide(
                recoveryInProgress: true,
                attemptPending: false,
                report: nil,
                currentTransactionID: "attempt-2"
            ),
            .awaitOutcome
        )
        gate.reset()
        XCTAssertEqual(
            gate.decide(
                recoveryInProgress: true,
                attemptPending: false,
                report: settledReport("attempt-2"),
                currentTransactionID: "attempt-2"
            ),
            .awaitOutcome
        )
    }

    func testAwaitedReportDecidesOnlyAfterRollbackSettles() {
        var gate = AutomaticRecoveryOutcomeGate()
        gate.await("launch")
        var rollingBack = settledReport("launch")
        rollingBack.rollbackComplete = false

        XCTAssertEqual(
            gate.decide(
                recoveryInProgress: true,
                attemptPending: false,
                report: rollingBack,
                currentTransactionID: "launch"
            ),
            .awaitOutcome
        )
        // The failure that opened the episode decides the first step.
        XCTAssertEqual(
            gate.decide(
                recoveryInProgress: true,
                attemptPending: false,
                report: settledReport("launch"),
                currentTransactionID: "launch"
            ),
            .attemptOutcome
        )
    }

    func testChangedUnderlayCapturedByParkedAttemptGetsFullBudget() {
        var ledger = parkedLedger(on: "en7")
        var gate = AutomaticRecoveryOutcomeGate()
        gate.attemptScheduled()
        // The wake attempt already captured en0 when a stray status arrives;
        // it must not park the recovery in en0.
        XCTAssertEqual(
            gate.decide(
                recoveryInProgress: true,
                attemptPending: true,
                report: settledReport("budget-5"),
                currentTransactionID: "budget-5"
            ),
            .awaitOutcome
        )
        XCTAssertEqual(ledger.parking?.epoch.underlayFingerprint, "en7")

        XCTAssertEqual(
            ledger.resume(
                .wake,
                observed: observed("en0"),
                systemAsleep: false,
                at: start.addingTimeInterval(900)
            ),
            .grant(.underlayChanged)
        )
        XCTAssertEqual(
            (1 ... 5).filter { ledger.recordStarted($0) }.count,
            5
        )
    }

    func testRateLimitedChangeStillGetsItsBudgetAfterTheAttemptReParks() {
        var ledger = parkedLedger(on: "en7")
        var now = start
        // Use up the hourly cap on other networks.
        for fingerprint in ["a1", "a2", "a3", "a4", "a5", "a6"] {
            now = now.addingTimeInterval(60)
            XCTAssertEqual(
                ledger.resume(
                    .networkEpoch(connectivityRestored: false),
                    observed: observed(fingerprint),
                    systemAsleep: false,
                    at: now
                ),
                .grant(.underlayChanged)
            )
            for attempt in 1 ... 5 {
                XCTAssertTrue(ledger.recordStarted(attempt))
            }
            ledger.park(
                epoch: epoch("en7"),
                failure: failure(),
                at: now
            )
        }

        // A wake attempt captures en0: the grant is deferred, the wake
        // attempt itself still runs inside the parked epoch.
        now = now.addingTimeInterval(60)
        XCTAssertEqual(
            ledger.resume(
                .wake,
                observed: observed("en0"),
                systemAsleep: false,
                at: now
            ),
            .singleAttempt(.wake)
        )
        let deferred = try? XCTUnwrap(ledger.parking?.deferredGrant)
        XCTAssertEqual(deferred?.epoch.underlayFingerprint, "en0")

        // It fails; the post-rollback capture re-anchors parking on en0.
        ledger.park(epoch: epoch("en7"), failure: failure(), at: now)
        ledger.absorbParkedUnderlay(fingerprint: "en0")
        XCTAssertEqual(ledger.parking?.deferredGrant, deferred)

        let until = try? XCTUnwrap(deferred?.notBefore)
        XCTAssertEqual(
            ledger.reevaluateDeferredGrant(
                systemAsleep: false,
                at: until ?? now
            ),
            .grant(.underlayChanged)
        )
        XCTAssertEqual(ledger.nextAttempt, 1)
        XCTAssertEqual(ledger.budgetEpoch?.underlayFingerprint, "en0")
    }

    func testAttemptRejectedBeforeItsTransactionKeepsTheParkedEpoch() {
        var ledger = parkedLedger(on: "en7")
        // The wake attempt is rejected (asleep again) after capturing en0.
        XCTAssertEqual(
            ledger.resume(
                .wake,
                observed: observed("en0"),
                systemAsleep: true,
                at: start.addingTimeInterval(60)
            ),
            .rejected(.asleep)
        )
        // No transaction ran, so nothing is absorbed; the observer resumes
        // from en7 and reports en0 as a host epoch.
        XCTAssertEqual(ledger.parking?.epoch.underlayFingerprint, "en7")
        XCTAssertEqual(
            ledger.resume(
                .networkEpoch(connectivityRestored: false),
                observed: observed("en0"),
                systemAsleep: false,
                at: start.addingTimeInterval(120)
            ),
            .grant(.underlayChanged)
        )
    }

    // MARK: - Helpers

    private func epoch(_ fingerprint: String) -> AutomaticRecoveryEpoch {
        AutomaticRecoveryEpoch(
            scenarioID: "home",
            underlayFingerprint: fingerprint,
            connectivityGeneration: 0
        )
    }

    private func observed(
        _ fingerprint: String
    ) -> AutomaticRecoveryObservation {
        AutomaticRecoveryObservation(
            scenarioID: "home",
            underlayFingerprint: fingerprint
        )
    }

    private func failure() -> ConnectionReportError {
        ConnectionReportError(
            code: "line-address-family-unavailable",
            message: "line-address-family-unavailable",
            taskID: "task"
        )
    }

    private func parkedLedger(on fingerprint: String) -> AutomaticRecoveryLedger {
        var ledger = AutomaticRecoveryLedger()
        ledger.beginEpisode(
            in: epoch(fingerprint),
            at: start.addingTimeInterval(-600)
        )
        for attempt in 1 ... 5 {
            XCTAssertTrue(ledger.recordStarted(attempt))
        }
        XCTAssertTrue(ledger.park(
            epoch: epoch(fingerprint),
            failure: failure(),
            at: start
        ))
        return ledger
    }

    private func plan() -> ConnectionPlan {
        ConnectionPlan(
            schemaVersion: 3,
            scenario: ConnectionPlanScenario(id: "home", name: "Home"),
            tasks: [
                ConnectionPlanTask(
                    id: "underlay:system",
                    kind: "underlay",
                    name: "Underlay",
                    preparation: "capture"
                ),
            ]
        )
    }

    private func runningReport(_ transactionID: String) -> ConnectionReport {
        var report = ConnectionReport(
            transactionID: transactionID,
            plan: plan()
        )
        report.setState(.preparing)
        return report
    }

    private func settledReport(_ transactionID: String) -> ConnectionReport {
        var report = ConnectionReport(
            transactionID: transactionID,
            plan: plan()
        )
        report.updateTask(id: "underlay:system", state: .running)
        report.fail(
            code: "line-address-family-unavailable",
            message: "line-address-family-unavailable",
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
