import XCTest

final class AutomaticConnectionPolicyTests: XCTestCase {
    func testAutomaticConnectionDefaultsToEnabled() {
        XCTAssertTrue(AutomaticConnectionPolicy.defaultEnabled)
    }

    func testLaunchWaitsForInstallationAndInitialStatusSync() {
        XCTAssertFalse(AutomaticConnectionPolicy.shouldConnectOnLaunch(
            enabled: true,
            initialStatusSynchronized: false,
            installationReady: true,
            runtimeStatus: "disconnected",
            canConnect: true
        ))
        XCTAssertFalse(AutomaticConnectionPolicy.shouldConnectOnLaunch(
            enabled: true,
            initialStatusSynchronized: true,
            installationReady: false,
            runtimeStatus: "disconnected",
            canConnect: true
        ))
        XCTAssertTrue(AutomaticConnectionPolicy.shouldConnectOnLaunch(
            enabled: true,
            initialStatusSynchronized: true,
            installationReady: true,
            runtimeStatus: "disconnected",
            canConnect: true
        ))
    }

    func testLaunchDoesNotReplaceAnExistingConnectionIntent() {
        for status in ["connected", "connecting", "reconnecting"] {
            XCTAssertFalse(AutomaticConnectionPolicy.shouldConnectOnLaunch(
                enabled: true,
                initialStatusSynchronized: true,
                installationReady: true,
                runtimeStatus: status,
                canConnect: true
            ))
        }
    }

    func testInitialStatusAdoptsExistingConnectionOnlyWhileUnresolved() {
        var desired = ConnectionDesiredState()

        desired.observeExistingConnection(modeID: "work")

        XCTAssertEqual(desired.value, .connected(
            modeID: "work",
            runtimeOwnership: .adopted
        ))

        desired.userRequestedDisconnection()
        desired.observeExistingConnection(modeID: "stale")
        XCTAssertEqual(
            desired.value,
            .disconnected(explicit: true)
        )
    }

    func testRepeatedWakeSignalsDoNotConsumeConnectionDesire() {
        var desired = ConnectionDesiredState()
        desired.userRequestedConnection(modeID: "work")

        XCTAssertEqual(DesiredConnectionReconcilePolicy.decide(
            desired: desired,
            activeModeID: "work",
            runtimeStatus: "connected",
            canConnect: false,
            networkWaitCompleted: false
        ), .none)
        XCTAssertEqual(DesiredConnectionReconcilePolicy.decide(
            desired: desired,
            activeModeID: "work",
            runtimeStatus: "disconnected",
            canConnect: true,
            networkWaitCompleted: false
        ), .waitForNetwork)
        XCTAssertEqual(DesiredConnectionReconcilePolicy.decide(
            desired: desired,
            activeModeID: "work",
            runtimeStatus: "disconnected",
            canConnect: false,
            networkWaitCompleted: false
        ), .waitForNetwork)
        XCTAssertEqual(DesiredConnectionReconcilePolicy.decide(
            desired: desired,
            activeModeID: "work",
            runtimeStatus: "disconnected",
            canConnect: true,
            networkWaitCompleted: true
        ), .startAutomatically(modeID: "work"))
        XCTAssertEqual(desired.value, .connected(
            modeID: "work",
            runtimeOwnership: .owned
        ))
    }

    func testWakeReconcileNeverRestartsAnActiveRuntime() {
        var desired = ConnectionDesiredState()
        desired.userRequestedConnection(modeID: "work")

        for status in ["connecting", "reconnecting", "connected"] {
            XCTAssertEqual(DesiredConnectionReconcilePolicy.decide(
                desired: desired,
                activeModeID: "work",
                runtimeStatus: status,
                canConnect: false,
                networkWaitCompleted: false
            ), .none)
        }
    }

    func testAdoptedRuntimeLossIsClaimedExactlyOnce() {
        var desired = ConnectionDesiredState()
        desired.observeExistingConnection(modeID: "work")

        XCTAssertTrue(desired.beginRestoringAdoptedRuntime())
        XCTAssertFalse(desired.beginRestoringAdoptedRuntime())
        XCTAssertEqual(desired.value, .connected(
            modeID: "work",
            runtimeOwnership: .restoring
        ))

        XCTAssertTrue(desired.automaticConnectionRequested(
            modeID: "work"
        ))
        XCTAssertEqual(desired.value, .connected(
            modeID: "work",
            runtimeOwnership: .owned
        ))
    }

