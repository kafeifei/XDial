import AppKit
import XCTest

final class ApplicationLaunchPolicyTests: XCTestCase {
    func testMenuBarRelaunchDoesNotCreateRecentApplicationTile() {
        let configuration = NSWorkspace.OpenConfiguration()

        ApplicationLaunchPolicy.configure(configuration)

        XCTAssertFalse(configuration.addsToRecentItems)
        XCTAssertFalse(configuration.activates)
        XCTAssertTrue(configuration.createsNewApplicationInstance)
    }
}
