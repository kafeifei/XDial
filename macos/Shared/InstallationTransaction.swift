import Foundation

enum SystemExtensionBundleNaming {
    static func matches(
        bundleIdentifier: String,
        bundleURL: URL
    ) -> Bool {
        bundleURL.pathExtension == "systemextension"
            && bundleURL.deletingPathExtension().lastPathComponent
                == bundleIdentifier
    }
}

enum InstallationTransactionState: String, Codable, Equatable {
    case checking
    case installing
    case waitingForApproval = "waiting_for_approval"
    case ready
    case failed
}

enum InstallationTaskState: String, Codable, Equatable {
    case pending
    case running
    case waitingForApproval = "waiting_for_approval"
    case ready
    case failed
}

struct InstallationReportError: Codable, Equatable {
    let code: String
    let message: String
    let taskID: String

    enum CodingKeys: String, CodingKey {
        case code
        case message
        case taskID = "task_id"
    }
}

struct InstallationTaskReport: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let detail: String
    var state: InstallationTaskState
    var error: InstallationReportError?
}

struct InstallationReportEvent: Codable, Equatable {
    let sequence: Int
    let timestamp: Date
    let taskID: String
    let state: String
    let code: String
    let message: String

    enum CodingKeys: String, CodingKey {
        case sequence
        case timestamp
        case taskID = "task_id"
        case state
        case code
        case message
    }
}

struct InstallationReport: Codable, Equatable {
    static let schemaVersion = 4

    let schemaVersion: Int
    let transactionID: String
    var state: InstallationTransactionState
    var tasks: [InstallationTaskReport]
    var error: InstallationReportError?
    var events: [InstallationReportEvent]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case transactionID = "transaction_id"
        case state
        case tasks
        case error
        case events
    }

    static func fresh(
        applicationAlreadyInstalled: Bool
    ) -> InstallationReport {
        InstallationReport(
            schemaVersion: schemaVersion,
            transactionID: UUID().uuidString.lowercased(),
            state: .checking,
            tasks: [
                InstallationTaskReport(
                    id: "application",
                    name: "安装 XDial",
                    detail: "验证并运行 /Applications/XDial.app",
                    state: applicationAlreadyInstalled ? .ready : .pending,
                    error: nil
                ),
                InstallationTaskReport(
                    id: "bundle",
                    name: "验证安装包",
                    detail: "核对签名、helper 和网络扩展",
                    state: .pending,
                    error: nil
                ),
                InstallationTaskReport(
                    id: "helper",
                    name: "配置后台服务",
                    detail: "注册并验证特权 helper",
                    state: .pending,
                    error: nil
                ),
                InstallationTaskReport(
                    id: "system-extension",
                    name: "启用网络扩展",
                    detail: "激活后复核当前版本与启用状态",
                    state: .pending,
                    error: nil
                ),
            ],
            error: nil,
            events: []
        )
    }

    var isReady: Bool {
        state == .ready && tasks.allSatisfy { $0.state == .ready }
    }

    var currentTask: InstallationTaskReport? {
        tasks.first {
            $0.state == .running || $0.state == .waitingForApproval
        }
    }

    mutating func updateTask(
        id: String,
        state: InstallationTaskState
    ) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            return
        }
        guard tasks[index].state != state else { return }
        tasks[index].state = state
        if state != .failed {
            tasks[index].error = nil
        }
        switch state {
        case .waitingForApproval:
            self.state = .waitingForApproval
        case .running:
            self.state = .installing
        case .ready, .pending, .failed:
            break
        }
        appendEvent(
            taskID: id,
            state: state.rawValue,
            code: "",
            message: ""
        )
    }

    mutating func fail(
        code: String,
        message: String,
        taskID: String
    ) {
        let failure = InstallationReportError(
            code: code,
            message: message,
            taskID: taskID
        )
        error = failure
        state = .failed
        if let index = tasks.firstIndex(where: { $0.id == taskID }) {
            tasks[index].state = .failed
            tasks[index].error = failure
        }
        appendEvent(
            taskID: taskID,
            state: InstallationTaskState.failed.rawValue,
            code: code,
            message: message
        )
    }

    mutating func finish() {
        guard tasks.allSatisfy({ $0.state == .ready }) else {
            return
        }
        error = nil
        state = .ready
        appendEvent(
            taskID: "",
            state: InstallationTransactionState.ready.rawValue,
            code: "installation-ready",
            message: ""
        )
    }

    private mutating func appendEvent(
        taskID: String,
        state: String,
        code: String,
        message: String
    ) {
        events.append(
            InstallationReportEvent(
                sequence: events.count + 1,
                timestamp: Date(),
                taskID: taskID,
                state: state,
                code: code,
                message: message
            )
        )
    }
}

