import Foundation

struct AppUpdateReleaseCandidate: Equatable, Sendable {
    let tag: String
    let version: String
    let archiveName: String
    let archiveURL: URL
    let releaseNotes: String?
}

enum AppUpdateReleaseSelectionError: Error, Equatable {
    case malformedResponse
    case draftRelease
    case prerelease
    case invalidVersionTag
    case notNewer
    case archiveMissing
    case archiveURLRejected
}

enum AppUpdateReleasePolicy {
    private static let owner = "kafeifei"
    private static let repository = "XDial"

    static func selectCandidate(
        from data: Data,
        currentVersion: String
    ) throws -> AppUpdateReleaseCandidate {
        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(
                GitHubRelease.self,
                from: data
            )
        } catch {
            throw AppUpdateReleaseSelectionError.malformedResponse
        }
        guard !release.draft else {
            throw AppUpdateReleaseSelectionError.draftRelease
        }
        guard !release.prerelease else {
            throw AppUpdateReleaseSelectionError.prerelease
        }
        guard let version = VersionUpdatePolicy.stableReleaseVersion(
            fromTag: release.tagName
        ) else {
            throw AppUpdateReleaseSelectionError.invalidVersionTag
        }
        guard VersionUpdatePolicy.isNewer(
            latestTag: release.tagName,
            than: currentVersion
        ) else {
            throw AppUpdateReleaseSelectionError.notNewer
        }

        let archiveName = "XDial-\(release.tagName).zip"
        guard let asset = release.assets.first(where: {
            $0.name == archiveName
        }) else {
            throw AppUpdateReleaseSelectionError.archiveMissing
        }
        guard permitsArchiveURL(
            asset.browserDownloadURL,
            tag: release.tagName,
            archiveName: archiveName
        ) else {
            throw AppUpdateReleaseSelectionError.archiveURLRejected
        }

        return AppUpdateReleaseCandidate(
            tag: release.tagName,
            version: version,
            archiveName: archiveName,
            archiveURL: asset.browserDownloadURL,
            releaseNotes: releaseNotes(from: release.body)
        )
    }

    static func releaseNotes(from body: String?) -> String? {
        guard let body else { return nil }
        let trimmedBody = body.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedBody.isEmpty else { return nil }

        let acceptedHeadings = Set(["更新了什么", "更新内容", "更新"])
        var capturesSection = false
        var capturedLines: [String] = []
        for line in body.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("## ") {
                if capturesSection { break }
                let heading = String(trimmedLine.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                capturesSection = acceptedHeadings.contains(heading)
                continue
            }
            if capturesSection {
                capturedLines.append(line)
            }
        }

        let section = capturedLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return section.isEmpty ? trimmedBody : section
    }

    private static func permitsArchiveURL(
        _ url: URL,
        tag: String,
        archiveName: String
    ) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com",
              url.port == nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            return false
        }
        return url.pathComponents == [
            "/",
            owner,
            repository,
            "releases",
            "download",
            tag,
            archiveName,
        ]
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body
            case draft
            case prerelease
            case assets
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
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
        names == ["XDial.app"]
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
    case available
    case downloading
    case validating
    case ready
    case handingOff = "handing_off"
    case failed
}

enum AppUpdateFailureCode: String, Equatable {
    case checkUnavailable = "check_unavailable"
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
    static let releaseHelperIdentifier = "com.kafeifei.xdial.helper"
    static let releaseExtensionIdentifier =
        "com.kafeifei.xdial.transparent-proxy"

    static func permits(
        currentIdentifier: String,
        currentTeamIdentifier: String,
        incomingIdentifier: String,
        incomingTeamIdentifier: String,
        incomingVersion: String,
        expectedVersion: String
    ) -> Bool {
        currentIdentifier == XDialApplicationIdentifierPolicy.release
            && incomingIdentifier == XDialApplicationIdentifierPolicy.release
            && !currentTeamIdentifier.isEmpty
            && currentTeamIdentifier == incomingTeamIdentifier
            && incomingVersion == expectedVersion
    }

    static func permitsVersionSet(
        expectedVersion: String,
        hostVersion: String,
        hostBuild: String,
        settingsVersion: String,
        settingsBuild: String,
        extensionVersion: String,
        extensionBuild: String
    ) -> Bool {
        !hostBuild.isEmpty
            && hostVersion == expectedVersion
            && settingsVersion == expectedVersion
            && extensionVersion == expectedVersion
            && settingsBuild == hostBuild
            && extensionBuild == hostBuild
    }
}
