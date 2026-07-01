import NetworkExtension
import Libbox
import os.log

/// XDial tvOS 的 packet-tunnel 扩展。
///
/// 进程内跑 Libbox(sslcon + gVisor + sing-box):
///   - `startTunnel` 建立到 AnyConnect 的连接、把 NE 的 packetFlow 文件描述符交给
///     sing-box 的 TUN inbound、配置 NEPacketTunnelNetworkSettings 后放行。
///   - `handleAppMessage` 承接 App(GoEngine.swift 的 sendProviderMessage)发来的
///     控制请求(start/stop/status/parse-sub),回一段 DaemonResponse JSON。
///
/// 通信/存储约定(与 GoEngine.swift、AppState.swift、core/libbox 对齐):
///   - App Group:group.com.kafeifei.xdialtv,凭据与配置的共享通道。
///   - Libbox 绑定:LibboxNew(cb) → LibboxLibbox;start(server,username,password,configJSON)、
///     setTunFD(_:)、stop()、status()、isRunning()(见 core/libbox/libbox.go 的
///     gomobile 导出面,方法名遵循 gomobile 首字母小写惯例)。
final class PacketTunnelProvider: NEPacketTunnelProvider {

    /// App Group 标识符。与两个 target 的 entitlements 一致。
    private static let appGroupID = "group.com.kafeifei.xdialtv"

    /// 共享容器里存放"待用配置"的键(App 侧写入,扩展侧读取)。
    /// - configKey:sing-box 配置 JSON(由 core/config.GenerateSingBoxFor(PlatformNE) 产出)。
    /// - serverKey/usernameKey/passwordKey:AnyConnect 凭据。
    private static let configKey = "xdial.tunnel.config"
    private static let serverKey = "xdial.tunnel.server"
    private static let usernameKey = "xdial.tunnel.username"
    private static let passwordKey = "xdial.tunnel.password"

    private let log = OSLog(subsystem: "com.kafeifei.xdialtv.tunnel", category: "provider")

    /// 进程内引擎实例。startTunnel 时创建,stopTunnel 时置空。
    private var libbox: LibboxLibbox?

    /// 引擎最近一次通过 Callback 报上来的错误文本(用于 status 响应带出)。
    private var lastError: String?

    // MARK: - Libbox 回调

    /// 桥接 LibboxCallbackProtocol → 本 provider。gomobile 生成的回调协议方法名
    /// 见 DebugSmokeTest.swift 里的 TestCallback(onStatusChanged / onError)。
    private final class EngineCallback: NSObject, LibboxCallbackProtocol {
        weak var provider: PacketTunnelProvider?
        init(provider: PacketTunnelProvider) {
            self.provider = provider
        }
        func onStatusChanged(_ statusJSON: String?) {
            os_log("libbox status: %{public}@", log: OSLog(subsystem: "com.kafeifei.xdialtv.tunnel", category: "provider"),
                   type: .info, statusJSON ?? "")
        }
        func onError(_ code: Int, message: String?) {
            os_log("libbox error %d: %{public}@", log: OSLog(subsystem: "com.kafeifei.xdialtv.tunnel", category: "provider"),
                   type: .error, code, message ?? "")
            provider?.lastError = message
        }
    }

    // MARK: - startTunnel

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        os_log("startTunnel: begin", log: log, type: .info)

        // 1) 取凭据与 sing-box 配置。
        //    优先 options(App 通过 startVPNTunnel(options:) 直接下发,最新最准);
        //    缺项回退到 App Group 共享存储(App 侧持久化的上次配置)。
        guard let bundle = resolveStartBundle(options: options) else {
            let err = providerError(2, "缺少 AnyConnect 凭据或 sing-box 配置(options 与 App Group 均无)")
            os_log("startTunnel: missing credentials/config", log: log, type: .error)
            completionHandler(err)
            return
        }

        // 2) 创建引擎实例。
        let cb = EngineCallback(provider: self)
        guard let lb = LibboxNew(cb) else {
            let err = providerError(4, "LibboxNew 返回 nil")
            os_log("startTunnel: LibboxNew returned nil", log: log, type: .error)
            completionHandler(err)
            return
        }
        self.libbox = lb

