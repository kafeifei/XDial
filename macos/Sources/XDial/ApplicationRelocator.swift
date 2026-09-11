import AppKit
import Foundation
import Security

enum ApplicationLaunchPreparation {
    case continueLaunch
    case relaunching
    case failed(message: String, canRetry: Bool)
}

/// XDial 的平台安装入口。替换前回收旧 helper，再复制并验证 app bundle；
/// 不注册网络配置，也不启动数据面。
enum ApplicationRelocator {
    private final class LaunchResult: @unchecked Sendable {
        private let lock = NSLock()
        private var application: NSRunningApplication?
        private var error: Error?

        func record(
            application: NSRunningApplication?,
            error: Error?
        ) {
            lock.lock()
            self.application = application
            self.error = error
            lock.unlock()
        }

        func snapshot() -> (NSRunningApplication?, Error?) {
            lock.lock()
            defer { lock.unlock() }
            return (application, error)
        }
    }

    private static let destinationURL =
        XDialBuildIdentity.applicationDestinationURL
    private static let launchServicesRegistrarURL = URL(
        fileURLWithPath:
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
                + "LaunchServices.framework/Support/lsregister"
    )

    static var isRunningFromApplications: Bool {
        canonical(Bundle.main.bundleURL) == canonical(destinationURL)
    }

    static func validateCurrentBundle() throws {
        _ = try validateDistributionBundle(at: Bundle.main.bundleURL)
    }

    static var permitsAutomaticUpdates: Bool {
        XDialBuildIdentity.allowsAutomaticUpdates
            && isRunningFromApplications
            && Bundle.main.bundleIdentifier
                == XDialBuildIdentity.applicationIdentifier
    }

    static func validateIncomingUpdateBundle(
        at bundleURL: URL,
        expectedVersion: String,
        expectedBuild: String
    ) throws {
        guard permitsAutomaticUpdates else {
            throw InstallationError.automaticUpdateUnsupported
        }
        let currentIdentity = try validateDistributionBundle(
            at: Bundle.main.bundleURL
        )
        let incomingIdentity = try validateDistributionBundle(at: bundleURL)
        let incomingVersion = ApplicationBundleInfo.string(
            forKey: "CFBundleShortVersionString",
            at: bundleURL
        ) ?? ""
        let incomingBuild = ApplicationBundleInfo.string(
            forKey: "CFBundleVersion",
            at: bundleURL
        ) ?? ""
        let currentAcceptanceID = try AppUpdateFeedConfiguration.current(
            at: Bundle.main.bundleURL
        ).acceptanceID
        let incomingAcceptanceID = try AppUpdateFeedConfiguration.current(
            at: bundleURL
        ).acceptanceID
        let settingsURL = bundleURL.appendingPathComponent(
            "Contents/Helpers/XDial Settings UI.app",
            isDirectory: true
        )
        let extensionURL = bundleURL.appendingPathComponent(
            "Contents/Library/SystemExtensions/"
                + AutomaticUpdateBundlePolicy
                    .releaseExtensionIdentifier
                + ".systemextension",
            isDirectory: true
        )
        guard AutomaticUpdateBundlePolicy.permits(
            currentIdentifier: currentIdentity.identifier,
            currentTeamIdentifier: currentIdentity.teamIdentifier,
            currentAcceptanceID: currentAcceptanceID,
            incomingIdentifier: incomingIdentity.identifier,
            incomingTeamIdentifier: incomingIdentity.teamIdentifier,
            incomingAcceptanceID: incomingAcceptanceID,
            incomingVersion: incomingVersion,
            expectedVersion: expectedVersion,
            incomingBuild: incomingBuild,
            expectedBuild: expectedBuild
        ),
        ApplicationBundleInfo.string(
            forKey: "XDialTransparentProxyBundleIdentifier",
            at: bundleURL
        ) == AutomaticUpdateBundlePolicy.releaseExtensionIdentifier,
        AutomaticUpdateBundlePolicy.permitsVersionSet(
            expectedVersion: expectedVersion,
            expectedBuild: expectedBuild,
            hostVersion: incomingVersion,
            hostBuild: incomingBuild,
            settingsVersion: ApplicationBundleInfo.string(
                forKey: "CFBundleShortVersionString",
                at: settingsURL
            ) ?? "",
            settingsBuild: ApplicationBundleInfo.string(
                forKey: "CFBundleVersion",
                at: settingsURL
            ) ?? "",
            extensionVersion: ApplicationBundleInfo.string(
                forKey: "CFBundleShortVersionString",
                at: extensionURL
            ) ?? "",
            extensionBuild: ApplicationBundleInfo.string(
                forKey: "CFBundleVersion",
                at: extensionURL
            ) ?? ""
        ) else {
            throw InstallationError.automaticUpdateIdentityMismatch
        }
    }

