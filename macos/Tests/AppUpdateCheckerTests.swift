import XCTest

final class AppUpdateCheckerTests: XCTestCase {
    func testNewerReleaseTagIsAvailable() {
        XCTAssertTrue(VersionUpdatePolicy.isNewer(
            latestTag: "v0.8.0",
            than: "0.7.0"
        ))
    }

    func testEquivalentAndOlderTagsAreNotAvailable() {
        XCTAssertFalse(VersionUpdatePolicy.isNewer(
            latestTag: "v0.7",
            than: "0.7.0"
        ))
        XCTAssertFalse(VersionUpdatePolicy.isNewer(
            latestTag: "v0.6.9",
            than: "0.7.0"
        ))
    }

    func testMalformedTagDoesNotProduceUpdate() {
        XCTAssertFalse(VersionUpdatePolicy.isNewer(
            latestTag: "nightly",
            than: "0.7.0"
        ))
    }

    func testStableVersionRequiresOnlyNumericComponents() {
        XCTAssertEqual(
            VersionUpdatePolicy.stableVersion(fromTag: "v1.2.3"),
            "1.2.3"
        )
        XCTAssertNil(
            VersionUpdatePolicy.stableVersion(fromTag: "v1.2.3-beta.1")
        )
        XCTAssertNil(
            VersionUpdatePolicy.stableVersion(fromTag: "v1..3")
        )
    }

    func testReleaseVersionRequiresExactCanonicalThreePartTag() {
        XCTAssertEqual(
            VersionUpdatePolicy.stableReleaseVersion(
                fromTag: "v1.2.3"
            ),
            "1.2.3"
        )
        for rejected in [
            "1.2.3",
            "V1.2.3",
            "v1.2",
            "v1.2.3.4",
            "v01.2.3",
            "v1.02.3",
            "v1.2.03",
            "v1.2.3-rc.1",
        ] {
            XCTAssertNil(
                VersionUpdatePolicy.stableReleaseVersion(
                    fromTag: rejected
                ),
                rejected
            )
        }
    }

    func testSelectsExactStableReleaseArchiveAndNotesSection() throws {
        let candidate = try AppUpdateReleasePolicy.selectCandidate(
            from: releaseJSON(
                tag: "v0.8.0",
                body: """
                # XDial v0.8.0

                ## 更新了什么

                - 支持应用内更新。

                ## 完整记录

                - Internal detail.
                """,
                assets: [
                    (
                        "unrelated.zip",
                        "https://github.com/kafeifei/XDial/releases/download/v0.8.0/unrelated.zip"
                    ),
                    (
                        "XDial-v0.8.0.zip",
                        "https://github.com/kafeifei/XDial/releases/download/v0.8.0/XDial-v0.8.0.zip"
                    ),
                ]
            ),
            currentVersion: "0.7.0"
        )

        XCTAssertEqual(candidate.tag, "v0.8.0")
        XCTAssertEqual(candidate.version, "0.8.0")
        XCTAssertEqual(candidate.archiveName, "XDial-v0.8.0.zip")
        XCTAssertEqual(candidate.releaseNotes, "- 支持应用内更新。")
    }

    func testRejectsDraftPrereleaseAndNonNumericStableTag() {
        assertSelectionError(.draftRelease) {
            _ = try AppUpdateReleasePolicy.selectCandidate(
                from: releaseJSON(tag: "v0.8.0", draft: true),
                currentVersion: "0.7.0"
            )
        }
        assertSelectionError(.prerelease) {
            _ = try AppUpdateReleasePolicy.selectCandidate(
                from: releaseJSON(tag: "v0.8.0", prerelease: true),
                currentVersion: "0.7.0"
            )
        }
        assertSelectionError(.invalidVersionTag) {
            _ = try AppUpdateReleasePolicy.selectCandidate(
                from: releaseJSON(tag: "v0.8.0-rc.1"),
                currentVersion: "0.7.0"
            )
        }
        for tag in ["v0.8", "v00.8.0"] {
            assertSelectionError(.invalidVersionTag) {
                _ = try AppUpdateReleasePolicy.selectCandidate(
                    from: releaseJSON(tag: tag),
                    currentVersion: "0.7.0"
                )
            }
        }
    }

