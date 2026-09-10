import Foundation

/// Installation owns registration. A responsive executable alone cannot prove
/// that launchd's registration points at the current bundle after an update.
@MainActor
final class HelperRegistrationCoordinator {
    enum ServiceStatus: Equatable {
        case notRegistered, enabled, requiresApproval, notFound
    }

    struct Daemon: Equatable {
        var pid: Int32
        var executableHash: String
        var handoffProtocolVersion: Int
    }

    enum Runtime: Equatable {
        case absent
        case running(Daemon)
        case unresponsive
        case unknown
    }

    enum Stage: Equatable {
        case checking, waitingForApproval, waitingForIdle
        case waitingForLegacyIdle, refreshingRegistration, reconcilingRegistration, verifying, ready
    }

    enum Failure: String, Error, LocalizedError {
        case approvalRequired
        case registrationFailed
        case serviceUnavailable
        case processStateUnknown
        case serviceBusy
        case legacyMigrationFailed
        case versionMismatch

        var errorDescription: String? {
            switch self {
            case .approvalRequired: "后台服务尚未获得 macOS 批准"
            case .registrationFailed: "后台服务注册未能更新，请检查 macOS 返回的错误"
            case .serviceUnavailable: "后台服务注册已更新，但未能建立本地控制通道"
            case .processStateUnknown: "无法确认后台服务的进程状态，已保留现有服务"
            case .serviceBusy: "后台服务仍有正在进行的操作，正在等待安全升级"
            case .legacyMigrationFailed: "旧版后台服务未能安全切换到当前安装包"
            case .versionMismatch: "后台服务未运行当前安装包中的版本"
            }
        }
    }

    struct Limits {
        var startup: TimeInterval = 6
        var approval: TimeInterval = 180
        // Legacy helpers have no atomic setup/activity query. Their Tailscale
        // setup expires after two idle minutes; never refresh its idle timer.
        var legacyIdle: TimeInterval = 125
        var poll: TimeInterval = 0.2
    }

    struct IO {
        var status: () -> ServiceStatus
        var runtime: () async -> Runtime
        var registrationMarker: () -> String?
        var pendingMaintenanceRecovery: () -> Bool
        var storeRegistrationMarker: (String) -> Void
        var maintenanceAllowed: () -> Bool
        var legacyMaintenanceIsExclusive: (Int32) async -> Bool
        var legacyEngineIsIdle: () async -> Bool
        /// The live path must hold a daemon-issued quiescence lease until the
        /// SMAppService unregister completion, including a late completion.
        var unregister: (Daemon?) async throws -> Void
        /// True only for an accepted registration of the current bundle.
        var register: () throws -> Bool
        /// True only for the observed SM denial of this committed maintenance
        /// transaction while its target service remains notRegistered.
        var canReconcileRegistrationFailure: (Error) -> Bool
        var finishMaintenance: () async throws -> Void
        var stageChanged: (Stage) -> Void
        var now: () -> TimeInterval
        var sleep: (TimeInterval) async throws -> Void
    }

    private let fingerprint: String
    private let expectedExecutableHash: String
    private let limits: Limits
    private let io: IO
    private var lastStage: Stage?

    init(
        fingerprint: String,
        expectedExecutableHash: String,
        limits: Limits = Limits(),
        io: IO
    ) {
        self.fingerprint = fingerprint
        self.expectedExecutableHash = expectedExecutableHash
        self.limits = limits
        self.io = io
    }

