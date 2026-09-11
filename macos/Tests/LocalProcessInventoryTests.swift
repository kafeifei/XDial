import Foundation
import XCTest

final class LocalProcessInventoryTests: XCTestCase {
    func testKnownSiblingPathDoesNotMatchCurrentProductBundle() {
        let siblingURL = XDialBuildIdentity.isDevelopment
            ? URL(fileURLWithPath: "/Applications/XDial.app")
            : URL(fileURLWithPath: "/Applications/Xdial debug.app")
        let entry = LocalProcessInventory.Entry(
            pid: 42,
            name: "xdial-daemon",
            executableURL: siblingURL.appendingPathComponent(
                "Contents/MacOS/xdial-daemon"
            )
        )
        XCTAssertEqual(
            entry.belongsToProductBundle(
                XDialBuildIdentity.applicationDestinationURL,
                excludingSiblingBundleURLs: [siblingURL],
                executableNames: ["xdial", "xdial-daemon"]
            ),
            false
        )
    }

    func testNameOnlyCommonExecutableHasUnknownProductChannel() {
        let entry = LocalProcessInventory.Entry(
            pid: 42,
            name: "xdial-daemon",
            executableURL: nil
        )
        XCTAssertNil(
            entry.belongsToProductBundle(
                XDialBuildIdentity.applicationDestinationURL,
                excludingSiblingBundleURLs: [
                    XDialBuildIdentity.siblingApplicationDestinationURL,
                ],
                executableNames: ["xdial", "xdial-daemon"]
            )
        )
    }

    func testNonDaemonInCurrentBundleIsNotDaemonOccupancy() {
        let entry = LocalProcessInventory.Entry(
            pid: 42,
            name: "XDial Settings UI",
            executableURL: XDialBuildIdentity.applicationDestinationURL
                .appendingPathComponent(
                    "Contents/Helpers/XDial Settings UI.app/Contents/MacOS/"
                        + "XDial Settings UI"
                )
        )
        XCTAssertEqual(
            entry.belongsToProductBundle(
                XDialBuildIdentity.applicationDestinationURL,
                excludingSiblingBundleURLs: [
                    XDialBuildIdentity.siblingApplicationDestinationURL,
                ],
                executableNames: ["xdial", "xdial-daemon"]
            ),
            false
        )
    }

    func testSameNamedDaemonAtUnclassifiedPathRemainsUnknown() {
        let entry = LocalProcessInventory.Entry(
            pid: 42,
            name: "xdial-daemon",
            executableURL: URL(
                fileURLWithPath: "/private/tmp/build/xdial-daemon"
            )
        )
        XCTAssertNil(
            entry.belongsToProductBundle(
                XDialBuildIdentity.applicationDestinationURL,
                excludingSiblingBundleURLs: [
                    XDialBuildIdentity.siblingApplicationDestinationURL,
                ],
                executableNames: ["xdial", "xdial-daemon"]
            )
        )
    }

    private let productNames: Set<String> = ["xdial", "xdial-daemon"]

    func testDeniedNameWithKnownSystemExecutableIsUnrelated() {
        for path in ["/sbin/launchd", "/usr/libexec/logd"] {
            let process = LocalProcessInventory.Entry(pid: 1, name: nil,
                executableURL: URL(fileURLWithPath: path))
            XCTAssertEqual(process.matchesExecutableName(in: productNames), false)
        }
    }

    func testDeniedNameWithHelperExecutableStillBlocksReplacement() {
        let process = LocalProcessInventory.Entry(pid: 20, name: nil,
            executableURL: URL(fileURLWithPath: "/Applications/XDial.app/Contents/MacOS/xdial-daemon"))
        XCTAssertEqual(process.matchesExecutableName(in: productNames), true)
    }

    func testUnavailablePathWithHelperNameStillBlocksReplacement() {
        let process = LocalProcessInventory.Entry(pid: 20, name: "xdial-daemon", executableURL: nil)
        XCTAssertEqual(process.matchesExecutableName(in: productNames), true)
    }

    func testPathCandidateCannotBeHiddenByDifferentProcessName() {
        let process = LocalProcessInventory.Entry(pid: 20, name: "alternate",
            executableURL: URL(fileURLWithPath: "/Applications/XDial.app/Contents/MacOS/XDial"))
        XCTAssertEqual(process.matchesExecutableName(in: productNames), true)
        let nameCandidate = LocalProcessInventory.Entry(pid: 21, name: "XDial",
            executableURL: URL(fileURLWithPath: "/different/executable"))
        XCTAssertEqual(nameCandidate.matchesExecutableName(in: productNames), true)
    }

    func testUnavailableNameAndPathRemainUnknown() {
        let process = LocalProcessInventory.Entry(pid: 20, name: nil, executableURL: nil)
        XCTAssertNil(process.matchesExecutableName(in: productNames))
    }

    func testEmptyNameIsNotProofOfAnUnrelatedProcess() {
        let process = LocalProcessInventory.Entry(pid: 20, name: "", executableURL: nil)
        XCTAssertNil(process.matchesExecutableName(in: productNames))
    }
}
