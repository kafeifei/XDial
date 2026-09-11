import Foundation

/// Removes the launchd registration before its owning app bundle can move.
/// Success means both macOS registration state and every helper process owned
/// by the supplied app bundle have disappeared.
struct HelperUninstallCoordinator {
    enum RegistrationStatus: Equatable {
        case registered
        case removed
        case unknown
    }

    enum ProcessSnapshot: Equatable {
        case available(Set<Int32>)
        case unknown
    }

    enum Failure: Error, LocalizedError, Equatable {
        case registrationStateUnknown
        case processStateUnknown
        case unregisterPending
        case registrationRemovalTimedOut
        case processExitTimedOut

        var errorDescription: String? {
            switch self {
            case .registrationStateUnknown:
                "无法确认后台服务的注册状态，已保留 XDial 应用"
            case .processStateUnknown:
                "无法确认 XDial 后台服务的进程状态，已保留 XDial 应用"
            case .unregisterPending:
                "macOS 仍在完成上一笔后台服务注销，已保留 XDial 应用"
            case .registrationRemovalTimedOut:
                "macOS 未能完成后台服务注销，已保留 XDial 应用"
            case .processExitTimedOut:
                "后台服务注销后仍未退出，已保留 XDial 应用"
            }
        }
    }

    struct Limits {
        var teardown: TimeInterval = 10
        var poll: TimeInterval = 0.1
    }

    struct IO {
        var unregisterPending: () -> Bool
        var registrationStatus: () -> RegistrationStatus
        /// `retaining` contains PIDs already authenticated as XDial-owned.
        /// Keep reporting those PIDs while they exist even if their executable
        /// path moves with an outgoing bundle during replacement.
        var ownedProcesses: (_ retaining: Set<Int32>) -> ProcessSnapshot
        /// This operation returns only after SMAppService's unregister
        /// completion has arrived, and throws the completion error unchanged.
        var unregister: () async throws -> Void
        var clearMaintenanceIntent: () throws -> Void
        var now: () -> TimeInterval
        var sleep: (TimeInterval) async throws -> Void
    }

    private let limits: Limits
    private let io: IO
    private let authenticatedProcessIDs: Set<Int32>
    private let requiresUnregister: Bool

    init(
        authenticatedProcessIDs: Set<Int32> = [],
        requiresUnregister: Bool = false,
        limits: Limits = Limits(),
        io: IO
    ) {
        self.authenticatedProcessIDs = authenticatedProcessIDs
        self.requiresUnregister = requiresUnregister
        self.limits = limits
        self.io = io
    }

    func run() async throws {
        guard !io.unregisterPending() else { throw Failure.unregisterPending }
        let registration = io.registrationStatus()
        guard registration != .unknown else { throw Failure.registrationStateUnknown }
        guard case let .available(initialProcessIDs) = io.ownedProcesses(authenticatedProcessIDs) else {
            throw Failure.processStateUnknown
        }

        if requiresUnregister || registration == .registered || !initialProcessIDs.isEmpty {
            try await io.unregister()
        }

        let deadline = io.now() + limits.teardown
        while true {
            guard !io.unregisterPending() else { throw Failure.unregisterPending }
            let currentRegistration = io.registrationStatus()
            guard currentRegistration != .unknown else { throw Failure.registrationStateUnknown }
            guard case let .available(pids) = io.ownedProcesses(initialProcessIDs) else {
                throw Failure.processStateUnknown
            }
            if currentRegistration == .removed, pids.isEmpty {
                // A completed unregister cannot race this token-checked clear.
                // Removing a stale refresh intent lets a later fresh install
                // begin from macOS registration state instead of maintenance.
                try io.clearMaintenanceIntent()
                return
            }
            guard io.now() < deadline else {
                if currentRegistration != .removed {
                    throw Failure.registrationRemovalTimedOut
                }
                throw Failure.processExitTimedOut
            }
            try await io.sleep(limits.poll)
        }
    }

    static func ownedDaemonProcesses(
        in snapshot: LocalProcessInventory.Snapshot,
        bundleURLs: [URL],
        retaining retainedPIDs: Set<Int32> = []
    ) -> ProcessSnapshot {
        guard case let .available(entries) = snapshot else { return .unknown }
        let executablePaths = Set(bundleURLs.map {
            $0.appendingPathComponent("Contents/MacOS/xdial-daemon")
                .standardizedFileURL.resolvingSymlinksInPath().path
        })
        var owned = Set<Int32>()
        for entry in entries {
            if retainedPIDs.contains(entry.pid) {
                owned.insert(entry.pid)
                continue
            }
            if let executableURL = entry.executableURL {
                let path = executableURL.standardizedFileURL.resolvingSymlinksInPath().path
                if executablePaths.contains(path) { owned.insert(entry.pid) }
                continue
            }
            // A same-name process without a kernel path might be ours, but its
            // identity is not authority to wait on or remove a different app.
            if entry.matchesExecutableName(in: ["xdial-daemon"]) == true {
                return .unknown
            }
        }
        return .available(owned)
    }
}
