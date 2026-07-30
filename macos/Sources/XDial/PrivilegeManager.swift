import CryptoKit
import Foundation
import ServiceManagement

// 特权模型（Surge 同款体验）：
// - daemon 以 SMAppService 注册，plist 与二进制都在 app bundle 内，由 launchd 以 root 运行
// - 首次启用在系统设置「登录项」批准一次（支持 Touch ID），之后重编/升级永远免授权：
//   launchd 直接运行 bundle 里的新二进制，信任绑定在开发者签名身份上，而非二进制快照
// - 重编后运行中的旧 daemon 通过 respawn 命令原地 re-exec 成新二进制，全程无感
// - 旧机制（密码安装到 /Library/PrivilegedHelperTools）只保留一次性清理入口
enum PrivilegeManager {
    static let label = "com.kafeifei.xdial.helper"
    static let plistName = "com.kafeifei.xdial.helper.plist"
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

    static func unregister() throws {
        try service.unregister()
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
    }

    /// bundle 内 daemon 二进制的 SHA256。与运行中 daemon 的 daemon-info 比对，
    /// 不一致说明重编过 → 发 respawn 让它原地换成新二进制。
    static func bundledDaemonSHA256() -> String? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/xdial-daemon")
        guard let data = try? Data(contentsOf: path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 旧机制残留（/Library 安装）

    static let legacyHelperPath = "/Library/PrivilegedHelperTools/\(label)"
    static let legacyPlistPath = "/Library/LaunchDaemons/\(label).plist"

    static var legacyInstalled: Bool {
        FileManager.default.fileExists(atPath: legacyPlistPath)
            || FileManager.default.fileExists(atPath: legacyHelperPath)
    }

    /// 清掉旧安装（bootout + 删文件）。这是整个生命周期里最后一次要密码的操作，
    /// 且只发生在从旧机制迁移的机器上。
    static func cleanupLegacy() throws {
        let shell = """
        launchctl bootout system/\(label) 2>/dev/null || true
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

        enum CodingKeys: String, CodingKey {
            case version, pid
            case exeSHA256 = "exe_sha256"
        }
    }

    /// 询问运行中 daemon 的版本与二进制 hash。独立短连接，不掺和 GoEngine 的主 socket。
    static func probeDaemonInfo() -> DaemonInfo? {
        guard let data = roundTrip(cmd: "daemon-info"), let payload = data.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(DaemonInfo.self, from: payload)
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
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cstr in
                _ = strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr, 104)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, len) == 0
            }
        }
        guard connected else { return nil }

        let reqID = "probe-\(UInt64.random(in: 1...UInt64.max))"
        let request = "{\"id\":\"\(reqID)\",\"cmd\":\"\(cmd)\"}\n"
        let sent = request.withCString { cstr in
            write(fd, cstr, strlen(cstr))
        }
        guard sent > 0 else { return nil }

        struct ProbeResponse: Decodable {
            let id: String?
            let ok: Bool?
            let data: String?
        }

        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var chunk = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return nil }
            buffer.append(contentsOf: chunk[..<n])
            while let idx = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<idx]
                buffer = Data(buffer[(idx + 1)...])
                guard let resp = try? JSONDecoder().decode(ProbeResponse.self, from: line),
                      resp.id == reqID else { continue }
                guard resp.ok == true else { return nil }
                return expectData ? resp.data : ""
            }
        }
        return nil
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
}
