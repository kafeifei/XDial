import XCTest

final class ApplicationInstallationArtifactsTests: XCTestCase {
    func testSuccessfulInstallationRemovesOwnedFilesAndRegistrations() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var unregistered: [String] = []
        let artifacts = fixture.artifacts(unregister: { url in
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            unregistered.append(url.lastPathComponent)
        })
        try artifacts.withExclusiveAccess {
            try artifacts.perform { transaction in
                let staged = artifacts.stagingURL(for: transaction)
                try fixture.makeApp(at: staged, marker: "new")
                try ApplicationBundleReplacer.replace(
                    destinationURL: fixture.destination,
                    newBundleURL: staged,
                    backupName: transaction.backupName,
                    retainBackupForRecovery: true
                ) { fixture.isTrusted($0) }
            }
        }
        XCTAssertEqual(try fixture.marker(at: fixture.destination), "new")
        XCTAssertTrue(try fixture.ownedArtifacts().isEmpty)
        // The replacer may consume the stage entirely or leave its old contents;
        // any such bundle must be unregistered before removal.
        XCTAssertTrue(unregistered.allSatisfy { $0.hasPrefix(".XDial.") })
        XCTAssertTrue(unregistered.contains { $0.hasPrefix(".XDial.backup-") })
    }

    func testCopyFailureCleansIncompleteStageAndKeepsExistingApp() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let artifacts = fixture.artifacts()
        XCTAssertThrowsError(try artifacts.withExclusiveAccess {
            try artifacts.perform { transaction in
                try FileManager.default.createDirectory(
                    at: artifacts.stagingURL(for: transaction),
                    withIntermediateDirectories: false
                )
                throw TestError.copyFailed
            }
        })
        XCTAssertEqual(try fixture.marker(at: fixture.destination), "old")
        XCTAssertTrue(try fixture.ownedArtifacts().isEmpty)
    }

    func testNextLaunchCleansUnsignedPartialCopyWithOwnedReceipt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transaction = try fixture.abandonedTransaction()
        let artifacts = fixture.artifacts()
        try FileManager.default.createDirectory(
            at: artifacts.stagingURL(for: transaction),
            withIntermediateDirectories: false
        )
        try artifacts.withExclusiveAccess { try artifacts.recoverAbandonedTransactions() }
        XCTAssertTrue(try fixture.ownedArtifacts().isEmpty)
        XCTAssertEqual(try fixture.marker(at: fixture.destination), "old")
    }

    func testCrashAfterSwapCleansBackupOnlyAfterVerifyingDestination() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transaction = try fixture.abandonedTransaction()
        let backup = fixture.root.appendingPathComponent(transaction.backupName)
        try fixture.makeApp(at: backup, marker: "old")
        try Data("new".utf8).write(to: fixture.destination.appendingPathComponent("marker"))
        let artifacts = fixture.artifacts()
        try artifacts.withExclusiveAccess { try artifacts.recoverAbandonedTransactions() }
        XCTAssertEqual(try fixture.marker(at: fixture.destination), "new")
        XCTAssertTrue(try fixture.ownedArtifacts().isEmpty)
    }

    func testCrashWithMissingDestinationRestoresVerifiedBackup() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transaction = try fixture.abandonedTransaction()
        let backup = fixture.root.appendingPathComponent(transaction.backupName)
        try FileManager.default.moveItem(at: fixture.destination, to: backup)
        let artifacts = fixture.artifacts()
        try artifacts.withExclusiveAccess { try artifacts.recoverAbandonedTransactions() }
        XCTAssertEqual(try fixture.marker(at: fixture.destination), "old")
        XCTAssertTrue(try fixture.ownedArtifacts().isEmpty)
    }

    func testUnknownDestinationCannotDestroyOnlyUsableBackup() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transaction = try fixture.abandonedTransaction()
        let backup = fixture.root.appendingPathComponent(transaction.backupName)
        try fixture.makeApp(at: backup, marker: "old")
        try Data("unrelated".utf8).write(to: fixture.destination.appendingPathComponent("marker"))
        let artifacts = fixture.artifacts()
        XCTAssertThrowsError(try artifacts.withExclusiveAccess {
            try artifacts.recoverAbandonedTransactions()
        })
        XCTAssertEqual(try fixture.marker(at: backup), "old")
        XCTAssertEqual(try fixture.marker(at: fixture.destination), "unrelated")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent(transaction.receiptName).path
        ))
    }

    func testForeignReceiptDoesNotBecomeLegacyCleanupAuthority() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transaction = try fixture.abandonedTransaction(team: "another-team")
        let staged = fixture.root.appendingPathComponent(transaction.stagingName)
        try fixture.makeApp(at: staged, marker: "new")
        let artifacts = fixture.artifacts()
        try artifacts.withExclusiveAccess { try artifacts.recoverAbandonedTransactions() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent(transaction.receiptName).path
        ))
    }

    func testLegacyCleanupPreservesLiveUntrustedAndUserCopies() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let stale = fixture.root.appendingPathComponent(".XDial.install-\(UUID()).app")
        let live = fixture.root.appendingPathComponent(".XDial.backup-\(UUID()).app")
        let untrusted = fixture.root.appendingPathComponent(".XDial.install-\(UUID()).app")
        let download = fixture.root.appendingPathComponent("My XDial.app")
        for url in [stale, live, download] { try fixture.makeApp(at: url, marker: "old") }
        try fixture.makeApp(at: untrusted, marker: "unrelated")
        let expectedRegistrationPath = stale.resolvingSymlinksInPath().path
        var unregistered: [String] = []
        let artifacts = fixture.artifacts(isInUse: {
            $0.resolvingSymlinksInPath().path == live.resolvingSymlinksInPath().path
        }, unregister: {
            unregistered.append($0.resolvingSymlinksInPath().path)
        })
        try artifacts.withExclusiveAccess { try artifacts.recoverAbandonedTransactions() }
        XCTAssertEqual(unregistered, [expectedRegistrationPath])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        for url in [live, untrusted, download] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
        }
    }

    func testSymlinkArtifactCannotDeleteItsTarget() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transaction = try fixture.abandonedTransaction()
        let staged = fixture.root.appendingPathComponent(transaction.stagingName)
        try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: fixture.destination)
        let artifacts = fixture.artifacts()
        XCTAssertThrowsError(try artifacts.withExclusiveAccess {
            try artifacts.recoverAbandonedTransactions()
        })
        XCTAssertEqual(try fixture.marker(at: fixture.destination), "old")
    }

    func testCleanupFailureRetainsReceiptAndNextLaunchFinishesIt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transaction = try fixture.abandonedTransaction()
        let staged = fixture.root.appendingPathComponent(transaction.stagingName)
        try fixture.makeApp(at: staged, marker: "new")
        let failing = FailingRemovalFileManager()
        failing.failingPath = staged.path
        var artifacts = fixture.artifacts()
        artifacts.fileManager = failing
        XCTAssertThrowsError(try artifacts.withExclusiveAccess {
            try artifacts.recoverAbandonedTransactions()
        })
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent(transaction.receiptName).path
        ))
        failing.failingPath = nil
        try artifacts.withExclusiveAccess { try artifacts.recoverAbandonedTransactions() }
        XCTAssertTrue(try fixture.ownedArtifacts().isEmpty)
    }

    func testConcurrentInstallIsRejectedAndThrownOperationReleasesLock() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = fixture.artifacts()
        let second = fixture.artifacts()
        XCTAssertThrowsError(try first.withExclusiveAccess {
            XCTAssertThrowsError(try second.withExclusiveAccess { XCTFail("concurrent install") })
            throw TestError.copyFailed
        })
        XCTAssertNoThrow(try second.withExclusiveAccess {})
    }

    func testSuccessfulLaunchDefersCleanupWhenAnotherInstallerHoldsLock() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transaction = try fixture.abandonedTransaction()
        let artifacts = fixture.artifacts()
        try artifacts.withExclusiveAccess {
            XCTAssertNotNil(artifacts.recoverAfterSuccessfulLaunch())
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent(transaction.receiptName).path
            ))
        }
        XCTAssertNil(artifacts.recoverAfterSuccessfulLaunch())
        XCTAssertTrue(try fixture.ownedArtifacts().isEmpty)
    }

    func testSuccessfulLaunchDefersReadOnlyCleanupAndRetainsReceipt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transaction = try fixture.abandonedTransaction()
        let staged = fixture.root.appendingPathComponent(transaction.stagingName)
        try fixture.makeApp(at: staged, marker: "new")
        let failing = FailingRemovalFileManager()
        failing.failingPath = staged.path
        var artifacts = fixture.artifacts()
        artifacts.fileManager = failing
        XCTAssertNotNil(artifacts.recoverAfterSuccessfulLaunch())
        XCTAssertEqual(try fixture.marker(at: fixture.destination), "old")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent(transaction.receiptName).path
        ))
    }

    func testDaemonOccupancyDefersReceiptUntilDaemonExits() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transaction = try fixture.abandonedTransaction()
        let backup = fixture.root.appendingPathComponent(transaction.backupName)
        try fixture.makeApp(at: backup, marker: "old")
        var processes: LocalProcessInventory.Snapshot = .available([
            .init(pid: 42, name: "xdial-daemon",
                  executableURL: backup.appendingPathComponent("Contents/MacOS/xdial-daemon")),
        ])
        let artifacts = fixture.artifacts(isInUse: {
            ApplicationInstallationOccupancy.mayBeInUse(
                $0, processes: processes, applicationURLs: []
            )
        })
        XCTAssertNil(artifacts.recoverAfterSuccessfulLaunch())
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        processes = .available([])
        XCTAssertNil(artifacts.recoverAfterSuccessfulLaunch())
        XCTAssertTrue(try fixture.ownedArtifacts().isEmpty)
    }

    func testUnknownDaemonPathPreservesBundleButUnrelatedProcessDoesNot() {
        let bundle = URL(fileURLWithPath: "/Applications/.XDial.backup-test.app")
        for snapshot: LocalProcessInventory.Snapshot in [
            .unknown,
            .available([.init(pid: 42, name: "xdial-daemon", executableURL: nil)]),
            .available([.init(pid: 42, name: nil, executableURL: nil)]),
        ] {
            XCTAssertTrue(ApplicationInstallationOccupancy.mayBeInUse(
                bundle, processes: snapshot, applicationURLs: []
            ))
        }
        XCTAssertFalse(ApplicationInstallationOccupancy.mayBeInUse(
            bundle,
            processes: .available([.init(pid: 42, name: "WindowServer", executableURL: nil)]),
            applicationURLs: []
        ))
    }

    private enum TestError: Error { case copyFailed }

    private final class FailingRemovalFileManager: FileManager, @unchecked Sendable {
        var failingPath: String?
        override func removeItem(at URL: URL) throws {
            if URL.path == failingPath { throw TestError.copyFailed }
            try super.removeItem(at: URL)
        }
    }

    private struct Fixture {
        let root: URL
        var destination: URL { root.appendingPathComponent("XDial.app") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try makeApp(at: destination, marker: "old")
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func makeApp(at url: URL, marker: String) throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(marker.utf8).write(to: url.appendingPathComponent("marker"))
        }
        func marker(at url: URL) throws -> String {
            try String(contentsOf: url.appendingPathComponent("marker"), encoding: .utf8)
        }
        func isTrusted(_ url: URL) -> Bool {
            guard let marker = try? marker(at: url) else { return false }
            return ["old", "new"].contains(marker)
        }
        func artifacts(
            isInUse: @escaping (URL) -> Bool = { _ in false },
            unregister: @escaping (URL) throws -> Void = { _ in }
        ) -> ApplicationInstallationArtifacts {
            ApplicationInstallationArtifacts(
                destinationURL: destination,
                applicationIdentifier: "com.kafeifei.xdial.app",
                teamIdentifier: "test-team",
                isTrustedApplication: isTrusted,
                isInUse: isInUse,
                unregisterApplication: unregister
            )
        }
        func abandonedTransaction(team: String = "test-team") throws -> ApplicationInstallationArtifacts.Transaction {
            let transaction = ApplicationInstallationArtifacts.Transaction(
                schemaVersion: 1, id: UUID(),
                applicationIdentifier: "com.kafeifei.xdial.app", teamIdentifier: team
            )
            try JSONEncoder().encode(transaction).write(
                to: root.appendingPathComponent(transaction.receiptName)
            )
            return transaction
        }
        func ownedArtifacts() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
                $0.hasPrefix(".XDial.") && $0 != ".XDial.installation.lock"
            }
        }
    }
}
