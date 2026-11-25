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

    private let vpnTunnel = StaleCommittedGenerationPolicy.Interface(
        name: "utun4",
        index: 56
    )

    func testEscalatesWhenCommittedDefaultInterfaceIsGone() {
        XCTAssertTrue(StaleCommittedGenerationPolicy.shouldEscalate(
            switchFinallyFailed: true,
            automaticEpoch: true,
            committedDefaultInterface: ethernet,
            currentDefaultInterface: wifi,
            currentInterfaces: [wifi]
        ))
    }

    func testDoesNotEscalateWhileOldInterfaceIsStillTheDefault() {
        XCTAssertFalse(StaleCommittedGenerationPolicy.shouldEscalate(
            switchFinallyFailed: true,
            automaticEpoch: true,
            committedDefaultInterface: ethernet,
            currentDefaultInterface: ethernet,
            currentInterfaces: [wifi, ethernet]
        ))
    }

    /// A VPN that drops its full-tunnel route keeps its utun; the old
    /// generation's Direct sockets stay bound to a tunnel without a path
    /// to the Internet.
    func testEscalatesWhenOldInterfaceRemainsButLostTheDefaultPath() {
        XCTAssertTrue(StaleCommittedGenerationPolicy.shouldEscalate(
            switchFinallyFailed: true,
            automaticEpoch: true,
            committedDefaultInterface: vpnTunnel,
            currentDefaultInterface: wifi,
            currentInterfaces: [wifi, vpnTunnel]
        ))
        XCTAssertTrue(StaleCommittedGenerationPolicy.shouldEscalate(
            switchFinallyFailed: true,
            automaticEpoch: true,
            committedDefaultInterface: ethernet,
            currentDefaultInterface: wifi,
            currentInterfaces: [wifi, ethernet]
        ))
    }

    func testRecreatedInterfaceWithNewIndexIsNotTheOldOne() {
        let recreated = StaleCommittedGenerationPolicy.Interface(
            name: "en7",
            index: 19
        )
        XCTAssertTrue(StaleCommittedGenerationPolicy.shouldEscalate(
            switchFinallyFailed: true,
            automaticEpoch: true,
            committedDefaultInterface: ethernet,
            currentDefaultInterface: recreated,
            currentInterfaces: [wifi, recreated]
        ))
    }

    func testOnlyAFinallyFailedAutomaticEpochWithEvidenceEscalates() {
        XCTAssertFalse(StaleCommittedGenerationPolicy.shouldEscalate(
            switchFinallyFailed: false,
            automaticEpoch: true,
            committedDefaultInterface: ethernet,
            currentDefaultInterface: wifi,
            currentInterfaces: [wifi]
        ))
        XCTAssertFalse(StaleCommittedGenerationPolicy.shouldEscalate(
            switchFinallyFailed: true,
            automaticEpoch: false,
            committedDefaultInterface: ethernet,
            currentDefaultInterface: wifi,
            currentInterfaces: [wifi]
        ))
        // No usable capture is not evidence that the interface is gone.
        XCTAssertFalse(StaleCommittedGenerationPolicy.shouldEscalate(
            switchFinallyFailed: true,
            automaticEpoch: true,
            committedDefaultInterface: ethernet,
            currentDefaultInterface: wifi,
            currentInterfaces: []
        ))
        XCTAssertFalse(StaleCommittedGenerationPolicy.shouldEscalate(
            switchFinallyFailed: true,
            automaticEpoch: true,
            committedDefaultInterface: ethernet,
            currentDefaultInterface: nil,
            currentInterfaces: [wifi]
        ))
        XCTAssertFalse(StaleCommittedGenerationPolicy.shouldEscalate(
            switchFinallyFailed: true,
            automaticEpoch: true,
            committedDefaultInterface: nil,
            currentDefaultInterface: wifi,
            currentInterfaces: [wifi]
        ))
    }
}
