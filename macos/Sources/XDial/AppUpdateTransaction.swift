import Foundation

struct AppUpdateReleaseCandidate: Equatable, Sendable {
    let tag: String
    let version: String
    let build: String
    let minimumSystemVersion: String
    let publishedAt: Date
    let archiveName: String
    let archiveURL: URL
    let archiveSize: Int64
    let archiveSHA256: String
    let releaseNotes: String

    var identity: AppUpdateCandidateIdentity {
        AppUpdateCandidateIdentity(
            version: version,
            build: build,
            archiveSHA256: archiveSHA256
        )
    }
}

struct AppUpdateCandidateIdentity: Equatable, Sendable {
    let version: String
    let build: String
    let archiveSHA256: String
}

enum AppUpdateReleaseSelectionError: Error, Equatable {
    case invalidVersionTag
    case invalidBuild
    case invalidMinimumSystemVersion
    case unsupportedSystemVersion
    case invalidPublishedAt
    case releaseNotesMissing
    case notNewer
    case archiveSizeInvalid
    case archiveSHA256Invalid
    case archiveURLRejected
}

enum AppUpdateReleasePolicy {
    static func selectCandidate(
        from release: AppUpdateFeedRelease,
        generatedAt: Date,
        configuration: AppUpdateFeedConfiguration,
        currentVersion: String,
        currentSystemVersion: String
    ) throws -> AppUpdateReleaseCandidate {
        guard VersionUpdatePolicy.stableReleaseVersion(
            fromTag: release.tag
        ) == release.version else {
            throw AppUpdateReleaseSelectionError.invalidVersionTag
        }
        guard isPositiveInteger(release.build) else {
            throw AppUpdateReleaseSelectionError.invalidBuild
        }
        guard let minimumSystemVersion = NumericSystemVersion(
            release.minimumSystemVersion
        ) else {
            throw AppUpdateReleaseSelectionError
                .invalidMinimumSystemVersion
        }
        guard let currentSystemVersion = NumericSystemVersion(
            currentSystemVersion
        ), currentSystemVersion >= minimumSystemVersion else {
            throw AppUpdateReleaseSelectionError.unsupportedSystemVersion
        }
        guard release.publishedAt <= generatedAt else {
            throw AppUpdateReleaseSelectionError.invalidPublishedAt
        }

        let releaseNotes = release.releaseNotes.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !releaseNotes.isEmpty else {
            throw AppUpdateReleaseSelectionError.releaseNotesMissing
        }
        guard AppUpdateArchivePolicy.permitsArchiveByteCount(
            release.archiveSize
        ) else {
            throw AppUpdateReleaseSelectionError.archiveSizeInvalid
        }
        guard release.archiveSHA256.count == 64,
              release.archiveSHA256.utf8.allSatisfy({
                  (48 ... 57).contains($0) || (97 ... 102).contains($0)
              }) else {
            throw AppUpdateReleaseSelectionError.archiveSHA256Invalid
        }

        let archiveName = "XDial-\(release.tag).zip"
        guard configuration.permitsArchiveURL(
            release.archiveURL,
            tag: release.tag,
            archiveName: archiveName
        ) else {
            throw AppUpdateReleaseSelectionError.archiveURLRejected
        }
        guard VersionUpdatePolicy.isNewer(
            latestTag: release.tag,
            than: currentVersion
        ) else {
            throw AppUpdateReleaseSelectionError.notNewer
        }

        return AppUpdateReleaseCandidate(
            tag: release.tag,
            version: release.version,
            build: release.build,
            minimumSystemVersion: release.minimumSystemVersion,
            publishedAt: release.publishedAt,
            archiveName: archiveName,
            archiveURL: release.archiveURL,
            archiveSize: release.archiveSize,
            archiveSHA256: release.archiveSHA256,
            releaseNotes: releaseNotes
        )
    }

    private static func isPositiveInteger(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              (49 ... 57).contains(first) else {
            return false
        }
        return value.utf8.dropFirst().allSatisfy {
            (48 ... 57).contains($0)
        }
    }

    private struct NumericSystemVersion: Comparable {
        let components: [Int]

