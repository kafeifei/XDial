import Foundation
import XCTest

final class SiblingProductProcessIdentityTests: XCTestCase {
    private let sibling = XDialBuildIdentity.InstalledChannel(
        applicationIdentifier: "com.kafeifei.xdial.debug", bundleName: "XDail Debug.app",
        daemonSocketPath: "/tmp/xdial-debug.sock"
    )

    func testRunningSiblingApplicationRemainsIdentifiedWithoutExecutablePath() {
        XCTAssertTrue(SiblingProductProcessIdentity.contains(42, channels: [sibling], application: { _ in
            .init(identifier: self.sibling.applicationIdentifier, bundleURL: self.sibling.bundleURL)
        }, daemonPeer: { _ in XCTFail("App identity already resolved"); return nil }))
    }

    func testBundlePathOrIdentifierAloneCannotIdentifySibling() {
        for app in [
            SiblingProductProcessIdentity.Application(identifier: "com.kafeifei.xdial.next", bundleURL: sibling.bundleURL),
            .init(identifier: sibling.applicationIdentifier, bundleURL: URL(fileURLWithPath: "/tmp/Other.app"))
        ] {
            XCTAssertFalse(SiblingProductProcessIdentity.contains(42, channels: [sibling], application: { _ in app }, daemonPeer: { _ in nil }))
        }
    }

    func testOnlyMatchingRootSocketPeerCanIdentifySiblingDaemon() {
        for (peer, expected) in [
            (SiblingProductProcessIdentity.Peer(pid: 42, uid: 0), true),
            (.init(pid: 99, uid: 0), false),
            (.init(pid: 42, uid: 501), false)
        ] {
            XCTAssertEqual(SiblingProductProcessIdentity.contains(42, channels: [sibling], application: { _ in nil }, daemonPeer: { path in
                XCTAssertEqual(path, self.sibling.daemonSocketPath)
                return peer
            }), expected)
        }
    }

    func testMissingFactsNeverClearAnUnknownProcess() {
        XCTAssertFalse(SiblingProductProcessIdentity.contains(42, channels: [sibling], application: { _ in nil }, daemonPeer: { _ in nil }))
        XCTAssertFalse(XDialBuildIdentity.siblingChannels.contains { $0.applicationIdentifier == XDialBuildIdentity.applicationIdentifier })
        XCTAssertFalse(XDialBuildIdentity.siblingChannels.contains { $0.daemonSocketPath == XDialBuildIdentity.daemonSocketPath })
    }
}
