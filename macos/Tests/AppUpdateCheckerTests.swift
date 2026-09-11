import CryptoKit
import XCTest

final class AppUpdateCheckerTests: XCTestCase {
    private let production = AppUpdateFeedConfiguration.production

    func testVersionPolicyAcceptsOnlyCanonicalNewerStableTag() {
        XCTAssertTrue(VersionUpdatePolicy.isNewer(
            latestTag: "v0.8.0",
            than: "0.7.0"
        ))
        XCTAssertFalse(VersionUpdatePolicy.isNewer(
            latestTag: "v0.7",
            than: "0.7.0"
        ))
        for rejected in [
            "1.2.3", "V1.2.3", "v1.2", "v1.2.3.4",
            "v01.2.3", "v1.02.3", "v1.2.03", "v1.2.3-rc.1",
        ] {
            XCTAssertNil(
                VersionUpdatePolicy.stableReleaseVersion(
                    fromTag: rejected
                ),
                rejected
            )
        }
    }

    func testFeedConfigurationUsesOnlySignedProductionOrAcceptanceID()
        throws
    {
        XCTAssertEqual(
            try AppUpdateFeedConfiguration.current(
                infoDictionary: [:]
            ),
            .production
        )
        XCTAssertEqual(
            try AppUpdateFeedConfiguration.current(
                infoDictionary: [
                    AppUpdateFeedConfiguration.acceptanceInfoKey: "",
                ]
            ),
            .production
        )

        let acceptanceID = "pages-Acceptance-42"
        let acceptance = try AppUpdateFeedConfiguration.current(
            infoDictionary: [
                AppUpdateFeedConfiguration.acceptanceInfoKey: acceptanceID,
            ]
        )
        XCTAssertEqual(acceptance.acceptanceID, acceptanceID)
        XCTAssertEqual(
            acceptance.feedURL.absoluteString,
            "https://saymiao.github.io/xdial-updates/acceptance/"
                + acceptanceID + "/stable.json"
        )
        XCTAssertTrue(acceptance.permitsArchiveURL(
            URL(string:
                "https://github.com/saymiao/xdial-updates/releases/download/"
                    + "v0.8.0/XDial-v0.8.0.zip"
            )!,
            tag: "v0.8.0",
            archiveName: "XDial-v0.8.0.zip"
        ))
        XCTAssertFalse(acceptance.permitsArchiveURL(
            productionArchiveURL(tag: "v0.8.0"),
            tag: "v0.8.0",
            archiveName: "XDial-v0.8.0.zip"
        ))

        for rejected: Any in [
            "-leading",
            "contains_underscore",
            "contains/slash",
            String(repeating: "a", count: 81),
            42,
        ] {
            XCTAssertThrowsError(
                try AppUpdateFeedConfiguration.current(
                    infoDictionary: [
                        AppUpdateFeedConfiguration.acceptanceInfoKey:
                            rejected,
                    ]
                ),
                "(rejected)"
            )
        }
        XCTAssertNoThrow(
            try AppUpdateFeedConfiguration.acceptance(
                id: "a" + String(repeating: "-", count: 79)
            )
        )
    }

    func testFeedConfigurationReadsFreshPlistAndRejectsNonStringID()
        throws
    {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "xdial-update-info-\(UUID().uuidString).app",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        try writeInfoPlist([
            AppUpdateFeedConfiguration.acceptanceInfoKey: "acceptance-a",
        ], to: bundleURL)
        XCTAssertEqual(
            try AppUpdateFeedConfiguration.current(at: bundleURL)
                .acceptanceID,
            "acceptance-a"
        )

        try writeInfoPlist([
            AppUpdateFeedConfiguration.acceptanceInfoKey: 42,
        ], to: bundleURL)
        XCTAssertThrowsError(
            try AppUpdateFeedConfiguration.current(at: bundleURL)
        ) { error in
            XCTAssertEqual(
                error as? AppUpdateFeedConfigurationError,
                .invalidAcceptanceID
            )
        }
    }

