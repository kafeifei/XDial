import XCTest

final class TransparentProxyRollbackPolicyTests: XCTestCase {
    func testProviderStopWaitsForSystemDisconnectAfterCommit() {
        XCTAssertEqual(
            TransparentProxyNetworkSettingsRollbackAction.providerStop(
                settingsCommitted: true
            ),
            .awaitSystemDisconnect
        )
    }

    func testProviderStopNeedsNoRemovalBeforeCommit() {
        XCTAssertEqual(
            TransparentProxyNetworkSettingsRollbackAction.providerStop(
                settingsCommitted: false
            ),
            .alreadyAbsent
        )
    }
}
