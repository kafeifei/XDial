import Darwin
import XCTest

final class ApplicationInstallationQuarantineTests: XCTestCase {
    func testCopyPreparationPreservesDownloadAndUnrelatedAttributes() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let nested = fixture.source.appendingPathComponent(
            "Contents/Helpers/Nested.app/.hidden"
        )
        try FileManager.default.createDirectory(
            at: nested.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("payload".utf8).write(to: nested)
        try fixture.quarantine(fixture.source)
        try fixture.quarantine(nested)
        try fixture.attribute("user.xdial-test", at: nested)
        try fixture.quarantine(fixture.outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.source.appendingPathComponent("external"),
            withDestinationURL: fixture.outside
        )
        try FileManager.default.copyItem(
            at: fixture.source, to: fixture.staged
        )

        try ApplicationInstallationQuarantine.prepareValidatedCopy(
            at: fixture.staged
        )
        try ApplicationInstallationQuarantine.validateInstalledCopy(
            at: fixture.staged
        )
        // Preparation is idempotent, including already-unquarantined files.
        try ApplicationInstallationQuarantine.prepareValidatedCopy(
            at: fixture.staged
        )
        XCTAssertTrue(fixture.hasQuarantine(fixture.source))
        XCTAssertTrue(fixture.hasQuarantine(nested))
        XCTAssertTrue(fixture.hasQuarantine(fixture.outside))
        XCTAssertTrue(fixture.hasAttribute(
            "user.xdial-test",
            at: fixture.staged.appendingPathComponent(
                "Contents/Helpers/Nested.app/.hidden"
            )
        ))
        XCTAssertEqual(
            try Data(contentsOf: fixture.staged.appendingPathComponent(
                "Contents/Helpers/Nested.app/.hidden"
            )), Data("payload".utf8)
        )
    }

    func testReplacementOfQuarantinedDestinationStaysUnquarantined() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.quarantine(fixture.source)
        try fixture.quarantine(fixture.destination)
        try FileManager.default.copyItem(at: fixture.source, to: fixture.staged)
        try ApplicationInstallationQuarantine.prepareValidatedCopy(
            at: fixture.staged
        )

        try ApplicationBundleReplacer.replace(
            destinationURL: fixture.destination,
            newBundleURL: fixture.staged,
            backupName: "backup.app"
        ) { installed in
            try ApplicationInstallationQuarantine.validateInstalledCopy(
                at: installed
            )
            return true
        }

        XCTAssertFalse(fixture.hasQuarantine(fixture.destination))
        XCTAssertTrue(fixture.hasQuarantine(fixture.source))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent("backup.app").path
        ))
    }

    func testUnexpectedQuarantineAfterReplacementRestoresOldBundle() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try Data("old".utf8).write(
            to: fixture.destination.appendingPathComponent("marker")
        )
        try FileManager.default.copyItem(at: fixture.source, to: fixture.staged)
        XCTAssertThrowsError(try ApplicationBundleReplacer.replace(
            destinationURL: fixture.destination,
            newBundleURL: fixture.staged,
            backupName: "backup.app"
        ) { installed in
            try fixture.quarantine(installed)
            try ApplicationInstallationQuarantine.validateInstalledCopy(
                at: installed
            )
            return true
        })
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appendingPathComponent("marker")),
            Data("old".utf8)
        )
    }

    func testPreparationFailsWhenQuarantineCannotBeRemoved() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.copyItem(at: fixture.source, to: fixture.staged)
        try fixture.quarantine(fixture.staged)
        try FileManager.default.setAttributes(
            [.immutable: true], ofItemAtPath: fixture.staged.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.immutable: false], ofItemAtPath: fixture.staged.path
            )
        }
        XCTAssertThrowsError(
            try ApplicationInstallationQuarantine.prepareValidatedCopy(
                at: fixture.staged
            )
        )
        XCTAssertTrue(fixture.hasQuarantine(fixture.staged))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.destination.path
        ))
    }

    func testMissingOrSymlinkRootIsRejectedWithoutTouchingTarget() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        XCTAssertThrowsError(
            try ApplicationInstallationQuarantine.prepareValidatedCopy(
                at: fixture.staged
            )
        )
        try fixture.quarantine(fixture.source)
        try FileManager.default.createSymbolicLink(
            at: fixture.staged, withDestinationURL: fixture.source
        )
        XCTAssertThrowsError(
            try ApplicationInstallationQuarantine.prepareValidatedCopy(
                at: fixture.staged
            )
        )
        XCTAssertTrue(fixture.hasQuarantine(fixture.source))
    }

    private struct Fixture {
        let root: URL
        var source: URL { root.appendingPathComponent("download.app") }
        var staged: URL { root.appendingPathComponent("staged.app") }
        var destination: URL { root.appendingPathComponent("installed.app") }
        var outside: URL { root.appendingPathComponent("outside") }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            for url in [source, destination, outside] {
                try FileManager.default.createDirectory(
                    at: url, withIntermediateDirectories: true
                )
            }
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func quarantine(_ url: URL) throws {
            try attribute("com.apple.quarantine", at: url)
        }
        func attribute(_ name: String, at url: URL) throws {
            let value = "0081;00000000;XDialTest;"
            let result = value.withCString {
                setxattr(url.path, name, $0, value.utf8.count, 0, XATTR_NOFOLLOW)
            }
            if result != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        func hasQuarantine(_ url: URL) -> Bool {
            hasAttribute("com.apple.quarantine", at: url)
        }
        func hasAttribute(_ name: String, at url: URL) -> Bool {
            getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0
        }
    }
}