    func testManifestParserAcceptsExactReleaseAndWithdrawal()
        throws
    {
        let data = manifestData()
        let manifest = try AppUpdateManifestParser.parse(data)
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.revision, 1)
        XCTAssertEqual(manifest.channel, "stable")
        XCTAssertEqual(manifest.release?.version, "0.8.0")
        XCTAssertEqual(manifest.release?.build, "1789130088")
        XCTAssertEqual(
            manifest.release?.releaseNotes,
            "- Pages update"
        )
        XCTAssertNil(
            try AppUpdateManifestParser.parse(
                manifestData(release: nil)
            ).release
        )
    }

    func testManifestParserRejectsUnknownMissingAndInvalidFields()
        throws
    {
        var unknown = try manifestObject()
        unknown["unexpected"] = true
        assertManifestError(.unexpectedFields, data: jsonData(unknown))

        var missing = try manifestObject()
        missing.removeValue(forKey: "generatedAt")
        assertManifestError(.unexpectedFields, data: jsonData(missing))

        var badSchema = try manifestObject()
        badSchema["schemaVersion"] = 2
        assertManifestError(.unsupportedSchema, data: jsonData(badSchema))

        var badRevision = try manifestObject()
        badRevision["revision"] = 0
        assertManifestError(.invalidRevision, data: jsonData(badRevision))

        var badChannel = try manifestObject()
        badChannel["channel"] = "beta"
        assertManifestError(.invalidChannel, data: jsonData(badChannel))

        var badRelease = try manifestObject()
        var release = try XCTUnwrap(
            badRelease["release"] as? [String: Any]
        )
        release.removeValue(forKey: "archiveSHA256")
        badRelease["release"] = release
        assertManifestError(.unexpectedFields, data: jsonData(badRelease))

        XCTAssertThrowsError(
            try AppUpdateManifestParser.parse(
                Data(repeating: 0x20,
                     count: AppUpdateManifestParser.maximumBytes + 1)
            )
        ) { error in
            XCTAssertEqual(error as? AppUpdateManifestError, .tooLarge)
        }
    }

    func testReleaseSelectionValidatesVersionBuildOSNotesURLSizeAndHash()
        throws
    {
        let manifest = try AppUpdateManifestParser.parse(manifestData())
        let candidate = try AppUpdateReleasePolicy.selectCandidate(
            from: try XCTUnwrap(manifest.release),
            generatedAt: manifest.generatedAt,
            configuration: production,
            currentVersion: "0.7.0",
            currentSystemVersion: "15.0"
        )
        XCTAssertEqual(candidate.tag, "v0.8.0")
        XCTAssertEqual(candidate.version, "0.8.0")
        XCTAssertEqual(candidate.build, "1789130088")
        XCTAssertEqual(candidate.minimumSystemVersion, "15.0")
        XCTAssertEqual(candidate.archiveSize, 1234)
        XCTAssertEqual(candidate.archiveSHA256, String(repeating: "a", count: 64))
        XCTAssertEqual(candidate.releaseNotes, "- Pages update")

        let cases: [(AppUpdateReleaseSelectionError, [String: Any])] = [
            (.invalidVersionTag, ["version": "0.8.1"]),
            (.invalidBuild, ["build": "0"]),
            (.invalidMinimumSystemVersion,
             ["minimumSystemVersion": "015.0"]),
            (.releaseNotesMissing, ["releaseNotes": "  \n"]),
            (.archiveSizeInvalid, ["archiveSize": 0]),
            (.archiveSHA256Invalid,
             ["archiveSHA256": String(repeating: "A", count: 64)]),
            (.archiveURLRejected,
             ["archiveURL":
                "https://example.com/XDial-v0.8.0.zip"]),
        ]
        for (expected, changes) in cases {
            let release = try parsedRelease(changes: changes)
            assertSelectionError(expected) {
                _ = try AppUpdateReleasePolicy.selectCandidate(
                    from: release,
                    generatedAt: manifest.generatedAt,
                    configuration: production,
                    currentVersion: "0.7.0",
                    currentSystemVersion: "15.0"
                )
            }
        }
        assertSelectionError(.unsupportedSystemVersion) {
            _ = try AppUpdateReleasePolicy.selectCandidate(
                from: try XCTUnwrap(manifest.release),
                generatedAt: manifest.generatedAt,
                configuration: production,
                currentVersion: "0.7.0",
                currentSystemVersion: "14.7"
            )
        }
        assertSelectionError(.notNewer) {
            _ = try AppUpdateReleasePolicy.selectCandidate(
                from: try XCTUnwrap(manifest.release),
                generatedAt: manifest.generatedAt,
                configuration: production,
                currentVersion: "0.8.0",
                currentSystemVersion: "15.0"
            )
        }
    }

    @MainActor
    func testLookupUsesOnlyPagesFeedAndPersistsValidatedETagCache()
        async throws
    {
        let defaults = try temporaryDefaults()
        let feedURL = production.feedURL
        let firstRecorder = AppUpdateHTTPRecorder(replies: [
            .response(AppUpdateHTTPResult(
                data: manifestData(revision: 4),
                statusCode: 200,
                url: feedURL,
                headers: [
                    "Content-Type": "application/json; charset=utf-8",
                    "ETag": "\"revision-4\"",
                ]
            )),
        ])
        let firstLookup = AppUpdateReleaseLookup(
            configuration: production,
            transport: firstRecorder.transport,
            defaults: defaults
        )
        let checkedAt = Date(timeIntervalSince1970: 1_000)
        let first = try await firstLookup.check(
            currentVersion: "0.7.0",
            currentSystemVersion: "15.0",
            now: checkedAt
        )
        XCTAssertEqual(first.checkedAt, checkedAt)
        XCTAssertEqual(first.revision, 4)
        guard case let .available(candidate) = first.availability else {
            return XCTFail("expected Pages candidate")
        }
        XCTAssertEqual(candidate.version, "0.8.0")
        let firstRequests = await firstRecorder.recordedRequests()
        XCTAssertEqual(firstRequests.map(\.url), [feedURL])
        XCTAssertEqual(
            firstRequests[0].value(forHTTPHeaderField: "Cache-Control"),
            "no-cache, max-age=0"
        )
        XCTAssertEqual(
            firstRequests[0].value(forHTTPHeaderField: "Pragma"),
            "no-cache"
        )
        XCTAssertNil(firstRequests[0].value(
            forHTTPHeaderField: "If-None-Match"
        ))

        let secondRecorder = AppUpdateHTTPRecorder(replies: [
            .response(AppUpdateHTTPResult(
                statusCode: 304,
                url: feedURL
            )),
        ])
        let secondLookup = AppUpdateReleaseLookup(
            configuration: production,
            transport: secondRecorder.transport,
            defaults: defaults
        )
        let second = try await secondLookup.check(
            currentVersion: "0.7.0",
            currentSystemVersion: "15.0",
            now: checkedAt.addingTimeInterval(20)
        )
        XCTAssertEqual(second.availability, first.availability)
        XCTAssertEqual(second.revision, 4)
        let secondRequests = await secondRecorder.recordedRequests()
        XCTAssertEqual(secondRequests.map(\.url), [feedURL])
        XCTAssertEqual(
            secondRequests[0].value(
                forHTTPHeaderField: "If-None-Match"
            ),
            "\"revision-4\""
        )
        let secondCheckedAt = checkedAt.addingTimeInterval(20)
        let persistedCheckedAt = await secondLookup.lastValidatedAt(
            now: secondCheckedAt.addingTimeInterval(1)
        )
        XCTAssertEqual(persistedCheckedAt, secondCheckedAt)
        let checker = AppUpdateChecker(
            releaseLookup: secondLookup,
            automaticUpdatesPermitted: { true },
            pruneStaleStaging: {}
        )
        await checker.waitForTasksForTesting()
        XCTAssertEqual(checker.lastCheckedAt, secondCheckedAt)
    }

    func testLookupDistinguishesWithdrawalFromUpToDate() async throws {
        let feedURL = production.feedURL
        let recorder = AppUpdateHTTPRecorder(replies: [
            .response(AppUpdateHTTPResult(
                data: manifestData(release: nil),
                statusCode: 200,
                url: feedURL,
                headers: jsonHeaders(etag: "\"withdrawn\"")
            )),
            .response(AppUpdateHTTPResult(
                data: manifestData(revision: 2),
                statusCode: 200,
                url: feedURL,
                headers: jsonHeaders(etag: "\"available\"")
            )),
        ])
        let defaults = try temporaryDefaults()
        let lookup = AppUpdateReleaseLookup(
            configuration: production,
            transport: recorder.transport,
            defaults: defaults
        )

        let withdrawn = try await lookup.check(
            currentVersion: "0.7.0",
            currentSystemVersion: "15.0",
            now: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(withdrawn.availability, .noRelease)

        let upToDate = try await lookup.check(
            currentVersion: "0.8.0",
            currentSystemVersion: "15.0",
            now: Date(timeIntervalSince1970: 1_010)
        )
        XCTAssertEqual(upToDate.availability, .upToDate)
    }

    func testLookupRejectsRedirectOversizeRevisionRollbackAndConflict()
        async throws
    {
        let feedURL = production.feedURL
        let redirected = AppUpdateHTTPRecorder(replies: [
            .response(AppUpdateHTTPResult(
                data: manifestData(),
                statusCode: 200,
                url: URL(string: "https://example.com/stable.json")!,
                headers: jsonHeaders(etag: "\"one\"")
            )),
        ])
        do {
            _ = try await AppUpdateReleaseLookup(
                configuration: production,
                transport: redirected.transport,
                defaults: try temporaryDefaults()
            ).check(
                currentVersion: "0.7.0",
                currentSystemVersion: "15.0"
            )
            XCTFail("redirected manifest accepted")
        } catch let error as AppUpdateReleaseLookupError {
            guard case .responseURLRejected = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let oversized = AppUpdateHTTPRecorder(replies: [
            .response(AppUpdateHTTPResult(
                data: Data(repeating: 0,
                    count: AppUpdateManifestParser.maximumBytes + 1),
                statusCode: 200,
                url: feedURL
            )),
        ])
        do {
            _ = try await AppUpdateReleaseLookup(
                configuration: production,
                transport: oversized.transport,
                defaults: try temporaryDefaults()
            ).check(
                currentVersion: "0.7.0",
                currentSystemVersion: "15.0"
            )
            XCTFail("oversized manifest accepted")
        } catch let error as AppUpdateReleaseLookupError {
            XCTAssertEqual(error, .responseTooLarge)
        }

        let defaults = try temporaryDefaults()
        let recorder = AppUpdateHTTPRecorder(replies: [
            .response(AppUpdateHTTPResult(
                data: manifestData(revision: 3),
                statusCode: 200,
                url: feedURL,
                headers: jsonHeaders(etag: "\"three\"")
            )),
            .response(AppUpdateHTTPResult(
                data: manifestData(revision: 2),
                statusCode: 200,
                url: feedURL,
                headers: jsonHeaders(etag: "\"two\"")
            )),
        ])
        let lookup = AppUpdateReleaseLookup(
            configuration: production,
            transport: recorder.transport,
            defaults: defaults
        )
        _ = try await lookup.check(
            currentVersion: "0.7.0",
            currentSystemVersion: "15.0",
            now: Date(timeIntervalSince1970: 1_000)
        )
        do {
            _ = try await lookup.check(
                currentVersion: "0.7.0",
                currentSystemVersion: "15.0",
                now: Date(timeIntervalSince1970: 1_010)
            )
            XCTFail("revision rollback accepted")
        } catch let error as AppUpdateReleaseLookupError {
            XCTAssertEqual(
                error,
                .revisionRollback(previous: 3, received: 2)
            )
        }
    }

    func testLookupRejectsSameRevisionWithDifferentRawBytes()
        async throws
    {
        let feedURL = production.feedURL
        let firstData = manifestData(revision: 7)
        var secondData = firstData
        secondData.append(contentsOf: Data("\n".utf8))
        XCTAssertEqual(
            try AppUpdateManifestParser.parse(firstData),
            try AppUpdateManifestParser.parse(secondData)
        )
        let recorder = AppUpdateHTTPRecorder(replies: [
            .response(AppUpdateHTTPResult(
                data: firstData,
                statusCode: 200,
                url: feedURL,
                headers: jsonHeaders(etag: "\"first-seven\"")
            )),
            .response(AppUpdateHTTPResult(
                data: secondData,
                statusCode: 200,
                url: feedURL,
                headers: jsonHeaders(etag: "\"second-seven\"")
            )),
        ])
        let lookup = AppUpdateReleaseLookup(
            configuration: production,
            transport: recorder.transport,
            defaults: try temporaryDefaults()
        )
        _ = try await lookup.check(
            currentVersion: "0.7.0",
            currentSystemVersion: "15.0",
            now: Date(timeIntervalSince1970: 1_000)
        )

        do {
            _ = try await lookup.check(
                currentVersion: "0.7.0",
                currentSystemVersion: "15.0",
                now: Date(timeIntervalSince1970: 1_010)
            )
            XCTFail("same revision with different bytes was accepted")
        } catch let error as AppUpdateReleaseLookupError {
            XCTAssertEqual(error, .revisionConflict(7))
        }
    }

    func testLookupHonorsRetryAfterThenResumesPagesRequest()
        async throws
    {
        let feedURL = production.feedURL
        let now = Date(timeIntervalSince1970: 1_000)
        let recorder = AppUpdateHTTPRecorder(replies: [
            .response(AppUpdateHTTPResult(
                statusCode: 429,
                url: feedURL,
                headers: ["Retry-After": "120"]
            )),
            .response(AppUpdateHTTPResult(
                data: manifestData(),
                statusCode: 200,
                url: feedURL,
                headers: jsonHeaders(etag: "\"one\"")
            )),
        ])
        let defaults = try temporaryDefaults()
        let lookup = AppUpdateReleaseLookup(
            configuration: production,
            transport: recorder.transport,
            defaults: defaults
        )
        do {
            _ = try await lookup.check(
                currentVersion: "0.7.0",
                currentSystemVersion: "15.0",
                now: now
            )
            XCTFail("429 accepted")
        } catch let error as AppUpdateReleaseLookupError {
            XCTAssertEqual(
                error,
                .rateLimited(until: now.addingTimeInterval(120))
            )
        }
        do {
            _ = try await lookup.check(
                currentVersion: "0.7.0",
                currentSystemVersion: "15.0",
                now: now.addingTimeInterval(119)
            )
            XCTFail("cooldown ignored")
        } catch let error as AppUpdateReleaseLookupError {
            XCTAssertEqual(
                error,
                .retryDeferred(until: now.addingTimeInterval(120))
            )
        }
        _ = try await lookup.check(
            currentVersion: "0.7.0",
            currentSystemVersion: "15.0",
            now: now.addingTimeInterval(121)
        )
        let requestCount = await recorder.recordedRequests().count
        XCTAssertEqual(requestCount, 2)
    }

    func testSlowerOldResponseCannotOverwriteNewerRevision()
        async throws
    {
        let feedURL = production.feedURL
        let oldResponse = AppUpdateHTTPResult(
            data: manifestData(revision: 1),
            statusCode: 200,
            url: feedURL,
            headers: jsonHeaders(etag: "\"old\"")
        )
        let newResponse = AppUpdateHTTPResult(
            data: manifestData(
                revision: 2,
                release: [
                    "tag": "v0.8.1",
                    "version": "0.8.1",
                    "archiveURL": productionArchiveURL(
                        tag: "v0.8.1"
                    ).absoluteString,
                ]
            ),
            statusCode: 200,
            url: feedURL,
            headers: jsonHeaders(etag: "\"new\"")
        )
        let transport = AppUpdateReorderingTransport(
            firstResponse: oldResponse,
            secondResponse: newResponse,
            laterResponse: AppUpdateHTTPResult(
                statusCode: 304,
                url: feedURL
            )
        )
        let lookup = AppUpdateReleaseLookup(
            configuration: production,
            transport: transport.transport,
            defaults: try temporaryDefaults()
        )

        let first = Task {
            try await lookup.check(
                currentVersion: "0.7.0",
                currentSystemVersion: "15.0",
                now: Date(timeIntervalSince1970: 1_000)
            )
        }
        await transport.waitUntilFirstRequestStarts()
        let second = try await lookup.check(
            currentVersion: "0.7.0",
            currentSystemVersion: "15.0",
            now: Date(timeIntervalSince1970: 1_001)
        )
        guard case let .available(secondCandidate) = second.availability
        else { return XCTFail("new response was not available") }
        XCTAssertEqual(secondCandidate.version, "0.8.1")

        await transport.releaseFirstResponse()
        do {
            _ = try await first.value
            XCTFail("late old response overwrote the new revision")
        } catch let error as AppUpdateReleaseLookupError {
            XCTAssertEqual(
                error,
                .revisionRollback(previous: 2, received: 1)
            )
        }

        let cached = try await lookup.check(
            currentVersion: "0.7.0",
            currentSystemVersion: "15.0",
            now: Date(timeIntervalSince1970: 1_002)
        )
        guard case let .available(cachedCandidate) = cached.availability
        else { return XCTFail("new cached response was lost") }
        XCTAssertEqual(cached.revision, 2)
        XCTAssertEqual(cachedCandidate.version, "0.8.1")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(
            requests[2].value(forHTTPHeaderField: "If-None-Match"),
            "\"new\""
        )
    }

    @MainActor
    func testCandidateWithdrawalStopsBeforeDownload() async throws {
        let feedURL = production.feedURL
        let recorder = AppUpdateHTTPRecorder(replies: [
            .response(AppUpdateHTTPResult(
                data: manifestData(revision: 2, release: nil),
                statusCode: 200,
                url: feedURL,
                headers: jsonHeaders(etag: "\"withdrawn-two\"")
            )),
        ])
        let lookup = AppUpdateReleaseLookup(
            configuration: production,
            transport: recorder.transport,
            defaults: try temporaryDefaults()
        )
        let candidate = try releaseCandidate()
        let checker = AppUpdateChecker(
            releaseLookup: lookup,
            automaticUpdatesPermitted: { true },
            pruneStaleStaging: {}
        )
        await checker.waitForTasksForTesting()
        checker.configureForTesting(
            candidate: candidate,
            phase: .available
        )

        checker.downloadAndPrepare()
        await checker.waitForTasksForTesting()

        XCTAssertEqual(checker.phase, .failed)
        XCTAssertNil(checker.releaseCandidate)
        XCTAssertEqual(checker.failure?.code, .candidateChanged)
        XCTAssertNotNil(checker.lastCheckedAt)
        let requestCount = await recorder.recordedRequests().count
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(checker.launchAttemptCount, 0)
    }

    @MainActor
    func testInstallFreshnessFailureKeepsStageAndDoesNotLaunch()
        async throws
    {
        let recorder = AppUpdateHTTPRecorder(replies: [
            .failure(.notConnectedToInternet),
        ])
        let lookup = AppUpdateReleaseLookup(
            configuration: production,
            transport: recorder.transport,
            defaults: try temporaryDefaults()
        )
        let candidate = try releaseCandidate()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staged = StagedAppUpdate(
            rootURL: rootURL,
            applicationURL: rootURL.appendingPathComponent("XDial.app")
        )
        let checker = AppUpdateChecker(
            releaseLookup: lookup,
            automaticUpdatesPermitted: { true },
            pruneStaleStaging: {}
        )
        await checker.waitForTasksForTesting()
        checker.configureForTesting(
            candidate: candidate,
            stagedUpdate: staged,
            phase: .ready
        )

        checker.installPreparedUpdate(reconnectScenarioID: nil)
        await checker.waitForTasksForTesting()

        XCTAssertEqual(checker.phase, .ready)
        XCTAssertEqual(checker.releaseCandidate, candidate)
        XCTAssertEqual(checker.stagedUpdate, staged)
        XCTAssertEqual(checker.failure?.code, .checkUnavailable)
        XCTAssertEqual(checker.launchAttemptCount, 0)
        let requestCount = await recorder.recordedRequests().count
        XCTAssertEqual(requestCount, 1)
    }

    @MainActor
    func testImmediateManualChecksAreCoalesced() async throws {
        let feedURL = production.feedURL
        let recorder = AppUpdateHTTPRecorder(replies: [
            .response(AppUpdateHTTPResult(
                data: manifestData(),
                statusCode: 200,
                url: feedURL,
                headers: jsonHeaders(etag: "\"manual-one\"")
            )),
        ])
        let checker = AppUpdateChecker(
            releaseLookup: AppUpdateReleaseLookup(
                configuration: production,
                transport: recorder.transport,
                defaults: try temporaryDefaults()
            ),
            automaticUpdatesPermitted: { true },
            pruneStaleStaging: {}
        )
        await checker.waitForTasksForTesting()

        await checker.checkNow()
        await checker.checkNow()

        XCTAssertNotNil(checker.lastCheckedAt)
        XCTAssertNil(checker.failure)
        let requestCount = await recorder.recordedRequests().count
        XCTAssertEqual(requestCount, 1)
    }

    func testArchiveIntegrityRequiresExactSizeAndSHA256() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "xdial-update-integrity-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data("signed archive".utf8)
        try data.write(to: url)
        let digest = SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()

        XCTAssertNoThrow(
            try AppUpdateArchiveIntegrity.validate(
                fileURL: url,
                expectedSize: Int64(data.count),
                expectedSHA256: digest
            )
        )
        XCTAssertThrowsError(
            try AppUpdateArchiveIntegrity.validate(
                fileURL: url,
                expectedSize: Int64(data.count + 1),
                expectedSHA256: digest
            )
        ) { error in
            guard case AppUpdateDownloadError.archiveSizeMismatch = error
            else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertThrowsError(
            try AppUpdateArchiveIntegrity.validate(
                fileURL: url,
                expectedSize: Int64(data.count),
                expectedSHA256: String(repeating: "0", count: 64)
            )
        ) { error in
            guard case AppUpdateDownloadError.archiveIntegrityMismatch = error
            else { return XCTFail("unexpected error: \(error)") }
        }
    }

    private func manifestData(
        revision: Int = 1,
        release: [String: Any]? = [:]
    ) -> Data {
        jsonData(try! manifestObject(
            revision: revision,
            release: release
        ))
    }

    private func releaseCandidate() throws -> AppUpdateReleaseCandidate {
        let manifest = try AppUpdateManifestParser.parse(manifestData())
        return try AppUpdateReleasePolicy.selectCandidate(
            from: try XCTUnwrap(manifest.release),
            generatedAt: manifest.generatedAt,
            configuration: production,
            currentVersion: "0.7.0",
            currentSystemVersion: "15.0"
        )
    }

    private func manifestObject(
        revision: Int = 1,
        release: [String: Any]? = [:]
    ) throws -> [String: Any] {
        [
            "schemaVersion": 1,
            "revision": revision,
            "channel": "stable",
            "generatedAt": "1970-01-01T00:15:00Z",
            "release": release == nil
                ? NSNull()
                : releaseObject(changes: release ?? [:]),
        ]
    }

    private func releaseObject(
        changes: [String: Any] = [:]
    ) -> [String: Any] {
        var release: [String: Any] = [
            "tag": "v0.8.0",
            "version": "0.8.0",
            "build": "1789130088",
            "minimumSystemVersion": "15.0",
            "publishedAt": "1970-01-01T00:13:20Z",
            "releaseNotes": "- Pages update",
            "archiveURL": productionArchiveURL(
                tag: "v0.8.0"
            ).absoluteString,
            "archiveSize": 1234,
            "archiveSHA256": String(repeating: "a", count: 64),
        ]
        for (key, value) in changes { release[key] = value }
        return release
    }

    private func parsedRelease(
        changes: [String: Any]
    ) throws -> AppUpdateFeedRelease {
        let object = try manifestObject(release: changes)
        return try XCTUnwrap(
            AppUpdateManifestParser.parse(
                jsonData(object)
            ).release
        )
    }

    private func productionArchiveURL(tag: String) -> URL {
        URL(string:
            "https://github.com/kafeifei/XDial/releases/download/"
                + "\(tag)/XDial-\(tag).zip"
        )!
    }

    private func jsonHeaders(etag: String) -> [String: String] {
        ["Content-Type": "application/json", "ETag": etag]
    }

    private func jsonData(_ object: Any) -> Data {
        try! JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
    }

    private func writeInfoPlist(
        _ dictionary: [String: Any],
        to bundleURL: URL
    ) throws {
        let contentsURL = bundleURL.appendingPathComponent(
            "Contents",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: contentsURL,
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: .xml,
            options: 0
        )
        try data.write(
            to: contentsURL.appendingPathComponent("Info.plist"),
            options: .atomic
        )
    }

    private func temporaryDefaults() throws -> UserDefaults {
        let suiteName = "xdial-update-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private func assertManifestError(
        _ expected: AppUpdateManifestError,
        data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try AppUpdateManifestParser.parse(data),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? AppUpdateManifestError,
                expected,
                file: file,
                line: line
            )
        }
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

    func testAutomaticUpdateBundleMatchesIdentityTeamChannelVersionAndBuild() {
        XCTAssertTrue(
            AutomaticUpdateBundlePolicy.permitsAcceptanceTransition(
                currentAcceptanceID: nil,
                incomingAcceptanceID: nil
            )
        )
        XCTAssertTrue(
            AutomaticUpdateBundlePolicy.permitsAcceptanceTransition(
                currentAcceptanceID: "acceptance-a",
                incomingAcceptanceID: "acceptance-a"
            )
        )
        XCTAssertFalse(
            AutomaticUpdateBundlePolicy.permitsAcceptanceTransition(
                currentAcceptanceID: nil,
                incomingAcceptanceID: "acceptance-a"
            )
        )
        XCTAssertFalse(
            AutomaticUpdateBundlePolicy.permitsAcceptanceTransition(
                currentAcceptanceID: "acceptance-a",
                incomingAcceptanceID: "acceptance-b"
            )
        )
        XCTAssertEqual(
            AutomaticUpdateBundlePolicy.permits(
                currentIdentifier: XDialBuildIdentity.applicationIdentifier,
                currentTeamIdentifier: "TEAM",
                currentAcceptanceID: "acceptance-a",
                incomingIdentifier: XDialBuildIdentity.applicationIdentifier,
                incomingTeamIdentifier: "TEAM",
                incomingAcceptanceID: "acceptance-a",
                incomingVersion: "0.8.0",
                expectedVersion: "0.8.0",
                incomingBuild: "100",
                expectedBuild: "100"
            ),
            XDialBuildIdentity.allowsAutomaticUpdates
        )
        XCTAssertFalse(
            AutomaticUpdateBundlePolicy.permits(
                currentIdentifier: XDialBuildIdentity.applicationIdentifier,
                currentTeamIdentifier: "TEAM",
                currentAcceptanceID: "acceptance-a",
                incomingIdentifier: XDialBuildIdentity.applicationIdentifier,
                incomingTeamIdentifier: "TEAM",
                incomingAcceptanceID: "acceptance-b",
                incomingVersion: "0.8.0",
                expectedVersion: "0.8.0",
                incomingBuild: "100",
                expectedBuild: "100"
            )
        )
        XCTAssertFalse(
            AutomaticUpdateBundlePolicy.permits(
                currentIdentifier: XDialApplicationIdentifierPolicy.release,
                currentTeamIdentifier: "TEAM-A",
                currentAcceptanceID: nil,
                incomingIdentifier: XDialApplicationIdentifierPolicy.release,
                incomingTeamIdentifier: "TEAM-B",
                incomingAcceptanceID: nil,
                incomingVersion: "0.8.0",
                expectedVersion: "0.8.0",
                incomingBuild: "100",
                expectedBuild: "100"
            )
        )
        XCTAssertFalse(
            AutomaticUpdateBundlePolicy.permits(
                currentIdentifier: XDialApplicationIdentifierPolicy.release,
                currentTeamIdentifier: "TEAM",
                currentAcceptanceID: nil,
                incomingIdentifier: XDialApplicationIdentifierPolicy.release,
                incomingTeamIdentifier: "TEAM",
                incomingAcceptanceID: nil,
                incomingVersion: "0.8.0",
                expectedVersion: "0.8.0",
                incomingBuild: "101",
                expectedBuild: "100"
            )
        )
        XCTAssertTrue(
            AutomaticUpdateBundlePolicy.permitsVersionSet(
                expectedVersion: "0.8.0",
                expectedBuild: "100",
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
                expectedBuild: "100",
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
            at: fixture.archiveURL,
            fileManager: fixture.fileManager
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
                staged.applicationURL,
                fileManager: fixture.fileManager
            )
        )
        AppUpdateStager.discard(
            staged,
            fileManager: fixture.fileManager
        )
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
            try AppUpdateStager.stageArchive(
                at: ambiguous.archiveURL,
                fileManager: ambiguous.fileManager
            ) {
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
            try AppUpdateStager.stageArchive(
                at: rejected.archiveURL,
                fileManager: rejected.fileManager
            ) {
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
            at: fixture.archiveURL,
            fileManager: fixture.fileManager
        ) { _ in }

        AppUpdateStager.discardOwnedRoot(
            containing: staged.applicationURL,
            fileManager: fixture.fileManager
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staged.rootURL.path)
        )

        let unrelated = fixture.sourceRoot.appendingPathComponent(
            XDialBuildIdentity.applicationBundleName,
            isDirectory: true
        )
        AppUpdateStager.discardOwnedRoot(
            containing: unrelated,
            fileManager: fixture.fileManager
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.sourceRoot.path)
        )
    }

    func testStaleStagingCleanupRemovesOnlyOldOwnedUUIDRoots() throws {
        let fileManager = AppUpdateTemporaryFileManager()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let staleRoot = try AppUpdateStager.makeStagingRoot(
            fileManager: fileManager
        )
        let freshRoot = try AppUpdateStager.makeStagingRoot(
            fileManager: fileManager
        )
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

        AppUpdateStager.pruneStaleRoots(
            now: now,
            fileManager: fileManager
        )

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

}

