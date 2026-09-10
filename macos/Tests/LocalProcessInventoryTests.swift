import Foundation
import XCTest

final class LocalProcessInventoryTests: XCTestCase {
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