        // 3) 先配置 NE 网络设置(隧道地址/DNS/路由),再拨号。
        //    NE 要求在 completionHandler(nil) 之前必须 setTunnelNetworkSettings 一次,
        //    否则 packetFlow 不会真正建立、拿不到有效 fd。
        //    真实的隧道地址/DNS 要等 AnyConnect 握手结果(X-CSTP-Address / X-CSTP-DNS),
        //    当前 Libbox.Start 尚未把握手结果回吐给 Swift,这里先用与 core/config
        //    buildTUNInbound 一致的占位网段(198.18.0.1/15),DNS 用公共兜底。
        //    TODO(真机联调):从 AnyConnect 握手结果动态填真实地址/DNS/路由。
        let settings = buildNetworkSettings()
        setTunnelNetworkSettings(settings) { [weak self] settingsError in
            guard let self else {
                completionHandler(providerErrorStatic(4, "provider deallocated"))
                return
            }
            if let settingsError {
                os_log("startTunnel: setTunnelNetworkSettings failed: %{public}@",
                       log: self.log, type: .error, settingsError.localizedDescription)
                self.libbox = nil
                completionHandler(settingsError)
                return
            }

            // 4) 把 packetFlow 对应的 tun fd 交给引擎(见下方 tunFileDescriptor 说明)。
            if let fd = self.tunFileDescriptor(), fd > 0 {
                lb.setTunFD(fd)
                os_log("startTunnel: tun fd set = %d", log: self.log, type: .info, fd)
            } else {
                // 拿不到 fd:不硬塞一个非法值(会让 Go 侧 dup 失败或行为错误)。
                // 若配置里含 tun inbound,Start 会在 OpenInterface 阶段返回明确错误;
                // 这里如实记录,交由 Start 的错误路径处理,而不是假装成功。
                os_log("startTunnel: WARNING tun fd unavailable — packetFlow fd not obtained",
                       log: self.log, type: .error)
            }

            // 5) 拨号 + 启动 sing-box。Start 是阻塞调用(内含 AnyConnect 握手),放后台线程。
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try lb.start(bundle.server, username: bundle.username,
                                 password: bundle.password, configJSON: bundle.configJSON)
                    os_log("startTunnel: engine started", log: self.log, type: .info)
                    completionHandler(nil)
                } catch {
                    os_log("startTunnel: engine start failed: %{public}@",
                           log: self.log, type: .error, error.localizedDescription)
                    self.libbox = nil
                    completionHandler(error)
                }
            }
        }
    }

    // MARK: - stopTunnel

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("stopTunnel: reason=%d", log: log, type: .info, reason.rawValue)
        // Stop 也可能阻塞(关闭 sing-box + 断开 AnyConnect),放后台线程。
        let lb = self.libbox
        self.libbox = nil
        DispatchQueue.global(qos: .userInitiated).async {
            if let lb {
                try? lb.stop()
            }
            os_log("stopTunnel: done", log: self.log, type: .info)
            completionHandler()
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

        guard let obj = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
              let cmd = obj["cmd"] as? String else {
            completionHandler(encodeResponse(ok: false, message: "无法解析请求(缺少 cmd)"))
            return
        }
        os_log("handleAppMessage: cmd=%{public}@", log: log, type: .info, cmd)

        switch cmd {
        case "status":
            completionHandler(handleStatus())

        case "start":
            // 扩展的真实启动由 NETunnelProviderManager.startVPNTunnel(options:) 触发
            // (走 startTunnel 而非本消息)。这里保留一条幂等语义的应答:若引擎已在跑
            // 回 ok,便于 App 在既有隧道上做「确认」。真正的拨号不在此路径完成。
            let running = libbox?.isRunning() ?? false
            completionHandler(encodeResponse(ok: true,
                message: running ? nil : "隧道由系统 VPN 配置启动(startVPNTunnel),非此消息路径",
                dataString: statusJSONString()))

        case "stop":
            // 与 start 对称:真正停止隧道应调 NETunnelProviderManager.stopVPNTunnel()。
            // 这里做一次尽力而为的引擎停止,并回 ok。
            let lb = libbox
            libbox = nil
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                if let lb { try? lb.stop() }
                completionHandler(self?.encodeResponse(ok: true, dataString: "{\"status\":\"disconnected\"}"))
            }

        case "parse-sub":
            // 订阅解析目前没有进程内实现(macOS 版在 helper daemon 里做)。
            // 如实回一个"未实现"的失败响应,而不是假装成功——上层 sendSubRequest
            // 会把它当解析失败处理并给用户明确提示。
            // TODO:接入进程内订阅解析(复用 core 的订阅解析逻辑并经 Libbox 导出)。
            completionHandler(encodeResponse(ok: false, message: "扩展暂不支持订阅解析(parse-sub 未实现)"))

        default:
            completionHandler(encodeResponse(ok: false, message: "未知命令: \(cmd)"))
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
        if let lastError, !lastError.isEmpty {
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

    /// 组合 options 与 App Group 两个来源,得到启动所需的完整参数。
    /// 任一必填项缺失则返回 nil。
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
        return StartBundle(server: server, username: username, password: password, configJSON: configJSON)
    }

    // MARK: - NE 网络设置

    /// 构造 NEPacketTunnelNetworkSettings。
    /// 隧道 IPv4 地址与 core/config buildTUNInbound 的 tun address(198.18.0.1/15)对齐;
    /// DNS 先用公共兜底。真实值待 AnyConnect 握手结果(见 startTunnel 里的 TODO)。
    private func buildNetworkSettings() -> NEPacketTunnelNetworkSettings {
        // remoteAddress 仅作展示用途,给一个占位。
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.254.0.0"]) // /15
        // 默认路由:全部流量进隧道,由 sing-box 的 route 规则再做分流。
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        let dns = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        settings.dnsSettings = dns

        settings.mtu = 9000 // 与 buildTUNInbound 的 mtu 对齐

        return settings
    }

    // MARK: - tun fd 获取(已知风险点)

    /// 取 NE packetFlow 对应的文件描述符。
    ///
    /// NEPacketTunnelFlow 不公开暴露底层 fd。业界(WireGuard/sing-box 官方 NE 实现)
    /// 的通行做法是 KVC 反射:provider 自身有个私有属性链
    /// `packetFlow` → 内部 socket 对象 → `fileDescriptor`。
    /// 这里尝试两条常见的 keyPath;取不到就返回 nil(由调用方按缺 fd 处理,不硬造)。
    ///
    /// ⚠️ 已知风险:这是私有 API / KVC 反射,依赖 NE 内部实现,可能随系统版本失效,
    /// 且未经真机验证。tvOS 上是否可用需真机联调确认。若失效,备选方案是走
    /// packetFlow.readPackets/writePackets 的公开读写循环把包搬进/搬出 gVisor 栈
    /// (不需要 fd,但要 Libbox 侧提供 read/write 数据面 API,当前绑定尚未提供)。
    private func tunFileDescriptor() -> Int? {
        // 路径一:self.packetFlow.value(forKeyPath: "socket.fileDescriptor")
        // 路径二:self.value(forKeyPath: "packetFlow.socket.fileDescriptor")
        let candidates = [
            (packetFlow as AnyObject, "socket.fileDescriptor"),
            (self as AnyObject, "packetFlow.socket.fileDescriptor"),
        ]
        for (obj, keyPath) in candidates {
            if let num = (obj.value(forKeyPath: keyPath) as? NSNumber) {
                let fd = num.intValue
                if fd > 0 { return fd }
            }
        }
        return nil
    }

    // MARK: - 错误构造

    private func providerError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "com.kafeifei.xdialtv.tunnel", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// 静态版错误构造:供 startTunnel 内 `[weak self]` 闭包在 self 已释放时使用。
private func providerErrorStatic(_ code: Int, _ message: String) -> NSError {
    NSError(domain: "com.kafeifei.xdialtv.tunnel", code: code,
            userInfo: [NSLocalizedDescriptionKey: message])
}
