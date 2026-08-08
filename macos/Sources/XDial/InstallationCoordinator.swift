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
    )

    var isReady: Bool { report.isReady }
    var blockingMessage: String {
        report.error?.message ?? "XDial 的安装或升级尚未完成"
    }

    private var runTask: Task<Void, Never>?
    private let completionMarkerKey = "xdial.installation.ready"

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
            let taskID = report.currentTask?.id ?? "bundle"
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

        if !PrivilegeManager.isInstalled {
            do {
                try PrivilegeManager.register()
            } catch {
                // register() 在等待系统批准时也可能抛错；真实结论只看
                // SMAppService 的结构化 status。
                appLog(
                    "installation helper register returned: "
                        + error.localizedDescription
                )
            }
            // SMAppService 的 status 可能比 register() 返回晚一拍；等待它收敛到
            // 可判定状态，不能把瞬时 notRegistered 当成安装失败。
            for _ in 0..<20 {
                if PrivilegeManager.isInstalled
                    || PrivilegeManager.requiresApproval {
                    break
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        if PrivilegeManager.requiresApproval {
            report.updateTask(
                id: "helper",
                state: .waitingForApproval
            )
            present()
            PrivilegeManager.openApprovalSettings()
            for _ in 0..<180 {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 1_000_000_000)
                if PrivilegeManager.isInstalled { break }
            }
        }
        guard PrivilegeManager.isInstalled else {
            throw InstallationFailure(
                code: "helper-not-approved",
                message: "后台服务尚未获得 macOS 批准",
                taskID: "helper"
            )
        }

        report.updateTask(id: "helper", state: .running)
        try await Task.detached {
            try PrivilegeManager.ensureHelperRunning()
        }.value
        await GoEngine.syncDaemonBinary()

        guard
            let bundledHash = PrivilegeManager.bundledDaemonSHA256(),
            let daemonInfo = await Task.detached(
                operation: { PrivilegeManager.probeDaemonInfo() }
            ).value,
            daemonInfo.exeSHA256 == bundledHash
        else {
            throw InstallationFailure(
                code: "helper-version-mismatch",
                message: "后台服务未运行当前安装包中的版本",
                taskID: "helper"
            )
        }
    }

    private func prepareSystemExtension() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            GoEngine.shared.prepareSystemExtension { result in
                continuation.resume(with: result)
            }
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
