import XCTest

final class ParkedRecoveryTransitionPolicyTests: XCTestCase {
    func testParkedRecoveryReceivesSettledUnderlayEpoch() {
        XCTAssertEqual(
            decide(underlayChanged: true),
            .resumeParkedRecovery
        )
    }

    func testSSIDChoosingAnotherScenarioWhileParkedResumesRecovery() {
        XCTAssertEqual(
            decide(desired: "office", underlayChanged: false),
            .resumeParkedRecovery
        )
    }

    func testSSIDRepeatOfCurrentScenarioWhileParkedIsNoOp() {
        XCTAssertEqual(decide(underlayChanged: false), .none)
    }

    func testExplicitDisconnectEndsParkedTransitions() {
        XCTAssertEqual(
            decide(underlayChanged: true, keepsConnection: false),
            .none
        )
    }

    func testParkedTransitionWaitsForPendingSwitchAndDisconnectedRuntime() {
        XCTAssertEqual(
            decide(underlayChanged: true, hasPendingScenarioSwitch: true),
            .none
        )
        XCTAssertEqual(
            decide(underlayChanged: true, runtimeStatus: "reconnecting"),
            .none
        )
    }

    func testUnparkedRuntimeKeepsExistingDecisions() {
        XCTAssertEqual(
            decide(underlayChanged: true, parked: false),
            .none
        )
        XCTAssertEqual(
            decide(
                underlayChanged: true,
                runtimeStatus: "connected",
                parked: false
            ),
            .switchScenario(requiresUnderlayRefresh: true)
        )
    }

    func testConnectivityRestorationIsCarriedSeparatelyFromForcedEpochs() {
        var coordinator = NetworkEpochSwitchCoordinator()
        let restored = coordinator.observeUnderlayChange(
            currentDesiredScenarioID: "home",
            underlayFingerprint: "en0",
            forceNewEpoch: true,
            connectivityRestored: true
        )!
        XCTAssertTrue(coordinator.settle(restored)!.connectivityRestored)

        // Recovery preparation forces a new epoch but is not an edge.
        let preparation = coordinator.observeUnderlayChange(
            currentDesiredScenarioID: "home",
            underlayFingerprint: "en0",
            forceNewEpoch: true
        )!
        XCTAssertFalse(
            coordinator.settle(preparation)!.connectivityRestored
        )
    }

    private func decide(
        desired: String = "home",
        underlayChanged: Bool,
        keepsConnection: Bool = true,
        runtimeStatus: String = "disconnected",
        hasPendingScenarioSwitch: Bool = false,
        parked: Bool = true
    ) -> NetworkEpochTransitionAction {
        NetworkEpochTransitionPolicy.decide(
            desiredScenarioID: desired,
            currentDesiredScenarioID: "home",
            committedScenarioID: "home",
            underlayChanged: underlayChanged,
            keepsConnection: keepsConnection,
            runtimeStatus: runtimeStatus,
            hasPendingScenarioSwitch: hasPendingScenarioSwitch,
            automaticRecoveryParked: parked
        )
    }
}

final class StaleCommittedGenerationPolicyTests: XCTestCase {
    private let ethernet = StaleCommittedGenerationPolicy.Interface(
        name: "en7",
        index: 14
    )
    private let wifi = StaleCommittedGenerationPolicy.Interface(
        name: "en0",
        index: 11
    )

    func testEscalatesWhenCommittedDefaultInterfaceIsGone() {
        XCTAssertTrue(StaleCommittedGenerationPolicy.shouldEscalate(
            switchFinallyFailed: true,
            automaticEpoch: true,
            committedDefaultInterface: ethernet,
            currentInterfaces: [wifi]
        ))
    }

    func testDoesNotEscalateWhileOldDefaultInterfaceStillExists() {
        XCTAssertFalse(StaleCommittedGenerationPolicy.shouldEscalate(
            switchFinallyFailed: true,
            automaticEpoch: true,
            committedDefaultInterface: ethernet,
            currentInterfaces: [wifi, ethernet]
        ))
    }

    func testRecreatedInterfaceWithNewIndexIsNotTheOldOne() {
        XCTAssertTrue(StaleCommittedGenerationPolicy.shouldEscalate(
            switchFinallyFailed: true,
            automaticEpoch: true,
            committedDefaultInterface: ethernet,
            currentInterfaces: [
                wifi,
                .init(name: "en7", index: 19),
            ]
        ))
    }

    func testOnlyAFinallyFailedAutomaticEpochWithEvidenceEscalates() {
        XCTAssertFalse(StaleCommittedGenerationPolicy.shouldEscalate(
            switchFinallyFailed: false,
            automaticEpoch: true,
            committedDefaultInterface: ethernet,
            currentInterfaces: [wifi]
        ))
        XCTAssertFalse(StaleCommittedGenerationPolicy.shouldEscalate(
            switchFinallyFailed: true,
            automaticEpoch: false,
            committedDefaultInterface: ethernet,
            currentInterfaces: [wifi]
        ))
        // No usable capture is not evidence that the interface is gone.
        XCTAssertFalse(StaleCommittedGenerationPolicy.shouldEscalate(
            switchFinallyFailed: true,
            automaticEpoch: true,
            committedDefaultInterface: ethernet,
            currentInterfaces: []
        ))
        XCTAssertFalse(StaleCommittedGenerationPolicy.shouldEscalate(
            switchFinallyFailed: true,
            automaticEpoch: true,
            committedDefaultInterface: nil,
            currentInterfaces: [wifi]
        ))
    }
}
