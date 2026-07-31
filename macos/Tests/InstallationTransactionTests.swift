import XCTest

final class InstallationTransactionTests: XCTestCase {
    func testReplacementExitWaiterExcludesCurrentInvalidAndDuplicates() {
        XCTAssertEqual(
            ApplicationReplacementExitWaiter
                .otherProcessIdentifiers(
                    currentProcessIdentifier: 42,
                    candidateProcessIdentifiers:
                        [0, -1, 42, 81, 81, 82]
                ),
            Set([81, 82])
        )
    }

    func testReplacementExitWaiterUsesFreshSnapshotUntilExit() {
        var now: TimeInterval = 10
        var snapshots = [
            Set<Int32>([81]),
            Set<Int32>([81]),
            Set<Int32>(),
        ]
        var sleepCount = 0

        XCTAssertTrue(
            ApplicationReplacementExitWaiter.wait(
                timeout: 5,
                pollInterval: 0.5,
                monotonicNow: { now },
                sleep: {
                    sleepCount += 1
                    now += $0
                },
                requestGracefulTermination: { _ in },
                remainingProcessIdentifiers: {
                    snapshots.removeFirst()
                }
            )
        )
        XCTAssertEqual(sleepCount, 2)
        XCTAssertEqual(now, 11)
    }

    func testReplacementExitWaiterStopsAtDeadline() {
        var now: TimeInterval = 20
        var sleepDurations: [TimeInterval] = []

        XCTAssertFalse(
            ApplicationReplacementExitWaiter.wait(
                timeout: 1,
                pollInterval: 0.4,
                monotonicNow: { now },
                sleep: {
                    sleepDurations.append($0)
                    now += $0
                },
                requestGracefulTermination: { _ in },
                remainingProcessIdentifiers: {
                    Set<Int32>([81])
                }
            )
        )
        XCTAssertEqual(
            sleepDurations.reduce(0, +),
            1,
            accuracy: 0.000_001
        )
    }

    func testReplacementExitWaiterReturnsImmediatelyWhenAlreadyGone() {
        var slept = false

        XCTAssertTrue(
            ApplicationReplacementExitWaiter.wait(
                timeout: 12,
                pollInterval: 0.05,
                monotonicNow: { 100 },
                sleep: { _ in slept = true },
                requestGracefulTermination: { _ in },
                remainingProcessIdentifiers: { [] }
            )
        )
        XCTAssertFalse(slept)
    }

    func testReplacementExitWaiterRequestsNewProcessOnce() {
        var now: TimeInterval = 10
        var snapshots = [
            Set<Int32>([81]),
            Set<Int32>([81, 82]),
            Set<Int32>([82]),
            Set<Int32>(),
        ]
        var requested: [Int32] = []

        XCTAssertTrue(
            ApplicationReplacementExitWaiter.wait(
                timeout: 5,
                pollInterval: 0.5,
                monotonicNow: { now },
                sleep: { now += $0 },
                requestGracefulTermination: {
                    requested.append($0)
                },
                remainingProcessIdentifiers: {
                    snapshots.removeFirst()
                }
            )
        )
        XCTAssertEqual(requested, [81, 82])
    }

    func testReplacementExitWaiterDoesNotRepeatVisibleProcess() {
        var now: TimeInterval = 10
        var snapshots = [
            Set<Int32>([81]),
            Set<Int32>([81]),
            Set<Int32>([81]),
            Set<Int32>(),
        ]
        var requested: [Int32] = []

        XCTAssertTrue(
            ApplicationReplacementExitWaiter.wait(
                timeout: 5,
                pollInterval: 0.5,
                monotonicNow: { now },
                sleep: { now += $0 },
                requestGracefulTermination: {
                    requested.append($0)
                },
                remainingProcessIdentifiers: {
                    snapshots.removeFirst()
                }
            )
        )
        XCTAssertEqual(requested, [81])
    }

