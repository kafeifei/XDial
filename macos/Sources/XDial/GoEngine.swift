import Foundation

func appLog(_ msg: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
    if let fh = FileHandle(forWritingAtPath: "/tmp/xdial-app.log") {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: "/tmp/xdial-app.log", contents: line.data(using: .utf8))
    }
}

@MainActor
final class GoEngine: ObservableObject {
    static let shared = GoEngine()

    private let socketPath = "/tmp/xdial.sock"
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var readBuffer = Data()

    @Published private(set) var status: String = "disconnected"
    @Published var lastError: String?
    @Published private(set) var connectedAt: Date?

    var isConnected: Bool { status == "connected" }
    var isBusy: Bool { status == "connecting" || status == "disconnecting" }

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
                self.sendCommand("start", profile: json)
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
        if !sendCommand("stop") {
            appLog("stop: sendCommand failed")
            status = "disconnected"
            connectedAt = nil
        }
    }

    func syncStatus() {
        closeSocket()
        guard PrivilegeManager.isHelperRunning, openSocket() else { return }
        sendCommand("status")
    }

    // MARK: - Helper lifecycle

    private nonisolated func ensureHelperAsync() async -> Bool {
        guard PrivilegeManager.isInstalled else {
            await MainActor.run { [weak self] in
                self?.lastError = "请先点击「一键配置」安装 helper"
                self?.status = "disconnected"
            }
            return false
        }
        do {
            try PrivilegeManager.ensureHelperRunning()
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
        if let source = readSource {
            readSource = nil
            source.cancel()
        } else if fd >= 0 {
            close(fd)
        }
        fd = -1
        readBuffer = Data()
    }

    @discardableResult
    private func sendCommand(_ cmd: String, profile: String? = nil) -> Bool {
        guard fd >= 0 else {
            appLog("sendCommand(\(cmd)): fd < 0")
            return false
        }
        var obj: [String: String] = ["cmd": cmd]
        if let profile { obj["profile"] = profile }
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return false }
        data.append(UInt8(ascii: "\n"))

        let written = data.withUnsafeBytes { write(fd, $0.baseAddress!, data.count) }
        if written >= 0 {
            appLog("sendCommand(\(cmd)): wrote \(written) bytes")
            return true
        }

        appLog("sendCommand(\(cmd)): write failed errno=\(errno), reconnecting")
        closeSocket()
        guard openSocket() else {
            appLog("sendCommand(\(cmd)): reconnect failed")
            return false
        }
        let retry = data.withUnsafeBytes { write(fd, $0.baseAddress!, data.count) }
        appLog("sendCommand(\(cmd)): retry wrote \(retry) bytes")
        return retry >= 0
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        if n > 0 {
            readBuffer.append(contentsOf: buf[..<n])
            processLines()
            return
        }
        // EOF or error: socket broken, reconnect and query real status
        closeSocket()
        if openSocket() {
            sendCommand("status")
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
            handleResponse(resp)
        }
    }

    private func handleResponse(_ resp: DaemonResponse) {
        appLog("handleResponse: type=\(resp.type) ok=\(String(describing: resp.ok)) data=\(resp.data ?? "")")
        switch resp.type {
        case "status":
            if let data = resp.data?.data(using: .utf8),
               let msg = try? JSONDecoder().decode(EngineStatus.self, from: data) {
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
        case "error":
            lastError = resp.message
            if status == "connecting" || status == "disconnecting" {
                sendCommand("status")
            }
        case "result":
            if resp.ok != true {
                lastError = resp.message
                sendCommand("status")
            }
        default:
            break
        }
    }
}

private struct DaemonResponse: Decodable {
    let type: String
    let cmd: String?
    let ok: Bool?
    let message: String?
    let data: String?
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