    /// 开发重启先在无 UI、无 AppState 的进程中完成原子替换，再只启动
    /// /Applications 中的最终 bundle。这样不会先启动构建目录副本、建立一次
    /// 网络事务，随后又因自动安装被终止并建立第二次事务。
    static func installCurrentBundleWithoutRelaunch() throws {
        let sourceURL = Bundle.main.bundleURL
        let sourceIdentity = try validateDistributionBundle(at: sourceURL)
        if isRunningFromApplications {
            recoverOwnedArtifactsAfterSuccessfulLaunch(sourceIdentity: sourceIdentity)
            return
        }
        try install(
            sourceURL: sourceURL,
            sourceIdentity: sourceIdentity
        )
    }

    static func moveInstalledApplicationToTrash() throws {
        guard isRunningFromApplications else {
            throw InstallationError.applicationNotInstalled
        }
        try unregisterApplication(at: destinationURL)
        var resultingURL: NSURL?
        try FileManager.default.trashItem(
            at: destinationURL,
            resultingItemURL: &resultingURL
        )
    }

    /// A command-line uninstaller does not pass through the normal singleton
    /// launch check. Finish the installed UI process before removing services
    /// so it cannot recreate them while this process is uninstalling the app.
    static func prepareCommandLineUninstall() throws {
        guard isRunningFromApplications else {
            throw InstallationError.applicationNotInstalled
        }
        let identity = try validateDistributionBundle(at: Bundle.main.bundleURL)
        try terminateOtherCopies(bundleIdentifiers: [identity.identifier])
    }

    /// Run by the incoming installer's own child process, whose event loop can
    /// await ServiceManagement without blocking the synchronous file transaction.
    /// Keep the outgoing container at its registered path until teardown ends.
    static func validateHelperReplacement() throws -> URL {
        let incoming = try validateDistributionBundle(at: Bundle.main.bundleURL)
        let outgoing = try existingApplicationIdentity(at: destinationURL)
        guard incoming == outgoing,
              platformComponentIdentifiers(at: destinationURL)
                == platformComponentIdentifiers(at: Bundle.main.bundleURL) else {
            throw InstallationError.existingApplicationNotReplaceable
        }
        return destinationURL
    }

    /// A helper may have held the replaced bundle during launch. Installation
    /// retries receipt cleanup once platform preparation has released it.
    static func finishOwnedArtifactRecovery() {
        guard isRunningFromApplications,
              let identity = try? validateDistributionBundle(at: destinationURL) else { return }
        recoverOwnedArtifactsAfterSuccessfulLaunch(sourceIdentity: identity)
    }

