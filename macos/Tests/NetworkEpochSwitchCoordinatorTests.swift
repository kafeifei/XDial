import XCTest

final class NetworkEpochSwitchCoordinatorTests: XCTestCase {
    func testUnderlayThenSSIDSettlesAsOneEpochWithLatestScenario() {
        var coordinator = NetworkEpochSwitchCoordinator()
        let stale = coordinator.observeUnderlayChange(
            currentDesiredScenarioID: "home",
            underlayFingerprint: "underlay-2"
        )!
        let latest = coordinator.observeSSIDResolution(
            desiredScenarioID: "office"
        )!

        XCTAssertNil(coordinator.settle(stale))
        XCTAssertEqual(
            coordinator.settle(latest),
            .init(
                epoch: latest.epoch,
                desiredScenarioID: "office",
                underlayFingerprint: "underlay-2",
                underlayChanged: true
            )
        )
    }

    func testSSIDThenUnderlayDoesNotOverwriteMatchedScenario() {
        var coordinator = NetworkEpochSwitchCoordinator()
        _ = coordinator.observeSSIDResolution(desiredScenarioID: "office")
        let latest = coordinator.observeUnderlayChange(
            currentDesiredScenarioID: "home",
            underlayFingerprint: "underlay-2"
        )!

        XCTAssertEqual(
            coordinator.settle(latest)?.desiredScenarioID,
            "office"
        )
    }

    func testSSIDSettlingKeepsLateStableValueInSameEpoch() {
        var coordinator = NetworkEpochSwitchCoordinator()
        let underlay = coordinator.observeUnderlayChange(
            currentDesiredScenarioID: "home",
            underlayFingerprint: "underlay-2"
        )!
        let settling = coordinator.observeSSIDSettling(
            currentDesiredScenarioID: "home"
        )!
        let resolved = coordinator.observeSSIDResolution(
            desiredScenarioID: "office"
        )!

        XCTAssertNil(coordinator.settle(underlay))
        XCTAssertNil(coordinator.settle(settling))
        XCTAssertEqual(
            coordinator.settle(resolved),
            .init(
                epoch: resolved.epoch,
                desiredScenarioID: "office",
                underlayFingerprint: "underlay-2",
                underlayChanged: true
            )
        )
    }

    func testRapidSSIDChangesAreLatestWins() {
        var coordinator = NetworkEpochSwitchCoordinator()
        let first = coordinator.observeSSIDResolution(desiredScenarioID: "a")!
        let second = coordinator.observeSSIDResolution(desiredScenarioID: "b")!
        let third = coordinator.observeSSIDResolution(desiredScenarioID: "c")!
        let stable = coordinator.refreshUnderlayFingerprint("underlay-1")!

        XCTAssertNil(coordinator.settle(first))
        XCTAssertNil(coordinator.settle(second))
        XCTAssertNil(coordinator.settle(third))
        XCTAssertEqual(
            coordinator.settle(stable)?.desiredScenarioID,
            "c"
        )
    }

    func testSettledSignalsStartANewEpochForNewUnderlay() {
        var coordinator = NetworkEpochSwitchCoordinator()
        _ = coordinator.observeSSIDResolution(desiredScenarioID: "a")
        let first = coordinator.refreshUnderlayFingerprint("underlay-1")!
        XCTAssertNotNil(coordinator.settle(first))

        let second = coordinator.observeUnderlayChange(
            currentDesiredScenarioID: "a",
            underlayFingerprint: "underlay-2"
        )!
        XCTAssertNotEqual(first.epoch, second.epoch)
    }

    func testCancelInvalidatesOutstandingQuietToken() {
        var coordinator = NetworkEpochSwitchCoordinator()
        let token = coordinator.observeSSIDResolution(
            desiredScenarioID: "office"
        )!

        coordinator.cancel()

        XCTAssertNil(coordinator.settle(token))
        XCTAssertFalse(coordinator.hasPendingIntent)
    }

    func testLatestUnmatchedSSIDCanSupersedeTransientMatch() {
        var coordinator = NetworkEpochSwitchCoordinator()
        let transient = coordinator.observeSSIDResolution(
            desiredScenarioID: "office"
        )!
        coordinator.noteUnmatchedSSID()
        _ = coordinator.observeSSIDResolution(
            desiredScenarioID: "source"
        )!
        let latest = coordinator.refreshUnderlayFingerprint("underlay-1")!

        XCTAssertNil(coordinator.settle(transient))
        XCTAssertEqual(
            coordinator.settle(latest)?.desiredScenarioID,
            "source"
        )
    }

    func testSettleUsesFreshlySampledUnderlayFingerprint() {
        var coordinator = NetworkEpochSwitchCoordinator()
        let notification = coordinator.observeUnderlayChange(
            currentDesiredScenarioID: "home",
            underlayFingerprint: "underlay-intermediate"
        )!
        let stable = coordinator.refreshUnderlayFingerprint(
            "underlay-stable"
        )!

        XCTAssertNil(coordinator.settle(notification))
        XCTAssertEqual(
            coordinator.settle(stable)?.underlayFingerprint,
            "underlay-stable"
        )
    }

    func testLateEventsForAlreadySettledTupleDoNotCreateSecondIntent() {
        var coordinator = NetworkEpochSwitchCoordinator()
        _ = coordinator.observeUnderlayChange(
            currentDesiredScenarioID: "home",
            underlayFingerprint: "underlay-2"
        )
        _ = coordinator.observeSSIDResolution(
            desiredScenarioID: "office"
        )
        let first = coordinator.refreshUnderlayFingerprint("underlay-2")!
        XCTAssertNotNil(coordinator.settle(first))

        _ = coordinator.observeSSIDResolution(
            desiredScenarioID: "office"
        )
        let lateSSID = coordinator.refreshUnderlayFingerprint("underlay-2")!
        XCTAssertNil(coordinator.settle(lateSSID))
        XCTAssertNil(coordinator.observeUnderlayChange(
            currentDesiredScenarioID: "office",
            underlayFingerprint: "underlay-2"
        ))
        XCTAssertFalse(coordinator.hasPendingIntent)
    }

    func testRealUnmatchedSSIDSeparatesReturnToSameTuple() {
        var coordinator = NetworkEpochSwitchCoordinator()
        _ = coordinator.observeSSIDResolution(
            desiredScenarioID: "office"
        )
        let first = coordinator.refreshUnderlayFingerprint("underlay-1")!
        XCTAssertNotNil(coordinator.settle(first))

        coordinator.noteUnmatchedSSID()
        _ = coordinator.observeSSIDResolution(
            desiredScenarioID: "office"
        )
        let returned = coordinator.refreshUnderlayFingerprint("underlay-1")!
        XCTAssertNotNil(coordinator.settle(returned))
    }
}
