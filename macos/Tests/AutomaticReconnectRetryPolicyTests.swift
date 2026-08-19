import XCTest

final class AutomaticReconnectRetryPolicyTests: XCTestCase {
    func testRetriesOnlyCompletedUnderlayEgressFailure() {
        let policy = AutomaticReconnectRetryPolicy(
            delays: [2, 5, 10, 20, 30]
        )
        let report = failedReport(
            code: ConnectionFailureCode.underlayEgressUnavailable
        )

        XCTAssertEqual(
            policy.delay(
                after: report,
                attemptsUsed: 0,
                trigger: .underlayChange
            ),
            2
        )
        XCTAssertEqual(
            policy.delay(
                after: report,
                attemptsUsed: 1,
                trigger: .underlayChange
            ),
            5
        )
        XCTAssertEqual(
            policy.delay(
                after: report,
                attemptsUsed: 4,
                trigger: .underlayChange
            ),
            30
        )
        XCTAssertNil(policy.delay(
            after: report,
            attemptsUsed: 5,
            trigger: .underlayChange
        ))
        XCTAssertEqual(policy.maxAttempts, 5)
        XCTAssertEqual(policy.stableResetInterval, 300)
    }

    func testUnexpectedDisconnectRecoveryCanRetryACompletedLineFailure() {
        let policy = AutomaticReconnectRetryPolicy()
        let report = failedReport(
            code: "tailscale-peer-handshake-failed"
        )

        XCTAssertEqual(
            policy.delay(
                after: report,
                attemptsUsed: 0,
                trigger: .unexpectedDisconnect
            ),
            2
        )
    }

    func testUnderlayRecoveryDoesNotRetryLineOrHandshakeFailures() {
        let policy = AutomaticReconnectRetryPolicy()

        XCTAssertNil(policy.delay(
            after: failedReport(
                code: "tailscale-peer-handshake-failed"
            ),
            attemptsUsed: 0,
            trigger: .underlayChange
        ))
        XCTAssertNil(policy.delay(
            after: failedReport(
                code: "tailscale-exit-node-unavailable"
            ),
            attemptsUsed: 0,
            trigger: .underlayChange
        ))
    }

    func testLaunchAutoConnectCanRetryACompletedLineFailure() {
        let policy = AutomaticReconnectRetryPolicy()
        let report = failedReport(code: "tailscale-peer-handshake-failed")

        XCTAssertEqual(
            policy.delay(
                after: report,
                attemptsUsed: 0,
                trigger: .automaticConnection
            ),
            2
        )
    }

    func testRuntimeStateExposesRetryCountdown() {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let state = AutomaticReconnectRuntimeState(
            inProgress: true,
            trigger: .automaticConnection,
            attemptsUsed: 1,
            maxAttempts: 5,
            stableResetAt: nil,
            retryAt: now.addingTimeInterval(2),
            retryAttempt: 1
        )

        XCTAssertEqual(
            state.retryCountdownSeconds(
                at: now.addingTimeInterval(0.1)
            ),
            2
        )
        XCTAssertEqual(
            state.retryCountdownSeconds(
                at: now.addingTimeInterval(1.1)
            ),
            1
        )
        XCTAssertEqual(
            state.retryCountdownSeconds(
                at: now.addingTimeInterval(2.1)
            ),
            0
        )
        XCTAssertEqual(state.retryAttempt, 1)
    }

    func testRuntimeStateExposesStructuredUnderlayWaitReason() {
        let evidence = HostUnderlayCaptureEvidence(
            schemaVersion: 1,
            reason: .pathUnsatisfied,
            pathStatus: "unsatisfied",
            routeInterface: "",
            candidateInterfaces: ["en0"],
            invalidCandidateInterfaces: [],
            routeError: ""
        )
        let state = AutomaticReconnectRuntimeState(
            inProgress: true,
            trigger: .unexpectedDisconnect,
            attemptsUsed: 0,
            maxAttempts: 5,
            stableResetAt: nil,
            retryAt: nil,
            retryAttempt: nil,
            underlayWaitEvidence: evidence
        )

        XCTAssertEqual(state.underlayWaitEvidence, evidence)
    }

    func testDoesNotRetryBeforeRollbackCompletes() {
        let policy = AutomaticReconnectRetryPolicy()
        var report = failedReport(
            code: ConnectionFailureCode.underlayEgressUnavailable
        )
        report.rollbackComplete = false

        XCTAssertNil(policy.delay(
            after: report,
            attemptsUsed: 0,
            trigger: .unexpectedDisconnect
        ))
    }

    func testFiveAttemptBudgetHasNoSixthDelay() {
        let policy = AutomaticReconnectRetryPolicy()
        XCTAssertEqual(
            (0 ..< 5).compactMap {
                policy.delayForNextAttempt(attemptsUsed: $0)
            },
            [2, 5, 10, 20, 30]
        )
        XCTAssertNil(policy.delayForNextAttempt(attemptsUsed: 5))
    }

    func testUnderlayWaitDoesNotConsumeConnectionAttemptBudget() {
        var budget = AutomaticReconnectAttemptBudget(maxAttempts: 5)

        XCTAssertEqual(budget.nextAttempt, 1)
        XCTAssertEqual(budget.attemptsUsed, 0)

        // Repeated host snapshot failures reserve the same first attempt;
        // no connection transaction has started yet.
        XCTAssertEqual(budget.nextAttempt, 1)
        XCTAssertEqual(budget.nextAttempt, 1)
        XCTAssertEqual(budget.attemptsUsed, 0)

        XCTAssertTrue(budget.recordStarted(1))
        XCTAssertEqual(budget.attemptsUsed, 1)
        XCTAssertEqual(budget.nextAttempt, 2)
        XCTAssertFalse(budget.recordStarted(1))
        XCTAssertFalse(budget.recordStarted(3))

        for attempt in 2 ... 5 {
            XCTAssertTrue(budget.recordStarted(attempt))
        }
        XCTAssertNil(budget.nextAttempt)

        budget.reset()
        XCTAssertEqual(budget.attemptsUsed, 0)
        XCTAssertEqual(budget.nextAttempt, 1)
    }

    func testUnderlayWaitUsesShortestRetryCadence() {
        let policy = AutomaticReconnectRetryPolicy(
            delays: [2, 5, 10, 20, 30]
        )

        XCTAssertEqual(policy.underlayWaitRetryDelay, 2)
    }

    private func failedReport(code: String) -> ConnectionReport {
        let plan = ConnectionPlan(
            schemaVersion: 3,
            scenario: ConnectionPlanScenario(id: "scenario", name: "Scenario"),
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
