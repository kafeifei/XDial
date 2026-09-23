import XCTest

final class TailscaleControlTests: XCTestCase {
    func testConnectedIdentityCanRefreshAndResumeLogin() {
        for command in [TailscaleControlCommand.status, .login] {
            let request = TailscaleControlRequest(transactionID: "tx", identityProfileID: "profile-a", command: command)
            XCTAssertNil(TailscaleControlPolicy.rejection(request: request, transactionID: "tx",
                committed: true, switching: false, activeIdentity: "profile-a"))
        }
    }

    func testOnlyUnusedIdentityMayFallBackToSetup() {
        let request = TailscaleControlRequest(transactionID: "tx", identityProfileID: "profile-b", command: .login)
        XCTAssertEqual(TailscaleControlPolicy.rejection(request: request, transactionID: "tx",
            committed: true, switching: false, activeIdentity: "profile-a"), "identity-not-active")
        // A stale response or a prepared switch must never authorize a second writer.
        XCTAssertEqual(TailscaleControlPolicy.rejection(request: request, transactionID: "new-tx",
            committed: true, switching: false, activeIdentity: "profile-a"), "transaction-mismatch")
        XCTAssertEqual(TailscaleControlPolicy.rejection(request: request, transactionID: "tx",
            committed: true, switching: true, activeIdentity: "profile-a"), "connection-busy")
        XCTAssertEqual(TailscaleControlPolicy.rejection(request: request, transactionID: "tx",
            committed: false, switching: false, activeIdentity: nil), "connection-busy")
    }

    func testLogoutCannotInvalidateCommittedIdentity() {
        let request = TailscaleControlRequest(transactionID: "tx", identityProfileID: "profile-a", command: .logout)
        XCTAssertEqual(TailscaleControlPolicy.rejection(request: request, transactionID: "tx",
            committed: true, switching: false, activeIdentity: "profile-a"), "identity-in-use")
        XCTAssertEqual(TailscaleControlPolicy.rejection(request: request, transactionID: "tx",
            committed: true, switching: false, activeIdentity: "profile-b"), "identity-not-active")
    }

    func testSetupPayloadCannotClaimProviderOwnership() throws {
        let status = try JSONDecoder().decode(TailscaleRuntimeStatus.self, from: Data(
            #"{"backend_state":"Running","auth_url":"","exit_nodes":[],"device_name":"xdial-debug-device","isInUse":true}"#.utf8))
        XCTAssertFalse(status.isInUse)
        XCTAssertEqual(status.deviceName, "xdial-debug-device")
    }

    func testMalformedIdentityNeverAuthorizesSetup() {
        let request = TailscaleControlRequest(transactionID: "tx", identityProfileID: "", command: .status)
        XCTAssertEqual(TailscaleControlPolicy.rejection(request: request, transactionID: "tx",
            committed: true, switching: false, activeIdentity: nil), "invalid-request")
    }
}

final class TailscaleConfigurationLeaseTests: XCTestCase {
    func testHandoffWaitsForAcceptedOperationsAndBlocksNewLogin() {
        let lease = TailscaleConfigurationLease()
        XCTAssertTrue(lease.begin())
        XCTAssertTrue(lease.begin())
        var released = false
        lease.suspend { released = true }
        XCTAssertFalse(released)
        XCTAssertFalse(lease.begin())
        lease.end()
        XCTAssertFalse(released)
        lease.end()
        XCTAssertTrue(released)
        XCTAssertFalse(lease.begin())
        lease.resume()
        XCTAssertTrue(lease.begin())
        lease.end()
    }

    func testIdleHandoffRunsImmediately() {
        let lease = TailscaleConfigurationLease()
        var released = false
        lease.suspend { released = true }
        XCTAssertTrue(released)
        lease.resume()
        XCTAssertFalse(lease.suspended)
    }
}