        init?(_ value: String) {
            let parts = value.split(
                separator: ".",
                omittingEmptySubsequences: false
            )
            guard (2 ... 3).contains(parts.count),
                  parts.allSatisfy({
                      !$0.isEmpty
                          && $0.utf8.allSatisfy {
                              (48 ... 57).contains($0)
                          }
                          && ($0 == "0" || $0.first != "0")
                  }) else {
                return nil
            }
            components = parts.compactMap { Int($0) }
            guard components.count == parts.count else { return nil }
        }

        static func < (
            lhs: NumericSystemVersion,
            rhs: NumericSystemVersion
        ) -> Bool {
            let count = max(lhs.components.count, rhs.components.count)
            for index in 0..<count {
                let left = index < lhs.components.count
                    ? lhs.components[index] : 0
                let right = index < rhs.components.count
                    ? rhs.components[index] : 0
                if left != right { return left < right }
            }
            return false
        }
    }
}
enum AppUpdateArchivePolicy {
    static let maximumArchiveBytes: Int64 = 512 * 1024 * 1024

    static func permitsArchiveByteCount(_ byteCount: Int64) -> Bool {
        byteCount > 0 && byteCount <= maximumArchiveBytes
    }

    static func containsExactlyOneRootApplication(
        _ names: [String]
    ) -> Bool {
        names == [XDialBuildIdentity.applicationBundleName]
    }
}

enum AppUpdateDownloadPolicy {
    static func permitsRedirect(to url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased()
                == "release-assets.githubusercontent.com"
            && url.port == nil
            && url.user == nil
            && url.password == nil
    }

    static func permitsResponse(
        statusCode: Int,
        expectedByteCount: Int64
    ) -> Bool {
        guard statusCode == 200 else { return false }
        return expectedByteCount == NSURLSessionTransferSizeUnknown
            || AppUpdateArchivePolicy.permitsArchiveByteCount(
                expectedByteCount
            )
    }

    static func permitsProgress(
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) -> Bool {
        guard totalBytesWritten >= 0,
              totalBytesWritten
                <= AppUpdateArchivePolicy.maximumArchiveBytes else {
            return false
        }
        return totalBytesExpectedToWrite
            == NSURLSessionTransferSizeUnknown
            || AppUpdateArchivePolicy.permitsArchiveByteCount(
                totalBytesExpectedToWrite
            )
    }
}

enum AppUpdatePhase: String, Equatable {
    case idle
    case checking
    case upToDate = "up_to_date"
    case noRelease = "no_release"
    case available
    case downloading
    case validating
    case ready
    case handingOff = "handing_off"
    case failed
}

enum AppUpdateFailureCode: String, Equatable {
    case checkUnavailable = "check_unavailable"
    case candidateChanged = "candidate_changed"
    case downloadFailed = "download_failed"
    case validationFailed = "validation_failed"
}

struct AppUpdateFailure: Equatable {
    let code: AppUpdateFailureCode
    let detail: String
}

struct AppUpdateRelaunchIntent: Codable, Equatable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let targetVersion: String
    let reconnectScenarioID: String?
    let createdAt: Date
}

enum AppUpdateRelaunchDecision: Equatable {
    case reconnect(scenarioID: String)
    case stayDisconnected
}

enum AppUpdateRelaunchIntentPolicy {
    static let maximumAge: TimeInterval = 30 * 60

    static func decision(
        for intent: AppUpdateRelaunchIntent,
        currentVersion: String,
        activeScenarioID: String,
        now: Date
    ) -> AppUpdateRelaunchDecision? {
        guard permitsTarget(
            intent,
            version: currentVersion,
            now: now
        ) else {
            return nil
        }
        guard let scenarioID = intent.reconnectScenarioID else {
            return .stayDisconnected
        }
        guard !scenarioID.isEmpty,
              scenarioID == activeScenarioID else {
            return nil
        }
        return .reconnect(scenarioID: scenarioID)
    }

