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

    func testExtensionReadinessNeverInstallsFromConnectionOrVerification() {
        let identifier = "com.kafeifei.xdial.app.transparent-proxy"
        let unavailableSnapshots: [[SystemExtensionPropertySnapshot]] = [
            [],
            [.init(bundleIdentifier: identifier, bundleVersion: "78",
                   isEnabled: true, isAwaitingUserApproval: false,
                   isUninstalling: false)],
            [.init(bundleIdentifier: identifier, bundleVersion: "79",
                   isEnabled: false, isAwaitingUserApproval: false,
                   isUninstalling: false)],
            [.init(bundleIdentifier: identifier, bundleVersion: "79",
                   isEnabled: true, isAwaitingUserApproval: true,
                   isUninstalling: false)],
            [.init(bundleIdentifier: identifier, bundleVersion: "79",
                   isEnabled: true, isAwaitingUserApproval: false,
                   isUninstalling: true)],
        ]
        for properties in unavailableSnapshots {
            for phase in [SystemExtensionActivationVerifier.Phase.connection,
                          .installationCompletion] {
                XCTAssertEqual(SystemExtensionActivationVerifier.action(
                    for: properties, expectedIdentifier: identifier,
                    expectedVersion: "79", phase: phase
                ), .unavailable)
            }
            XCTAssertEqual(SystemExtensionActivationVerifier.action(
                for: properties, expectedIdentifier: identifier,
                expectedVersion: "79", phase: .installationPreflight
            ), .activate)
        }
    }

    func testRepeatedInstallationAcceptsCurrentVersionAlongsideRetiredVersions() {
        let identifier = "com.kafeifei.xdial.app.transparent-proxy"
        let properties: [SystemExtensionPropertySnapshot] = [
            .init(bundleIdentifier: identifier, bundleVersion: "78",
                  isEnabled: false, isAwaitingUserApproval: false,
                  isUninstalling: true),
            .init(bundleIdentifier: identifier, bundleVersion: "79",
                  isEnabled: true, isAwaitingUserApproval: false,
                  isUninstalling: false),
        ]
        for phase in [SystemExtensionActivationVerifier.Phase.connection,
                      .installationPreflight, .installationCompletion] {
            XCTAssertEqual(SystemExtensionActivationVerifier.action(
                for: properties, expectedIdentifier: identifier,
                expectedVersion: "79", phase: phase
            ), .ready)
        }
    }

    func testRelocationAllowsKnownApplicationReplacementForSameTeam() {
        XCTAssertEqual(
            XDialApplicationIdentifierPolicy.permitsReplacement(
                existingIdentifier:
                    XDialApplicationIdentifierPolicy.legacyRelease,
                incomingIdentifier:
                    XDialBuildIdentity.applicationIdentifier,
                teamIdentifiersMatch: true
            ),
            XDialBuildIdentity.allowsFormalDataMigration
        )
        XCTAssertTrue(
            XDialApplicationIdentifierPolicy.permitsReplacement(
                existingIdentifier: XDialBuildIdentity.applicationIdentifier,
                incomingIdentifier: XDialBuildIdentity.applicationIdentifier,
                teamIdentifiersMatch: true
            )
        )
        XCTAssertFalse(
            XDialApplicationIdentifierPolicy.permitsReplacement(
                existingIdentifier:
                    XDialApplicationIdentifierPolicy.release,
                incomingIdentifier:
                    XDialApplicationIdentifierPolicy.legacyProbe,
                teamIdentifiersMatch: true
            )
        )
        XCTAssertFalse(
            XDialApplicationIdentifierPolicy.permitsReplacement(
                existingIdentifier: XDialApplicationIdentifierPolicy.release,
                incomingIdentifier: XDialApplicationIdentifierPolicy.development,
                teamIdentifiersMatch: true
            )
        )
        XCTAssertFalse(
            XDialApplicationIdentifierPolicy.permitsReplacement(
                existingIdentifier: XDialApplicationIdentifierPolicy.development,
                incomingIdentifier: XDialApplicationIdentifierPolicy.release,
                teamIdentifiersMatch: true
            )
        )
    }

    func testOnlyCanonicalApplicationCanBeAnInstallationSource() {
        XCTAssertTrue(
            XDialApplicationIdentifierPolicy
                .permitsIncomingInstallation(
                    identifier: XDialBuildIdentity.applicationIdentifier
                )
        )
        XCTAssertFalse(
            XDialApplicationIdentifierPolicy
                .permitsIncomingInstallation(
                    identifier:
                        XDialApplicationIdentifierPolicy.legacyProbe
                )
        )
        XCTAssertFalse(
            XDialApplicationIdentifierPolicy
                .permitsIncomingInstallation(
                    identifier:
                        XDialApplicationIdentifierPolicy.legacyRelease
                )
        )
    }

    func testReleaseUnregistersObsoleteApplicationIdentities() {
        let expected: Set<String> = XDialBuildIdentity.allowsFormalDataMigration
            ? [
                XDialApplicationIdentifierPolicy.legacyProbe,
                XDialApplicationIdentifierPolicy.legacyRelease,
            ]
            : []
        XCTAssertEqual(
            XDialApplicationIdentifierPolicy.obsoleteIdentifiers(
                forInstalledIdentifier:
                    XDialBuildIdentity.applicationIdentifier
            ),
            expected
        )
        XCTAssertEqual(
            XDialApplicationIdentifierPolicy.obsoleteIdentifiers(
                forInstalledIdentifier:
                    XDialApplicationIdentifierPolicy.legacyProbe
            ),
            []
        )
        XCTAssertEqual(
            XDialApplicationIdentifierPolicy.obsoleteIdentifiers(
                forInstalledIdentifier: "com.example.not-xdial"
            ),
            []
        )
    }

    func testReleaseUnregistersNonInstalledApplicationCopies() {
        XCTAssertTrue(
            XDialApplicationIdentifierPolicy
                .shouldUnregisterApplicationRegistration(
                    installedIdentifier:
                        XDialBuildIdentity.applicationIdentifier,
                    registeredIdentifier:
                        XDialBuildIdentity.applicationIdentifier,
                    onDiskIdentifier:
                        XDialBuildIdentity.applicationIdentifier,
                    isInstalledDestination: false
                )
        )
        XCTAssertEqual(
            XDialApplicationIdentifierPolicy
                .shouldUnregisterApplicationRegistration(
                    installedIdentifier:
                        XDialBuildIdentity.applicationIdentifier,
                    registeredIdentifier:
                        XDialApplicationIdentifierPolicy.legacyRelease,
                    onDiskIdentifier:
                        XDialApplicationIdentifierPolicy.legacyRelease,
                    isInstalledDestination: false
                ),
            XDialBuildIdentity.allowsFormalDataMigration
        )
        XCTAssertFalse(
            XDialApplicationIdentifierPolicy
                .shouldUnregisterApplicationRegistration(
                    installedIdentifier:
                        XDialBuildIdentity.applicationIdentifier,
                    registeredIdentifier:
                        XDialBuildIdentity.applicationIdentifier,
                    onDiskIdentifier:
                        XDialBuildIdentity.applicationIdentifier,
                    isInstalledDestination: true
                )
        )
        XCTAssertEqual(
            XDialApplicationIdentifierPolicy
                .shouldUnregisterApplicationRegistration(
                    installedIdentifier:
                        XDialBuildIdentity.applicationIdentifier,
                    registeredIdentifier:
                        XDialApplicationIdentifierPolicy.legacyProbe,
                    onDiskIdentifier:
                        XDialApplicationIdentifierPolicy.legacyProbe,
                    isInstalledDestination: false
                ),
            XDialBuildIdentity.allowsFormalDataMigration
        )
        XCTAssertFalse(
            XDialApplicationIdentifierPolicy
                .shouldUnregisterApplicationRegistration(
                    installedIdentifier:
                        XDialApplicationIdentifierPolicy.legacyProbe,
                    registeredIdentifier:
                        XDialBuildIdentity.applicationIdentifier,
                    onDiskIdentifier:
                        XDialApplicationIdentifierPolicy.release,
                    isInstalledDestination: false
                )
        )
        XCTAssertEqual(
            XDialApplicationIdentifierPolicy
                .shouldUnregisterApplicationRegistration(
                    installedIdentifier:
                        XDialApplicationIdentifierPolicy.release,
                    registeredIdentifier:
                        XDialApplicationIdentifierPolicy.legacyProbe,
                    onDiskIdentifier:
                        XDialApplicationIdentifierPolicy.release,
                    isInstalledDestination: false
                ),
            XDialBuildIdentity.allowsFormalDataMigration
        )
        XCTAssertFalse(
            XDialApplicationIdentifierPolicy
                .shouldUnregisterApplicationRegistration(
                    installedIdentifier:
                        XDialApplicationIdentifierPolicy.release,
                    registeredIdentifier:
                        XDialApplicationIdentifierPolicy.legacyProbe,
                    onDiskIdentifier:
                        XDialApplicationIdentifierPolicy.release,
                    isInstalledDestination: true
                )
        )
    }

    func testOutgoingCleanupPlansForIdentityOrComponentMigration() throws {
        let existingURL = XDialBuildIdentity.applicationDestinationURL
        XCTAssertEqual(
            OutgoingApplicationCleanup.plan(
                existingBundleURL: existingURL,
                existingIdentifier:
                    XDialApplicationIdentifierPolicy.legacyProbe,
                incomingIdentifier:
                    XDialBuildIdentity.applicationIdentifier,
                teamIdentifiersMatch: true
            ) != nil,
            XDialBuildIdentity.allowsFormalDataMigration
        )
        XCTAssertNil(
            OutgoingApplicationCleanup.plan(
                existingBundleURL: existingURL,
                existingIdentifier: XDialBuildIdentity.applicationIdentifier,
                incomingIdentifier: XDialBuildIdentity.applicationIdentifier,
                teamIdentifiersMatch: true
            )
        )
        let componentPlan = try XCTUnwrap(
            OutgoingApplicationCleanup.plan(
                existingBundleURL: existingURL,
                existingIdentifier: XDialBuildIdentity.applicationIdentifier,
                incomingIdentifier: XDialBuildIdentity.applicationIdentifier,
                teamIdentifiersMatch: true,
                requiresComponentCleanup: true
            )
        )
        XCTAssertEqual(
            componentPlan.executableURL.path,
            existingURL.appendingPathComponent("Contents/MacOS/XDial").path
        )
        XCTAssertEqual(
            componentPlan.arguments,
            [OutgoingApplicationCleanup.replacementArgument]
        )
        XCTAssertEqual(componentPlan.timeout, 5 * 60)
        XCTAssertNil(
            OutgoingApplicationCleanup.plan(
                existingBundleURL: existingURL,
                existingIdentifier:
                    XDialApplicationIdentifierPolicy.legacyProbe,
                incomingIdentifier:
                    XDialBuildIdentity.applicationIdentifier,
                teamIdentifiersMatch: false
            )
        )
    }

    func testOutgoingCleanupRunsExactBoundedOldHostCommand() throws {
        let plan = try XCTUnwrap(
            OutgoingApplicationCleanup.plan(
                existingBundleURL: URL(
                    fileURLWithPath:
                        XDialBuildIdentity.applicationDestinationURL.path,
                    isDirectory: true
                ),
                existingIdentifier:
                    XDialBuildIdentity.applicationIdentifier,
                incomingIdentifier:
                    XDialBuildIdentity.applicationIdentifier,
                teamIdentifiersMatch: true,
                requiresComponentCleanup: true
            )
        )
        var invocation: OutgoingApplicationCleanup.Plan?

        try OutgoingApplicationCleanup.run(plan) {
            executableURL, arguments, timeout in
            invocation = OutgoingApplicationCleanup.Plan(
                executableURL: executableURL,
                arguments: arguments,
                timeout: timeout
            )
            return true
        }

        XCTAssertEqual(invocation, plan)
    }

    func testOutgoingCleanupFailureStopsReplacement() throws {
        let plan = try XCTUnwrap(
            OutgoingApplicationCleanup.plan(
                existingBundleURL: URL(
                    fileURLWithPath:
                        XDialBuildIdentity.applicationDestinationURL.path,
                    isDirectory: true
                ),
                existingIdentifier:
                    XDialBuildIdentity.applicationIdentifier,
                incomingIdentifier:
                    XDialBuildIdentity.applicationIdentifier,
                teamIdentifiersMatch: true,
                requiresComponentCleanup: true
            )
        )

        XCTAssertThrowsError(
            try OutgoingApplicationCleanup.run(plan) {
                _, _, _ in false
            }
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

    func testBundleInfoReadsReplacementAfterFoundationCachedOldBundle()
        throws {
        let fixture = try BundleInfoReplacementFixture()
        defer { fixture.cleanup() }

        XCTAssertEqual(
            Bundle(url: fixture.destinationURL)?.bundleIdentifier,
            XDialApplicationIdentifierPolicy.legacyProbe
        )

        try ApplicationBundleReplacer.replace(
            destinationURL: fixture.destinationURL,
            newBundleURL: fixture.newBundleURL,
            backupName: fixture.backupName
        ) { url in
            ApplicationBundleInfo.identifier(at: url)
                == XDialApplicationIdentifierPolicy.release
        }

        XCTAssertEqual(
            ApplicationBundleInfo.identifier(at: fixture.destinationURL),
            XDialApplicationIdentifierPolicy.release
        )
    }
}

private final class BundleInfoReplacementFixture {
    let rootURL: URL
    let destinationURL: URL
    let newBundleURL: URL
    let backupName = ".XDial.bundle-info-backup.app"

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "xdial-bundle-info-\(UUID().uuidString)",
                isDirectory: true
            )
        destinationURL = rootURL.appendingPathComponent(
            "XDial.app",
            isDirectory: true
        )
        newBundleURL = rootURL.appendingPathComponent(
            "New.app",
            isDirectory: true
        )
        try Self.writeBundle(
            at: destinationURL,
            identifier: XDialApplicationIdentifierPolicy.legacyProbe
        )
        try Self.writeBundle(
            at: newBundleURL,
            identifier: XDialApplicationIdentifierPolicy.release
        )
    }

    private static func writeBundle(
        at url: URL,
        identifier: String
    ) throws {
        let contentsURL = url.appendingPathComponent(
            "Contents",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: contentsURL,
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": identifier,
                "CFBundleName": "XDial",
                "CFBundlePackageType": "APPL",
                "CFBundleVersion": "1",
            ],
            format: .xml,
            options: 0
        )
        try data.write(
            to: contentsURL.appendingPathComponent("Info.plist")
        )
    }

    func cleanup() {
        if FileManager.default.fileExists(atPath: rootURL.path) {
            try? FileManager.default.removeItem(at: rootURL)
        }
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
