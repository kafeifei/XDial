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

    func testSleepReconnectIntentIsSingleUse() {
        var intent = SleepWakeConnectionIntent()

        XCTAssertTrue(intent.prepareForSleep(
            runtimeStatus: "connected"
        ))
        XCTAssertTrue(intent.consumeWakeReconnect())
        XCTAssertFalse(intent.consumeWakeReconnect())
    }

    func testSleepDoesNotCreateIntentWhileDisconnected() {
        var intent = SleepWakeConnectionIntent()

        XCTAssertFalse(intent.prepareForSleep(
            runtimeStatus: "disconnected"
        ))
        XCTAssertFalse(intent.consumeWakeReconnect())
    }

    func testUserDisconnectCancelsPendingWakeReconnect() {
        var intent = SleepWakeConnectionIntent()
        intent.prepareForSleep(runtimeStatus: "reconnecting")

        intent.cancel()

        XCTAssertFalse(intent.consumeWakeReconnect())
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
        var intent = ConnectionIntentLatch()

        intent.userRequestedDisconnection()

        XCTAssertFalse(intent.allowsAutomaticConnection)
    }

    func testExplicitConnectReenablesConnectionIntent() {
        var intent = ConnectionIntentLatch()
        intent.userRequestedDisconnection()

        intent.userRequestedConnection()

        XCTAssertTrue(intent.allowsAutomaticConnection)
    }
}