    func testReplacementExitWaiterRequestsReappearingProcessAgain() {
        var now: TimeInterval = 10
        var snapshots = [
            Set<Int32>([81, 82]),
            Set<Int32>([82]),
            Set<Int32>([81, 82]),
            Set<Int32>(),
        ]
        var requested: [Int32] = []

        XCTAssertTrue(
            ApplicationReplacementExitWaiter.wait(
                timeout: 5,
                pollInterval: 0.5,
                monotonicNow: { now },
                sleep: { now += $0 },
                requestGracefulTermination: {
                    requested.append($0)
                },
                remainingProcessIdentifiers: {
                    snapshots.removeFirst()
                }
            )
        )
        XCTAssertEqual(requested, [81, 82, 81])
    }

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

    func testInstallationMarkerInvalidatesOlderReportSchema() {
        XCTAssertEqual(
            InstallationBuildMarker.make(
                bundleIdentifier: "com.kafeifei.xdial",
                bundleVersion: "79"
            ),
            "com.kafeifei.xdial:79:installation-v4"
        )
    }

    func testSystemExtensionOnlyVerifiesCurrentEnabledVersion() {
        let expected = SystemExtensionPropertySnapshot(
            bundleIdentifier:
                "com.kafeifei.xdial.transparent-proxy",
            bundleVersion: "79",
            isEnabled: true,
            isAwaitingUserApproval: false,
            isUninstalling: false
        )
        XCTAssertTrue(
            SystemExtensionActivationVerifier
                .containsReadyCurrentVersion(
                    [expected],
                    expectedIdentifier:
                        "com.kafeifei.xdial.transparent-proxy",
                    expectedVersion: "79"
                )
        )
        XCTAssertFalse(
            SystemExtensionActivationVerifier
                .containsReadyCurrentVersion(
                    [
                        SystemExtensionPropertySnapshot(
                            bundleIdentifier:
                                expected.bundleIdentifier,
                            bundleVersion: "78",
                            isEnabled: true,
                            isAwaitingUserApproval: false,
                            isUninstalling: false
                        ),
                    ],
                    expectedIdentifier:
                        expected.bundleIdentifier,
                    expectedVersion: "79"
                )
        )
        XCTAssertFalse(
            SystemExtensionActivationVerifier
                .containsReadyCurrentVersion(
                    [
                        SystemExtensionPropertySnapshot(
                            bundleIdentifier:
                                expected.bundleIdentifier,
                            bundleVersion:
                                expected.bundleVersion,
                            isEnabled: false,
                            isAwaitingUserApproval: false,
                            isUninstalling: false
                        ),
                    ],
                    expectedIdentifier:
                        expected.bundleIdentifier,
                    expectedVersion: expected.bundleVersion
                )
        )
    }

    func testRelocationAllowsKnownDebugReleaseReplacementForSameTeam() {
        XCTAssertTrue(
            XDialApplicationIdentifierPolicy.permitsReplacement(
                existingIdentifier:
                    XDialApplicationIdentifierPolicy.release,
                incomingIdentifier:
                    XDialApplicationIdentifierPolicy.debug,
                teamIdentifiersMatch: true
            )
        )
        XCTAssertFalse(
            XDialApplicationIdentifierPolicy.permitsReplacement(
                existingIdentifier:
                    XDialApplicationIdentifierPolicy.release,
                incomingIdentifier:
                    XDialApplicationIdentifierPolicy.debug,
                teamIdentifiersMatch: false
            )
        )
        XCTAssertFalse(
            XDialApplicationIdentifierPolicy.permitsReplacement(
                existingIdentifier: "com.example.not-xdial",
                incomingIdentifier:
                    XDialApplicationIdentifierPolicy.debug,
                teamIdentifiersMatch: true
            )
        )
    }

    func testInstallationOnlyFinishesWhenEveryTaskIsReady() {
        var report = InstallationReport.fresh(
            applicationAlreadyInstalled: true
        )
        XCTAssertEqual(report.schemaVersion, 4)
        XCTAssertEqual(
            report.tasks.last?.id,
            "system-extension"
        )
        XCTAssertFalse(
            report.tasks.contains {
                $0.id == "system-extension-cleanup"
            }
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
