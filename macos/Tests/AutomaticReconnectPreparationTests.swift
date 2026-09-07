import XCTest

final class AutomaticReconnectPreparationTests: XCTestCase {
    func testPreparationIsSingleFlightAndConsumedOnce() throws {
        var gate = AutomaticReconnectPreparationGate()
        let token = try XCTUnwrap(gate.begin())

        XCTAssertNil(gate.begin())
        XCTAssertTrue(gate.isCurrent(token))
        XCTAssertTrue(gate.finish(token))
        XCTAssertNil(gate.token)
        XCTAssertFalse(gate.isCurrent(token))
        XCTAssertFalse(gate.finish(token))
    }

    func testCancellationInvalidatesOldCallbackWithoutConsumingNewRequest()
        throws {
        var gate = AutomaticReconnectPreparationGate()
        let cancelled = try XCTUnwrap(gate.begin())
        gate.cancel()

        XCTAssertFalse(gate.isCurrent(cancelled))
        XCTAssertFalse(gate.finish(cancelled))
        let current = try XCTUnwrap(gate.begin())
        XCTAssertNotEqual(cancelled, current)
        XCTAssertFalse(gate.finish(cancelled))
        XCTAssertTrue(gate.isCurrent(current))
        XCTAssertTrue(gate.finish(current))
    }

    func testUnrelatedCallbackCannotConsumeCurrentPreparation() throws {
        var gate = AutomaticReconnectPreparationGate()
        let current = try XCTUnwrap(gate.begin())

        XCTAssertFalse(gate.finish(UUID()))
        XCTAssertTrue(gate.isCurrent(current))
        XCTAssertNil(gate.begin())
    }

    func testRecoveryCanSettlePreviouslyConsumedScenarioAndUnderlay()
        throws {
        var coordinator = NetworkEpochSwitchCoordinator()
        let initial = try XCTUnwrap(coordinator.observeUnderlayChange(
            currentDesiredScenarioID: "home",
            underlayFingerprint: "underlay-a"
        ))
        let previous = try XCTUnwrap(coordinator.settle(initial))
        XCTAssertNil(coordinator.observeUnderlayChange(
            currentDesiredScenarioID: "home",
            underlayFingerprint: "underlay-a"
        ))

        var gate = AutomaticReconnectPreparationGate()
        let request = try XCTUnwrap(gate.begin())
        let recovery = try XCTUnwrap(coordinator.observeUnderlayChange(
            currentDesiredScenarioID: "home",
            underlayFingerprint: "underlay-a",
            forceNewEpoch: true
        ))
        let intent = try XCTUnwrap(coordinator.settle(recovery))

        XCTAssertGreaterThan(intent.epoch, previous.epoch)
        XCTAssertEqual(intent.desiredScenarioID, "home")
        XCTAssertEqual(intent.underlayFingerprint, "underlay-a")
        XCTAssertTrue(gate.finish(request))
        XCTAssertNil(coordinator.settle(recovery))
        XCTAssertFalse(gate.finish(request))
    }

    func testRecoveryUsesLatestScenarioAndStableUnderlayIdentity() throws {
        var coordinator = NetworkEpochSwitchCoordinator()
        var gate = AutomaticReconnectPreparationGate()
        let request = try XCTUnwrap(gate.begin())
        let initial = try XCTUnwrap(coordinator.observeUnderlayChange(
            currentDesiredScenarioID: "home",
            underlayFingerprint: "underlay-a",
            forceNewEpoch: true
        ))
        let selected = try XCTUnwrap(coordinator.observeSSIDResolution(
            desiredScenarioID: "office"
        ))

        XCTAssertFalse(coordinator.isCurrent(initial))
        XCTAssertFalse(coordinator.hasUnderlayFingerprint("underlay-b"))
        let refreshed = try XCTUnwrap(
            coordinator.refreshUnderlayFingerprint("underlay-b")
        )
        XCTAssertFalse(coordinator.isCurrent(selected))
        XCTAssertNil(coordinator.settle(selected))
        XCTAssertTrue(coordinator.hasUnderlayFingerprint("underlay-b"))
        XCTAssertEqual(
            coordinator.refreshUnderlayFingerprint("underlay-b"),
            refreshed
        )

        let intent = try XCTUnwrap(coordinator.settle(refreshed))
        XCTAssertEqual(intent.desiredScenarioID, "office")
        XCTAssertEqual(intent.underlayFingerprint, "underlay-b")
        XCTAssertTrue(gate.finish(request))
        XCTAssertFalse(coordinator.hasUnderlayFingerprint("underlay-b"))
    }

    func testCancelledEpochCannotCompleteReplacementRecovery() throws {
        var coordinator = NetworkEpochSwitchCoordinator()
        var gate = AutomaticReconnectPreparationGate()
        let cancelled = try XCTUnwrap(gate.begin())
        let oldEpoch = try XCTUnwrap(coordinator.observeUnderlayChange(
            currentDesiredScenarioID: "home",
            underlayFingerprint: "underlay-a",
            forceNewEpoch: true
        ))
        gate.cancel()
        coordinator.cancel()

        let current = try XCTUnwrap(gate.begin())
        let newEpoch = try XCTUnwrap(coordinator.observeUnderlayChange(
            currentDesiredScenarioID: "manual",
            underlayFingerprint: "underlay-b",
            forceNewEpoch: true
        ))
        XCTAssertFalse(gate.finish(cancelled))
        XCTAssertNil(coordinator.settle(oldEpoch))
        XCTAssertTrue(gate.isCurrent(current))
        let intent = try XCTUnwrap(coordinator.settle(newEpoch))
        XCTAssertEqual(intent.desiredScenarioID, "manual")
        XCTAssertTrue(gate.finish(current))
    }
}
