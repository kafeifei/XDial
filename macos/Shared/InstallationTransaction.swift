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
    static let release = "com.kafeifei.xdial"

    static func permitsReplacement(
        existingIdentifier: String,
        incomingIdentifier: String,
        teamIdentifiersMatch: Bool
    ) -> Bool {
        guard teamIdentifiersMatch else { return false }
        let knownIdentifiers = Set([debug, release])
        return knownIdentifiers.contains(existingIdentifier)
            && knownIdentifiers.contains(incomingIdentifier)
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
