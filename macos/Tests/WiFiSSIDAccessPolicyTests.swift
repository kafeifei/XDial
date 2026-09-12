import CoreLocation
import XCTest

final class WiFiSSIDAccessPolicyTests: XCTestCase {
    func testAuthorizedColdLaunchDoesNotPresentSetupForProvisionalStatus() {
        var lifecycle = WiFiSSIDAccessLifecycle()
        var check = WiFiSSIDInitialAccessCheck()
        let provisional = lifecycle.accessState(for: .notDetermined)
        XCTAssertEqual(provisional, .checking)
        XCTAssertFalse(check.shouldPresent(accessState: provisional, requiresSSIDAccess: true))

        lifecycle.authorizationDidChange()
        let resolved = lifecycle.accessState(for: .authorizedAlways)
        XCTAssertEqual(resolved, .ready)
        XCTAssertFalse(check.shouldPresent(accessState: resolved, requiresSSIDAccess: true))
    }

    func testUnresolvedInitialCheckDoesNotConsumeRealPermissionPrompt() {
        for status in [CLAuthorizationStatus.notDetermined, .denied, .restricted] {
            var lifecycle = WiFiSSIDAccessLifecycle()
            var check = WiFiSSIDInitialAccessCheck()
            XCTAssertFalse(check.shouldPresent(
                accessState: lifecycle.accessState(for: status), requiresSSIDAccess: true
            ))
            lifecycle.authorizationDidChange()
            let resolved = lifecycle.accessState(for: status)
            XCTAssertTrue(check.shouldPresent(accessState: resolved, requiresSSIDAccess: true))
            XCTAssertFalse(check.shouldPresent(accessState: resolved, requiresSSIDAccess: true))
        }
    }

    func testNoSSIDBindingsDoNotPresentPermissionSetup() {
        var check = WiFiSSIDInitialAccessCheck()
        XCTAssertFalse(check.shouldPresent(accessState: .permissionRequired, requiresSSIDAccess: false))
    }

    func testAuthorizationChangeInvalidatesQueuedPermissionPromptBeforeSSIDRead() {
        var lifecycle = WiFiSSIDAccessLifecycle()
        var check = WiFiSSIDInitialAccessCheck()
        lifecycle.authorizationDidChange()
        let oldState = lifecycle.accessState(for: .notDetermined)
        let queuedRevision = lifecycle.invalidatePendingUpdates()

        // The old notification may already be queued in AppState's MainActor
        // task when the authorization callback arrives, before SSID refresh.
        lifecycle.authorizationDidChange()
        XCTAssertFalse(lifecycle.isCurrentUpdate(queuedRevision))
        if lifecycle.isCurrentUpdate(queuedRevision) {
            XCTFail("Stale permission status reached the setup decision")
            _ = check.shouldPresent(accessState: oldState, requiresSSIDAccess: true)
        }
        let readyRevision = lifecycle.invalidatePendingUpdates()
        XCTAssertTrue(lifecycle.isCurrentUpdate(readyRevision))
        XCTAssertFalse(check.shouldPresent(
            accessState: lifecycle.accessState(for: .authorizedAlways), requiresSSIDAccess: true
        ))
    }

    func testLaterSSIDObservationSupersedesQueuedObservation() {
        var lifecycle = WiFiSSIDAccessLifecycle()
        lifecycle.authorizationDidChange()
        let oldRevision = lifecycle.invalidatePendingUpdates()
        let newRevision = lifecycle.invalidatePendingUpdates()
        XCTAssertFalse(lifecycle.isCurrentUpdate(oldRevision))
        XCTAssertTrue(lifecycle.isCurrentUpdate(newRevision))
        lifecycle.invalidatePendingUpdates() // stopping or a synchronous epoch sample
        XCTAssertFalse(lifecycle.isCurrentUpdate(newRevision))
    }

    func testPermissionRevocationStillHasDeniedStateAfterInitialization() {
        var lifecycle = WiFiSSIDAccessLifecycle()
        lifecycle.authorizationDidChange()
        XCTAssertEqual(lifecycle.accessState(for: .authorizedAlways), .ready)
        lifecycle.authorizationDidChange()
        XCTAssertEqual(lifecycle.accessState(for: .denied), .denied)
    }

    func testAuthorizedStatusCanReadSSIDWithoutAnotherPrompt() {
        XCTAssertEqual(
            WiFiSSIDAccessPolicy.accessState(for: .authorizedAlways),
            .ready
        )
        XCTAssertEqual(
            WiFiSSIDAccessPolicy.requestDisposition(for: .authorizedAlways),
            .refreshed
        )
    }

    func testUndeterminedStatusRequestsAuthorizationFromExplicitAction() {
        XCTAssertEqual(
            WiFiSSIDAccessPolicy.accessState(for: .notDetermined),
            .permissionRequired
        )
        XCTAssertEqual(
            WiFiSSIDAccessPolicy.requestDisposition(for: .notDetermined),
            .authorizationRequested
        )
    }

    func testDeniedAndRestrictedStatusesDirectUserToSystemSettings() {
        for status in [
            CLAuthorizationStatus.denied,
            .restricted,
        ] {
            XCTAssertEqual(
                WiFiSSIDAccessPolicy.accessState(for: status),
                .denied
            )
            XCTAssertEqual(
                WiFiSSIDAccessPolicy.requestDisposition(for: status),
                .openSystemSettings
            )
        }
    }
}