    static func prepareForLaunch() -> ApplicationLaunchPreparation {
        let sourceURL = Bundle.main.bundleURL
        do {
            let sourceIdentity = try validateDistributionBundle(at: sourceURL)
            // Only the final /Applications launch carries this marker. A
            // staged automatic update still needs to perform installation.
            // Never recurse into replacement if LaunchServices relocates the
            // final successor: its predecessor is waiting for this launch.
            guard !ApplicationLaunchPolicy.shouldRejectInstalledSuccessor(
                currentIsCanonical: isRunningFromApplications,
                arguments: CommandLine.arguments
            ) else {
                throw InstallationError.installedSuccessorLocationMismatch
            }
            if AppUpdateStager.isOwnedStagedApplication(sourceURL) {
                let sourceVersion = ApplicationBundleInfo.string(
                    forKey: "CFBundleShortVersionString",
                    at: sourceURL
                ) ?? ""
                guard AppUpdateRelaunchIntentStore
                    .permitsStagedSuccessor(
                        targetVersion: sourceVersion
                    ) else {
                    throw InstallationError
                        .automaticUpdateIdentityMismatch
                }
            }
            if isRunningFromApplications {
                recoverOwnedArtifactsAfterSuccessfulLaunch(sourceIdentity: sourceIdentity)
            } else {
                try recoverOwnedArtifacts(sourceIdentity: sourceIdentity)
            }
            let destinationExists = FileManager.default.fileExists(
                atPath: destinationURL.path
            )
            let destinationMatchesIdentity: Bool
            let destinationIsRecognizedProduct: Bool
            let destinationIdentity: SigningIdentity?
            if destinationExists {
                let identity = try existingApplicationIdentity(
                    at: destinationURL
                )
                destinationIdentity = identity
                destinationMatchesIdentity = identity == sourceIdentity
                destinationIsRecognizedProduct =
                    XDialApplicationIdentifierPolicy
                        .permitsReplacement(
                            existingIdentifier: identity.identifier,
                            incomingIdentifier: sourceIdentity.identifier,
                            teamIdentifiersMatch:
                                identity.teamIdentifier
                                    == sourceIdentity.teamIdentifier
                        )
            } else {
                destinationIdentity = nil
                destinationMatchesIdentity = false
                destinationIsRecognizedProduct = false
            }

            switch ApplicationRelocationDecision.decide(
                currentIsCanonical: isRunningFromApplications,
                destinationExists: destinationExists,
                destinationMatchesIdentity: destinationMatchesIdentity,
                destinationIsRecognizedProduct:
                    destinationIsRecognizedProduct
            ) {
            case .continueLaunch:
                // A matching bundle identifier does not make a downloaded or
                // running installer ours to unregister. Only receipt-owned
                // artifacts and an explicitly replaced destination may have
                // their LaunchServices registration removed.
                return .continueLaunch
            case .rejectExisting:
                return .failed(
                    message:
                        "“应用程序”中已有另一份签名或标识不同的 XDial。"
                        + "为避免覆盖未知程序，XDial 已停止自动安装。",
                    canRetry: false
                )
            case .install, .replace:
                do {
                    try install(
                        sourceURL: sourceURL,
                        sourceIdentity: sourceIdentity
                    )
                    try relaunchInstalledApplication()
                    // A legacy temporary app may itself have been launched.
                    // Once its successor is ready, this installer can release
                    // its own artifact without touching the user's download.
                    recoverOwnedArtifactsAfterSuccessfulLaunch(
                        sourceIdentity: sourceIdentity,
                        ignoringCurrentInstaller: true
                    )
                    AppUpdateStager.discardOwnedRoot(
                        containing: sourceURL
                    )
                    return .relaunching
                } catch {
                    if case InstallationError.helperReplacementPreparationFailed = error {
                        // An abnormal cleanup-child exit cannot establish the
                        // OS completion barrier. Keep the old container closed.
                    } else {
                        relaunchInstalledApplicationAfterFailedReplacement(
                            sourceIdentity: sourceIdentity,
                            replacedIdentity: destinationIdentity
                        )
                    }
                    throw error
                }
            }
        } catch {
            return .failed(
                message: error.localizedDescription,
                canRetry:
                    (error as? InstallationError)?.canRetry ?? false
            )
        }
    }

    private static func install(
        sourceURL: URL,
        sourceIdentity: SigningIdentity
    ) throws {
        let artifacts = installationArtifacts(sourceIdentity: sourceIdentity)
        try artifacts.withExclusiveAccess {
            try artifacts.recoverAbandonedTransactions()
            // Another installer may have run since launch preparation. Re-read
            // the destination while holding the same lock as the replacement.
            let replaceExisting = FileManager.default.fileExists(atPath: destinationURL.path)
            let replacedIdentity = replaceExisting
                ? try existingApplicationIdentity(at: destinationURL) : nil
            if let replacedIdentity {
                guard XDialApplicationIdentifierPolicy.permitsReplacement(
                    existingIdentifier: replacedIdentity.identifier,
                    incomingIdentifier: sourceIdentity.identifier,
                    teamIdentifiersMatch:
                        replacedIdentity.teamIdentifier == sourceIdentity.teamIdentifier
                ) else {
                    throw InstallationError.existingApplicationNotReplaceable
                }
            }
            try artifacts.perform { transaction in
                try installApplicationFiles(
                    sourceURL: sourceURL,
                    sourceIdentity: sourceIdentity,
                    replacedIdentity: replacedIdentity,
                    replaceExisting: replaceExisting,
                    temporaryURL: artifacts.stagingURL(for: transaction),
                    backupName: transaction.backupName
                )
            }
        }
        // Release the lock before waiting for the final successor, which also
        // reconciles abandoned artifacts during its own startup.
    }

