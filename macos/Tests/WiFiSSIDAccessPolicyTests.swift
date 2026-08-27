import CoreLocation
import XCTest

final class WiFiSSIDAccessPolicyTests: XCTestCase {
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