    func prepare() async throws {
        var registeredCurrentBundle = false
        var refreshedRegistration = false
        var needsVerificationStage = true
        var publishedRefreshAttempt = false
        publish(.checking)

        while true {
            try Task.checkCancellation()
            let recoveringMaintenance = !registeredCurrentBundle && io.pendingMaintenanceRecovery()
            switch io.status() {
            case .notRegistered, .notFound:
                if recoveringMaintenance { break }
                guard !registeredCurrentBundle else { throw Failure.registrationFailed }
                registeredCurrentBundle = try io.register()
                try await awaitRegistrationStatus()
                needsVerificationStage = true
            case .requiresApproval:
                try await awaitApproval()
            case .enabled:
                break
            }
            guard io.status() == .enabled || recoveringMaintenance else { throw Failure.approvalRequired }
            if needsVerificationStage {
                publish(.verifying)
                needsVerificationStage = false
            }
            let runtime = try await awaitRuntime()
            if case let .running(daemon) = runtime,
               daemon.executableHash == expectedExecutableHash,
               registeredCurrentBundle || io.registrationMarker() == fingerprint {
                try await io.finishMaintenance()
                if registeredCurrentBundle {
                    io.storeRegistrationMarker(fingerprint)
                }
                publish(.ready)
                return
            }
            if registeredCurrentBundle {
                throw runtime == .absent ? Failure.serviceUnavailable : Failure.versionMismatch
            }

            guard runtime != .unknown, runtime != .unresponsive else {
                throw Failure.processStateUnknown
            }
            if !io.maintenanceAllowed() {
                publish(.waitingForIdle)
                try await io.sleep(limits.poll)
                continue
            }

            let daemon: Daemon?
            switch runtime {
            case .absent:
                daemon = nil
            case let .running(running):
                if running.handoffProtocolVersion < 1 {
                    // Legacy helpers cannot atomically lease maintenance. The
                    // compatibility path uses the full product-exclusive idle
                    // window, then refreshes registration directly. Re-exec can
                    // resolve the previous hidden installation bundle again.
                    guard try await awaitLegacyMaintenanceWindow(for: running) else {
                        // KeepAlive may replace the legacy PID while we wait.
                        // Re-read its protocol and ownership before maintaining it.
                        continue
                    }
                }
                daemon = running
            case .unknown, .unresponsive:
                throw Failure.processStateUnknown
            }
            guard !refreshedRegistration else { throw Failure.registrationFailed }
            if !publishedRefreshAttempt {
                publish(.refreshingRegistration)
                publishedRefreshAttempt = true
            }
            do {
                try await io.unregister(daemon)
            } catch Failure.serviceBusy {
                // No registration mutation was made: keep serving the current
                // operation and continue this same installation automatically.
                publish(.waitingForIdle)
                try await io.sleep(limits.poll)
                continue
            }
            publish(.refreshingRegistration)
            refreshedRegistration = true
            registeredCurrentBundle = try await registerAfterRefresh()
            guard registeredCurrentBundle else { throw Failure.registrationFailed }
            try await awaitRegistrationStatus()
            needsVerificationStage = true
        }
    }

    private func registerAfterRefresh() async throws -> Bool {
        do {
            return try io.register()
        } catch {
            // Observed on two real updates: successful unregister completion,
            // then SMAppService/EPERM with notRegistered and no helper. A later
            // unregister completion + register succeeded. Reconcile once under
            // that same owned maintenance boundary; never retry a general EPERM.
            guard io.canReconcileRegistrationFailure(error),
                  io.status() == .notRegistered,
                  io.pendingMaintenanceRecovery(),
                  io.maintenanceAllowed(),
                  await io.runtime() == .absent else { throw error }
            try Task.checkCancellation()
            publish(.reconcilingRegistration)
            try await io.unregister(nil)
            // This second attempt deliberately has no catch/retry loop. Its
            // accepted registration still requires runtime hash + finalize ACK.
            return try io.register()
        }
    }

    private func awaitRegistrationStatus() async throws {
        let deadline = io.now() + 4
        while io.status() == .notRegistered || io.status() == .notFound {
            guard io.now() < deadline else { throw Failure.registrationFailed }
            try await io.sleep(limits.poll)
        }
        if io.status() == .requiresApproval { try await awaitApproval() }
    }

    private func awaitApproval() async throws {
        publish(.waitingForApproval)
        let deadline = io.now() + limits.approval
        while io.status() != .enabled {
            try Task.checkCancellation()
            guard io.now() < deadline else { throw Failure.approvalRequired }
            try await io.sleep(max(limits.poll, 1))
        }
    }

    private func awaitRuntime() async throws -> Runtime {
        let deadline = io.now() + limits.startup
        while true {
            try Task.checkCancellation()
            let runtime = await io.runtime()
            if case .running = runtime { return runtime }
            if io.now() >= deadline { return runtime }
            try await io.sleep(limits.poll)
        }
    }

    private func awaitLegacyMaintenanceWindow(for daemon: Daemon) async throws -> Bool {
        publish(.waitingForLegacyIdle)
        var quietSince: TimeInterval?
        while true {
            try Task.checkCancellation()
            guard case let .running(current) = await io.runtime(),
                  current.pid == daemon.pid,
                  current.executableHash == daemon.executableHash else {
                return false
            }
            let exclusive = await io.legacyMaintenanceIsExclusive(daemon.pid)
            let idle = await io.legacyEngineIsIdle()
            if io.maintenanceAllowed(), exclusive, idle {
                if quietSince == nil { quietSince = io.now() }
                if io.now() - (quietSince ?? io.now()) >= limits.legacyIdle { return true }
            } else {
                quietSince = nil
            }
            try await io.sleep(max(limits.poll, 1))
        }
    }

    private func publish(_ stage: Stage) {
        guard stage != lastStage else { return }
        lastStage = stage
        io.stageChanged(stage)
    }
}
