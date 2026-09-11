import CryptoKit
import Foundation
import ServiceManagement

// daemon 以 SMAppService 注册，plist 与二进制都在 app bundle 内，由 launchd 托管。
// .enabled 只代表允许运行；更新 plist 或 executable 后必须重新注册。安装协调器
// 先取得空闲服务的维护租约，再等待 unregister completion 后注册当前 bundle。
enum PrivilegeManager {
    static let label = "com.kafeifei.xdial.app.daemon"
    static let plistName =
        "com.kafeifei.xdial.app.daemon.plist"
    private static let legacyLabel = "com.kafeifei.xdial.helper"
    static let socketPath = "/tmp/xdial.sock"

    static var service: SMAppService { SMAppService.daemon(plistName: plistName) }

    static var status: SMAppService.Status { service.status }

    /// daemon 是否已批准并托管给 launchd（不代表进程此刻活着，KeepAlive 会拉起）
    static var isInstalled: Bool { status == .enabled }

    /// 已注册但等待用户在系统设置里批准
    static var requiresApproval: Bool { status == .requiresApproval }

    static var isHelperRunning: Bool {
        canConnectSocket()
    }

    static func register() throws {
        try service.register()
    }

    static func registerCurrentBundle() throws -> Bool {
        let appService = service
        let statusBefore = appService.status
        appLog("helper register begin status=\(statusBefore.rawValue)")
        do {
            try appService.register()
        } catch {
            let statusAfter = appService.status
            appLog("helper register result=error statusBefore=\(statusBefore.rawValue)"
                + " statusAfter=\(statusAfter.rawValue) "
                + ServiceManagementErrorDiagnostics.summary(error))
            // A newly registered daemon can await user consent. Do not turn an
            // AlreadyRegistered response into proof of refreshed registration.
            if ServiceManagementErrorDiagnostics.matches(
                error, domain: SMAppServiceErrorDomain, code: kSMErrorAlreadyRegistered
            ) { return false }
            if statusAfter == .requiresApproval {
                try recordAcceptedRegistration()
                return true
            }
            throw error
        }
        appLog("helper register result=accepted statusBefore=\(statusBefore.rawValue)"
            + " statusAfter=\(appService.status.rawValue)")
        try recordAcceptedRegistration()
        return true
    }

    static func canReconcileRegistrationFailure(_ error: Error) -> Bool {
        guard ServiceManagementErrorDiagnostics.matches(
            error, domain: SMAppServiceErrorDomain, code: Int(EPERM)
        ), status == .notRegistered,
              registrationMaintenanceTarget() != nil else { return false }
        appLog("helper register reconciliation eligible status=0 "
            + ServiceManagementErrorDiagnostics.summary(error))
        return true
    }

    static func registrationMaintenanceTarget() -> HelperRegistrationCoordinator.MaintenanceTarget? {
        do {
            guard let intent = try HelperRegistrationMaintenanceIntent.read(),
                  intent.phase == "committed",
                  let identity = try? registrationIdentity(),
                  intent.targetHash == identity.executableHash else { return nil }
            return .init(
                token: intent.token,
                targetHash: intent.targetHash,
                registrationFingerprint: identity.fingerprint
            )
        } catch { return nil }
    }

    private static func recordAcceptedRegistration() throws {
        if let intent = try HelperRegistrationMaintenanceIntent.read() {
            try HelperRegistrationMaintenanceIntent.update(
                token: intent.token, phase: "registered", targetHash: registrationIdentity().executableHash
            )
        }
    }

    static func verifiedRegistrationMarker(fingerprint: String, executableHash: String, savedMarker: String?) -> String? {
        do {
            if let intent = try HelperRegistrationMaintenanceIntent.read() {
                // Only an acknowledged unregister followed by successful register
                // can produce this phase. Earlier crashes need a new OS barrier.
                return intent.phase == "registered" && intent.targetHash == executableHash ? fingerprint : nil
            }
            return savedMarker
        } catch { return nil }
    }

