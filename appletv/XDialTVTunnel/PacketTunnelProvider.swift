import NetworkExtension
import Network
@preconcurrency import Libbox
import os.log

/// NetworkExtension 的 completion handler 尚未标注 Sendable，但 provider 必须把阻塞的
/// Go 引擎工作移出系统回调队列。这个小盒子只负责跨队列携带不可变闭包。
private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// XDial iOS / tvOS 的 packet-tunnel 扩展。
///
/// 进程内跑 Libbox(sslcon + gVisor + sing-box):
///   - `startTunnel` 建立到 AnyConnect 的连接、把 NE 的 packetFlow 文件描述符交给
///     sing-box 的 TUN inbound、配置 NEPacketTunnelNetworkSettings 后放行。
///   - `handleAppMessage` 承接 App(GoEngine.swift 的 sendProviderMessage)发来的
///     控制请求(start/stop/status/parse-sub),回一段 DaemonResponse JSON。
///
/// 通信/存储约定(与 GoEngine.swift、AppState.swift、core/libbox 对齐):
///   - App Group:规则文件的共享容器；启动配置只通过 start options 一次性交付。
///   - Libbox 绑定:LibboxNew(cb) → LibboxLibbox;start(server,username,password,configJSON)、
///     setTunFD(_:)、stop()、status()、isRunning()(见 core/libbox/libbox.go 的
///     gomobile 导出面,方法名遵循 gomobile 首字母小写惯例)。
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {

    #if os(iOS)
    private static let appGroupID = "group.com.kafeifei.xdial.ios"
    private static let subsystem = "com.kafeifei.xdial.ios.tunnel"
    #else
    private static let appGroupID = "group.com.kafeifei.xdialtv"
    private static let subsystem = "com.kafeifei.xdialtv.tunnel"
    #endif

    /// 仅用于读取并清理早期版本留在 App Group 的启动参数。
    /// 新版本不会再写这些 key，完整配置统一通过一次性 start options 交付。
    private static let configKey = "xdial.tunnel.config"
    private static let serverKey = "xdial.tunnel.server"
    private static let usernameKey = "xdial.tunnel.username"
    private static let passwordKey = "xdial.tunnel.password"
    private static let diagnosticKey = "xdial.tunnel.diagnostic"

    private let log = OSLog(subsystem: subsystem, category: "provider")

    /// 进程内引擎实例。startTunnel 时创建,stopTunnel 时置空。
    private var libbox: LibboxLibbox?

    /// 引擎最近一次通过 Callback 报上来的错误文本(用于 status 响应带出)。
    private var lastError: String?

    /// sing-box 的 direct/DNS 出站必须始终知道真实 Wi-Fi/蜂窝出口。
    /// 不能把 utun 自身或 nil 当默认接口，否则会出现“系统显示已连接但没有网络”。
    private var pathMonitor: NWPathMonitor?
    private var diagnosticStage = "idle"
    private var activeAttemptID = ""
    private var physicalInterfaceName = ""
    private var physicalInterfaceIndex = -1
    private let diagnosticLock = NSLock()
    private let diagnosticWriteQueue = DispatchQueue(label: "com.kafeifei.xdial.tunnel.diagnostics")

    // MARK: - Libbox 回调

    /// 桥接 LibboxCallbackProtocol → 本 provider。gomobile 生成的回调协议方法名
    /// 见 DebugSmokeTest.swift 里的 TestCallback(onStatusChanged / onError)。
    private final class EngineCallback: NSObject, LibboxCallbackProtocol {
        weak var provider: PacketTunnelProvider?
        init(provider: PacketTunnelProvider) {
            self.provider = provider
        }
        func onStatusChanged(_ statusJSON: String?) {
            os_log("libbox status: %{public}@", log: OSLog(subsystem: PacketTunnelProvider.subsystem, category: "provider"),
                   type: .info, statusJSON ?? "")
        }
        func onError(_ code: Int, message: String?) {
            os_log("libbox error %d: %{public}@", log: OSLog(subsystem: PacketTunnelProvider.subsystem, category: "provider"),
                   type: .error, code, message ?? "")
            provider?.setLastError(message)
        }
    }

    // MARK: - startTunnel

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let completion = UncheckedSendableBox(completionHandler)
        beginAttempt(options?["attemptID"] as? String ?? "")
        recordDiagnostic("start_begin")
        os_log("startTunnel: begin", log: log, type: .info)

        // 1) 取凭据与 sing-box 配置。
        //    优先 options(App 通过 startVPNTunnel(options:) 一次性下发)；
        //    缺项仅为升级兼容回退旧 App Group 数据，读取后会立即清理。
        guard let bundle = resolveStartBundle(options: options) else {
            let err = providerError(2, "缺少 AnyConnect 凭据或 sing-box 配置(options 与 App Group 均无)")
            setLastError(err.localizedDescription)
            recordDiagnostic("start_bundle_missing")
            os_log("startTunnel: missing credentials/config", log: log, type: .error)
            completion.value(err)
            return
        }
        recordDiagnostic("start_bundle_loaded")

        // 2) 创建引擎实例。
        let cb = EngineCallback(provider: self)
        guard let lb = LibboxNew(cb) else {
            let err = providerError(4, "LibboxNew 返回 nil")
            setLastError(err.localizedDescription)
            recordDiagnostic("engine_create_failed")
            os_log("startTunnel: LibboxNew returned nil", log: log, type: .error)
            completion.value(err)
            return
        }
        self.libbox = lb

        // 3) 在默认路由切进 utun 之前先取得真实物理出口，并持续监听 Wi-Fi/蜂窝切换。
        //    sing-box 官方 Apple 客户端也用 NWPathMonitor 驱动平台接口监控。
        do {
            try startDefaultInterfaceMonitor()
            recordDiagnostic("physical_interface_ready")
        } catch {
            setLastError(error.localizedDescription)
            recordDiagnostic("physical_interface_failed")
            os_log("startTunnel: physical interface unavailable: %{public}@",
                   log: log, type: .error, error.localizedDescription)
            pathMonitor?.cancel()
            pathMonitor = nil
            libbox = nil
            completion.value(error)
            return
        }

        // 4) 在默认路由进入 utun 前解析控制连接地址。NETunnelNetworkSettings
        //    明确要求 tunnelRemoteAddress 是数值 IP，不能传 hostname；同一个 IP
        //    也会作为 /32 排除路由和 sslcon 的 socket 目标。原始域名仍由 sslcon
        //    用作 TLS SNI/证书校验与 HTTP Host。
        recordDiagnostic("remote_address_resolving")
        var resolveError: NSError?
        let remoteIPv4 = LibboxResolveServerIPv4(bundle.server, &resolveError)
        guard resolveError == nil, IPv4Address(remoteIPv4) != nil else {
            let error = providerError(5, resolveError?.localizedDescription
                ?? "服务器地址未解析为有效 IPv4")
            setLastError(error.localizedDescription)
            recordDiagnostic("remote_address_resolution_failed")
            os_log("startTunnel: remote address resolution failed: %{public}@",
                   log: log, type: .error, error.localizedDescription)
            pathMonitor?.cancel()
            pathMonitor = nil
            libbox = nil
            completion.value(error)
            return
        }
        recordDiagnostic("remote_address_resolved")

        // 5) 先配置 NE 网络设置(隧道地址/DNS/路由),再拨号。
        //    NE 要求在 completionHandler(nil) 之前必须 setTunnelNetworkSettings 一次,
        //    否则 packetFlow 不会真正建立、拿不到有效 fd。
        //    真实的隧道地址/DNS 要等 AnyConnect 握手结果(X-CSTP-Address / X-CSTP-DNS),
        //    当前 Libbox.Start 尚未把握手结果回吐给 Swift,这里先用与 core/config
        //    buildTUNInbound 一致的占位网段(198.18.0.1/15),DNS 用公共兜底。
        //    TODO(真机联调):从 AnyConnect 握手结果动态填真实地址/DNS/路由。
        let settings = buildNetworkSettings(remoteAddress: remoteIPv4)
        setTunnelNetworkSettings(settings) { [weak self] settingsError in
            guard let self else {
                completion.value(providerErrorStatic(4, "provider deallocated"))
                return
            }
            if let settingsError {
                self.setLastError(settingsError.localizedDescription)
                self.recordDiagnostic("network_settings_failed")
                os_log("startTunnel: setTunnelNetworkSettings failed: %{public}@",
                       log: self.log, type: .error, settingsError.localizedDescription)
                self.pathMonitor?.cancel()
                self.pathMonitor = nil
                self.libbox = nil
                completion.value(settingsError)
                return
            }
            self.recordDiagnostic("network_settings_applied")

            // 6) 把 packetFlow 对应的 tun fd 交给引擎(见下方 tunFileDescriptor 说明)。
            if let fd = self.tunFileDescriptor(), fd > 0 {
                lb.setTunFD(fd)
                self.recordDiagnostic("tun_ready")
                os_log("startTunnel: tun fd set = %d", log: self.log, type: .info, fd)
            } else {
                let error = self.providerError(4, "无法获取系统隧道接口")
                self.setLastError(error.localizedDescription)
                self.recordDiagnostic("tun_unavailable")
                os_log("startTunnel: tun fd unavailable",
                       log: self.log, type: .error)
                self.pathMonitor?.cancel()
                self.pathMonitor = nil
                self.libbox = nil
                completion.value(error)
                return
            }

            // 7) 拨号 + 启动 sing-box。StartResolved 是阻塞调用，socket 直拨
            //    remoteIPv4；TLS/HTTP 身份仍使用 bundle.server 的原始域名。
            self.recordDiagnostic("engine_starting")
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try lb.startResolved(bundle.server, dialAddress: remoteIPv4,
                                         username: bundle.username, password: bundle.password,
                                         configJSON: bundle.configJSON)
                    self.recordDiagnostic("engine_started")
                    os_log("startTunnel: engine started", log: self.log, type: .info)
                    completion.value(nil)
                } catch {
                    self.setLastError(error.localizedDescription)
                    self.recordDiagnostic("engine_failed")
                    os_log("startTunnel: engine start failed: %{public}@",
                           log: self.log, type: .error, error.localizedDescription)
                    self.pathMonitor?.cancel()
                    self.pathMonitor = nil
                    self.libbox = nil
                    completion.value(error)
                }
            }
        }
    }

    // MARK: - stopTunnel

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let completion = UncheckedSendableBox(completionHandler)
        recordDiagnostic("stopping")
        os_log("stopTunnel: reason=%d", log: log, type: .info, reason.rawValue)
        // Stop 也可能阻塞(关闭 sing-box + 断开 AnyConnect),放后台线程。
        let lb = self.libbox
        self.libbox = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        DispatchQueue.global(qos: .userInitiated).async {
            if let lb {
                try? lb.stop()
            }
            os_log("stopTunnel: done", log: self.log, type: .info)
            completion.value()
        }
    }

    // MARK: - handleAppMessage

    /// 处理 App(GoEngine.sendProviderMessage)发来的一段 JSON 请求,回一段
    /// DaemonResponse JSON。请求结构见 GoEngine.swift 的 sendRequest / sendSubRequest:
    ///   {"cmd":"start","profile":"<...>"}            // 目前扩展侧不再从 profile 拨号
    ///   {"cmd":"stop"}
    ///   {"cmd":"status"}
    ///   {"cmd":"parse-sub","sub_url":"...","sub_format":"...","sub_content":"..."}
    /// 响应结构见 GoEngine.swift 的 DaemonResponse:{id?, ok?, message?, data?, event?}。
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let completionHandler else { return }
        let completion = UncheckedSendableBox(completionHandler)

        guard let obj = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
              let cmd = obj["cmd"] as? String else {
            completion.value(encodeResponse(ok: false, message: "无法解析请求(缺少 cmd)"))
            return
        }
        os_log("handleAppMessage: cmd=%{public}@", log: log, type: .info, cmd)

        switch cmd {
        case "status":
            completion.value(handleStatus())

        case "start":
            // 扩展的真实启动由 NETunnelProviderManager.startVPNTunnel(options:) 触发
            // (走 startTunnel 而非本消息)。这里保留一条幂等语义的应答:若引擎已在跑
            // 回 ok,便于 App 在既有隧道上做「确认」。真正的拨号不在此路径完成。
            let running = libbox?.isRunning() ?? false
            completion.value(encodeResponse(ok: true,
                message: running ? nil : "隧道由系统 VPN 配置启动(startVPNTunnel),非此消息路径",
                dataString: statusJSONString()))

        case "stop":
            // 与 start 对称:真正停止隧道应调 NETunnelProviderManager.stopVPNTunnel()。
            // 这里做一次尽力而为的引擎停止,并回 ok。
            let lb = libbox
            libbox = nil
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                if let lb { try? lb.stop() }
                completion.value(self?.encodeResponse(ok: true, dataString: "{\"status\":\"disconnected\"}"))
            }

        case "parse-sub":
            // 订阅解析目前没有进程内实现(macOS 版在 helper daemon 里做)。
            // 如实回一个"未实现"的失败响应,而不是假装成功——上层 sendSubRequest
            // 会把它当解析失败处理并给用户明确提示。
            // TODO:接入进程内订阅解析(复用 core 的订阅解析逻辑并经 Libbox 导出)。
            completion.value(encodeResponse(ok: false, message: "扩展暂不支持订阅解析(parse-sub 未实现)"))

        default:
            completion.value(encodeResponse(ok: false, message: "未知命令: \(cmd)"))
        }
    }

    // MARK: - status 辅助

    private func handleStatus() -> Data {
        encodeResponse(ok: true, dataString: statusJSONString())
    }

    /// 组装 GoEngine.EngineStatus 期望的 JSON:{"status": "...", "error": "..."?}。
    /// EngineStatus 只解 status / mode / connected_at / error;这里给 status(+error)。
    private func statusJSONString() -> String {
        let running = libbox?.isRunning() ?? false
        var dict: [String: Any] = ["status": running ? "connected" : "disconnected"]
        dict["diagnostics"] = diagnosticSnapshot(includeEngine: true)
        if let lastError = currentLastError(), !lastError.isEmpty {
            dict["error"] = lastError
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else {
            return running ? "{\"status\":\"connected\"}" : "{\"status\":\"disconnected\"}"
        }
        return s
    }

    // MARK: - 响应编码(对齐 GoEngine.DaemonResponse)

    /// DaemonResponse 里 data 是 String?(它自身是一段被转义的 JSON 文本,
    /// 比如 EngineStatus/ParseResult 的 JSON)。这里把 dataString 原样放进 data 字段。
    private func encodeResponse(ok: Bool, message: String? = nil, dataString: String? = nil) -> Data {
        var dict: [String: Any] = ["ok": ok]
        if let message { dict["message"] = message }
        if let dataString { dict["data"] = dataString }
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else {
            // 兜底:手写一个最小合法响应,保证 App 侧能解出 ok=false。
            return Data("{\"ok\":false,\"message\":\"响应编码失败\"}".utf8)
        }
        return data
    }

    // MARK: - 凭据/配置读取

    private struct StartBundle {
        let server: String
        let username: String
        let password: String
        let configJSON: String
    }

    /// 优先从一次性 options 读取；回退 App Group 只为兼容早期版本。
    /// 成功复制到内存后立即清理旧 key，避免敏感配置继续持久化。
    private func resolveStartBundle(options: [String: NSObject]?) -> StartBundle? {
        let defaults = UserDefaults(suiteName: Self.appGroupID)

        func pick(_ optKey: String, _ groupKey: String) -> String? {
            if let v = options?[optKey] as? String, !v.isEmpty { return v }
            if let v = defaults?.string(forKey: groupKey), !v.isEmpty { return v }
            return nil
        }

        guard let server = pick("server", Self.serverKey),
              let username = pick("username", Self.usernameKey),
              let password = pick("password", Self.passwordKey),
              let configJSON = pick("configJSON", Self.configKey) else {
            return nil
        }
        for key in [Self.serverKey, Self.usernameKey, Self.passwordKey, Self.configKey] {
            defaults?.removeObject(forKey: key)
        }
        return StartBundle(server: server, username: username, password: password, configJSON: configJSON)
    }

    // MARK: - NE 网络设置

    /// 启动真实物理接口监控并同步等待首个结果。首个接口必须在 Libbox.Start 前
    /// 设置，否则 route.auto_detect_interface 没有可用出口，不能把这种状态算连接成功。
    private func startDefaultInterfaceMonitor() throws {
        let monitor = NWPathMonitor()
        let ready = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "\(Self.subsystem).path-monitor")

        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            self?.updateDefaultInterface(path)
            ready.signal()
            monitor?.pathUpdateHandler = { [weak self] path in
                self?.updateDefaultInterface(path)
            }
        }
        pathMonitor = monitor
        monitor.start(queue: queue)

        guard ready.wait(timeout: .now() + 5) == .success else {
            throw providerError(5, "等待物理网络接口超时")
        }
        guard monitor.currentPath.status == .satisfied,
              selectPhysicalInterface(from: monitor.currentPath) != nil else {
            throw providerError(5, "没有可用的物理网络接口")
        }
    }

    private func updateDefaultInterface(_ path: NWPath) {
        guard path.status == .satisfied, let interface = selectPhysicalInterface(from: path) else {
            setPhysicalInterface(name: "", index: -1)
            libbox?.setDefaultInterface("", index: -1)
            refreshDiagnostic()
            os_log("physical interface unavailable", log: log, type: .error)
            return
        }
        setPhysicalInterface(name: interface.name, index: interface.index)
        libbox?.setDefaultInterface(interface.name, index: interface.index)
        refreshDiagnostic()
        os_log("physical interface: %{public}@ (%d)", log: log, type: .info,
               interface.name, interface.index)
    }

    private func selectPhysicalInterface(from path: NWPath) -> NWInterface? {
        let preferredTypes: [NWInterface.InterfaceType] = [.wifi, .cellular, .wiredEthernet]
        for type in preferredTypes where path.usesInterfaceType(type) {
            if let interface = path.availableInterfaces.first(where: {
                $0.type == type && !isTunnelInterface($0.name)
            }) {
                return interface
            }
        }
        return path.availableInterfaces.first(where: { !isTunnelInterface($0.name) })
    }

    private func isTunnelInterface(_ name: String) -> Bool {
        name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp")
    }

    /// 构造 NEPacketTunnelNetworkSettings。
    /// 隧道 IPv4 地址与 core/config buildTUNInbound 的 tun address(198.18.0.1/15)对齐;
    /// DNS 先用公共兜底。真实值待 AnyConnect 握手结果(见 startTunnel 里的 TODO)。
    private func buildNetworkSettings(remoteAddress: String) -> NEPacketTunnelNetworkSettings {
        // 调用方已用 IPv4Address 做过最终数值校验；不要在这里回退 hostname。
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remoteAddress)

        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.254.0.0"]) // /15
        // 默认路由:全部流量进隧道,由 sing-box 的 route 规则再做分流。
        ipv4.includedRoutes = [NEIPv4Route.default()]
        // 控制连接必须始终走物理出口，不能被刚安装的默认路由套回自身。
        ipv4.excludedRoutes = [
            NEIPv4Route(destinationAddress: remoteAddress, subnetMask: "255.255.255.255"),
        ]
        settings.ipv4Settings = ipv4

        let dns = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        settings.dnsSettings = dns

        settings.mtu = 9000 // 与 buildTUNInbound 的 mtu 对齐

        return settings
    }

    // MARK: - 发布版诊断

    private struct DiagnosticState {
        let stage: String
        let attemptID: String
        let physicalInterfaceName: String
        let physicalInterfaceIndex: Int
        let lastError: String?
    }

    private func beginAttempt(_ attemptID: String) {
        diagnosticLock.lock()
        activeAttemptID = attemptID
        lastError = nil
        diagnosticStage = "idle"
        physicalInterfaceName = ""
        physicalInterfaceIndex = -1
        diagnosticLock.unlock()
    }

    private func setLastError(_ value: String?) {
        diagnosticLock.lock()
        lastError = value
        diagnosticLock.unlock()
    }

    private func currentLastError() -> String? {
        diagnosticLock.lock()
        let value = lastError
        diagnosticLock.unlock()
        return value
    }

    private func setPhysicalInterface(name: String, index: Int) {
        diagnosticLock.lock()
        physicalInterfaceName = name
        physicalInterfaceIndex = index
        diagnosticLock.unlock()
    }

    private func captureDiagnosticState(updatingStage stage: String? = nil) -> DiagnosticState {
        diagnosticLock.lock()
        if let stage {
            diagnosticStage = stage
        }
        let state = DiagnosticState(
            stage: diagnosticStage,
            attemptID: activeAttemptID,
            physicalInterfaceName: physicalInterfaceName,
            physicalInterfaceIndex: physicalInterfaceIndex,
            lastError: lastError
        )
        diagnosticLock.unlock()
        return state
    }

    private func recordDiagnostic(_ stage: String) {
        diagnosticWriteQueue.sync {
            let state = captureDiagnosticState(updatingStage: stage)
            persistDiagnostic(makeDiagnosticSnapshot(from: state, includeEngine: false))
            os_log("diagnostic stage=%{public}@ interface=%{public}@",
                   log: log, type: .info, state.stage, state.physicalInterfaceName)
        }
    }

    /// 接口监控只刷新当前快照，不允许把已经推进的启动 stage 写回旧值。
    private func refreshDiagnostic() {
        diagnosticWriteQueue.sync {
            let state = captureDiagnosticState()
            persistDiagnostic(makeDiagnosticSnapshot(from: state, includeEngine: false))
        }
    }

    private func persistDiagnostic(_ snapshot: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: snapshot),
           let text = String(data: data, encoding: .utf8) {
            let defaults = UserDefaults(suiteName: Self.appGroupID)
            defaults?.set(text, forKey: Self.diagnosticKey)
            // 诊断的价值恰恰在进程异常退出时仍可读取；这里主动落盘，避免只留在缓存。
            defaults?.synchronize()
        }
    }

    private func diagnosticSnapshot(includeEngine: Bool) -> [String: Any] {
        makeDiagnosticSnapshot(from: captureDiagnosticState(), includeEngine: includeEngine)
    }

    private func makeDiagnosticSnapshot(
        from state: DiagnosticState,
        includeEngine: Bool
    ) -> [String: Any] {
        var snapshot: [String: Any] = [
            "stage": state.stage,
            "timestamp": Date().timeIntervalSince1970,
            "physical_interface_name": state.physicalInterfaceName,
            "physical_interface_index": state.physicalInterfaceIndex,
        ]
        if !state.attemptID.isEmpty {
            snapshot["attempt_id"] = state.attemptID
        }
        if let lastError = state.lastError, !lastError.isEmpty {
            snapshot["last_error"] = lastError
        }
        if includeEngine, let engineJSON = libbox?.diagnostics(),
           let data = engineJSON.data(using: .utf8),
           let engine = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            snapshot["engine"] = engine
        }
        return snapshot
    }

    // MARK: - tun fd 获取

    /// 取 NE packetFlow 对应的文件描述符。
    ///
    /// NEPacketTunnelFlow 不公开暴露底层 fd。直接采用 sing-box Apple 客户端的
    /// 官方做法：扫描扩展进程持有的 utun control socket。不要先读私有 KVC keyPath；
    /// key 不存在时会抛 Objective-C exception，Swift 无法捕获并会让扩展直接退出。
    private func tunFileDescriptor() -> Int? {
        let discoveredFD = LibboxGetTunnelFileDescriptor()
        if discoveredFD > 0 { return Int(discoveredFD) }
        return nil
    }

    // MARK: - 错误构造

    private func providerError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: Self.subsystem, code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// 静态版错误构造:供 startTunnel 内 `[weak self]` 闭包在 self 已释放时使用。
private func providerErrorStatic(_ code: Int, _ message: String) -> NSError {
    #if os(iOS)
    let domain = "com.kafeifei.xdial.ios.tunnel"
    #else
    let domain = "com.kafeifei.xdialtv.tunnel"
    #endif
    return NSError(domain: domain, code: code,
            userInfo: [NSLocalizedDescriptionKey: message])
}