    func testRejectsEquivalentOlderMissingAndWrongArchive() {
        assertSelectionError(.notNewer) {
            _ = try AppUpdateReleasePolicy.selectCandidate(
                from: releaseJSON(tag: "v0.7.0"),
                currentVersion: "0.7.0"
            )
        }
        assertSelectionError(.notNewer) {
            _ = try AppUpdateReleasePolicy.selectCandidate(
                from: releaseJSON(tag: "v0.6.9"),
                currentVersion: "0.7.0"
            )
        }
        assertSelectionError(.archiveMissing) {
            _ = try AppUpdateReleasePolicy.selectCandidate(
                from: releaseJSON(tag: "v0.8.0", assets: []),
                currentVersion: "0.7.0"
            )
        }
        assertSelectionError(.archiveMissing) {
            _ = try AppUpdateReleasePolicy.selectCandidate(
                from: releaseJSON(
                    tag: "v0.8.0",
                    assets: [
                        (
                            "another.zip",
                            "https://github.com/kafeifei/XDial/releases/download/v0.8.0/another.zip"
                        )
                    ]
                ),
                currentVersion: "0.7.0"
            )
        }
    }

    func testRejectsArchiveURLOutsideExactGitHubReleasePath() {
        for rejectedURL in [
            "http://github.com/kafeifei/XDial/releases/download/v0.8.0/XDial-v0.8.0.zip",
            "https://example.com/kafeifei/XDial/releases/download/v0.8.0/XDial-v0.8.0.zip",
            "https://github.com/kafeifei/Other/releases/download/v0.8.0/XDial-v0.8.0.zip",
            "https://github.com/kafeifei/XDial/releases/download/v0.8.1/XDial-v0.8.0.zip",
            "https://github.com/kafeifei/XDial/releases/download/v0.8.0/XDial-v0.8.0.zip?token=unexpected",
        ] {
            assertSelectionError(.archiveURLRejected) {
                _ = try AppUpdateReleasePolicy.selectCandidate(
                    from: releaseJSON(
                        tag: "v0.8.0",
                        assets: [("XDial-v0.8.0.zip", rejectedURL)]
                    ),
                    currentVersion: "0.7.0"
                )
            }
        }
    }

    func testMalformedResponseIsRejected() {
        assertSelectionError(.malformedResponse) {
            _ = try AppUpdateReleasePolicy.selectCandidate(
                from: Data("{}".utf8),
                currentVersion: "0.7.0"
            )
        }
    }

    func testArchivePolicyBoundsAndExactRootShape() {
        XCTAssertFalse(
            AppUpdateArchivePolicy.permitsArchiveByteCount(0)
        )
        XCTAssertTrue(
            AppUpdateArchivePolicy.permitsArchiveByteCount(
                AppUpdateArchivePolicy.maximumArchiveBytes
            )
        )
        XCTAssertFalse(
            AppUpdateArchivePolicy.permitsArchiveByteCount(
                AppUpdateArchivePolicy.maximumArchiveBytes + 1
            )
        )
        XCTAssertTrue(
            AppUpdateArchivePolicy.containsExactlyOneRootApplication(
                [XDialBuildIdentity.applicationBundleName]
            )
        )
        XCTAssertFalse(
            AppUpdateArchivePolicy.containsExactlyOneRootApplication(
                ["README.md", XDialBuildIdentity.applicationBundleName]
            )
        )
    }

