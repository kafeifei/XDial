import XCTest

final class InstallationTransactionTests: XCTestCase {
    func testSystemExtensionFilenameMustMatchBundleIdentifier() {
        let identifier = "com.kafeifei.xdial.transparent-proxy"
        XCTAssertTrue(
            SystemExtensionBundleNaming.matches(
                bundleIdentifier: identifier,
                bundleURL: URL(
                    fileURLWithPath:
                        "/Applications/XDial.app/Contents/Library/"
                        + "SystemExtensions/\(identifier).systemextension"
                )
            )
        )
        XCTAssertFalse(
            SystemExtensionBundleNaming.matches(
                bundleIdentifier: identifier,
                bundleURL: URL(
                    fileURLWithPath:
                        "/Applications/XDial.app/Contents/Library/"
                        + "SystemExtensions/"
                        + "XDialTransparentProxy.systemextension"
                )
            )
        )
    }

    func testInstallationOnlyFinishesWhenEveryTaskIsReady() {
        var report = InstallationReport.fresh(
            applicationAlreadyInstalled: true
        )
        report.finish()
        XCTAssertFalse(report.isReady)

        for task in report.tasks {
            report.updateTask(id: task.id, state: .ready)
        }
        report.finish()

        XCTAssertTrue(report.isReady)
        XCTAssertEqual(report.state, .ready)
        XCTAssertEqual(
            report.events.map(\.sequence),
            Array(1 ... report.events.count)
        )
    }

    func testApprovalAndFailureRemainAttachedToExactTask() {
        var report = InstallationReport.fresh(
            applicationAlreadyInstalled: true
        )
        report.updateTask(
            id: "system-extension",
            state: .waitingForApproval
        )
        XCTAssertEqual(report.state, .waitingForApproval)
        XCTAssertEqual(
            report.currentTask?.id,
            "system-extension"
        )

        report.fail(
            code: "extension-not-found",
            message: "找不到网络扩展",
            taskID: "system-extension"
        )
        XCTAssertEqual(report.state, .failed)
        XCTAssertEqual(report.error?.taskID, "system-extension")
        XCTAssertEqual(
            report.tasks.first {
                $0.id == "system-extension"
            }?.state,
            .failed
        )
    }

    func testRelocationPolicyNeverOverwritesDifferentIdentity() {
        XCTAssertEqual(
            ApplicationRelocationDecision.decide(
                currentIsCanonical: false,
                destinationExists: true,
                destinationMatchesIdentity: false
            ),
            .rejectExisting
        )
        XCTAssertEqual(
            ApplicationRelocationDecision.decide(
                currentIsCanonical: false,
                destinationExists: true,
                destinationMatchesIdentity: true
            ),
            .replace
        )
        XCTAssertEqual(
            ApplicationRelocationDecision.decide(
                currentIsCanonical: false,
                destinationExists: false,
                destinationMatchesIdentity: false
            ),
            .install
        )
    }

    func testBundleReplacementKeepsBackupUntilValidationSucceeds()
        throws {
        let fixture = try ReplacementFixture()
        defer { fixture.cleanup() }

        try ApplicationBundleReplacer.replace(
            destinationURL: fixture.destinationURL,
            newBundleURL: fixture.newBundleURL,
            backupName: fixture.backupName
        ) { url in
            try fixture.marker(at: url) == "new"
        }

        XCTAssertEqual(
            try fixture.marker(at: fixture.destinationURL),
            "new"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.backupURL.path
            )
        )
    }

    func testBundleReplacementRestoresBackupAfterValidationFailure()
        throws {
        let fixture = try ReplacementFixture()
        defer { fixture.cleanup() }

        XCTAssertThrowsError(
            try ApplicationBundleReplacer.replace(
                destinationURL: fixture.destinationURL,
                newBundleURL: fixture.newBundleURL,
                backupName: fixture.backupName
            ) { _ in false }
        )

        XCTAssertEqual(
            try fixture.marker(at: fixture.destinationURL),
            "old"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.backupURL.path
            )
        )
    }
}

private final class ReplacementFixture {
    let rootURL: URL
    let destinationURL: URL
    let newBundleURL: URL
    let backupName = ".XDial.backup.app"

    var backupURL: URL {
        rootURL.appendingPathComponent(
            backupName,
            isDirectory: true
        )
    }

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "xdial-replacement-\(UUID().uuidString)",
                isDirectory: true
            )
        destinationURL = rootURL.appendingPathComponent(
            "XDial.fixture",
            isDirectory: true
        )
        newBundleURL = rootURL.appendingPathComponent(
            "new.fixture",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: destinationURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: newBundleURL,
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(
            to: destinationURL.appendingPathComponent("marker")
        )
        try Data("new".utf8).write(
            to: newBundleURL.appendingPathComponent("marker")
        )
    }

    func marker(at url: URL) throws -> String {
        let data = try Data(
            contentsOf: url.appendingPathComponent("marker")
        )
        return String(decoding: data, as: UTF8.self)
    }

    func cleanup() {
        if FileManager.default.fileExists(atPath: rootURL.path) {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }
}
