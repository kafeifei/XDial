import Foundation

struct StagedAppUpdate: Equatable {
    let rootURL: URL
    let applicationURL: URL
}

enum AppUpdateStagingError: LocalizedError {
    case archiveOutsideOwnedRoot
    case archiveInvalid
    case extractionFailed
    case archiveLayoutInvalid
    case applicationIsSymbolicLink

    var errorDescription: String? {
        switch self {
        case .archiveOutsideOwnedRoot:
            "更新包不在 XDial 管理的临时目录中"
        case .archiveInvalid:
            "更新包为空或超过 512 MiB"
        case .extractionFailed:
            "无法解压更新包"
        case .archiveLayoutInvalid:
            "更新包必须只包含一个 XDial.app"
        case .applicationIsSymbolicLink:
            "更新包中的 XDial.app 不能是符号链接"
        }
    }
}

enum AppUpdateStager {
    static let staleRootMaximumAge: TimeInterval = 24 * 60 * 60
    private static let rootDirectoryName = "XDialUpdates"
    private static let archiveName = "download.zip"

    static func makeStagingRoot(
        fileManager: FileManager = .default
    ) throws -> URL {
        let baseURL = ownedBaseURL(fileManager: fileManager)
        try fileManager.createDirectory(
            at: baseURL,
            withIntermediateDirectories: true
        )
        pruneStaleRoots(fileManager: fileManager)
        let rootURL = baseURL.appendingPathComponent(
            UUID().uuidString.lowercased(),
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false
        )
        return rootURL
    }

    static func pruneStaleRoots(
        now: Date = Date(),
        fileManager: FileManager = .default
    ) {
        let baseURL = ownedBaseURL(fileManager: fileManager)
        guard let contents = try? fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for candidate in contents {
            guard UUID(uuidString: candidate.lastPathComponent) != nil,
                  let values = try? candidate.resourceValues(
                      forKeys: [
                          .contentModificationDateKey,
                          .isDirectoryKey,
                          .isSymbolicLinkKey,
                      ]
                  ),
                  values.isDirectory == true,
                  values.isSymbolicLink != true,
                  let modifiedAt = values.contentModificationDate,
                  now.timeIntervalSince(modifiedAt)
                    > staleRootMaximumAge,
                  isOwnedRoot(candidate, fileManager: fileManager) else {
                continue
            }
            try? fileManager.removeItem(at: candidate)
        }
    }

    static func archiveURL(in rootURL: URL) -> URL {
        rootURL.appendingPathComponent(archiveName, isDirectory: false)
    }

    static func stageArchive(
        at archiveURL: URL,
        fileManager: FileManager = .default,
        validate: (URL) throws -> Void
    ) throws -> StagedAppUpdate {
        let rootURL = archiveURL.deletingLastPathComponent()
        guard isOwnedRoot(rootURL, fileManager: fileManager),
              archiveURL.lastPathComponent == archiveName else {
            throw AppUpdateStagingError.archiveOutsideOwnedRoot
        }

        do {
            let values = try archiveURL.resourceValues(
                forKeys: [
                    .fileSizeKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ]
            )
            let byteCount = Int64(values.fileSize ?? 0)
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  AppUpdateArchivePolicy.permitsArchiveByteCount(
                      byteCount
                  ) else {
                throw AppUpdateStagingError.archiveInvalid
            }

            let extractionURL = rootURL.appendingPathComponent(
                "expanded",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: extractionURL,
                withIntermediateDirectories: false
            )
            try extract(
                archiveURL: archiveURL,
                destinationURL: extractionURL
            )

            let contents = try fileManager.contentsOfDirectory(
                at: extractionURL,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: []
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard AppUpdateArchivePolicy
                .containsExactlyOneRootApplication(
                    contents.map(\.lastPathComponent)
                ), let applicationURL = contents.first else {
                throw AppUpdateStagingError.archiveLayoutInvalid
            }
            let applicationValues = try applicationURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard applicationValues.isSymbolicLink != true else {
                throw AppUpdateStagingError.applicationIsSymbolicLink
            }
            guard applicationValues.isDirectory == true,
                  applicationURL.standardizedFileURL
                    .resolvingSymlinksInPath()
                    .deletingLastPathComponent()
                    == extractionURL.standardizedFileURL
                    .resolvingSymlinksInPath() else {
                throw AppUpdateStagingError.archiveLayoutInvalid
            }

            try validate(applicationURL)
            return StagedAppUpdate(
                rootURL: rootURL,
                applicationURL: applicationURL
            )
        } catch {
            if fileManager.fileExists(atPath: rootURL.path) {
                try? fileManager.removeItem(at: rootURL)
            }
            throw error
        }
    }

    static func discard(
        _ update: StagedAppUpdate,
        fileManager: FileManager = .default
    ) {
        guard isOwnedRoot(update.rootURL, fileManager: fileManager),
              fileManager.fileExists(atPath: update.rootURL.path) else {
            return
        }
        try? fileManager.removeItem(at: update.rootURL)
    }

    static func discardOwnedRoot(
        containing applicationURL: URL,
        fileManager: FileManager = .default
    ) {
        guard isOwnedStagedApplication(
            applicationURL,
            fileManager: fileManager
        ) else {
            return
        }
        let rootURL = applicationURL.deletingLastPathComponent()
            .deletingLastPathComponent()
        guard isOwnedRoot(rootURL, fileManager: fileManager),
              fileManager.fileExists(atPath: rootURL.path) else {
            return
        }
        try? fileManager.removeItem(at: rootURL)
    }

    static func isOwnedStagedApplication(
        _ applicationURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard applicationURL.lastPathComponent == "XDial.app",
              applicationURL.deletingLastPathComponent()
                .lastPathComponent == "expanded" else {
            return false
        }
        let rootURL = applicationURL.deletingLastPathComponent()
            .deletingLastPathComponent()
        return isOwnedRoot(rootURL, fileManager: fileManager)
    }

    private static func extract(
        archiveURL: URL,
        destinationURL: URL
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-x",
            "-k",
            archiveURL.path,
            destinationURL.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit,
              process.terminationStatus == 0 else {
            throw AppUpdateStagingError.extractionFailed
        }
    }

    private static func isOwnedRoot(
        _ rootURL: URL,
        fileManager: FileManager
    ) -> Bool {
        let canonicalRoot = rootURL.standardizedFileURL
            .resolvingSymlinksInPath()
        let canonicalBase = ownedBaseURL(fileManager: fileManager)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        return canonicalRoot.deletingLastPathComponent() == canonicalBase
            && UUID(uuidString: canonicalRoot.lastPathComponent) != nil
    }

    private static func ownedBaseURL(
        fileManager: FileManager
    ) -> URL {
        fileManager.temporaryDirectory.appendingPathComponent(
            rootDirectoryName,
            isDirectory: true
        )
    }
}