    func testAutomaticUpdateBundleMustMatchReleaseIdentityTeamAndVersion() {
        XCTAssertEqual(
            AutomaticUpdateBundlePolicy.permits(
                currentIdentifier: XDialBuildIdentity.applicationIdentifier,
                currentTeamIdentifier: "TEAM",
                incomingIdentifier: XDialBuildIdentity.applicationIdentifier,
                incomingTeamIdentifier: "TEAM",
                incomingVersion: "0.8.0",
                expectedVersion: "0.8.0"
            ),
            XDialBuildIdentity.allowsAutomaticUpdates
        )
        XCTAssertFalse(
            AutomaticUpdateBundlePolicy.permits(
                currentIdentifier:
                    XDialApplicationIdentifierPolicy.legacyProbe,
                currentTeamIdentifier: "TEAM",
                incomingIdentifier: XDialApplicationIdentifierPolicy.release,
                incomingTeamIdentifier: "TEAM",
                incomingVersion: "0.8.0",
                expectedVersion: "0.8.0"
            )
        )
        XCTAssertFalse(
            AutomaticUpdateBundlePolicy.permits(
                currentIdentifier: XDialApplicationIdentifierPolicy.release,
                currentTeamIdentifier: "TEAM-A",
                incomingIdentifier: XDialApplicationIdentifierPolicy.release,
                incomingTeamIdentifier: "TEAM-B",
                incomingVersion: "0.8.0",
                expectedVersion: "0.8.0"
            )
        )
        XCTAssertFalse(
            AutomaticUpdateBundlePolicy.permits(
                currentIdentifier: XDialApplicationIdentifierPolicy.release,
                currentTeamIdentifier: "TEAM",
                incomingIdentifier: XDialApplicationIdentifierPolicy.release,
                incomingTeamIdentifier: "TEAM",
                incomingVersion: "0.8.1",
                expectedVersion: "0.8.0"
            )
        )
        XCTAssertTrue(
            AutomaticUpdateBundlePolicy.permitsVersionSet(
                expectedVersion: "0.8.0",
                hostVersion: "0.8.0",
                hostBuild: "100",
                settingsVersion: "0.8.0",
                settingsBuild: "100",
                extensionVersion: "0.8.0",
                extensionBuild: "100"
            )
        )
        XCTAssertFalse(
            AutomaticUpdateBundlePolicy.permitsVersionSet(
                expectedVersion: "0.8.0",
                hostVersion: "0.8.0",
                hostBuild: "100",
                settingsVersion: "0.7.0",
                settingsBuild: "100",
                extensionVersion: "0.8.0",
                extensionBuild: "101"
            )
        )
    }

    func testDownloadPolicyAllowsOnlyGitHubReleaseAssetRedirect() {
        XCTAssertTrue(
            AppUpdateDownloadPolicy.permitsRedirect(
                to: URL(
                    string: "https://release-assets.githubusercontent.com/github-production-release-asset/1/file?token=signed"
                )!
            )
        )
        for rejected in [
            "http://release-assets.githubusercontent.com/file",
            "https://github.com/kafeifei/XDial/file",
            "https://objects.githubusercontent.com/file",
            "https://release-assets.githubusercontent.com:444/file",
            "https://user@release-assets.githubusercontent.com/file",
        ] {
            XCTAssertFalse(
                AppUpdateDownloadPolicy.permitsRedirect(
                    to: URL(string: rejected)!
                ),
                rejected
            )
        }
    }

    func testDownloadResponseRequiresSuccessAndBoundedLength() {
        XCTAssertTrue(
            AppUpdateDownloadPolicy.permitsResponse(
                statusCode: 200,
                expectedByteCount: NSURLSessionTransferSizeUnknown
            )
        )
        XCTAssertTrue(
            AppUpdateDownloadPolicy.permitsResponse(
                statusCode: 200,
                expectedByteCount: 4_000_000
            )
        )
        XCTAssertFalse(
            AppUpdateDownloadPolicy.permitsResponse(
                statusCode: 302,
                expectedByteCount: 0
            )
        )
        XCTAssertTrue(
            AppUpdateDownloadPolicy.permitsProgress(
                totalBytesWritten: 4_000_000,
                totalBytesExpectedToWrite:
                    NSURLSessionTransferSizeUnknown
            )
        )
        XCTAssertFalse(
            AppUpdateDownloadPolicy.permitsProgress(
                totalBytesWritten:
                    AppUpdateArchivePolicy.maximumArchiveBytes + 1,
                totalBytesExpectedToWrite:
                    NSURLSessionTransferSizeUnknown
            )
        )
        XCTAssertFalse(
            AppUpdateDownloadPolicy.permitsProgress(
                totalBytesWritten: 1,
                totalBytesExpectedToWrite:
                    AppUpdateArchivePolicy.maximumArchiveBytes + 1
            )
        )
        XCTAssertFalse(
            AppUpdateDownloadPolicy.permitsResponse(
                statusCode: 200,
                expectedByteCount:
                    AppUpdateArchivePolicy.maximumArchiveBytes + 1
            )
        )
    }