    static func permitsTarget(
        _ intent: AppUpdateRelaunchIntent,
        version: String,
        now: Date
    ) -> Bool {
        let age = now.timeIntervalSince(intent.createdAt)
        return intent.schemaVersion
            == AppUpdateRelaunchIntent.schemaVersion
            && intent.targetVersion == version
            && age >= 0
            && age <= maximumAge
    }
}

enum AppUpdateRelaunchIntentStore {
    private static let key = "xdial.update.relaunch-intent"

    static func write(
        targetVersion: String,
        reconnectScenarioID: String?,
        now: Date = Date(),
        defaults: UserDefaults = xdialDefaults
    ) throws {
        let intent = AppUpdateRelaunchIntent(
            schemaVersion: AppUpdateRelaunchIntent.schemaVersion,
            targetVersion: targetVersion,
            reconnectScenarioID: reconnectScenarioID,
            createdAt: now
        )
        defaults.set(try JSONEncoder().encode(intent), forKey: key)
    }

    static func loadDecision(
        currentVersion: String,
        activeScenarioID: String,
        now: Date = Date(),
        defaults: UserDefaults = xdialDefaults
    ) -> AppUpdateRelaunchDecision? {
        guard let data = defaults.data(forKey: key),
              let intent = try? JSONDecoder().decode(
                  AppUpdateRelaunchIntent.self,
                  from: data
              ),
              let decision = AppUpdateRelaunchIntentPolicy.decision(
                  for: intent,
                  currentVersion: currentVersion,
                  activeScenarioID: activeScenarioID,
                  now: now
              ) else {
            defaults.removeObject(forKey: key)
            return nil
        }
        return decision
    }

    static func permitsStagedSuccessor(
        targetVersion: String,
        now: Date = Date(),
        defaults: UserDefaults = xdialDefaults
    ) -> Bool {
        guard let data = defaults.data(forKey: key),
              let intent = try? JSONDecoder().decode(
                  AppUpdateRelaunchIntent.self,
                  from: data
              ),
              AppUpdateRelaunchIntentPolicy.permitsTarget(
                  intent,
                  version: targetVersion,
                  now: now
              ) else {
            defaults.removeObject(forKey: key)
            return false
        }
        return true
    }

    static func clear(
        defaults: UserDefaults = xdialDefaults
    ) {
        defaults.removeObject(forKey: key)
    }
}

enum AutomaticUpdateBundlePolicy {
    static let releaseHelperIdentifier =
        XDialBuildIdentity.helperIdentifier
    static let releaseExtensionIdentifier =
        XDialBuildIdentity.transparentProxyIdentifier

    static func permits(
        currentIdentifier: String,
        currentTeamIdentifier: String,
        currentAcceptanceID: String?,
        incomingIdentifier: String,
        incomingTeamIdentifier: String,
        incomingAcceptanceID: String?,
        incomingVersion: String,
        expectedVersion: String,
        incomingBuild: String,
        expectedBuild: String
    ) -> Bool {
        XDialBuildIdentity.allowsAutomaticUpdates
            && currentIdentifier == XDialBuildIdentity.applicationIdentifier
            && incomingIdentifier == XDialBuildIdentity.applicationIdentifier
            && !currentTeamIdentifier.isEmpty
            && currentTeamIdentifier == incomingTeamIdentifier
            && permitsAcceptanceTransition(
                currentAcceptanceID: currentAcceptanceID,
                incomingAcceptanceID: incomingAcceptanceID
            )
            && incomingVersion == expectedVersion
            && incomingBuild == expectedBuild
    }

    static func permitsAcceptanceTransition(
        currentAcceptanceID: String?,
        incomingAcceptanceID: String?
    ) -> Bool {
        currentAcceptanceID == incomingAcceptanceID
    }

    static func permitsVersionSet(
        expectedVersion: String,
        expectedBuild: String,
        hostVersion: String,
        hostBuild: String,
        settingsVersion: String,
        settingsBuild: String,
        extensionVersion: String,
        extensionBuild: String
    ) -> Bool {
        hostBuild == expectedBuild
            && hostVersion == expectedVersion
            && settingsVersion == expectedVersion
            && extensionVersion == expectedVersion
            && settingsBuild == hostBuild
            && extensionBuild == hostBuild
    }
}