private enum AppUpdateHTTPReply: Sendable {
    case response(AppUpdateHTTPResult)
    case failure(URLError.Code)
    case cancelled
}

private actor AppUpdateHTTPRecorder {
    private var replies: [AppUpdateHTTPReply]
    private var requests: [URLRequest] = []

    init(replies: [AppUpdateHTTPReply]) {
        self.replies = replies
    }

    nonisolated var transport: AppUpdateHTTPTransport {
        AppUpdateHTTPTransport { [self] request in
            try await perform(request)
        }
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }

    private func perform(_ request: URLRequest) throws
        -> AppUpdateHTTPResult
    {
        requests.append(request)
        guard !replies.isEmpty else {
            throw URLError(.resourceUnavailable)
        }
        switch replies.removeFirst() {
        case let .response(response):
            return response
        case let .failure(code):
            throw URLError(code)
        case .cancelled:
            throw CancellationError()
        }
    }
}

private actor AppUpdateReorderingTransport {
    private let firstResponse: AppUpdateHTTPResult
    private let secondResponse: AppUpdateHTTPResult
    private let laterResponse: AppUpdateHTTPResult
    private var requests: [URLRequest] = []
    private var firstStarted = false
    private var firstStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstRelease: CheckedContinuation<Void, Never>?

    init(
        firstResponse: AppUpdateHTTPResult,
        secondResponse: AppUpdateHTTPResult,
        laterResponse: AppUpdateHTTPResult
    ) {
        self.firstResponse = firstResponse
        self.secondResponse = secondResponse
        self.laterResponse = laterResponse
    }

    nonisolated var transport: AppUpdateHTTPTransport {
        AppUpdateHTTPTransport { [self] request in
            await perform(request)
        }
    }

    func waitUntilFirstRequestStarts() async {
        if firstStarted { return }
        await withCheckedContinuation { continuation in
            firstStartWaiters.append(continuation)
        }
    }

    func releaseFirstResponse() {
        firstRelease?.resume()
        firstRelease = nil
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }

    private func perform(_ request: URLRequest) async
        -> AppUpdateHTTPResult
    {
        requests.append(request)
        switch requests.count {
        case 1:
            firstStarted = true
            let waiters = firstStartWaiters
            firstStartWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                firstRelease = continuation
            }
            return firstResponse
        case 2:
            return secondResponse
        default:
            return laterResponse
        }
    }
}

private final class AppUpdateArchiveFixture {
    let fileManager = AppUpdateTemporaryFileManager()
    let sourceRoot: URL
    let stagingRoot: URL
    let archiveURL: URL

    init(rootEntries: [String]) throws {
        sourceRoot = fileManager.temporaryDirectory
            .appendingPathComponent(
                "xdial-update-source-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: sourceRoot,
            withIntermediateDirectories: true
        )
        for entry in rootEntries {
            let entryURL = sourceRoot.appendingPathComponent(entry)
            if entry == XDialBuildIdentity.applicationBundleName {
                try fileManager.createDirectory(
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

        stagingRoot = try AppUpdateStager.makeStagingRoot(
            fileManager: fileManager
        )
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
        where fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }
}

private final class AppUpdateTemporaryFileManager: FileManager {
    private let isolatedTemporaryDirectory: URL

    override var temporaryDirectory: URL {
        isolatedTemporaryDirectory
    }

    override init() {
        isolatedTemporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "xdial-update-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        super.init()
        try! createDirectory(
            at: isolatedTemporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(
            at: isolatedTemporaryDirectory
        )
    }
}