    func testDuplicateWakeIsNoOpOnceConnectionTransactionStarted() {
        var desired = ConnectionDesiredState()
        desired.userRequestedConnection(modeID: "work")

        for status in ["connecting", "reconnecting", "connected"] {
            XCTAssertEqual(DesiredConnectionReconcilePolicy.decide(
                desired: desired,
                activeModeID: "work",
                runtimeStatus: status,
                canConnect: false,
                networkWaitCompleted: false
            ), .none)
        }
    }

    func testWakeDoesNotSilentlyRestoreAChangedMode() {
        var desired = ConnectionDesiredState()
        desired.userRequestedConnection(modeID: "before-sleep")

        XCTAssertEqual(DesiredConnectionReconcilePolicy.decide(
            desired: desired,
            activeModeID: "current",
            runtimeStatus: "disconnected",
            canConnect: true,
            networkWaitCompleted: true
        ), .modeChanged(
            expectedModeID: "before-sleep",
            activeModeID: "current"
        ))
    }

    func testNewConnectionAttemptSupersedesPendingPreflight() {
        var gate = ConnectionAttemptGate()
        let first = gate.begin()
        let second = gate.begin()

        XCTAssertFalse(gate.isCurrent(first))
        XCTAssertTrue(gate.isCurrent(second))
    }

    func testDisconnectCancelsPendingConnectionPreflight() {
        var gate = ConnectionAttemptGate()
        let attempt = gate.begin()

        gate.cancel()

        XCTAssertFalse(gate.isCurrent(attempt))
    }

    func testExplicitDisconnectBlocksLateAutomaticConnection() {
        var desired = ConnectionDesiredState()

        desired.userRequestedDisconnection()

        XCTAssertFalse(desired.automaticConnectionRequested(
            modeID: "work"
        ))
        XCTAssertEqual(DesiredConnectionReconcilePolicy.decide(
            desired: desired,
            activeModeID: "work",
            runtimeStatus: "connecting",
            canConnect: false,
            networkWaitCompleted: false
        ), .stopRuntime)
    }

    func testExplicitConnectReenablesConnectionIntent() {
        var desired = ConnectionDesiredState()
        desired.userRequestedDisconnection()

        desired.userRequestedConnection(modeID: "work")

        XCTAssertTrue(desired.automaticConnectionRequested(
            modeID: "work"
        ))
        XCTAssertEqual(desired.value, .connected(
            modeID: "work",
            runtimeOwnership: .owned
        ))
    }

    func testTerminationWaitsForRuntimeAndSystemTakeoverRollback() {
        XCTAssertTrue(ApplicationTerminationPolicy.requiresDrain(
            runtimeStatus: "connected",
            hasConnectionReport: true,
            rollbackComplete: false,
            systemTakeoverRemoved: false
        ))
        XCTAssertTrue(ApplicationTerminationPolicy.requiresDrain(
            runtimeStatus: "disconnected",
            hasConnectionReport: true,
            rollbackComplete: false,
            systemTakeoverRemoved: true
        ))
        XCTAssertTrue(ApplicationTerminationPolicy.requiresDrain(
            runtimeStatus: "disconnected",
            hasConnectionReport: true,
            rollbackComplete: true,
            systemTakeoverRemoved: false
        ))
        XCTAssertFalse(ApplicationTerminationPolicy.requiresDrain(
            runtimeStatus: "disconnected",
            hasConnectionReport: true,
            rollbackComplete: true,
            systemTakeoverRemoved: true
        ))
        XCTAssertFalse(ApplicationTerminationPolicy.requiresDrain(
            runtimeStatus: "disconnected",
            hasConnectionReport: false,
            rollbackComplete: false,
            systemTakeoverRemoved: false
        ))
    }

    func testWakeRecoveryPhasesHidePreviousCancelledReport() {
        for phase in WakeReconnectPhase.allCases {
            XCTAssertFalse(phase.presentsConnectionReport)
        }
    }

    func testWaitingForNetworkHasRecoveryStatusInsteadOfCancelled() {
        let phase = WakeReconnectPhase.waitingForNetwork

        XCTAssertEqual(phase.zhStatusText, "等待网络恢复…")
        XCTAssertEqual(phase.enStatusText, "Waiting for network…")
        XCTAssertNotEqual(phase.zhStatusText, "已取消")
        XCTAssertNotEqual(phase.enStatusText, "Cancelled")
    }
}
