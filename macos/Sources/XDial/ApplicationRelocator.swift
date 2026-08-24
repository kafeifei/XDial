import AppKit
import Foundation
import Security

enum ApplicationLaunchPreparation {
    case continueLaunch
    case relaunching
    case failed(message: String, canRetry: Bool)
}

/// XDial 的平台安装入口。它只复制并验证 app bundle，不注册网络配置，也不启动数据面。
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

    private static let destinationURL = URL(
        fileURLWithPath: "/Applications/XDial.app",
        isDirectory: true
    )
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
        isRunningFromApplications
            && Bundle.main.bundleIdentifier
                == XDialApplicationIdentifierPolicy.release
    }

    static func validateIncomingUpdateBundle(
        at bundleURL: URL,
        expectedVersion: String
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
            incomingIdentifier: incomingIdentity.identifier,
            incomingTeamIdentifier: incomingIdentity.teamIdentifier,
            incomingVersion: incomingVersion,
            expectedVersion: expectedVersion
        ),
        ApplicationBundleInfo.string(
            forKey: "XDialTransparentProxyBundleIdentifier",
            at: bundleURL
        ) == AutomaticUpdateBundlePolicy.releaseExtensionIdentifier,
        AutomaticUpdateBundlePolicy.permitsVersionSet(
            expectedVersion: expectedVersion,
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
        if isRunningFromApplications {
            try validateCurrentBundle()
            return
        }

        let sourceURL = Bundle.main.bundleURL
        let sourceIdentity = try validateDistributionBundle(at: sourceURL)
        let destinationExists = FileManager.default.fileExists(
            atPath: destinationURL.path
        )
        var replacedIdentity: SigningIdentity?
        if destinationExists {
            let identity = try existingApplicationIdentity(
                at: destinationURL
            )
            guard XDialApplicationIdentifierPolicy.permitsReplacement(
                existingIdentifier: identity.identifier,
                incomingIdentifier: sourceIdentity.identifier,
                teamIdentifiersMatch:
                    identity.teamIdentifier == sourceIdentity.teamIdentifier
            ) else {
                throw InstallationError.existingApplicationNotReplaceable
            }
            replacedIdentity = identity
        }

        try install(
            sourceURL: sourceURL,
            sourceIdentity: sourceIdentity,
            replacedIdentity: replacedIdentity,
            replaceExisting: destinationExists
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

    static func prepareForLaunch() -> ApplicationLaunchPreparation {
        let sourceURL = Bundle.main.bundleURL
        do {
            let sourceIdentity = try validateDistributionBundle(at: sourceURL)
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
                try unregisterConflictingApplications(
                    forInstalledIdentifier: sourceIdentity.identifier
                )
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
                        sourceIdentity: sourceIdentity,
                        replacedIdentity: destinationIdentity,
                        replaceExisting: destinationExists
                    )
                    try relaunchInstalledApplication()
                    AppUpdateStager.discardOwnedRoot(
                        containing: sourceURL
                    )
                    return .relaunching
                } catch {
                    relaunchInstalledApplicationAfterFailedReplacement(
                        sourceIdentity: sourceIdentity,
                        replacedIdentity: destinationIdentity
                    )
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
        sourceIdentity: SigningIdentity,
        replacedIdentity: SigningIdentity?,
        replaceExisting: Bool
    ) throws {
        let fileManager = FileManager.default
        let temporaryURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".XDial.install-\(UUID().uuidString).app",
                isDirectory: true
            )
        defer {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        try fileManager.copyItem(at: sourceURL, to: temporaryURL)
        guard try validateDistributionBundle(at: temporaryURL)
            == sourceIdentity else {
            throw InstallationError.copiedBundleIdentityChanged
        }

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
            }
            let backupName =
                ".XDial.backup-\(UUID().uuidString).app"
            let backupURL = destinationURL
                .deletingLastPathComponent()
                .appendingPathComponent(
                    backupName,
                    isDirectory: true
                )
            try ApplicationBundleReplacer.replace(
                fileManager: fileManager,
                destinationURL: destinationURL,
                newBundleURL: temporaryURL,
                backupName: backupName
            ) { installedURL in
                try validateDistributionBundle(at: installedURL)
                    == sourceIdentity
            }
            // ApplicationBundleReplacer 成功时会清理备份；这里的显式检查让
            // 安装过程不会把一份意外遗留的旧 app 当作成功终态。
            if fileManager.fileExists(atPath: backupURL.path) {
                throw InstallationError.backupCleanupFailed
            }
        } else {
            try fileManager.moveItem(
                at: temporaryURL,
                to: destinationURL
            )
            do {
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
        guard completion.wait(
            timeout: .now() + max(0, timeout)
        ) == .success else {
            process.terminate()
            _ = completion.wait(timeout: .now() + 1)
            return false
        }
        return process.terminationReason == .exit
            && process.terminationStatus == 0
    }

    private static func unregisterConflictingApplications(
        forInstalledIdentifier identifier: String
    ) throws {
        let candidateIdentifiers =
            XDialApplicationIdentifierPolicy.obsoleteIdentifiers(
                forInstalledIdentifier: identifier
            )
                .union([identifier])
        for candidateIdentifier in candidateIdentifiers {
            let registeredURLs = NSWorkspace.shared
                .urlsForApplications(
                    withBundleIdentifier: candidateIdentifier
                )
            var canonicalPaths = Set<String>()
            for registeredURL in registeredURLs {
                guard
                    ApplicationBundleInfo.identifier(at: registeredURL)
                        == candidateIdentifier
                else {
                    continue
                }
                let canonicalURL = canonical(registeredURL)
                guard canonicalPaths.insert(canonicalURL.path).inserted
                else {
                    continue
                }
                guard
                    XDialApplicationIdentifierPolicy
                        .shouldUnregisterApplicationRegistration(
                            installedIdentifier: identifier,
                            registeredIdentifier: candidateIdentifier,
                            isInstalledDestination:
                                canonicalURL == canonical(destinationURL)
                        )
                else {
                    continue
                }
                try unregisterApplication(at: registeredURL)
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
                NSRunningApplication.current.processIdentifier
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
                NSRunningApplication.current.processIdentifier
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
            NSRunningApplication.current.processIdentifier
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
        ) else {
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
        case existingApplicationDidNotTerminate
        case existingApplicationNotReplaceable
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
            case .existingApplicationDidNotTerminate:
                "旧版 XDial 仍在运行，无法安全替换。"
                    + "XDial 不会强制结束它；请稍等后重试，"
                    + "或从菜单栏退出旧版后再重试。"
            case .existingApplicationNotReplaceable:
                "“应用程序”中的 XDial 与当前构建签名或标识不一致，"
                    + "已拒绝覆盖"
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