enum ApplicationRelocationDecision: Equatable {
    case continueLaunch
    case install
    case replace
    case rejectExisting

    static func decide(
        currentIsCanonical: Bool,
        destinationExists: Bool,
        destinationMatchesIdentity: Bool,
        destinationIsRecognizedProduct: Bool = false
    ) -> ApplicationRelocationDecision {
        if currentIsCanonical {
            return .continueLaunch
        }
        guard destinationExists else {
            return .install
        }
        return destinationMatchesIdentity
            || destinationIsRecognizedProduct
            ? .replace
            : .rejectExisting
    }
}

enum SystemExtensionInstallationEvent: Equatable {
    case submitted
    case waitingForApproval
    case completed
    case failed(String)
}

enum InstallationBuildMarker {
    static func make(
        bundleIdentifier: String,
        bundleVersion: String
    ) -> String {
        "\(bundleIdentifier):\(bundleVersion)"
            + ":installation-v\(InstallationReport.schemaVersion)"
    }
}

struct SystemExtensionPropertySnapshot: Equatable {
    let bundleIdentifier: String
    let bundleVersion: String
    let isEnabled: Bool
    let isAwaitingUserApproval: Bool
    let isUninstalling: Bool
}

enum SystemExtensionActivationVerifier {
    static func containsReadyCurrentVersion(
        _ properties: [SystemExtensionPropertySnapshot],
        expectedIdentifier: String,
        expectedVersion: String
    ) -> Bool {
        properties.contains {
            $0.bundleIdentifier == expectedIdentifier
                && $0.bundleVersion == expectedVersion
                && $0.isEnabled
                && !$0.isAwaitingUserApproval
                && !$0.isUninstalling
        }
    }
}

enum XDialApplicationIdentifierPolicy {
    static let debug = "com.kafeifei.xdial.ne-probe"
    static let legacyRelease = "com.kafeifei.xdial"
    static let release = "com.kafeifei.xdial.app"
    static let debugSettingsUI =
        "com.kafeifei.xdial.ne-probe.settings-ui"
    static let legacyReleaseSettingsUI =
        "com.kafeifei.xdial.settings-ui"
    static let releaseSettingsUI =
        "com.kafeifei.xdial.app.settings-ui"

    static func settingsUIIdentifier(
        forApplicationIdentifier identifier: String
    ) -> String? {
        switch identifier {
        case debug: debugSettingsUI
        case legacyRelease: legacyReleaseSettingsUI
        case release: releaseSettingsUI
        default: nil
        }
    }

    static func permitsReplacement(
        existingIdentifier: String,
        incomingIdentifier: String,
        teamIdentifiersMatch: Bool
    ) -> Bool {
        guard teamIdentifiersMatch else { return false }
        let knownIdentifiers = Set([
            debug,
            legacyRelease,
            release,
        ])
        return knownIdentifiers.contains(existingIdentifier)
            && knownIdentifiers.contains(incomingIdentifier)
    }

    static func obsoleteIdentifiers(
        forInstalledIdentifier identifier: String
    ) -> Set<String> {
        guard identifier == release else { return [] }
        return [debug, legacyRelease]
    }

