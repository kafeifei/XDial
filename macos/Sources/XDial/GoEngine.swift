import Foundation

// 日志放到用户私有目录并以 0600 创建；之前写 /tmp/xdial-app.log（世界可读），
// 会把 parse-sub 响应里的节点密码等敏感内容暴露给同机任意用户。
func appLogPath() -> String {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/XDial")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("xdial-app.log").path
}

func appLog(_ msg: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
    let path = appLogPath()
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        FileManager.default.createFile(
            atPath: path, contents: line.data(using: .utf8),
            attributes: [.posixPermissions: 0o600])
    }
}

@MainActor
final class GoEngine: ObservableObject {
    static let shared = GoEngine()

    private let socketPath = "/tmp/xdial.sock"
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var readBuffer = Data()
    private var requestSeq: UInt64 = 0
    private var pendingCallbacks: [String: (DaemonResponse) -> Void] = [:]

    @Published private(set) var status: String = "disconnected"
    @Published var lastError: String?
    @Published private(set) var connectedAt: Date?

    struct ParseResult: Decodable {
        let lines: [Line]
        let proxyGroups: [SubProxyGroup]?
        let rules: [SubRule]?

        enum CodingKeys: String, CodingKey {
            case lines
            case proxyGroups = "proxy_groups"
            case rules
        }
    }

    var isConnected: Bool { status == "connected" }
    var isBusy: Bool { status == "connecting" || status == "disconnecting" || status == "reconnecting" }

    // MARK: - Public API

    func start(profileJSON: String) {
        lastError = nil
        status = "connecting"
        let json = profileJSON
        Task.detached { [weak self] in
            let ok = await self?.ensureHelperAsync() ?? false
            await MainActor.run {
                guard let self, ok else { return }
                guard self.ensureSocket() else {
                    self.lastError = "无法连接到 helper 进程"
                    self.status = "disconnected"
                    return
                }
                self.sendRequest(cmd: "start", profile: json)
            }
        }
    }

    func stop() {
        appLog("stop() called, fd=\(self.fd), status=\(self.status)")
        guard ensureSocket() else {
            appLog("stop: ensureSocket failed")
            status = "disconnected"
            connectedAt = nil
            return
        }
        sendRequest(cmd: "stop") { [weak self] resp in
            if resp.ok != true {
                self?.lastError = resp.message
            }
        }
    }

    func parseSubscription(url: String, content: String = "", format: String = "auto",
                           completion: @escaping (Result<ParseResult, Error>) -> Void) {
        Task.detached { [weak self] in
            let ok = await self?.ensureHelperAsync() ?? false
            await MainActor.run {
                guard let self, ok else {
                    completion(.failure(NSError(domain: "XDial", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Cannot connect to helper"])))
                    return
                }
                guard self.ensureSocket() else {
                    completion(.failure(NSError(domain: "XDial", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Socket not available"])))
                    return
                }
                self.sendSubRequest(url: url, content: content, format: format, completion: completion)
            }
        }
    }

    func syncStatus() {
        closeSocket()
        guard PrivilegeManager.isHelperRunning, openSocket() else { return }
        sendRequest(cmd: "status") { [weak self] resp in
            if resp.ok == true, let data = resp.data {
                self?.applyStatusData(data)
            }
        }
    }

    // MARK: - Request sending

    private func nextID() -> String {
        requestSeq += 1
        return String(requestSeq)
    }

    @discardableResult
    private func sendRequest(cmd: String, profile: String? = nil,
                             callback: ((DaemonResponse) -> Void)? = nil) -> Bool {
        guard fd >= 0 else {
            appLog("sendRequest(\(cmd)): fd < 0")
            return false
        }

        let reqID = nextID()
        var obj: [String: String] = ["id": reqID, "cmd": cmd]
        if let profile { obj["profile"] = profile }

        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return false }
        data.append(UInt8(ascii: "\n"))

        if let callback {
            pendingCallbacks[reqID] = callback
        }

        let written = data.withUnsafeBytes { write(fd, $0.baseAddress!, data.count) }
        if written >= 0 {
            appLog("sendRequest(\(cmd) id=\(reqID)): wrote \(written) bytes")
            return true
        }

        appLog("sendRequest(\(cmd)): write failed errno=\(errno), reconnecting")
        pendingCallbacks.removeValue(forKey: reqID)
        closeSocket()
        guard openSocket() else {
            appLog("sendRequest(\(cmd)): reconnect failed")
            return false
        }
        if let callback {
            pendingCallbacks[reqID] = callback
        }
        let retry = data.withUnsafeBytes { write(fd, $0.baseAddress!, data.count) }
        appLog("sendRequest(\(cmd)): retry wrote \(retry) bytes")
        return retry >= 0
    }

    private func sendSubRequest(url: String, content: String, format: String,
                                completion: @escaping (Result<ParseResult, Error>) -> Void) {
        guard fd >= 0 else { return }
        let reqID = nextID()
        var obj: [String: String] = [
            "id": reqID,
            "cmd": "parse-sub",
            "sub_url": url,
            "sub_format": format,
        ]
        if !content.isEmpty {
            obj["sub_content"] = content
        }
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(UInt8(ascii: "\n"))

        pendingCallbacks[reqID] = { resp in
            if resp.ok == true, let raw = resp.data?.data(using: .utf8),
               let result = try? JSONDecoder().decode(ParseResult.self, from: raw) {
                completion(.success(result))
            } else {
                let msg = resp.message ?? "parse failed"
                completion(.failure(NSError(domain: "XDial", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: msg])))
            }
        }

        data.withUnsafeBytes { _ = write(fd, $0.baseAddress!, data.count) }
    }

    // MARK: - Helper lifecycle

    /// 重编自愈：bundle 里的 daemon 二进制和运行中的不一致时，让 daemon 原地
    /// re-exec 成新版。全程零授权（respawn 走 socket，launchd 无感知）。
    static nonisolated func syncDaemonBinary() async {
        guard let bundled = PrivilegeManager.bundledDaemonSHA256(),
              let info = PrivilegeManager.probeDaemonInfo(),
              info.exeSHA256 != "unknown", info.exeSHA256 != bundled else { return }
        appLog("daemon outdated (running \(info.exeSHA256.prefix(8)) vs bundled \(bundled.prefix(8))), respawning")
        guard PrivilegeManager.requestRespawn() else {
            appLog("daemon respawn refused (engine busy?), will retry on next operation")
            return
        }
        for _ in 0..<25 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if let fresh = PrivilegeManager.probeDaemonInfo(), fresh.exeSHA256 == bundled {
                appLog("daemon respawned to bundled binary (pid \(fresh.pid))")
                return
            }
        }
        appLog("daemon respawn did not converge, continuing with running daemon")
    }

    private nonisolated func ensureHelperAsync() async -> Bool {
        guard PrivilegeManager.isInstalled else {
            await MainActor.run { [weak self] in
                self?.lastError = "请先点击「一键配置」启用后台服务"
                self?.status = "disconnected"
            }
            return false
        }
        do {
            try PrivilegeManager.ensureHelperRunning()
            await Self.syncDaemonBinary()
            for _ in 0..<20 {
                if PrivilegeManager.canConnectSocket() { return true }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            await MainActor.run { [weak self] in
                self?.lastError = "helper 已启动但无法连接 socket"
                self?.status = "disconnected"
            }
            return false
        } catch {
            let msg = error.localizedDescription
            await MainActor.run { [weak self] in
                self?.lastError = "启动 helper 失败: \(msg)"
                self?.status = "disconnected"
            }
            return false
        }
    }

    // MARK: - Socket (private)

    private func ensureSocket() -> Bool {
        if fd >= 0 { return true }
        return openSocket()
    }

    private func openSocket() -> Bool {
        if fd >= 0 { return true }

        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cstr in
                _ = strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr, 104)
            }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(sock, sockPtr, len)
            }
        }
        guard result == 0 else {
            close(sock)
            return false
        }

        fd = sock
        let source = DispatchSource.makeReadSource(fileDescriptor: sock, queue: .main)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { close(sock) }
        readSource = source
        source.resume()
        return true
    }