    static var hasPendingRegistrationRecovery: Bool {
        do {
            guard let intent = try HelperRegistrationMaintenanceIntent.read() else { return false }
            return intent.phase != "registered" || intent.targetHash != bundledDaemonSHA256()
        } catch { return true }
    }

    static let registrationMarkerKey = "xdial.helper.registration.v1"

    struct RegistrationIdentity {
        let fingerprint: String
        let executableHash: String
    }

    static func registrationIdentity() throws -> RegistrationIdentity {
        guard let identifier = Bundle.main.bundleIdentifier,
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let executableHash = bundledDaemonSHA256() else {
            throw HelperError.registrationIdentityUnavailable
        }
        let plist = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Library/LaunchDaemons/\(plistName)"
        )
        let plistHash = SHA256.hash(data: try Data(contentsOf: plist))
            .map { String(format: "%02x", $0) }.joined()
        return RegistrationIdentity(
            fingerprint: [identifier, build, plistHash, executableHash].joined(separator: ":"),
            executableHash: executableHash
        )
    }

    static var registrationStatus: HelperRegistrationCoordinator.ServiceStatus {
        switch status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    static func registrationRuntime() -> HelperRegistrationCoordinator.Runtime {
        if let info = probeDaemonInfo(), let pid = Int32(exactly: info.pid), pid > 0 {
            return .running(.init(
                pid: pid,
                executableHash: info.exeSHA256,
                handoffProtocolVersion: info.registrationHandoffVersion ?? 0
            ))
        }
        if canConnectSocket() { return .unresponsive }
        guard case let .available(entries) = LocalProcessInventory.capture() else { return .unknown }
        var hasUnknown = false
        for entry in entries where entry.pid != ProcessInfo.processInfo.processIdentifier {
            switch entry.matchesExecutableName(in: ["xdial", "xdial-daemon"]) {
            case true: return .unresponsive
            case false: continue
            case nil: hasUnknown = true
            }
        }
        return hasUnknown ? .unknown : .absent
    }

    static func legacyMaintenanceIsExclusive(daemonPID: Int32) -> Bool {
        guard case let .available(entries) = LocalProcessInventory.capture() else { return false }
        let hostPID = ProcessInfo.processInfo.processIdentifier
        return entries.allSatisfy { entry in
            if entry.pid == hostPID || entry.pid == daemonPID { return true }
            return entry.matchesExecutableName(in: ["xdial", "xdial-daemon"]) == false
        }
    }

    static func legacyEngineIsIdle() -> Bool {
        struct Status: Decodable { let status: String }
        guard let raw = roundTrip(cmd: "status"),
              let data = raw.data(using: .utf8),
              let result = try? JSONDecoder().decode(Status.self, from: data) else { return false }
        return result.status == "disconnected"
    }

    private static let registrationRefreshLock = NSLock()
    private static var registrationRefreshInFlight = false

    /// Keep a cooperative live daemon quiesced through the OS completion. A
    /// timeout reports an unknown result; it never releases a lease while a
    /// pending unregister could still kill the daemon after it resumes work.
    static func unregisterForRegistrationRefresh(
        daemon: HelperRegistrationCoordinator.Daemon?
    ) async throws -> HelperRegistrationCoordinator.MaintenanceTarget {
        guard await MainActor.run(body: { GoEngine.shared.helperRegistrationMaintenanceAllowed }) else {
            throw HelperRegistrationCoordinator.Failure.serviceBusy
        }
        let targetIdentity = try registrationIdentity()
        let previousIntent = try HelperRegistrationMaintenanceIntent.read()
        // Live services first grant an idle lease. Only the absent path needs
        // an intent before probing again to cover a racing KeepAlive start.
        let earlyIntent = daemon == nil ? try HelperRegistrationMaintenanceIntent.establish(
            targetHash: targetIdentity.executableHash, previousPID: nil
        ) : previousIntent
        let lease: LocalDaemonConnection?
        do {
            lease = try await Task.detached { () throws -> LocalDaemonConnection? in
                let runtime = registrationRuntime()
                guard case let .running(current) = runtime else {
                    guard runtime == .absent else {
                        throw HelperRegistrationCoordinator.Failure.serviceBusy
                    }
                    return nil
                }
                if current.handoffProtocolVersion < 1 {
                    // Only the coordinator's full legacy idle window authorizes
                    // this path. Unknown third-party IPC clients cannot be proven
                    // idle on the old protocol; no re-exec path can repair that.
                    guard current == daemon,
                          legacyMaintenanceIsExclusive(daemonPID: current.pid),
                          legacyEngineIsIdle() else {
                        throw HelperRegistrationCoordinator.Failure.serviceBusy
                    }
                    return nil
                }
                guard let connection = LocalDaemonConnection(timeout: 2) else {
                    throw HelperRegistrationCoordinator.Failure.serviceBusy
                }
                guard connection.peerPID == current.pid,
                      let response = connection.request("registration-handoff"), response.ok == true,
                      let raw = response.data?.data(using: .utf8),
                      let reply = try? JSONDecoder().decode(HandoffReply.self, from: raw),
                      reply.pid == current.pid, reply.protocolVersion == 1 else {
                    connection.close()
                    throw HelperRegistrationCoordinator.Failure.serviceBusy
                }
                return connection
            }.value
            guard await MainActor.run(body: { GoEngine.shared.helperRegistrationMaintenanceAllowed }) else {
                lease?.close()
                throw HelperRegistrationCoordinator.Failure.serviceBusy
            }
        } catch {
            if previousIntent == nil, let earlyIntent {
                try? HelperRegistrationMaintenanceIntent.clear(token: earlyIntent.token)
            }
            throw error
        }
        let intent: HelperRegistrationMaintenanceIntent.Record
        do {
            intent = try earlyIntent ?? HelperRegistrationMaintenanceIntent.establish(
                targetHash: targetIdentity.executableHash, previousPID: daemon?.pid
            )
        } catch {
            lease?.close()
            throw error
        }
        let maintenanceTarget = HelperRegistrationCoordinator.MaintenanceTarget(
            token: intent.token,
            targetHash: targetIdentity.executableHash,
            registrationFingerprint: targetIdentity.fingerprint
        )
        let targetHash = targetIdentity.executableHash
        let leasedPID = lease?.peerPID
        try await Task.detached {
            try unregisterHoldingLease(lease, intent: intent, targetHash: targetHash)
            // SM completion is the registration barrier; the previous process
            // must also have exited before a replacement registration is made.
            try awaitPreviousDaemonExit(pids: [daemon?.pid, leasedPID, intent.previousPID].compactMap { $0 })
        }.value
        return maintenanceTarget
    }

    private static func awaitPreviousDaemonExit(pids: [Int32]) throws {
        guard !pids.isEmpty else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while true {
            guard case let .available(entries) = LocalProcessInventory.capture() else {
                throw HelperRegistrationCoordinator.Failure.processStateUnknown
            }
            if !entries.contains(where: { pids.contains($0.pid) }) { return }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw HelperRegistrationCoordinator.Failure.processStateUnknown
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    static func finishRegistrationMaintenance() throws {
        guard let intent = try HelperRegistrationMaintenanceIntent.read() else { return }
        guard intent.phase == "registered",
              intent.targetHash == bundledDaemonSHA256(),
              let connection = LocalDaemonConnection(timeout: 2),
              connection.request("registration-finalize", fields: ["profile": intent.token])?.ok == true else {
            throw HelperRegistrationCoordinator.Failure.serviceUnavailable
        }
    }

    private static func unregisterHoldingLease(
        _ lease: LocalDaemonConnection?, intent: HelperRegistrationMaintenanceIntent.Record,
        targetHash: String
    ) throws {
        registrationRefreshLock.lock()
        if registrationRefreshInFlight {
            registrationRefreshLock.unlock()
            lease?.close()
            throw HelperError.registrationRefreshPending
        }
        registrationRefreshInFlight = true
        registrationRefreshLock.unlock()

        do {
            // A new completed unregister barrier may adopt an interrupted older
            // intent for the currently installed bundle. Delayed retries then
            // remain pinned to this token and target without blocking recovery
            // merely because the previous attempt named an older helper hash.
            try HelperRegistrationMaintenanceIntent.update(
                token: intent.token, phase: "committed", targetHash: targetHash
            )
        } catch {
            lease?.close()
            registrationRefreshLock.lock()
            registrationRefreshInFlight = false
            registrationRefreshLock.unlock()
            throw error
        }
        if let lease, lease.request("registration-commit")?.ok != true {
            // An unanswered commit may have succeeded. Preserve its intent and
            // quiescence for adoption instead of guessing that it was rejected.
            lease.close()
            registrationRefreshLock.lock()
            registrationRefreshInFlight = false
            registrationRefreshLock.unlock()
            throw HelperError.registrationRefreshTimedOut
        }
        let result = UnregisterResult()
        let completion = DispatchSemaphore(value: 0)
        let appService = service
        let statusBefore = appService.status
        appLog("helper unregister begin status=\(statusBefore.rawValue)")
        appService.unregister { error in
            result.record(error)
            appLog("helper unregister completion statusBefore=\(statusBefore.rawValue)"
                + " statusAfter=\(appService.status.rawValue) "
                + ServiceManagementErrorDiagnostics.summary(error))
            if let error, !ServiceManagementErrorDiagnostics.matches(
                error, domain: SMAppServiceErrorDomain, code: kSMErrorJobNotFound
            ) {
                // A definite OS failure is the only pre-verification abort.
                do {
                    if let lease {
                        try HelperRegistrationMaintenanceIntent.update(token: intent.token, phase: "aborted")
                        _ = lease.request("registration-abort", fields: ["profile": intent.token])
                    } else {
                        try HelperRegistrationMaintenanceIntent.clear(token: intent.token)
                    }
                } catch {
                    appLog("helper maintenance intent retained after unregister failure: \(error)")
                }
            }
            lease?.close()
            registrationRefreshLock.lock()
            registrationRefreshInFlight = false
            registrationRefreshLock.unlock()
            completion.signal()
        }
        guard completion.wait(timeout: .now() + 15) == .success else {
            throw HelperError.registrationRefreshTimedOut
        }
        if let error = result.error {
            if ServiceManagementErrorDiagnostics.matches(
                error, domain: SMAppServiceErrorDomain, code: kSMErrorJobNotFound
            ), status == .notRegistered || status == .notFound {
                return
            }
            throw error
        }
    }

    private struct HandoffReply: Decodable {
        let pid: Int32
        let protocolVersion: Int
        enum CodingKeys: String, CodingKey {
            case pid
            case protocolVersion = "protocol_version"
        }
    }

    private final class UnregisterResult: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Error?
        func record(_ error: Error?) {
            lock.lock()
            value = error
            lock.unlock()
        }
        var error: Error? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    static func unregister() throws {
        try service.unregister()
    }

    static func unregisterForIdentityReplacement() throws {
        if #available(macOS 13.0, *) {
            let mainAppService = SMAppService.mainApp
            if mainAppService.status == .enabled
                || mainAppService.status == .requiresApproval {
                try mainAppService.unregister()
            }
        }
        if status == .enabled || status == .requiresApproval {
            try unregister()
        }
        for _ in 0..<50 {
            if status != .enabled,
               status != .requiresApproval,
               !canConnectSocket() {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw HelperError.unregisterTimedOut
    }

    static func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func ensureHelperRunning() throws {
        // launchd KeepAlive 保证 helper 常驻，只需等 socket 就绪
        for _ in 0..<30 {
            if canConnectSocket() { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw HelperError.socketUnavailable
    }

    /// bundle 内 daemon 二进制的 SHA256。与运行中 daemon 的 daemon-info 比对，
    /// 不一致说明重编过 → 发 respawn 让它原地换成新二进制。
    static func bundledDaemonSHA256() -> String? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/xdial-daemon")
        guard let data = try? Data(contentsOf: path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 旧机制残留（/Library 安装）

    static let legacyHelperPath =
        "/Library/PrivilegedHelperTools/\(legacyLabel)"
    static let legacyPlistPath =
        "/Library/LaunchDaemons/\(legacyLabel).plist"

    static var legacyInstalled: Bool {
        FileManager.default.fileExists(atPath: legacyPlistPath)
            || FileManager.default.fileExists(atPath: legacyHelperPath)
    }

    /// 清掉旧安装（bootout + 删文件）。这是整个生命周期里最后一次要密码的操作，
    /// 且只发生在从旧机制迁移的机器上。
    static func cleanupLegacy() throws {
        let shell = """
        launchctl bootout system/\(legacyLabel) 2>/dev/null || true
        rm -f '\(legacyPlistPath)' '\(legacyHelperPath)'
        rm -f '/etc/sudoers.d/xdial'
        """
        if !runAdminShell(shell) {
            throw NSError(domain: "XDial", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "清理旧版 helper 失败（用户取消或权限不足）"])
        }
        guard !legacyInstalled else {
            throw NSError(domain: "XDial", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "旧版 helper 清理后仍有残留，请重试"])
        }
    }

    /// 卸载：注销 SMAppService（免密）+ 清运行数据。旧机制残留另走 cleanupLegacy。
    static func uninstall(deleteData: Bool = false) throws {
        try? unregister()
        if legacyInstalled {
            try cleanupLegacy()
        }
        if deleteData {
            // /Library/Application Support/XDial 是 root 属主，得借 root daemon 或
            // 管理员权限删；daemon 已被注销，这里只能走一次管理员授权。
            _ = runAdminShell("rm -rf '/Library/Application Support/XDial' '/tmp/xdial-engine' '/tmp/xdial.log' '\(socketPath)'")
        }
    }

    // MARK: - Daemon 探测（阻塞式，只在后台线程调用）

    struct DaemonInfo: Decodable {
        let version: String
        let exeSHA256: String
        let pid: Int
        let registrationHandoffVersion: Int?

        enum CodingKeys: String, CodingKey {
            case version, pid
            case exeSHA256 = "exe_sha256"
            case registrationHandoffVersion = "registration_handoff_version"
        }
    }

    /// 询问运行中 daemon 的版本与二进制 hash。独立短连接，不掺和 GoEngine 的主 socket。
    static func probeDaemonInfo() -> DaemonInfo? {
        guard let connection = LocalDaemonConnection(timeout: 2) else { return nil }
        defer { connection.close() }
        guard let response = connection.request("daemon-info"), response.ok == true,
              let payload = response.data?.data(using: .utf8),
              let info = try? JSONDecoder().decode(DaemonInfo.self, from: payload),
              let peerPID = connection.peerPID,
              Int(peerPID) == info.pid else { return nil }
        return info
    }

    /// Network Extension 以 root 运行，同名 App Group 会映射到 root 容器。
    /// helper 只读转发扩展侧的权威事务报告，宿主再镜像到自己的容器供 UI 使用。
    static func probeProviderConnectionReport() -> ConnectionReport? {
        guard
            let raw = roundTrip(
                cmd: "connection-report",
                timeout: 0.2
            ),
            let data = raw.data(using: .utf8)
        else {
            return nil
        }
        return try? ConnectionReportCodec.decode(data)
    }

    /// 请求 daemon 原地 re-exec 成 bundle 里的当前二进制。引擎忙时 daemon 会拒绝。
    static func requestRespawn() -> Bool {
        roundTrip(cmd: "respawn", expectData: false) != nil
    }

    /// 发一条命令并等对应响应。daemon 连接后会先推 status 事件，逐行过滤到匹配 id 为止。
    private static func roundTrip(cmd: String, expectData: Bool = true, timeout: Double = 2) -> String? {
        guard let connection = LocalDaemonConnection(timeout: timeout) else { return nil }
        defer { connection.close() }
        guard let response = connection.request(cmd), response.ok == true else { return nil }
        return expectData ? response.data : ""
    }

    private final class LocalDaemonConnection: @unchecked Sendable {
        struct Response: Decodable {
            let id: String?
            let ok: Bool?
            let data: String?
        }

        private let lock = NSLock()
        private var descriptor: Int32
        private let timeout: TimeInterval

        init?(timeout: TimeInterval) {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            var tv = timeval(
                tv_sec: Int(timeout),
                tv_usec: Int32((timeout - floor(timeout)) * 1_000_000)
            )
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                socketPath.withCString { source in
                    _ = strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, 104)
                }
            }
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
                }
            }
            guard connected else {
                Darwin.close(fd)
                return nil
            }
            self.descriptor = fd
            self.timeout = timeout
        }

        deinit { close() }

        func close() {
            lock.lock()
            let fd = descriptor
            descriptor = -1
            lock.unlock()
            if fd >= 0 { Darwin.close(fd) }
        }

        var peerPID: Int32? {
            var pid: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0,
                  pid > 0 else { return nil }
            return pid
        }

        func request(_ command: String, fields: [String: String] = [:]) -> Response? {
            let requestID = "probe-\(UUID().uuidString)"
            var payload = fields
            payload["id"] = requestID
            payload["cmd"] = command
            guard var request = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
            request.append(0x0A)
            let written = request.withUnsafeBytes { bytes -> Bool in
                var offset = 0
                while offset < bytes.count {
                    let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    guard count > 0 else { return false }
                    offset += count
                }
                return true
            }
            guard written else { return nil }
            var buffer = Data()
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            var chunk = [UInt8](repeating: 0, count: 4096)
            while ProcessInfo.processInfo.systemUptime < deadline {
                let count = read(descriptor, &chunk, chunk.count)
                guard count > 0 else { return nil }
                buffer.append(contentsOf: chunk.prefix(count))
                guard buffer.count <= 4 * 1024 * 1024 else { return nil }
                while let index = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[..<index])
                    buffer.removeSubrange(...index)
                    guard let response = try? JSONDecoder().decode(Response.self, from: line),
                          response.id == requestID else { continue }
                    return response
                }
            }
            return nil
        }
    }

    // MARK: - Socket

    static func canConnectSocket() -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cstr in
                _ = strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr, 104)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, len) == 0
            }
        }
    }

    // MARK: - Private

    @discardableResult
    private static func runAdminShell(_ shell: String) -> Bool {
        let script = "do shell script \(appleScriptQuote(shell)) with administrator privileges"
        var err: NSDictionary?
        _ = NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err = err {
            appLog("runAdminShell FAILED: \(err)")
        }
        return err == nil
    }

    private static func appleScriptQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    private enum HelperError: LocalizedError {
        case socketUnavailable
        case unregisterTimedOut
        case registrationIdentityUnavailable
        case registrationRefreshPending
        case registrationRefreshTimedOut

        var errorDescription: String? {
            switch self {
            case .socketUnavailable:
                "后台服务已注册，但 6 秒内没有建立本地控制通道"
            case .unregisterTimedOut:
                "旧版后台服务未能在 5 秒内退出"
            case .registrationIdentityUnavailable:
                "无法验证安装包中的后台服务注册信息"
            case .registrationRefreshPending:
                "macOS 仍在完成上一笔后台服务注册更新"
            case .registrationRefreshTimedOut:
                "macOS 未在 15 秒内确认后台服务注销，已停止后续注册操作"
            }
        }
    }
}