    private static func installApplicationFiles(
        sourceURL: URL,
        sourceIdentity: SigningIdentity,
        replacedIdentity: SigningIdentity?,
        replaceExisting: Bool,
        temporaryURL: URL,
        backupName: String
    ) throws {
        let fileManager = FileManager.default
        try fileManager.copyItem(at: sourceURL, to: temporaryURL)
        guard try validateDistributionBundle(at: temporaryURL)
            == sourceIdentity else {
            throw InstallationError.copiedBundleIdentityChanged
        }
        try ApplicationInstallationQuarantine.prepareValidatedCopy(
            at: temporaryURL
        )
        try ApplicationInstallationQuarantine.validateInstalledCopy(
            at: temporaryURL
        )

        if replaceExisting {
            try terminateOtherCopies(
                bundleIdentifiers: Set(
                    [
                        sourceIdentity.identifier,
                        replacedIdentity?.identifier,
                    ].compactMap { $0 }
                )
            )
            if let replacedIdentity,
               let cleanup = OutgoingApplicationCleanup.plan(
                   existingBundleURL: destinationURL,
                   existingIdentifier: replacedIdentity.identifier,
                   incomingIdentifier: sourceIdentity.identifier,
                   teamIdentifiersMatch:
                        replacedIdentity.teamIdentifier
                           == sourceIdentity.teamIdentifier,
                   requiresComponentCleanup:
                        platformComponentIdentifiers(at: destinationURL)
                            != platformComponentIdentifiers(at: sourceURL)
               ) {
                try OutgoingApplicationCleanup.run(
                    cleanup,
                    execute: runOutgoingCleanupProcess
                )
                try unregisterApplication(at: destinationURL)
            } else {
                // The currently registered helper still belongs to the old
                // container. Unregister it before moving that container to a
                // backup; a successor must not repair registration afterwards.
                let cleanup = OutgoingApplicationCleanup.Plan(
                    executableURL: sourceURL.appendingPathComponent("Contents/MacOS/XDial"),
                    arguments: [OutgoingApplicationCleanup.helperReplacementArgument],
                    timeout: .infinity
                )
                do {
                    try OutgoingApplicationCleanup.run(cleanup, execute: runOutgoingCleanupProcess)
                } catch {
                    throw InstallationError.helperReplacementPreparationFailed
                }
            }
            try ApplicationBundleReplacer.replace(
                fileManager: fileManager,
                destinationURL: destinationURL,
                newBundleURL: temporaryURL,
                backupName: backupName,
                retainBackupForRecovery: true
            ) { installedURL in
                try ApplicationInstallationQuarantine.validateInstalledCopy(
                    at: installedURL
                )
                return try validateDistributionBundle(at: installedURL)
                    == sourceIdentity
            }
            // The receipt owns removal: it first checks background-process
            // occupancy and unregisters the backup while it still exists.
        } else {
            try fileManager.moveItem(
                at: temporaryURL,
                to: destinationURL
            )
            do {
                try ApplicationInstallationQuarantine.validateInstalledCopy(
                    at: destinationURL
                )
                guard try validateDistributionBundle(
                    at: destinationURL
                ) == sourceIdentity else {
                    throw InstallationError
                        .installedBundleIdentityChanged
                }
            } catch {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try? fileManager.removeItem(at: destinationURL)
                }
                throw error
            }
        }
    }

    private static func runOutgoingCleanupProcess(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> Bool {
        guard FileManager.default.isExecutableFile(
            atPath: executableURL.path
        ) else {
            return false
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            completion.signal()
        }
        try process.run()
        let deadline: DispatchTime = timeout.isInfinite
            ? .distantFuture : .now() + max(0, timeout)
        guard completion.wait(timeout: deadline) == .success else {
            process.terminate()
            _ = completion.wait(timeout: .now() + 1)
            return false
        }
        return process.terminationReason == .exit
            && process.terminationStatus == 0
    }

    private static func installationArtifacts(
        sourceIdentity: SigningIdentity,
        ignoringCurrentInstaller: Bool = false
    ) -> ApplicationInstallationArtifacts {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let identifiers = XDialApplicationIdentifierPolicy.obsoleteIdentifiers(
            forInstalledIdentifier: sourceIdentity.identifier
        ).union([sourceIdentity.identifier])
        return ApplicationInstallationArtifacts(
            destinationURL: destinationURL,
            applicationIdentifier: sourceIdentity.identifier,
            teamIdentifier: sourceIdentity.teamIdentifier,
            isTrustedApplication: { url in
                guard let identity = try? existingApplicationIdentity(at: url),
                      XDialApplicationIdentifierPolicy.permitsReplacement(
                        existingIdentifier: identity.identifier,
                        incomingIdentifier: sourceIdentity.identifier,
                        teamIdentifiersMatch:
                            identity.teamIdentifier == sourceIdentity.teamIdentifier
                      ) else { return false }
                if canonical(url) == canonical(destinationURL) {
                    return (try? validateDistributionBundle(at: url)) == sourceIdentity
                }
                return true
            },
            isInUse: { url in
                var runningURLs = NSWorkspace.shared.runningApplications.compactMap {
                    application -> URL? in
                    if ignoringCurrentInstaller, application.processIdentifier == currentPID {
                        return nil
                    }
                    return application.bundleURL
                }
                // CLI installers need not have registered with AppKit yet.
                if !ignoringCurrentInstaller { runningURLs.append(Bundle.main.bundleURL) }
                return ApplicationInstallationOccupancy.mayBeInUse(
                    url,
                    processes: LocalProcessInventory.capture(),
                    applicationURLs: runningURLs,
                    ignoringPID: ignoringCurrentInstaller ? currentPID : nil
                )
            },
            unregisterApplication: { url in
                for identifier in identifiers {
                    if NSWorkspace.shared.urlsForApplications(
                        withBundleIdentifier: identifier
                    ).contains(where: { canonical($0) == canonical(url) }) {
                        try unregisterApplication(at: url)
                        return
                    }
                }
            }
        )
    }

    private static func recoverOwnedArtifactsAfterSuccessfulLaunch(
        sourceIdentity: SigningIdentity,
        ignoringCurrentInstaller: Bool = false
    ) {
        do {
            try recoverOwnedArtifacts(
                sourceIdentity: sourceIdentity,
                ignoringCurrentInstaller: ignoringCurrentInstaller,
                successfulLaunch: true
            )
        } catch {
            NSLog("XDial installation cleanup deferred: %@", error.localizedDescription)
        }
    }

    private static func recoverOwnedArtifacts(
        sourceIdentity: SigningIdentity,
        ignoringCurrentInstaller: Bool = false,
        successfulLaunch: Bool = false
    ) throws {
        // A canonical app can be run by a user without write access to
        // /Applications. Do not create installation state when none is pending.
        let names = try FileManager.default.contentsOfDirectory(
            atPath: destinationURL.deletingLastPathComponent().path
        )
        let prefix = XDialBuildIdentity.installationArtifactPrefix
        guard names.contains(where: {
            $0.hasPrefix(prefix + ".transaction-")
                || $0.hasPrefix(prefix + ".install-")
                || $0.hasPrefix(prefix + ".backup-")
        }) else { return }
        let artifacts = installationArtifacts(
            sourceIdentity: sourceIdentity,
            ignoringCurrentInstaller: ignoringCurrentInstaller
        )
        if successfulLaunch {
            if let failure = artifacts.recoverAfterSuccessfulLaunch() {
                NSLog("XDial installation cleanup deferred: %@", failure)
            }
        } else {
            try artifacts.withExclusiveAccess {
                try artifacts.recoverAbandonedTransactions()
            }
        }
    }

    private static func unregisterApplication(at bundleURL: URL) throws {
        guard FileManager.default.isExecutableFile(
            atPath: launchServicesRegistrarURL.path
        ) else {
            throw InstallationError.launchServicesRegistrarMissing
        }
        let process = Process()
        process.executableURL = launchServicesRegistrarURL
        process.arguments = ["-u", bundleURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard
            process.terminationReason == .exit,
            process.terminationStatus == 0
        else {
            throw InstallationError.applicationUnregistrationFailed
        }
    }

    private static func relaunchInstalledApplication() throws {
        let configuration = NSWorkspace.OpenConfiguration()
        ApplicationLaunchPolicy.configure(
            configuration,
            relocationPredecessorProcessIdentifier:
                ProcessInfo.processInfo.processIdentifier,
            isInstalledSuccessor: true
        )
        let completion = DispatchSemaphore(value: 0)
        let result = LaunchResult()
        NSWorkspace.shared.openApplication(
            at: destinationURL,
            configuration: configuration
        ) { application, error in
            result.record(application: application, error: error)
            completion.signal()
        }
        guard completion.wait(timeout: .now() + 30) == .success else {
            throw InstallationError.relaunchFailed
        }
        let (application, error) = result.snapshot()
        guard application != nil, error == nil else {
            throw InstallationError.relaunchFailed
        }
    }

    private static func relaunchInstalledApplicationAfterFailedReplacement(
        sourceIdentity: SigningIdentity,
        replacedIdentity: SigningIdentity?
    ) {
        guard FileManager.default.fileExists(atPath: destinationURL.path)
        else {
            return
        }
        let identifiers = Set(
            [
                sourceIdentity.identifier,
                replacedIdentity?.identifier,
            ].compactMap { $0 }
        )
        guard otherRunningCopies(
            bundleIdentifiers: identifiers,
            currentProcessIdentifier:
                ProcessInfo.processInfo.processIdentifier
        ).isEmpty else {
            return
        }
        try? relaunchInstalledApplication()
    }

    static func isExpectedRelaunchPredecessor(
        _ application: NSRunningApplication,
        processIdentifier: Int32?
    ) -> Bool {
        let bundleIdentifierMatches =
            application.bundleIdentifier == Bundle.main.bundleIdentifier
        let candidateBundleIsCanonical = application.bundleURL.map {
            canonical($0) == canonical(destinationURL)
        } ?? true
        return ApplicationRelaunchHandoffPolicy.shouldIgnoreCandidate(
            currentIsCanonical: isRunningFromApplications,
            candidateProcessIdentifier: application.processIdentifier,
            candidateBundleIdentifierMatches:
                bundleIdentifierMatches,
            candidateBundleIsCanonical: candidateBundleIsCanonical,
            expectedPredecessorProcessIdentifier: processIdentifier
        )
    }

    private static func terminateOtherCopies(
        bundleIdentifiers: Set<String>
    ) throws {
        let currentProcessIdentifier =
            ProcessInfo.processInfo.processIdentifier
        let terminated =
            ApplicationReplacementExitWaiter.wait(
                requestGracefulTermination: {
                    processIdentifier in
                    guard
                        let application = otherRunningCopies(
                            bundleIdentifiers:
                                bundleIdentifiers,
                            currentProcessIdentifier:
                                currentProcessIdentifier
                        ).first(where: {
                            $0.processIdentifier
                                == processIdentifier
                        })
                    else {
                        return
                    }
                    _ = application.terminate()
                },
                remainingProcessIdentifiers: {
                    Set(
                        otherRunningCopies(
                            bundleIdentifiers:
                                bundleIdentifiers,
                            currentProcessIdentifier:
                                currentProcessIdentifier
                        ).map(\.processIdentifier)
                    )
                }
            )
        guard terminated else {
            throw InstallationError.existingApplicationDidNotTerminate
        }
    }

    private static func otherRunningCopies(
        bundleIdentifiers: Set<String>,
        currentProcessIdentifier: Int32
    ) -> [NSRunningApplication] {
        let candidates = bundleIdentifiers.flatMap {
            NSRunningApplication.runningApplications(
                withBundleIdentifier: $0
            )
        }
        let processIdentifiers =
            ApplicationReplacementExitWaiter
                .otherProcessIdentifiers(
                    currentProcessIdentifier:
                        currentProcessIdentifier,
                    candidateProcessIdentifiers:
                        candidates.map(\.processIdentifier)
                )
        var applicationsByProcessIdentifier:
            [Int32: NSRunningApplication] = [:]
        for application in candidates
        where processIdentifiers.contains(
            application.processIdentifier
        ) {
            applicationsByProcessIdentifier[
                application.processIdentifier
            ] = application
        }
        return Array(applicationsByProcessIdentifier.values)
    }

    private static func validateDistributionBundle(
        at bundleURL: URL
    ) throws -> SigningIdentity {
        guard
            bundleURL.pathExtension == "app",
            let bundleIdentifier = ApplicationBundleInfo.identifier(
                at: bundleURL
            )
        else {
            throw InstallationError.invalidApplicationBundle
        }

        let hostIdentity = try signingIdentity(at: bundleURL)
        guard hostIdentity.identifier == bundleIdentifier else {
            throw InstallationError.bundleIdentifierMismatch
        }
        guard XDialApplicationIdentifierPolicy
            .permitsIncomingInstallation(
                identifier: hostIdentity.identifier
            ) else {
            throw InstallationError.bundleIdentifierMismatch
        }

        let helperURL = bundleURL.appendingPathComponent(
            "Contents/MacOS/xdial-daemon"
        )
        guard FileManager.default.isExecutableFile(
            atPath: helperURL.path
        ) else {
            throw InstallationError.helperMissing
        }
        let helperIdentity = try signingIdentity(at: helperURL)
        guard helperIdentity.identifier
                == AutomaticUpdateBundlePolicy.releaseHelperIdentifier,
              helperIdentity.teamIdentifier == hostIdentity.teamIdentifier else {
            throw InstallationError.helperSignatureMismatch
        }

        guard let expectedSettingsIdentifier =
            XDialApplicationIdentifierPolicy.settingsUIIdentifier(
                forApplicationIdentifier: hostIdentity.identifier
            ) else {
            throw InstallationError.bundleIdentifierMismatch
        }
        let settingsURL = bundleURL.appendingPathComponent(
            "Contents/Helpers/XDial Settings UI.app",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            throw InstallationError.settingsUIMissing
        }
        let settingsIdentity = try signingIdentity(at: settingsURL)
        guard settingsIdentity.identifier == expectedSettingsIdentifier,
              settingsIdentity.teamIdentifier == hostIdentity.teamIdentifier
        else {
            throw InstallationError.settingsUISignatureMismatch
        }

        guard let extensionIdentifier = ApplicationBundleInfo.string(
            forKey: "XDialTransparentProxyBundleIdentifier",
            at: bundleURL
        ), extensionIdentifier
            == XDialBuildIdentity.transparentProxyIdentifier else {
            throw InstallationError.extensionIdentifierMissing
        }
        let extensionsURL = bundleURL.appendingPathComponent(
            "Contents/Library/SystemExtensions",
            isDirectory: true
        )
        let extensionURLs = try FileManager.default.contentsOfDirectory(
            at: extensionsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "systemextension" }
        guard let extensionURL = extensionURLs.first(where: {
            ApplicationBundleInfo.identifier(at: $0)
                == extensionIdentifier
        }) else {
            throw InstallationError.extensionMissing
        }
        guard SystemExtensionBundleNaming.matches(
            bundleIdentifier: extensionIdentifier,
            bundleURL: extensionURL
        ) else {
            throw InstallationError.extensionFilenameMismatch
        }
        let extensionIdentity = try signingIdentity(at: extensionURL)
        guard
            extensionIdentity.identifier == extensionIdentifier,
            extensionIdentity.teamIdentifier == hostIdentity.teamIdentifier
        else {
            throw InstallationError.extensionSignatureMismatch
        }
        return hostIdentity
    }

    private static func platformComponentIdentifiers(
        at bundleURL: URL
    ) -> Set<String> {
        var identifiers: Set<String> = []
        if let extensionIdentifier = ApplicationBundleInfo.string(
            forKey: "XDialTransparentProxyBundleIdentifier",
            at: bundleURL
        ) {
            identifiers.insert(extensionIdentifier)
        }
        let helperURL = bundleURL.appendingPathComponent(
            "Contents/MacOS/xdial-daemon"
        )
        if let helperIdentity = try? signingIdentity(at: helperURL) {
            identifiers.insert(helperIdentity.identifier)
        }
        return identifiers
    }

    /// An upgrade must be able to repair an older app whose embedded helper or
    /// system extension is incomplete. The incoming app is fully validated,
    /// while the existing destination is trusted only enough to prove that it
    /// is the same signed host application and therefore safe to replace.
    private static func existingApplicationIdentity(
        at bundleURL: URL
    ) throws -> SigningIdentity {
        guard
            bundleURL.pathExtension == "app",
            let bundleIdentifier = ApplicationBundleInfo.identifier(
                at: bundleURL
            )
        else {
            throw InstallationError.invalidApplicationBundle
        }
        let identity = try signingIdentity(at: bundleURL)
        guard identity.identifier == bundleIdentifier else {
            throw InstallationError.bundleIdentifierMismatch
        }
        return identity
    }

    private static func signingIdentity(at url: URL) throws
        -> SigningIdentity {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            url as CFURL,
            [],
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            throw InstallationError.signatureUnreadable(url.lastPathComponent)
        }
        let flags = SecCSFlags(
            rawValue: kSecCSStrictValidate
                | kSecCSCheckAllArchitectures
                | kSecCSCheckNestedCode
        )
        guard SecStaticCodeCheckValidity(
            staticCode,
            flags,
            nil
        ) == errSecSuccess else {
            throw InstallationError.signatureInvalid(url.lastPathComponent)
        }

        var rawInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInformation
        ) == errSecSuccess,
        let information = rawInformation as? [String: Any],
        let identifier = information[
            kSecCodeInfoIdentifier as String
        ] as? String,
        let teamIdentifier = information[
            kSecCodeInfoTeamIdentifier as String
        ] as? String,
        !identifier.isEmpty,
        !teamIdentifier.isEmpty else {
            throw InstallationError.signatureMetadataMissing(
                url.lastPathComponent
            )
        }
        return SigningIdentity(
            identifier: identifier,
            teamIdentifier: teamIdentifier
        )
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private struct SigningIdentity: Equatable {
        let identifier: String
        let teamIdentifier: String
    }

    private enum InstallationError: LocalizedError {
        case invalidApplicationBundle
        case bundleIdentifierMismatch
        case helperMissing
        case helperSignatureMismatch
        case settingsUIMissing
        case settingsUISignatureMismatch
        case extensionIdentifierMissing
        case extensionMissing
        case extensionFilenameMismatch
        case extensionSignatureMismatch
        case copiedBundleIdentityChanged
        case installedBundleIdentityChanged
        case backupCleanupFailed
        case signatureUnreadable(String)
        case signatureInvalid(String)
        case signatureMetadataMissing(String)
        case relaunchFailed
        case installedSuccessorLocationMismatch
        case existingApplicationDidNotTerminate
        case existingApplicationNotReplaceable
        case helperReplacementPreparationFailed
        case applicationNotInstalled
        case launchServicesRegistrarMissing
        case applicationUnregistrationFailed
        case automaticUpdateUnsupported
        case automaticUpdateIdentityMismatch

        var canRetry: Bool {
            switch self {
            case .existingApplicationDidNotTerminate:
                true
            default:
                false
            }
        }

        var errorDescription: String? {
            switch self {
            case .invalidApplicationBundle:
                "当前 XDial.app 结构无效"
            case .bundleIdentifierMismatch:
                "XDial 的应用标识与签名不一致"
            case .helperMissing:
                "安装包缺少 xdial-daemon"
            case .helperSignatureMismatch:
                "xdial-daemon 与 XDial 的签名身份不一致"
            case .settingsUIMissing:
                "安装包缺少 XDial 设置窗口组件"
            case .settingsUISignatureMismatch:
                "设置窗口组件与 XDial 的签名身份不一致"
            case .extensionIdentifierMissing:
                "安装包没有声明网络扩展标识"
            case .extensionMissing:
                "安装包内找不到 XDial 网络扩展"
            case .extensionFilenameMismatch:
                "网络扩展文件名必须与其 Bundle Identifier 完全一致"
            case .extensionSignatureMismatch:
                "XDial 网络扩展与主程序的签名身份不一致"
            case .copiedBundleIdentityChanged:
                "复制后的 XDial 签名发生变化"
            case .installedBundleIdentityChanged:
                "安装到“应用程序”后的 XDial 未通过签名验证"
            case .backupCleanupFailed:
                "新版已验证，但旧版临时备份未能清理"
            case let .signatureUnreadable(name):
                "无法读取 \(name) 的代码签名"
            case let .signatureInvalid(name):
                "\(name) 的代码签名验证失败"
            case let .signatureMetadataMissing(name):
                "\(name) 的签名缺少开发团队信息"
            case .relaunchFailed:
                "XDial 已安装，但无法从“应用程序”重新启动"
            case .installedSuccessorLocationMismatch:
                "XDial 已复制到“应用程序”，但系统仍从下载隔离位置启动它。"
                    + "请退出此窗口，再从“应用程序”打开 XDial。"
            case .existingApplicationDidNotTerminate:
                "旧版 XDial 仍在运行，无法安全替换。"
                    + "XDial 不会强制结束它；请稍等后重试，"
                    + "或从菜单栏退出旧版后再重试。"
            case .existingApplicationNotReplaceable:
                "“应用程序”中的 XDial 与当前构建签名或标识不一致，"
                    + "已拒绝覆盖"
            case .helperReplacementPreparationFailed:
                "旧版后台服务未能确认完成注销，已保留原应用并停止替换。"
            case .applicationNotInstalled:
                "XDial 不在“应用程序”目录，无法完成卸载"
            case .launchServicesRegistrarMissing:
                "系统缺少 LaunchServices 注册工具，无法清理旧版 XDial"
            case .applicationUnregistrationFailed:
                "旧版 XDial 的系统应用注册未能清理"
            case .automaticUpdateUnsupported:
                "当前 XDial 构建不允许应用内自动更新"
            case .automaticUpdateIdentityMismatch:
                "下载的 XDial 版本或签名身份与当前应用不一致"
            }
        }
    }
}