    private func closeSocket() {
        pendingCallbacks.removeAll()
        if let source = readSource {
            readSource = nil
            source.cancel()
        } else if fd >= 0 {
            close(fd)
        }
        fd = -1
        readBuffer = Data()
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        if n > 0 {
            readBuffer.append(contentsOf: buf[..<n])
            processLines()
            return
        }
        closeSocket()
        if openSocket() {
            sendRequest(cmd: "status") { [weak self] resp in
                if resp.ok == true, let data = resp.data {
                    self?.applyStatusData(data)
                }
            }
        } else {
            status = "disconnected"
            connectedAt = nil
        }
    }

    private func processLines() {
        while let idx = readBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = readBuffer[readBuffer.startIndex..<idx]
            readBuffer = Data(readBuffer[(idx + 1)...])
            guard let resp = try? JSONDecoder().decode(DaemonResponse.self, from: line) else { continue }
            handleMessage(resp)
        }
    }

    // MARK: - Message handling

    private func handleMessage(_ msg: DaemonResponse) {
        if let event = msg.event {
            handleEvent(event: event, data: msg.data)
        } else if let id = msg.id {
            handleResponse(id: id, msg: msg)
        }
    }

    private func handleEvent(event: String, data: String?) {
        appLog("event: \(event) data=\(data ?? "")")
        switch event {
        case "status":
            if let data {
                applyStatusData(data)
            }
        case "error":
            lastError = data
            if status == "connecting" || status == "disconnecting" {
                sendRequest(cmd: "status") { [weak self] resp in
                    if resp.ok == true, let data = resp.data {
                        self?.applyStatusData(data)
                    }
                }
            }
        default:
            break
        }
    }

    private func handleResponse(id: String, msg: DaemonResponse) {
        // 不记录 data 正文：parse-sub 等响应含节点明文密码/订阅 token，只记长度
        appLog("response: id=\(id) ok=\(String(describing: msg.ok)) dataLen=\(msg.data?.count ?? 0)")
        if let callback = pendingCallbacks.removeValue(forKey: id) {
            callback(msg)
        } else if msg.ok != true {
            lastError = msg.message
        }
    }

    private func applyStatusData(_ dataStr: String) {
        guard let data = dataStr.data(using: .utf8),
              let msg = try? JSONDecoder().decode(EngineStatus.self, from: data) else { return }
        let old = status
        status = msg.status
        if msg.status == "connected" && old != "connected" {
            connectedAt = Date()
            lastError = nil
        } else if msg.status == "disconnected" {
            connectedAt = nil
        }
        if let e = msg.error, !e.isEmpty {
            lastError = e
        }
    }

}

private struct DaemonResponse: Decodable {
    let id: String?
    let ok: Bool?
    let message: String?
    let data: String?
    let event: String?
}

struct EngineStatus: Decodable {
    let status: String
    let mode: String?
    let connectedAt: Int?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case status, mode, error
        case connectedAt = "connected_at"
    }
}
