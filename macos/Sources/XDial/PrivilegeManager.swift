import Foundation

enum PrivilegeManager {
    static let label = "com.kafeifei.xdial.helper"
    static let helperDir = "/Library/PrivilegedHelperTools"
    static let helperPath = "\(helperDir)/\(label)"
    static let plistDir = "/Library/LaunchDaemons"
    static let plistPath = "\(plistDir)/\(label).plist"
    static let socketPath = "/tmp/xdial.sock"

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
            && FileManager.default.fileExists(atPath: helperPath)
    }

    static var isHelperRunning: Bool {
        canConnectSocket()
    }

    static var needsUpdate: Bool {
        guard isInstalled else { return false }
        let src = helperSourcePath()
        guard FileManager.default.fileExists(atPath: src) else { return false }
        let srcAttrs = try? FileManager.default.attributesOfItem(atPath: src)
        let dstAttrs = try? FileManager.default.attributesOfItem(atPath: helperPath)
        let srcSize = srcAttrs?[.size] as? Int ?? 0
        let dstSize = dstAttrs?[.size] as? Int ?? 0
        if srcSize != dstSize { return true }
        let srcDate = srcAttrs?[.modificationDate] as? Date ?? .distantPast
        let dstDate = dstAttrs?[.modificationDate] as? Date ?? .distantPast
        return srcDate > dstDate
    }

    static func ensureHelperRunning() throws {
        // launchd KeepAlive 保证 helper 常驻，只需等 socket 就绪
        for _ in 0..<30 {
            if canConnectSocket() { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    // MARK: - Install / Update / Uninstall

    static func install() throws {
        let helperSource = helperSourcePath()
        guard FileManager.default.fileExists(atPath: helperSource) else {
            throw NSError(domain: "XDial", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "找不到 xdial-helper 二进制: \(helperSource)"])
        }

        let tmpPlist = "/tmp/xdial-daemon.plist"
        try buildPlist().write(toFile: tmpPlist, atomically: true, encoding: .utf8)

        let shell = """
        set -eu
        mkdir -p '\(helperDir)'
        cp '\(helperSource)' '\(helperPath)'
        chown root:wheel '\(helperPath)'
        chmod 0755 '\(helperPath)'
        cp '\(tmpPlist)' '\(plistPath)'
        chown root:wheel '\(plistPath)'
        chmod 0644 '\(plistPath)'
        rm -f '\(tmpPlist)'
        launchctl bootout system/\(label) 2>/dev/null || true
        launchctl bootstrap system '\(plistPath)'
        """

        if !runAdminShell(shell) {
            throw NSError(domain: "XDial", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "安装失败（用户取消或权限不足）"])
        }

        guard isInstalled else {
            throw NSError(domain: "XDial", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "安装后验证失败，请重试"])
        }
    }

    static func uninstall() throws {
        let shell = """
        launchctl bootout system/\(label) 2>/dev/null || true
        rm -f '\(plistPath)' '\(helperPath)' '\(socketPath)' '/tmp/xdial-helper.log' '/tmp/xdial-app.log'
        rm -rf '/tmp/xdial-engine'
        rm -f '/etc/sudoers.d/xdial'
        """
        if !runAdminShell(shell) {
            throw NSError(domain: "XDial", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "卸载失败（用户取消或权限不足）"])
        }
    }

    // MARK: - Private

    private static func buildPlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(helperPath)</string>
                <string>\(socketPath)</string>
            </array>
            <key>KeepAlive</key>
            <true/>
            <key>RunAtLoad</key>
            <true/>
            <key>StandardOutPath</key>
            <string>/tmp/xdial-helper.log</string>
            <key>StandardErrorPath</key>
            <string>/tmp/xdial-helper.log</string>
        </dict>
        </plist>
        """
    }

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

    static func helperSourcePath() -> String {
        let bundle = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/xdial-helper").path
        if FileManager.default.fileExists(atPath: bundle) {
            return bundle
        }
        let dev = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("xdial-helper").path
        if FileManager.default.fileExists(atPath: dev) {
            return dev
        }
        return "\(NSHomeDirectory())/Codes/Vibe/XDial/build/xdial-helper"
    }

    @discardableResult
    private static func runAdminShell(_ shell: String) -> Bool {
        let script = "do shell script \(appleScriptQuote(shell)) with administrator privileges"
        var err: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&err)
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
