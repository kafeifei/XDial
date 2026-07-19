import XCTest
@testable import XDial

@MainActor
final class AppStateTests: XCTestCase {
    func testConnectingDoesNotLookLikeIncompleteConfiguration() {
        let engine = FakeTunnelEngine()
        let manager = FakeTunnelManager(engine: engine)
        engine.retain(manager: manager)
        let app = AppState(engine: engine, tunnelManager: manager)

        var profile = Profile.bootstrap()
        profile.lines[1].vpnServer = "gateway.example.com"
        profile.lines[1].vpnUsername = "tester"
        profile.lines[1].vpnPassword = "secret"
        profile.modes = [
            Mode(
                id: "test-mode",
                name: "Test",
                bindings: [RuleBinding(ruleSetID: "internal", lineID: "vpn")],
                defaultLineID: "direct"
            ),
        ]
        profile.activeModeID = "test-mode"
        app.profile = profile

        XCTAssertTrue(app.isConnectionConfigured)
        XCTAssertTrue(app.canConnect)

        engine.simulateConnect()

        XCTAssertTrue(app.isBusy)
        XCTAssertFalse(app.canConnect)
        XCTAssertTrue(app.isConnectionConfigured)
    }

    func testMissingCredentialsRemainIncomplete() {
        let engine = FakeTunnelEngine()
        let manager = FakeTunnelManager(engine: engine)
        engine.retain(manager: manager)
        let app = AppState(engine: engine, tunnelManager: manager)

        var profile = Profile.bootstrap()
        profile.modes = [
            Mode(
                id: "test-mode",
                name: "Test",
                bindings: [RuleBinding(ruleSetID: "internal", lineID: "vpn")],
                defaultLineID: "direct"
            ),
        ]
        profile.activeModeID = "test-mode"
        app.profile = profile

        XCTAssertFalse(app.isConnectionConfigured)
        XCTAssertFalse(app.canConnect)
    }

    func testTunnelDiagnosticSummaryKeepsProviderError() {
        let summary = TunnelDiagnosticFormatter.summary([
            "stage": "engine_failed",
            "last_error": "authentication rejected",
        ])

        XCTAssertEqual(summary, "error=authentication rejected · stage=engine_failed")
    }

    func testTunnelDiagnosticSummaryKeepsNestedEngineError() {
        let summary = TunnelDiagnosticFormatter.summary([
            "stage": "engine_started",
            "engine": [
                "last_error": "route setup failed",
                "gvisor_compiled": true,
                "selected_stack": "gvisor",
            ],
        ])

        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.contains("engine_error=route setup failed") == true)
        XCTAssertTrue(summary?.contains("stage=engine_started") == true)
    }

    func testTunnelDiagnosticSummaryRejectsAnotherAttempt() {
        let snapshot: [String: Any] = [
            "attempt_id": "attempt-a",
            "stage": "tun_unavailable",
        ]

        XCTAssertNotNil(TunnelDiagnosticFormatter.summary(
            snapshot,
            matchingAttemptID: "attempt-a"
        ))
        XCTAssertNil(TunnelDiagnosticFormatter.summary(
            snapshot,
            matchingAttemptID: "attempt-b"
        ))
    }
}
