import Foundation
import ServiceManagement

extension Notification.Name {
    static let xdialOpenInstallation = Notification.Name(
        "xdial.openInstallation"
    )
}

enum InstallationOperation: String, CaseIterable, Identifiable {
    case install
    case uninstall

    var id: String { rawValue }
}

@MainActor
final class InstallationCoordinator: ObservableObject {
    static let shared = InstallationCoordinator()

    @Published private(set) var presentedOperation: InstallationOperation =
        .install
    @Published private(set) var isInstalling = false
    @Published private(set) var report = InstallationReport.fresh(
        applicationAlreadyInstalled:
            ApplicationRelocator.isRunningFromApplications
    ) {
        didSet { recordReport() }
    }

    var isReady: Bool { report.isReady }
    var blockingMessage: String {
        report.error?.message ?? "XDial 的安装或升级尚未完成"
    }

    private var runTask: Task<Void, Never>?
    private let completionMarkerKey = "xdial.installation.ready"

    /// The release build has no debug server. Retain the same credential-free
    /// report shown by the UI so installation failures can be diagnosed without
    /// inferring state from separate log messages. PID and build distinguish a
    /// current run from a report left by a previous application process.
    private func recordReport() {
        let snapshot = InstallationReportSnapshot(
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            bundleVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
                as? String ?? "unknown",
            recordedAt: Date(),
            report: report
        )
        let url = URL(fileURLWithPath: appLogPath()).deletingLastPathComponent()
            .appendingPathComponent("installation-report.json")
        do {
            try snapshot.write(to: url)
        } catch {
            appLog("installation report could not be saved: \(error.localizedDescription)")
        }
    }

    private init() {
        TransparentProxyManager.shared.activationStatusHandler = {
            [weak self] event in
            Task { @MainActor in
                self?.handleSystemExtensionEvent(event)
            }
        }
    }

    func start(force: Bool = false) {
        if runTask != nil { return }
        if isReady, !force { return }

        let markerMatches = xdialDefaults.string(
            forKey: completionMarkerKey
        ) == currentBuildMarker
        report = InstallationReport.fresh(
            applicationAlreadyInstalled:
                ApplicationRelocator.isRunningFromApplications
        )
        if !markerMatches || !PrivilegeManager.isInstalled {
            present()
        }
        isInstalling = true
        runTask = Task { [weak self] in
            await self?.run()
        }
    }

    func retry() {
        let previousRun = runTask
        Task { [weak self] in
            previousRun?.cancel()
            if let previousRun {
                await previousRun.value
            }
            guard let self else { return }
            self.start(force: true)
            self.present()
        }
    }

    func selectOperation(_ operation: InstallationOperation) {
        presentedOperation = operation
    }