    static func shouldUnregisterApplicationRegistration(
        installedIdentifier: String,
        registeredIdentifier: String,
        isInstalledDestination: Bool
    ) -> Bool {
        guard installedIdentifier == release else { return false }
        if registeredIdentifier == debug
            || registeredIdentifier == legacyRelease {
            return true
        }
        return registeredIdentifier == release
            && !isInstalledDestination
    }
}

enum OutgoingApplicationCleanup {
    static let timeout: TimeInterval = 5 * 60
    static let replacementArgument =
        "--prepare-owned-components-for-replacement"

    struct Plan: Equatable {
        let executableURL: URL
        let arguments: [String]
        let timeout: TimeInterval
    }

    static func plan(
        existingBundleURL: URL,
        existingIdentifier: String,
        incomingIdentifier: String,
        teamIdentifiersMatch: Bool,
        requiresComponentCleanup: Bool = false
    ) -> Plan? {
        guard
            existingIdentifier != incomingIdentifier
                || requiresComponentCleanup,
            XDialApplicationIdentifierPolicy.permitsReplacement(
                existingIdentifier: existingIdentifier,
                incomingIdentifier: incomingIdentifier,
                teamIdentifiersMatch: teamIdentifiersMatch
            )
        else {
            return nil
        }
        return Plan(
            executableURL: existingBundleURL.appendingPathComponent(
                "Contents/MacOS/XDial"
            ),
            arguments: [replacementArgument],
            timeout: timeout
        )
    }

    static func run(
        _ plan: Plan,
        execute: (URL, [String], TimeInterval) throws -> Bool
    ) throws {
        guard try execute(
            plan.executableURL,
            plan.arguments,
            plan.timeout
        ) else {
            throw CleanupError.failed
        }
    }

    private enum CleanupError: LocalizedError {
        case failed

        var errorDescription: String? {
            "旧版 XDial 的后台服务或网络扩展未能完整清理，"
                + "正式版尚未替换，请重试"
        }
    }
}

enum ApplicationBundleReplacer {
    static func replace(
        fileManager: FileManager = .default,
        destinationURL: URL,
        newBundleURL: URL,
        backupName: String,
        validate: (URL) throws -> Bool
    ) throws {
        let backupURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                backupName,
                isDirectory: true
            )
        _ = try fileManager.replaceItemAt(
            destinationURL,
            withItemAt: newBundleURL,
            backupItemName: backupName,
            options: [.withoutDeletingBackupItem]
        )
        guard fileManager.fileExists(atPath: backupURL.path) else {
            throw ApplicationBundleReplacementError.backupMissing
        }
        do {
            guard try validate(destinationURL) else {
                throw ApplicationBundleReplacementError
                    .validationFailed
            }
        } catch {
            do {
                guard fileManager.fileExists(atPath: backupURL.path)
                else {
                    throw ApplicationBundleReplacementError
                        .backupMissing
                }
                if fileManager.fileExists(
                    atPath: destinationURL.path
                ) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.moveItem(
                    at: backupURL,
                    to: destinationURL
                )
            } catch let rollbackError {
                throw ApplicationBundleReplacementError
                    .rollbackFailed(
                        original: error.localizedDescription,
                        rollback: rollbackError.localizedDescription
                    )
            }
            throw error
        }

        if fileManager.fileExists(atPath: backupURL.path) {
            try? fileManager.removeItem(at: backupURL)
        }
    }

    private enum ApplicationBundleReplacementError:
        LocalizedError {
        case validationFailed
        case backupMissing
        case rollbackFailed(original: String, rollback: String)

        var errorDescription: String? {
            switch self {
            case .validationFailed:
                "替换后的应用未通过验证"
            case .backupMissing:
                "替换失败后找不到旧版备份"
            case let .rollbackFailed(original, rollback):
                "应用替换失败（\(original)），恢复旧版也失败（\(rollback)）"
            }
        }
    }
}
