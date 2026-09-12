import XCTest

final class MenuBarRecoveryPolicyTests: XCTestCase {
    func testStartupAndShortLayoutChangesDoNotRebuild() {
        var policy = MenuBarRecoveryPolicy()
        XCTAssertEqual(policy.observe(.missing, at: 0), .none)
        XCTAssertEqual(policy.observe(.missing, at: 2), .none)
        XCTAssertEqual(policy.observe(.visible, at: 2.5), .none)
        XCTAssertEqual(policy.observe(.missing, at: 10), .none)
        XCTAssertEqual(policy.observe(.missing, at: 13), .rebuild)
    }

    func testPersistentSystemBlockStopsRecreationLoop() {
        var policy = MenuBarRecoveryPolicy()
        _ = policy.observe(.missing, at: 0)
        XCTAssertEqual(policy.observe(.missing, at: 3), .rebuild)
        XCTAssertEqual(policy.observe(.missing, at: 4), .none)
        XCTAssertEqual(policy.observe(.missing, at: 8), .rebuild)
        XCTAssertEqual(policy.observe(.missing, at: 13), .rebuild)
        XCTAssertEqual(policy.observe(.missing, at: 18), .blocked)
        XCTAssertEqual(policy.observe(.missing, at: 1000), .none)
        XCTAssertTrue(policy.isBlocked)
        XCTAssertEqual(policy.attempts, 3)
    }

    func testTransientVisibilityAfterRecreationDoesNotResetBudget() {
        var policy = MenuBarRecoveryPolicy()
        _ = policy.observe(.missing, at: 0)
        _ = policy.observe(.missing, at: 3)
        _ = policy.observe(.visible, at: 4)
        _ = policy.observe(.missing, at: 4.1)
        XCTAssertEqual(policy.observe(.missing, at: 8), .rebuild)
        XCTAssertEqual(policy.attempts, 2)
    }

    func testStableVisibilityAllowsRecoveryOfALaterIncident() {
        var policy = MenuBarRecoveryPolicy()
        _ = policy.observe(.missing, at: 0)
        _ = policy.observe(.missing, at: 3)
        _ = policy.observe(.visible, at: 4)
        XCTAssertEqual(policy.observe(.visible, at: 13), .none)
        XCTAssertEqual(policy.observe(.visible, at: 14), .recovered)
        XCTAssertEqual(policy.attempts, 0)
        _ = policy.observe(.missing, at: 20)
        XCTAssertEqual(policy.observe(.missing, at: 23), .rebuild)
    }

    func testSleepOrHiddenSystemMenuRestartsGraceWithoutResettingBudget() {
        var policy = MenuBarRecoveryPolicy()
        _ = policy.observe(.missing, at: 0)
        _ = policy.observe(.missing, at: 3)
        _ = policy.observe(.deferred, at: 4)
        XCTAssertEqual(policy.observe(.missing, at: 100), .none)
        XCTAssertEqual(policy.observe(.missing, at: 103), .rebuild)
        XCTAssertEqual(policy.attempts, 2)
    }

    func testOffscreenControlCenterProxyIsNotVisibleMenu() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        XCTAssertFalse(MenuBarRecoveryPolicy.isAtMenuBar(
            frame: CGRect(x: 0, y: -6, width: 36, height: 22),
            screen: screen, thickness: 33
        ))
        XCTAssertTrue(MenuBarRecoveryPolicy.isAtMenuBar(
            frame: CGRect(x: 1022, y: 949, width: 36, height: 33),
            screen: screen, thickness: 33
        ))
        XCTAssertFalse(MenuBarRecoveryPolicy.isAtMenuBar(
            frame: CGRect(x: -100, y: 949, width: 36, height: 33),
            screen: screen, thickness: 33
        ))
        XCTAssertTrue(MenuBarRecoveryPolicy.isAtMenuBar(
            frame: CGRect(x: -100, y: 1440 - 24, width: 36, height: 24),
            screen: CGRect(x: -2560, y: 0, width: 2560, height: 1440), thickness: 24
        ))
    }
}