    func present(
        operation: InstallationOperation = .install
    ) {
        presentedOperation = operation
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .xdialOpenInstallation,
                object: nil
            )
        }
    }

    private func run() async {
        defer {
            runTask = nil
            isInstalling = false
        }
        do {
            guard ApplicationRelocator.isRunningFromApplications else {
                throw InstallationFailure(
                    code: "application-location-invalid",
                    message: "XDial 没有从“应用程序”目录运行",
                    taskID: "application"
                )
            }
            report.updateTask(id: "application", state: .ready)

            report.updateTask(id: "bundle", state: .running)
            try ApplicationRelocator.validateCurrentBundle()
            report.updateTask(id: "bundle", state: .ready)

            report.updateTask(id: "helper", state: .running)
            try await prepareHelper()
            report.updateTask(id: "helper", state: .ready)

            report.updateTask(
                id: "system-extension",
                state: .running
            )
            try await prepareSystemExtension()
            report.updateTask(
                id: "system-extension",
                state: .ready
            )

            report.finish()
            guard report.isReady else {
                throw InstallationFailure(
                    code: "installation-incomplete",
                    message: "安装事务没有完成全部任务",
                    taskID: report.currentTask?.id ?? "bundle"
                )
            }
            ApplicationRelocator.finishOwnedArtifactRecovery()
            xdialDefaults.set(
                currentBuildMarker,
                forKey: completionMarkerKey
            )
            appLog(
                "installation ready transaction=\(report.transactionID)"
            )
        } catch let failure as InstallationFailure {
            report.fail(
                code: failure.code,
                message: failure.message,
                taskID: failure.taskID
            )
            present()
            appLog(
                "installation failed task=\(failure.taskID)"
                    + " code=\(failure.code)"
            )
        } catch {
            // The System Extension delegate can publish its structured failure
            // before the activation continuation resumes with the same error.
            // Preserve that authoritative task instead of falsely turning the
            // already-ready bundle task red.
            let taskID = report.error?.taskID
                ?? report.currentTask?.id
                ?? "bundle"
            report.fail(
                code: "installation-failed",
                message: error.localizedDescription,
                taskID: taskID
            )
            present()
            appLog(
                "installation failed task=\(taskID): "
                    + error.localizedDescription
            )
        }
    }

    private func prepareHelper() async throws {
        if PrivilegeManager.legacyInstalled {
            try PrivilegeManager.cleanupLegacy()
        }
        let identity = try PrivilegeManager.registrationIdentity()
        let coordinator = HelperRegistrationCoordinator(
            fingerprint: identity.fingerprint,
            expectedExecutableHash: identity.executableHash,
            io: .init(
                status: { PrivilegeManager.registrationStatus },
                runtime: {
                    await Task.detached { PrivilegeManager.registrationRuntime() }.value
                },
                registrationMarker: {
                    PrivilegeManager.verifiedRegistrationMarker(
                        fingerprint: identity.fingerprint, executableHash: identity.executableHash,
                        savedMarker: xdialDefaults.string(forKey: PrivilegeManager.registrationMarkerKey)
                    )
                },
                pendingMaintenanceRecovery: { PrivilegeManager.hasPendingRegistrationRecovery },
                storeRegistrationMarker: {
                    xdialDefaults.set($0, forKey: PrivilegeManager.registrationMarkerKey)
                },
                maintenanceAllowed: {
                    GoEngine.shared.helperRegistrationMaintenanceAllowed
                },
                legacyMaintenanceIsExclusive: { pid in
                    await Task.detached {
                        PrivilegeManager.legacyMaintenanceIsExclusive(daemonPID: pid)
                    }.value
                },
                legacyEngineIsIdle: {
                    await Task.detached { PrivilegeManager.legacyEngineIsIdle() }.value
                },
                unregister: {
                    try await PrivilegeManager.unregisterForRegistrationRefresh(daemon: $0)
                },
                registrationMaintenanceTarget: { PrivilegeManager.registrationMaintenanceTarget() },
                register: { try PrivilegeManager.registerCurrentBundle() },
                canReconcileRegistrationFailure: { PrivilegeManager.canReconcileRegistrationFailure($0) },
                finishMaintenance: {
                    try await Task.detached { try PrivilegeManager.finishRegistrationMaintenance() }.value
                    xdialDefaults.set(identity.fingerprint, forKey: PrivilegeManager.registrationMarkerKey)
                },
                stageChanged: { [weak self] stage in
                    guard let self else { return }
                    let waitingForApproval = stage == .waitingForApproval
                    self.report.updateTask(
                        id: "helper", state: waitingForApproval ? .waitingForApproval : .running
                    )
                    if let index = self.report.tasks.firstIndex(where: { $0.id == "helper" }) {
                        let task = self.report.tasks[index]
                        self.report.tasks[index] = InstallationTaskReport(
                            id: task.id, name: task.name, detail: Self.helperDetail(for: stage),
                            state: task.state, error: task.error
                        )
                    }
                    appLog("installation helper stage=\(stage)")
                    if waitingForApproval {
                        self.present()
                        PrivilegeManager.openApprovalSettings()
                    }
                },
                now: { ProcessInfo.processInfo.systemUptime },
                sleep: { duration in
                    try await Task.sleep(nanoseconds: UInt64(max(0, duration) * 1_000_000_000))
                }
            )
        )
        do {
            try await coordinator.prepare()
            verifiedHelperExecutableHash = identity.executableHash
            ApplicationRelocator.finishOwnedArtifactRecovery()
        } catch let failure as HelperRegistrationCoordinator.Failure {
            throw InstallationFailure(
                code: "helper-\(failure.rawValue)",
                message: failure.localizedDescription,
                taskID: "helper"
            )
        }
    }

    private(set) var verifiedHelperExecutableHash: String?

    private static func helperDetail(for stage: HelperRegistrationCoordinator.Stage) -> String {
        switch stage {
        case .checking: "检查后台服务注册与运行版本"
        case .waitingForApproval: "请在 macOS 系统设置中允许后台服务"
        case .waitingForIdle: "保留当前连接和操作，空闲后自动继续升级"
        case .waitingForLegacyIdle: "等待旧版后台服务结束配置会话后自动升级"
        case .refreshingRegistration: "安全更新后台服务注册"
        case .reconcilingRegistration: "正在完成后台服务更新"
        case .verifying: "验证后台服务运行当前安装包中的版本"
        case .ready: "后台服务注册和运行版本已验证"
        }
    }

    private func prepareSystemExtension() async throws {
        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                GoEngine.shared.prepareSystemExtension { result in
                    continuation.resume(with: result)
                }
            }
        } catch {
            throw InstallationFailure(
                code: "system-extension-activation-failed",
                message: error.localizedDescription,
                taskID: "system-extension"
            )
        }
    }

    private func handleSystemExtensionEvent(
        _ event: SystemExtensionInstallationEvent
    ) {
        switch event {
        case .submitted:
            report.updateTask(
                id: "system-extension",
                state: .running
            )
        case .waitingForApproval:
            report.updateTask(
                id: "system-extension",
                state: .waitingForApproval
            )
            present()
        case .completed:
            report.updateTask(
                id: "system-extension",
                state: .ready
            )
        case let .failed(message):
            report.fail(
                code: "system-extension-activation-failed",
                message: message,
                taskID: "system-extension"
            )
        }
    }

    private var currentBuildMarker: String {
        let bundle = Bundle.main
        let identifier = bundle.bundleIdentifier ?? "unknown"
        let version = bundle.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"
        return InstallationBuildMarker.make(
            bundleIdentifier: identifier,
            bundleVersion: version
        )
    }

    private struct InstallationFailure: Error {
        let code: String
        let message: String
        let taskID: String
    }
}
