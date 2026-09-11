import Foundation

// 日志放到用户私有目录并以 0600 创建；之前写 /tmp/xdial-app.log（世界可读），
// 会把 parse-sub 响应里的节点密码等敏感内容暴露给同机任意用户。
func appLogPath() -> String {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs")
        .appendingPathComponent(XDialBuildIdentity.logDirectoryName)
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

    private let transparentProxy = TransparentProxyManager.shared
    private let socketPath = XDialBuildIdentity.daemonSocketPath
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var readBuffer = Data()
    private var requestSeq: UInt64 = 0
    private var pendingCallbacks: [String: (DaemonResponse) -> Void] = [:]
    private var transparentProxySystemStatus = "disconnected"
    var underlayChangeHandler: ((String, Bool) -> Void)?
    var automaticReconnectPreparationHandler:
        ((String, @escaping (AutomaticReconnectPreparation?) -> Void) -> Void)?

    @Published private(set) var status: String = "disconnected"
    @Published var lastError: String?
    @Published private(set) var connectedAt: Date?
    @Published private(set) var connectionReport: ConnectionReport?
    @Published private(set) var scenarioSwitchProjection:
        HostScenarioSwitchProjection?
    private var coldLaunchSettledTransactionID: String?
    private var explicitlyStoppedTransactionID: String?
    private var pendingStatusSyncCompletions: [() -> Void] = []

    var presentedConnectionReport: ConnectionReport? {
        ConnectionReportLiveProjection.presentedReport(
            connectionReport,
            status: status,
            coldLaunchSettledTransactionID:
                coldLaunchSettledTransactionID,
            explicitlyStoppedTransactionID:
                explicitlyStoppedTransactionID
        )
    }

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
    var isBusy: Bool {
        status == "connecting" || status == "disconnecting" || status == "reconnecting"
    }
    var automaticReconnectState: AutomaticReconnectRuntimeState {
        transparentProxy.automaticReconnectState
    }

    private init() {
        connectionReport = ConnectionReportJournal.read()
        scenarioSwitchProjection =
            transparentProxy.scenarioSwitchProjection
        if let connectionReport,
           ConnectionReportLiveProjection.isSafelySettledTerminal(
               connectionReport
           ) {
            coldLaunchSettledTransactionID =
                connectionReport.transactionID
        }
        transparentProxy.statusHandler = { [weak self] status, error in
            Task { @MainActor in
                self?.applyTransparentProxyStatus(status, error: error)
            }
        }
        transparentProxy.reportHandler = { [weak self] report in
            Task { @MainActor in
                self?.applyConnectionReport(report)
            }
        }
        transparentProxy.scenarioSwitchHandler = {
            [weak self] projection in
            Task { @MainActor in
                self?.scenarioSwitchProjection = projection
            }
        }
        transparentProxy.automaticReconnectPreparationHandler = {
            [weak self] fingerprint, completion in
            // The manager invokes preparation from its main-queue capture.
            // Register synchronously: an extra Task hop could install a
            // cancelled recovery waiter after a new manual connection intent.
            MainActor.assumeIsolated {
                guard let handler = self?.automaticReconnectPreparationHandler else {
                    completion(nil)
                    return
                }
                handler(fingerprint, completion)
            }
        }
        transparentProxy.underlayChangeHandler = {
            [weak self] fingerprint, connectivityRestored in
            Task { @MainActor in
                self?.underlayChangeHandler?(
                    fingerprint,
                    connectivityRestored
                )
            }
        }
    }

    // MARK: - Public API

    func start(
        profileJSON: String,
        automaticRetryTrigger: AutomaticReconnectTrigger? = nil
    ) {
        lastError = nil
        // The journal remains available for recovery and diagnostics, but the
        // previous terminal report must not flash while a new transaction is
        // being planned.
        connectionReport = nil
        explicitlyStoppedTransactionID = nil
        transparentProxySystemStatus = "connecting"
        reconcileTransparentProxyStatus()
        transparentProxy.start(
            profileJSON: profileJSON,
            automaticRetryTrigger: automaticRetryTrigger
        )
    }

    /// Replace the committed Scenario inside the current Provider session.
    /// The source report and `connected` status stay live until the Provider
    /// atomically commits the target transaction.
    func switchScenario(
        profileJSON: String,
        refreshLineRuntimes: Bool,
        networkEpochID: String? = nil,
        expectedUnderlayFingerprint: String? = nil,
        completion: @escaping (Result<ConnectionReport, Error>) -> Void
    ) {
        lastError = nil
        transparentProxy.switchScenario(
            profileJSON: profileJSON,
            refreshLineRuntimes: refreshLineRuntimes,
            networkEpochID: networkEpochID,
            expectedUnderlayFingerprint: expectedUnderlayFingerprint
        ) { [weak self] result in
            Task { @MainActor [weak self] in
                switch result {
                case let .success(report):
                    self?.applyConnectionReport(report)
                case let .failure(error):
                    self?.lastError = error.localizedDescription
                }
                completion(result)
            }
        }
    }

    func cancelScenarioSwitch() {
        transparentProxy.cancelScenarioSwitch()
    }

    func captureCurrentUnderlayFingerprint(
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        transparentProxy.captureCurrentUnderlayFingerprint { result in
            Task { @MainActor in
                completion(result)
            }
        }
    }

    func runtimeConfigurationFingerprint(
        profileJSON: String
    ) -> Result<String, Error> {
        transparentProxy.runtimeConfigurationFingerprint(
            profileJSON: profileJSON
        )
    }

    @discardableResult
    func retryAutomaticReconnectNow() -> Bool {
        transparentProxy.retryAutomaticReconnectNow()
    }

#if DEBUG
    func injectFailureOnNextStart(_ stage: String) -> Bool {
        transparentProxy.injectFailureOnNextStart(stage)
    }
#endif

    func prepareSystemExtension(
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        transparentProxy.prepareSystemExtension(completion: completion)
    }

    func uninstallSystemExtension(
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        transparentProxy.uninstallSystemExtension(
            completion: completion
        )
    }

    func probeLineOutboundAddress(
        transactionID: String,
        lineID: String,
        addressFamily: LineAddressFamily = .ipv4,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        transparentProxy.probeLineOutboundAddress(
            transactionID: transactionID,
            lineID: lineID,
            addressFamily: addressFamily,
            completion: completion
        )
    }

    func trafficSnapshot(
        transactionID: String,
        completion: @escaping (
            Result<ProviderTrafficSnapshot, Error>
        ) -> Void
    ) {
        transparentProxy.trafficSnapshot(
            transactionID: transactionID,
            completion: completion
        )
    }

    #if DEBUG
    func applicationAttributionSnapshot(
        transactionID: String,
        completion: @escaping (
            Result<ProviderApplicationAttributionSnapshot, Error>
        ) -> Void
    ) {
        transparentProxy.applicationAttributionSnapshot(
            transactionID: transactionID,
            completion: completion
        )
    }

    func routingProbeSnapshot(
        transactionID: String,
        probeID: String,
        completion: @escaping (
            Result<ProviderRoutingProbeSnapshot, Error>
        ) -> Void
    ) {
        transparentProxy.routingProbeSnapshot(
            transactionID: transactionID,
            probeID: probeID,
            completion: completion
        )
    }

    func beginRouteProbe(
        transactionID: String,
        host: String,
        timeoutMS: Int,
        completion: @escaping (
            Result<ProviderBegunRouteProbe, Error>
        ) -> Void
    ) {
        transparentProxy.beginRouteProbe(
            transactionID: transactionID,
            host: host,
            timeoutMS: timeoutMS,
            completion: completion
        )
    }
    #endif

    func stop(userInitiated: Bool = false) {
        appLog("stop() called for Transparent Proxy, status=\(status)")
        if userInitiated {
            explicitlyStoppedTransactionID =
                connectionReport?.transactionID
        }
        transparentProxy.stop()
    }

    func requiresTerminationDrain() -> Bool {
        let snapshot = transparentProxy.terminationDrainSnapshot()
        return ApplicationTerminationPolicy.requiresDrain(
            runtimeStatus: snapshot.runtimeStatus,
            hasConnectionReport: snapshot.report != nil,
            rollbackComplete: snapshot.report?.rollbackComplete ?? false,
            systemTakeoverRemoved:
                snapshot.report?.systemTakeoverRemoved ?? false
        )
    }

    func parseSubscription(url: String, content: String = "", format: String = "auto",
                           completion: @escaping (Result<ParseResult, Error>) -> Void) {
        Task { [weak self] in
            let ok = await self?.ensureHelperAsync() ?? false
            guard let self, ok else {
                completion(.failure(NSError(
                    domain: "XDial",
                    code: -1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            InstallationCoordinator.shared
                            .blockingMessage,
                    ]
                )))
                return
            }
            guard self.ensureSocket() else {
                completion(.failure(NSError(
                    domain: "XDial",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Socket not available"]
                )))
                return
            }
            self.sendSubRequest(
                url: url,
                content: content,
                format: format,
                completion: completion
            )
        }
    }

    func syncStatus(completion: (() -> Void)? = nil) {
        if let completion {
            pendingStatusSyncCompletions.append(completion)
        }
        transparentProxy.syncStatus()
    }

    func systemDidWake(
        isSystemWake: Bool,
        completion: (() -> Void)? = nil
    ) {
        if isSystemWake {
            transparentProxy.noteSystemWake()
        }
        syncStatus(completion: completion)
    }

    func systemWillSleep() {
        transparentProxy.noteSystemSleep()
    }

    func prepareTailscale(
        profileJSON: String,
        lineID: String,
        authKey: String = "",
        completion: @escaping (Result<TailscaleRuntimeStatus, Error>) -> Void
    ) {
        performTailscaleStatusRequest(
            cmd: "tailscale-prepare",
            profile: profileJSON,
            lineID: lineID,
            authKey: authKey,
            completion: completion
        )
    }

    func tailscaleStatus(
        lineID: String,
        completion: @escaping (Result<TailscaleRuntimeStatus, Error>) -> Void
    ) {
        performTailscaleStatusRequest(
            cmd: "tailscale-status",
            lineID: lineID,
            completion: completion
        )
    }

    func beginTailscaleLogin(
        lineID: String,
        completion: @escaping (Result<TailscaleRuntimeStatus, Error>) -> Void
    ) {
        performTailscaleStatusRequest(
            cmd: "tailscale-login",
            lineID: lineID,
            completion: completion
        )
    }

    func logoutTailscale(
        lineID: String,
        completion: @escaping (Result<TailscaleRuntimeStatus, Error>) -> Void
    ) {
        performTailscaleStatusRequest(
            cmd: "tailscale-logout",
            lineID: lineID,
            completion: completion
        )
    }

    func stopTailscaleSetup(
        lineID: String,
        completion: (() -> Void)? = nil
    ) {
        guard ensureSocket() else {
            completion?()
            return
        }
        let sent = sendRequest(
            cmd: "tailscale-stop-setup",
            fields: ["line_id": lineID]
        ) { _ in
            completion?()
        }
        if !sent {
            completion?()
        }
    }

    // MARK: - Request sending

    private func nextID() -> String {
        requestSeq += 1
        return String(requestSeq)
    }

    @discardableResult
    private func sendRequest(cmd: String, profile: String? = nil,
                             fields: [String: String] = [:],
                             callback: ((DaemonResponse) -> Void)? = nil) -> Bool {
        guard fd >= 0 else {
            appLog("sendRequest(\(cmd)): fd < 0")
            return false
        }

        let reqID = nextID()
        var obj: [String: String] = ["id": reqID, "cmd": cmd]
        if let profile { obj["profile"] = profile }
        for (key, value) in fields {
            obj[key] = value
        }

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

    private func performTailscaleStatusRequest(
        cmd: String,
        profile: String? = nil,
        lineID: String,
        authKey: String = "",
        completion: @escaping (Result<TailscaleRuntimeStatus, Error>) -> Void
    ) {
        Task { [weak self] in
            let ok = await self?.ensureHelperAsync() ?? false
            guard let self, ok, self.ensureSocket() else {
                completion(.failure(
                    self?.requestError(
                        InstallationCoordinator.shared.blockingMessage
                    ) ?? NSError(domain: "XDial", code: -1)
                ))
                return
            }
            var fields = ["line_id": lineID]
            if !authKey.isEmpty {
                fields["auth_key"] = authKey
            }
            let sent = self.sendRequest(
                cmd: cmd,
                profile: profile,
                fields: fields
            ) { response in
                guard response.ok == true,
                      let raw = response.data?.data(using: .utf8) else {
                    completion(.failure(self.requestError(
                        response.message ?? "Tailscale 请求失败"
                    )))
                    return
                }
                do {
                    completion(.success(
                        try JSONDecoder().decode(TailscaleRuntimeStatus.self, from: raw)
                    ))
                } catch {
                    completion(.failure(self.requestError("Tailscale 状态无效")))
                }
            }
            if !sent {
                completion(.failure(self.requestError("无法发送 Tailscale 请求")))
            }
        }
    }

    private func requestError(_ message: String) -> NSError {
        NSError(
            domain: "XDial",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
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
                completion(.failure(NSError(
                    domain: "XDial",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: msg]
                )))
            }
        }

        data.withUnsafeBytes { _ = write(fd, $0.baseAddress!, data.count) }
    }

    // MARK: - Helper lifecycle

    /// Registration maintenance must preserve both the Provider transaction
    /// and in-flight helper requests. The daemon independently gates all its
    /// clients and Tailscale setup before granting a maintenance lease.
    var helperRegistrationMaintenanceAllowed: Bool {
        !requiresTerminationDrain() && pendingCallbacks.isEmpty
    }

    private nonisolated func ensureHelperAsync() async -> Bool {
        let expectedHash = await MainActor.run { () -> String? in
            let installation = InstallationCoordinator.shared
            guard installation.isReady, PrivilegeManager.isInstalled else {
                installation.start()
                installation.present()
                return nil
            }
            return installation.verifiedHelperExecutableHash
        }
        guard let expectedHash else { return false }
        do {
            try PrivilegeManager.ensureHelperRunning()
            if let info = PrivilegeManager.probeDaemonInfo(),
               info.exeSHA256 == expectedHash {
                return true
            }
            await MainActor.run { [weak self] in
                self?.lastError = "后台服务版本发生变化，正在重新验证安装"
                InstallationCoordinator.shared.start(force: true)
            }
            return false
        } catch {
            await MainActor.run { [weak self] in
                self?.lastError = "后台服务不可用，正在恢复注册"
                InstallationCoordinator.shared.start(force: true)
            }
            return false
        }
    }

    // MARK: - Socket

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
                _ = strncpy(
                    UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                    cstr,
                    104
                )
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
        _ = openSocket()
    }

    private func processLines() {
        while let idx = readBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = readBuffer[readBuffer.startIndex..<idx]
            readBuffer = Data(readBuffer[(idx + 1)...])
            guard let resp = try? JSONDecoder().decode(DaemonResponse.self, from: line) else {
                continue
            }
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
            // helper 不再拥有桌面数据面。它仍服务于订阅解析、Tailscale 登录等
            // 控制面请求，但不得用旧 sing-box Engine 的状态覆盖系统扩展。
            break
        case "error":
            appLog("ignored legacy helper data-plane error: \(data ?? "")")
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

    private func applyTransparentProxyStatus(
        _ newStatus: String,
        error: String?
    ) {
        transparentProxySystemStatus = newStatus
        reconcileTransparentProxyStatus()
        if let error, !error.isEmpty {
            appLog("Transparent Proxy error: \(error)")
            lastError = error
        }
        let completions = pendingStatusSyncCompletions
        pendingStatusSyncCompletions.removeAll()
        for completion in completions {
            completion()
        }
    }

    private func applyConnectionReport(_ report: ConnectionReport) {
        connectionReport = report
        reconcileTransparentProxyStatus()
    }

    private func reconcileTransparentProxyStatus() {
        let old = status
        let resolved = TransparentProxyRuntimeGate.resolve(
            systemStatus: transparentProxySystemStatus,
            report: connectionReport,
            activeTransactionID: transparentProxy.activeTransactionID,
            previousStatus: old
        )
        status = resolved
        if resolved == "connected" && old != "connected" {
            connectedAt = Date()
            lastError = nil
        } else if resolved == "disconnected" {
            connectedAt = nil
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
    let scenarioID: String?
    let connectedAt: Int?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case status, error
        case scenarioID = "scenario_id"
        case connectedAt = "connected_at"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        status = try values.decode(String.self, forKey: .status)
        scenarioID = try values.decodeIfPresent(String.self, forKey: .scenarioID)
        connectedAt = try values.decodeIfPresent(Int.self, forKey: .connectedAt)
        error = try values.decodeIfPresent(String.self, forKey: .error)
    }
}
