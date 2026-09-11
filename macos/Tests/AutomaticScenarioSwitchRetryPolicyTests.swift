import XCTest

final class AutomaticScenarioSwitchRetryPolicyTests: XCTestCase {
    func testWakeResumesPreservedAutomaticTargetOnlyWhileStillDesired() {
        XCTAssertTrue(AutomaticScenarioSwitchWakePolicy.shouldResume(
            suspendedScenarioID: "office",
            currentDesiredScenarioID: "office",
            committedScenarioID: "home"
        ))
        XCTAssertFalse(AutomaticScenarioSwitchWakePolicy.shouldResume(
            suspendedScenarioID: "office",
            currentDesiredScenarioID: "manual",
            committedScenarioID: "home"
        ))
        XCTAssertFalse(AutomaticScenarioSwitchWakePolicy.shouldResume(
            suspendedScenarioID: "office",
            currentDesiredScenarioID: nil,
            committedScenarioID: "home"
        ))
        XCTAssertFalse(AutomaticScenarioSwitchWakePolicy.shouldResume(
            suspendedScenarioID: "office",
            currentDesiredScenarioID: "office",
            committedScenarioID: "office"
        ))
    }

    func testOnlyLineReadinessFailureReceivesBoundedBackoff() {
        var state = AutomaticScenarioSwitchRetryState()
        state.begin(identity(epoch: 7, generation: 3, target: "office"))

        XCTAssertNil(state.scheduleRetry(failureCode: nil))
        XCTAssertNil(state.scheduleRetry(failureCode: "certificate-invalid"))
        XCTAssertEqual(nextDelay(&state), 2)
        XCTAssertEqual(nextDelay(&state), 5)
        XCTAssertEqual(nextDelay(&state), 10)
        XCTAssertNil(state.scheduleRetry(
            failureCode: ScenarioSwitchFailureCode.lineReadinessTransient
        ))
        XCTAssertEqual(state.retriesScheduled, 3)
        XCTAssertEqual(state.maxRetries, 3)
    }

    func testScheduledBackoffBlocksOrdinaryDriveUntilTimerConsumesToken() {
        var state = AutomaticScenarioSwitchRetryState()
        state.begin(identity(epoch: 7, generation: 3, target: "office"))
        let retry = state.scheduleRetry(
            failureCode: ScenarioSwitchFailureCode.lineReadinessTransient
        )!

        XCTAssertTrue(state.hasPendingRetry)
        XCTAssertTrue(state.isCurrent(retry.token))
        // Status/report publications can ask AppState to drive repeatedly, but
        // the pending gate remains closed until the timer takes this token.
        XCTAssertTrue(state.hasPendingRetry)
        XCTAssertTrue(state.hasPendingRetry)
        XCTAssertTrue(state.takeRetry(retry.token))
        XCTAssertFalse(state.hasPendingRetry)
        XCTAssertFalse(state.takeRetry(retry.token))
        XCTAssertEqual(state.retriesScheduled, 1)
    }

    func testRepeatedIntentDoesNotResetSpentBudget() {
        var state = AutomaticScenarioSwitchRetryState(delays: [2, 5, 10])
        let same = identity(epoch: 7, generation: 3, target: "office")
        XCTAssertTrue(state.begin(same))
        XCTAssertEqual(nextDelay(&state), 2)

        XCTAssertFalse(state.begin(same))
        XCTAssertEqual(state.retriesScheduled, 1)
        XCTAssertTrue(state.hasPendingRetry)
        XCTAssertTrue(state.takeRetry(
            .init(identity: same, retryNumber: 1)
        ))
        XCTAssertEqual(nextDelay(&state), 5)
    }

    func testNewEpochMakesOldTimerUnableToStartRetry() {
        var state = AutomaticScenarioSwitchRetryState()
        state.begin(identity(epoch: 7, generation: 3, target: "office"))
        let stale = state.scheduleRetry(
            failureCode: ScenarioSwitchFailureCode.lineReadinessTransient
        )!.token

        state.begin(identity(epoch: 8, generation: 4, target: "home"))

        XCTAssertFalse(state.isCurrent(stale))
        XCTAssertFalse(state.takeRetry(stale))
        XCTAssertEqual(state.retriesScheduled, 0)
    }

    func testLatestGenerationWinsEvenWhenTargetIsUnchanged() {
        var state = AutomaticScenarioSwitchRetryState()
        state.begin(identity(epoch: 7, generation: 3, target: "office"))
        let stale = state.scheduleRetry(
            failureCode: ScenarioSwitchFailureCode.lineReadinessTransient
        )!.token

        state.begin(identity(epoch: 7, generation: 4, target: "office"))

        XCTAssertFalse(state.isCurrent(stale))
        XCTAssertFalse(state.takeRetry(stale))
        XCTAssertEqual(state.identity?.scenarioGeneration, 4)
    }

    func testExplicitCancellationInvalidatesTimerAndBudget() {
        var state = AutomaticScenarioSwitchRetryState()
        state.begin(identity(epoch: 7, generation: 3, target: "office"))
        let stale = state.scheduleRetry(
            failureCode: ScenarioSwitchFailureCode.lineReadinessTransient
        )!.token

        state.cancel()

        XCTAssertFalse(state.isCurrent(stale))
        XCTAssertFalse(state.takeRetry(stale))
        XCTAssertNil(state.identity)
        XCTAssertEqual(state.retriesScheduled, 0)
    }

    private func nextDelay(
        _ state: inout AutomaticScenarioSwitchRetryState
    ) -> TimeInterval? {
        state.scheduleRetry(
            failureCode: ScenarioSwitchFailureCode.lineReadinessTransient
        )?.delay
    }

    private func identity(
        epoch: UInt64,
        generation: Int,
        target: String
    ) -> AutomaticScenarioSwitchRetryState.Identity {
        .init(
            epoch: epoch,
            scenarioGeneration: generation,
            targetScenarioID: target
        )
    }
}