    func testStagesExactRootApplicationAndDiscardsOwnedRoot() throws {
        let fixture = try AppUpdateArchiveFixture(
            rootEntries: [XDialBuildIdentity.applicationBundleName]
        )
        defer { fixture.cleanup() }

        let staged = try AppUpdateStager.stageArchive(
            at: fixture.archiveURL
        ) { applicationURL in
            XCTAssertEqual(
                applicationURL.lastPathComponent,
                XDialBuildIdentity.applicationBundleName
            )
            XCTAssertEqual(
                try String(
                    contentsOf: applicationURL.appendingPathComponent(
                        "marker"
                    ),
                    encoding: .utf8
                ),
                "signed-fixture"
            )
        }

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: staged.applicationURL.path
            )
        )
        XCTAssertTrue(
            AppUpdateStager.isOwnedStagedApplication(
                staged.applicationURL
            )
        )
        AppUpdateStager.discard(staged)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staged.rootURL.path)
        )
    }

    func testAmbiguousArchiveAndValidationFailureCleanOwnedRoot() throws {
        let ambiguous = try AppUpdateArchiveFixture(
            rootEntries: [
                XDialBuildIdentity.applicationBundleName,
                "README.md",
            ]
        )
        XCTAssertThrowsError(
            try AppUpdateStager.stageArchive(at: ambiguous.archiveURL) {
                _ in XCTFail("ambiguous archive reached validation")
            }
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ambiguous.stagingRoot.path)
        )
        ambiguous.cleanup()

        let rejected = try AppUpdateArchiveFixture(
            rootEntries: [XDialBuildIdentity.applicationBundleName]
        )
        struct ValidationFailure: Error {}
        XCTAssertThrowsError(
            try AppUpdateStager.stageArchive(at: rejected.archiveURL) {
                _ in throw ValidationFailure()
            }
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: rejected.stagingRoot.path)
        )
        rejected.cleanup()
    }

    func testRelaunchIntentRestoresConnectionOrDisconnectionOnce() throws {
        let suiteName = "xdial-update-intent-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1000)

        try AppUpdateRelaunchIntentStore.write(
            targetVersion: "0.8.0",
            reconnectScenarioID: "scenario-office",
            now: now,
            defaults: defaults
        )
        XCTAssertEqual(
            AppUpdateRelaunchIntentStore.loadDecision(
                currentVersion: "0.8.0",
                activeScenarioID: "scenario-office",
                now: now.addingTimeInterval(10),
                defaults: defaults
            ),
            .reconnect(scenarioID: "scenario-office")
        )
        AppUpdateRelaunchIntentStore.clear(defaults: defaults)
        XCTAssertNil(
            AppUpdateRelaunchIntentStore.loadDecision(
                currentVersion: "0.8.0",
                activeScenarioID: "scenario-office",
                now: now,
                defaults: defaults
            )
        )

        try AppUpdateRelaunchIntentStore.write(
            targetVersion: "0.8.0",
            reconnectScenarioID: nil,
            now: now,
            defaults: defaults
        )
        XCTAssertEqual(
            AppUpdateRelaunchIntentStore.loadDecision(
                currentVersion: "0.8.0",
                activeScenarioID: "scenario-office",
                now: now,
                defaults: defaults
            ),
            .stayDisconnected
        )
    }

    func testRelaunchIntentRejectsWrongVersionScenarioAndExpiredState()
        throws
    {
        let suiteName = "xdial-update-intent-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1000)

        for (version, scenario, age) in [
            ("0.8.1", "scenario-office", 10.0),
            ("0.8.0", "scenario-home", 10.0),
            (
                "0.8.0",
                "scenario-office",
                AppUpdateRelaunchIntentPolicy.maximumAge + 1
            ),
        ] {
            try AppUpdateRelaunchIntentStore.write(
                targetVersion: "0.8.0",
                reconnectScenarioID: "scenario-office",
                now: now,
                defaults: defaults
            )
            XCTAssertNil(
                AppUpdateRelaunchIntentStore.loadDecision(
                    currentVersion: version,
                    activeScenarioID: scenario,
                    now: now.addingTimeInterval(age),
                    defaults: defaults
                )
            )
        }
    }

    func testStagedSuccessorCanRemoveOnlyItsOwnedUpdateRoot() throws {
        let fixture = try AppUpdateArchiveFixture(
            rootEntries: [XDialBuildIdentity.applicationBundleName]
        )
        defer { fixture.cleanup() }
        let staged = try AppUpdateStager.stageArchive(
            at: fixture.archiveURL
        ) { _ in }

        AppUpdateStager.discardOwnedRoot(
            containing: staged.applicationURL
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staged.rootURL.path)
        )

        let unrelated = fixture.sourceRoot.appendingPathComponent(
            XDialBuildIdentity.applicationBundleName,
            isDirectory: true
        )
        AppUpdateStager.discardOwnedRoot(containing: unrelated)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.sourceRoot.path)
        )
    }

    func testStaleStagingCleanupRemovesOnlyOldOwnedUUIDRoots() throws {
        let fileManager = FileManager.default
        let now = Date(timeIntervalSince1970: 2_000_000)
        let staleRoot = try AppUpdateStager.makeStagingRoot()
        let freshRoot = try AppUpdateStager.makeStagingRoot()
        let unknownRoot = staleRoot.deletingLastPathComponent()
            .appendingPathComponent(
                "preserve-(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            for url in [staleRoot, freshRoot, unknownRoot]
            where fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
        }
        try fileManager.createDirectory(
            at: unknownRoot,
            withIntermediateDirectories: false
        )
        let oldDate = now.addingTimeInterval(
            -AppUpdateStager.staleRootMaximumAge - 1
        )
        for url in [staleRoot, unknownRoot] {
            try fileManager.setAttributes(
                [.modificationDate: oldDate],
                ofItemAtPath: url.path
            )
        }
        try fileManager.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: freshRoot.path
        )

        AppUpdateStager.pruneStaleRoots(now: now)

        XCTAssertFalse(fileManager.fileExists(atPath: staleRoot.path))
        XCTAssertTrue(fileManager.fileExists(atPath: freshRoot.path))
        XCTAssertTrue(fileManager.fileExists(atPath: unknownRoot.path))
    }

    func testStagedSuccessorRequiresFreshMatchingVersionIntent() throws {
        let suiteName = "xdial-update-successor-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1000)

        try AppUpdateRelaunchIntentStore.write(
            targetVersion: "0.8.0",
            reconnectScenarioID: nil,
            now: now,
            defaults: defaults
        )
        XCTAssertTrue(
            AppUpdateRelaunchIntentStore.permitsStagedSuccessor(
                targetVersion: "0.8.0",
                now: now.addingTimeInterval(10),
                defaults: defaults
            )
        )
        XCTAssertFalse(
            AppUpdateRelaunchIntentStore.permitsStagedSuccessor(
                targetVersion: "0.8.1",
                now: now.addingTimeInterval(10),
                defaults: defaults
            )
        )
        XCTAssertFalse(
            AppUpdateRelaunchIntentStore.permitsStagedSuccessor(
                targetVersion: "0.8.0",
                now: now.addingTimeInterval(10),
                defaults: defaults
            )
        )
    }

    private func releaseJSON(
        tag: String,
        body: String? = nil,
        draft: Bool = false,
        prerelease: Bool = false,
        assets: [(String, String)]? = nil
    ) -> Data {
        let selectedAssets = assets ?? [
            (
                "XDial-\(tag).zip",
                "https://github.com/kafeifei/XDial/releases/download/\(tag)/XDial-\(tag).zip"
            )
        ]
        var object: [String: Any] = [
            "tag_name": tag,
            "draft": draft,
            "prerelease": prerelease,
            "assets": selectedAssets.map {
                ["name": $0.0, "browser_download_url": $0.1]
            },
        ]
        if let body { object["body"] = body }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func assertSelectionError(
        _ expected: AppUpdateReleaseSelectionError,
        operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try operation(),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? AppUpdateReleaseSelectionError,
                expected,
                file: file,
                line: line
            )
        }
    }
}

private final class AppUpdateArchiveFixture {
    let sourceRoot: URL
    let stagingRoot: URL
    let archiveURL: URL

    init(rootEntries: [String]) throws {
        sourceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "xdial-update-source-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: sourceRoot,
            withIntermediateDirectories: true
        )
        for entry in rootEntries {
            let entryURL = sourceRoot.appendingPathComponent(entry)
            if entry == XDialBuildIdentity.applicationBundleName {
                try FileManager.default.createDirectory(
                    at: entryURL,
                    withIntermediateDirectories: true
                )
                try Data("signed-fixture".utf8).write(
                    to: entryURL.appendingPathComponent("marker")
                )
            } else {
                try Data("extra".utf8).write(to: entryURL)
            }
        }

        stagingRoot = try AppUpdateStager.makeStagingRoot()
        archiveURL = AppUpdateStager.archiveURL(in: stagingRoot)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-c",
            "-k",
            sourceRoot.path,
            archiveURL.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func cleanup() {
        for url in [sourceRoot, stagingRoot]
        where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
