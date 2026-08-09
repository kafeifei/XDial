import XCTest

final class AppUpdateCheckerTests: XCTestCase {
    func testNewerReleaseTagIsAvailable() {
        XCTAssertTrue(VersionUpdatePolicy.isNewer(
            latestTag: "v0.8.0",
            than: "0.7.0"
        ))
    }

    func testEquivalentAndOlderTagsAreNotAvailable() {
        XCTAssertFalse(VersionUpdatePolicy.isNewer(
            latestTag: "v0.7",
            than: "0.7.0"
        ))
        XCTAssertFalse(VersionUpdatePolicy.isNewer(
            latestTag: "v0.6.9",
            than: "0.7.0"
        ))
    }

    func testMalformedTagDoesNotProduceUpdate() {
        XCTAssertFalse(VersionUpdatePolicy.isNewer(
            latestTag: "nightly",
            than: "0.7.0"
        ))
    }
}
