import Combine
import Foundation
import Libbox
// NetworkExtension 的类型(NETunnelProviderManager 等)还没有做 Sendable 审计,
// 完成 handler 里从系统线程切回 @MainActor 时 Swift 6 严格并发检查会报「sending
// 风险」。@preconcurrency 是 Apple 系统框架里这类未审计类型的标准处理方式。
@preconcurrency import NetworkExtension

// MARK: - TunnelManager (iOS / tvOS)
//
// macOS 版靠 PrivilegeManager 安装 LaunchDaemon + helper,再用 AF_UNIX socket 拨号。
// iOS / tvOS 上没有特权进程:VPN 逻辑跑在 NEPacketTunnelProvider 扩展进程里,由系统托管。
// App 侧只做两件事:
//   1. 通过 NETunnelProviderManager 把一份 VPN 配置写进系统偏好(saveToPreferences),
//      让系统「知道有这么一个隧道可以拨」——这一步会触发用户授权弹窗。
//   2. 通过一次性 start options 交付启动配置，再用 manager.connection
//      (即 NETunnelProviderSession)与扩展进程收发状态/控制消息。
//
// 本文件是「薄骨架」:核心运行时行为(授权弹窗 / on-demand 状态机 / 真实拨号)
// 在没有 NetworkExtension entitlement 和真机之前完全无法离线验证,凡是受签名/
// entitlement 影响的地方都标了 TODO,真机联调时按标记逐一核对。
//
// 依赖对接:
//   - conform `TunnelManaging`(AppState.swift):暴露并刷新 isProfileInstalled。
//   - 持有一个 `TunnelProviderSession`(conform GoEngine.swift 的 `TunnelSession`),
//     注入给 GoEngine.session,让 GoEngine 的 sendProviderMessage 落到真实扩展会话上。

/// bundle id 与 App Group 必须和各平台 target 的 entitlement 一致。
#if os(iOS)
private let kTunnelBundleIdentifier = "com.kafeifei.xdial.ios.tunnel"
private let kAppGroupIdentifier = "group.com.kafeifei.xdial.ios"
#else
private let kTunnelBundleIdentifier = "com.kafeifei.xdialtv.tunnel"
private let kAppGroupIdentifier = "group.com.kafeifei.xdialtv"
#endif

/// providerConfiguration 里携带的隧道自身描述名。
private let kTunnelLocalizedDescription = "XDial"
private let kTunnelDiagnosticKey = "xdial.tunnel.diagnostic"

/// NetworkExtension 的类型(NETunnelProviderManager 等)没有 Sendable 审计。这里的用法
/// 是"系统完成回调只调一次、拿到就立刻在同一步用掉",不存在真实并发访问——
/// 用这个 box 显式告诉 Swift 6 的 sending 检查器信任这一点,而不是引入 Task 或改变
/// 回调时序。仅用于跨越 assumeIsolated 边界搬运这几个已知安全的值。
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
}

/// 从主 App 发起探测，流量会像 Safari/其他 App 一样完整经过系统路由 → packetFlow →
/// sing-box → 实际出口。扩展进程内部自拨成功不能替代这条端到端断言。
private enum DataPathProbe {
    private static let rawIPURLs = [
        URL(string: "https://1.1.1.1/cdn-cgi/trace")!,
    ]
    private static let hostnameURLs = [
        URL(string: "https://www.apple.com/library/test/success.html")!,
        URL(string: "https://cloudflare.com/cdn-cgi/trace")!,
    ]

    struct Result: Sendable {
        let rawIPOK: Bool
        let hostnameOK: Bool

        var isUsable: Bool { hostnameOK }

        var failureMessage: String {
            if rawIPOK && !hostnameOK {
                return "系统隧道已启动，但域名解析不通，已自动断开"
            }
            return "系统隧道已启动，但出口流量不通，已自动断开"
        }
    }

    static func run() async -> Result {
        async let rawIPOK = firstReachable(rawIPURLs)
        async let hostnameOK = firstReachable(hostnameURLs)
        return await Result(rawIPOK: rawIPOK, hostnameOK: hostnameOK)
    }

    private static func firstReachable(_ urls: [URL]) async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        for url in urls {
            if Task.isCancelled { return false }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 6
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, (200..<500).contains(http.statusCode) {
                    return true
                }
            } catch {
                continue
            }
        }
        return false
    }
}

enum TunnelDiagnosticFormatter {
    static func recordLaunchRequested(attemptID: String) {
        let snapshot: [String: Any] = [
            "stage": "launch_requested",
            "attempt_id": attemptID,
            "timestamp": Date().timeIntervalSince1970,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot),
              let text = String(data: data, encoding: .utf8),
              let defaults = UserDefaults(suiteName: kAppGroupIdentifier) else { return }
        defaults.set(text, forKey: kTunnelDiagnosticKey)
        defaults.synchronize()
    }

    static func persistedSummary(matchingAttemptID expectedAttemptID: String? = nil) -> String? {
        guard let text = UserDefaults(suiteName: kAppGroupIdentifier)?
            .string(forKey: kTunnelDiagnosticKey),
              let data = text.data(using: .utf8),
              let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return summary(snapshot, matchingAttemptID: expectedAttemptID)
    }

    static func providerSummary(
        from responseData: Data?,
        matchingAttemptID expectedAttemptID: String? = nil
    ) -> String? {
        guard let responseData,
              let outer = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let dataString = outer["data"] as? String,
              let data = dataString.data(using: .utf8),
              let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let diagnostics = status["diagnostics"] as? [String: Any] else {
            return nil
        }
        return summary(diagnostics, matchingAttemptID: expectedAttemptID)
    }

    static func summary(
        _ snapshot: [String: Any],
        matchingAttemptID expectedAttemptID: String? = nil
    ) -> String? {
        if let expectedAttemptID,
           snapshot["attempt_id"] as? String != expectedAttemptID {
            return nil
        }
        var parts: [String] = []
        let topLevelError = nonEmptyString(snapshot["last_error"])
        if let topLevelError {
            parts.append("error=\(topLevelError)")
        }
        if let stage = snapshot["stage"] as? String, !stage.isEmpty {
            parts.append("stage=\(stage)")
        }
        if let name = snapshot["physical_interface_name"] as? String, !name.isEmpty {
            parts.append("if=\(name)")
        }
        if let engine = snapshot["engine"] as? [String: Any] {
            if let engineError = nonEmptyString(engine["last_error"]),
               engineError != topLevelError {
                parts.append("engine_error=\(engineError)")
            }
            if engine["gvisor_compiled"] as? Bool == false {
                parts.append("gvisor=missing")
            } else if let stack = engine["selected_stack"] as? String {
                parts.append("stack=\(stack)")
            }
            if let tunName = engine["tun_name"] as? String, !tunName.isEmpty {
                parts.append("tun=\(tunName)")
            } else if engine["tun_fd_ready"] as? Bool == true {
                parts.append("tun=fd-ready")
            }
            let tunIn = number(engine["tun_in_packets"])
            let tunOut = number(engine["tun_out_packets"])
            parts.append("flow=in\(tunIn)/out\(tunOut)")
            if let bridge = engine["bridge"] as? [String: Any] {
                let up = number(bridge["up_packets"])
                let down = number(bridge["down_packets"])
                parts.append("bridge=↑\(up)/↓\(down)")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func number(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - TunnelProviderSession
//
// GoEngine 的 `session` 是 `weak var session: TunnelSession?`,它只认识
// `sendProviderMessage(_:responseHandler:)` 这一个方法。这里用一个独立的小类包住
// 真实的 `NETunnelProviderSession`,而不是让 TunnelManager 直接 conform ——
// 好处是 GoEngine 弱引用的目标(session)与 AppState 弱引用的目标(tunnelManager)
// 是两个不同对象,由 TunnelManager 分别强持有,生命周期清晰、互不牵连。

/// 把 GoEngine 需要的 `TunnelSession` 转调到真实的 `NETunnelProviderSession`。
@MainActor
final class TunnelProviderSession: TunnelSession {
    /// 真实会话。来自 `NETunnelProviderManager.connection as? NETunnelProviderSession`。
    /// 隧道尚未 save / 未拨起时可能为 nil,此时发送直接抛错(语义等价 macOS 版 socket 不可用)。
    fileprivate weak var session: NETunnelProviderSession?

    init(session: NETunnelProviderSession?) {
        self.session = session
    }

    // TODO: 无法离线验证,真机联调时需要重点检查这里的实际行为。
    // sendProviderMessage 只有在扩展进程真正在运行(connection 状态 connecting/connected)
    // 时才会把消息投递到 handleAppMessage;若隧道未拨起,系统可能直接抛错或静默丢弃。
    // GoEngine 里 start/stop/status 全靠这条通道,真机上要确认:未连接时能不能发 status、
    // 发送时机与 connection.status 的关系、responseHandler 回调所在线程。
    func sendProviderMessage(_ messageData: Data, responseHandler: ((Data?) -> Void)?) throws {
        guard let session else {
            throw NSError(domain: "XDial", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "系统隧道会话不可用(未加载/未拨起)"])
        }
        try session.sendProviderMessage(messageData, responseHandler: responseHandler)
    }
}

// MARK: - TunnelManager

/// NETunnelProviderManager 管理层。负责:加载已有配置、组装 & 保存新配置、把真实
/// 扩展会话喂给 GoEngine。conform `TunnelManaging` 供 AppState 查询「是否已安装」。
@MainActor
final class TunnelManager: ObservableObject, TunnelManaging {

    /// 当前持有的 manager。loadAllFromPreferences 拿到已有的,或 ensure 时新建。
    @Published private(set) var manager: NETunnelProviderManager?

    /// 已保存并可用的隧道配置是否存在。AppState 用它更新 helperInstalled。
    @Published private(set) var isProfileInstalled: Bool = false

    /// 包给 GoEngine 用的会话封装。每次 manager/connection 变化时重建并重新注入。
    private(set) var providerSession: TunnelProviderSession?

    /// GoEngine 引用,用于注入 session。弱引用避免环(GoEngine 也不强持有本类)。
    private weak var engine: GoEngine?
    private var statusSubscription: AnyCancellable?
    private var observedSystemStatus: NEVPNStatus = .invalid
    private var dataPathProbeTask: Task<Void, Never>?
    private var dataPathProbeID: UUID?
    private var dataPathVerified = false
    private var activeStartAttemptID: String?
    private var startWatchdogTask: Task<Void, Never>?

    init(engine: GoEngine? = nil) {
        self.engine = engine
        statusSubscription = NotificationCenter.default
            .publisher(for: .NEVPNStatusDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self,
                      let connection = notification.object as? NEVPNConnection,
                      connection === self.manager?.connection else { return }
                self.applyConnectionStatus()
            }
    }

    /// 绑定引擎(若 init 时未传)。绑定后立即把当前 session 注入。
    func bind(engine: GoEngine) {
        self.engine = engine
        injectSession()
    }

    // MARK: - Load

    /// 加载系统里已存在的 XDial 隧道配置。
    /// - 找到匹配的(providerBundleIdentifier == kTunnelBundleIdentifier)就采用第一个;
    /// - 找不到则 manager 置 nil,isProfileInstalled = false(等 ensureConfigured 再建)。
    ///
    // TODO: 无法离线验证,真机联调时需要重点检查这里的实际行为。
    // loadAllFromPreferences 需要 NetworkExtension entitlement(Personal VPN / Packet Tunnel)。
    // 没有正确签名/描述文件时会直接回错误。真机要确认:首次(无配置)返回空数组而非报错、
    // 多个配置时的取舍、以及回调线程(这里统一切回 MainActor)。
    func loadFromPreferences(completion: (@Sendable (Result<Void, Error>) -> Void)? = nil) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            // loadAllFromPreferences 的完成回调历史上一直在主线程投递(它是给 UI 层用的
            // 偏好读取 API);用 assumeIsolated 同步断言回到 MainActor,而不是开一个新
            // Task。managers/error 经 UncheckedBox 搬运——这里只用一次、不并发访问。
            let box = UncheckedBox(value: (managers, error))
            MainActor.assumeIsolated {
                guard let self else { return }
                let (managers, error) = box.value
                if let error {
                    appLog("TunnelManager.load: error \(error.localizedDescription)")
                    self.isProfileInstalled = false
                    completion?(.failure(error))
                    return
                }
                let mine = (managers ?? []).first { mgr in
                    (mgr.protocolConfiguration as? NETunnelProviderProtocol)?
                        .providerBundleIdentifier == kTunnelBundleIdentifier
                }
                self.manager = mine
                self.isProfileInstalled = (mine != nil)
                appLog("TunnelManager.load: found \((managers ?? []).count) managers, mine=\(mine != nil)")
                self.injectSession()
                completion?(.success(()))
            }
        }
    }

    func refreshProfileStatus(completion: @escaping @Sendable (Bool) -> Void) {
        loadFromPreferences { [weak self] _ in
            Task { @MainActor in
                completion(self?.isProfileInstalled ?? false)
            }
        }
    }

    // MARK: - Configure & Save

    /// 确保系统里有一份「与 profile 对应」的隧道配置:
    /// 已有则更新其 protocolConfiguration,没有则新建一个 manager,然后 saveToPreferences。
    /// serverAddress 从 profile 的活动线路默认出口推导(仅用于系统 UI 展示,真实拨号参数
    /// 由 startTunnel(options:) 一次性交给扩展)。
    ///
    // TODO: 无法离线验证,真机联调时需要重点检查这里的实际行为。
    // saveToPreferences 是触发用户授权弹窗的地方(首次会弹「XDial 想要添加 VPN 配置」)。
    // 授权被拒 / 描述文件缺 NetworkExtension 能力 / bundle id 不匹配都会在这里失败。
    // 真机要确认:弹窗时机、拒绝后的 error code、重复 save 是否幂等、save 后 connection 是否可用。
    func ensureConfigured(serverAddress: String,
                          completion: (@Sendable (Result<Void, Error>) -> Void)? = nil) {
        let mgr = manager ?? NETunnelProviderManager()

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = kTunnelBundleIdentifier
        // serverAddress 不能为空,否则系统会拒绝保存;空则用占位。
        proto.serverAddress = serverAddress.isEmpty ? "XDial" : serverAddress
        // providerConfiguration 只放最基本的 key。完整配置不塞这里，
        // 运行时通过一次性 start options 下发；这里只放扩展身份所需的最小元信息。
        // TODO: 无法离线验证,真机联调时需要重点检查这里的实际行为。
        // providerConfiguration 有大小与类型限制(只接受 plist 可序列化类型),
        // 且系统对其可见，不应放密码等敏感数据（敏感启动参数只走 start options）。
        proto.providerConfiguration = [
            "appGroup": kAppGroupIdentifier,
            "schemaVersion": 1,
        ]

        mgr.protocolConfiguration = proto
        mgr.localizedDescription = kTunnelLocalizedDescription
        mgr.isEnabled = true
        // on-demand 规则:骨架阶段不配置(保持 nil / 关闭),避免引入难以离线验证的状态机。
        // TODO: 无法离线验证,真机联调时需要重点检查这里的实际行为。
        // 若以后要「按需自动拨号」,在此设置 onDemandRules + isOnDemandEnabled;
        // on-demand 会让系统在满足规则时自动拉起扩展,与手动 start/stop 的交互需真机验证。
        mgr.isOnDemandEnabled = false

        let mgrBox = UncheckedBox(value: mgr)
        mgr.saveToPreferences { [weak self] error in
            // 同上:同步 assumeIsolated,不开新 Task,避免 "sending" 检查。
            let box = UncheckedBox(value: error)
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error = box.value {
                    appLog("TunnelManager.save: error \(error.localizedDescription)")
                    completion?(.failure(error))
                    return
                }
                // saveToPreferences 后,系统给回的对象可能需要重新 load 一次才「完整」
                // (Apple 文档惯例:save 后紧接 load 以拿到系统规范化后的配置)。
                // TODO: 无法离线验证,真机联调时需要重点检查这里的实际行为。
                self.manager = mgrBox.value
                self.isProfileInstalled = true
                appLog("TunnelManager.save: ok")
                self.loadFromPreferences { _ in
                    completion?(.success(()))
                }
            }
        }
    }

    // MARK: - Session injection

    /// 从当前 manager 取真实会话,重建 TunnelProviderSession 并注入 GoEngine.session。
    /// manager 为 nil 或 connection 不是 NETunnelProviderSession 时,注入一个空会话
    /// (sendProviderMessage 会抛错),语义等价「隧道不可用」。
    private func injectSession() {
        let real = manager?.connection as? NETunnelProviderSession
        let wrapped = TunnelProviderSession(session: real)
        self.providerSession = wrapped
        engine?.session = wrapped
        appLog("TunnelManager.injectSession: real=\(real != nil), engineBound=\(engine != nil)")
        applyConnectionStatus()
    }

    private func applyConnectionStatus() {
        guard let connection = manager?.connection else {
            dataPathProbeTask?.cancel()
            dataPathProbeTask = nil
            dataPathProbeID = nil
            dataPathVerified = false
            observedSystemStatus = .invalid
            reportEarlyStartFailureIfNeeded()
            engine?.applySystemStatus("disconnected")
            return
        }
        let previousStatus = observedSystemStatus
        observedSystemStatus = connection.status
        switch connection.status {
        case .connected:
            if dataPathVerified {
                engine?.applySystemStatus("connected", connectedAt: connection.connectedDate)
            } else if previousStatus != .connected || dataPathProbeTask == nil {
                verifyDataPath(for: connection)
            }
        case .connecting:
            dataPathVerified = false
            engine?.applySystemStatus("connecting")
        case .disconnecting:
            dataPathProbeTask?.cancel()
            dataPathProbeTask = nil
            dataPathProbeID = nil
            dataPathVerified = false
            engine?.applySystemStatus("disconnecting")
        case .reasserting:
            dataPathProbeTask?.cancel()
            dataPathProbeTask = nil
            dataPathProbeID = nil
            dataPathVerified = false
            engine?.applySystemStatus("reconnecting", connectedAt: connection.connectedDate)
        case .disconnected, .invalid:
            dataPathProbeTask?.cancel()
            dataPathProbeTask = nil
            dataPathProbeID = nil
            dataPathVerified = false
            reportEarlyStartFailureIfNeeded()
            engine?.applySystemStatus("disconnected")
        @unknown default:
            dataPathProbeTask?.cancel()
            dataPathProbeTask = nil
            dataPathProbeID = nil
            dataPathVerified = false
            reportEarlyStartFailureIfNeeded()
            engine?.applySystemStatus("disconnected")
        }
    }

    /// 系统状态 connected 只是控制面信号。只有主 App 的真实 HTTPS 请求通过后，
    /// 才允许引擎/UI 进入 connected；失败会保留具体层级错误并立即断开，避免手机
    /// 留在“图标已连但无法上网”的坏状态。
    private func verifyDataPath(for connection: NEVPNConnection) {
        dataPathProbeTask?.cancel()
        let probeID = UUID()
        dataPathProbeID = probeID
        let attemptID = activeStartAttemptID
        dataPathVerified = false
        engine?.applySystemStatus("checking", connectedAt: connection.connectedDate)
        appLog("DataPathProbe: begin")

        dataPathProbeTask = Task { [weak self, weak connection] in
            let result = await DataPathProbe.run()
            guard !Task.isCancelled, let self, let connection,
                  self.dataPathProbeID == probeID,
                  connection === self.manager?.connection,
                  connection.status == .connected else { return }

            self.dataPathProbeTask = nil
            if result.isUsable {
                self.dataPathProbeID = nil
                self.dataPathVerified = true
                self.activeStartAttemptID = nil
                self.startWatchdogTask?.cancel()
                self.startWatchdogTask = nil
                self.engine?.applySystemStatus("connected", connectedAt: connection.connectedDate)
                appLog("DataPathProbe: passed rawIP=\(result.rawIPOK) hostname=\(result.hostnameOK)")
            } else {
                self.dataPathVerified = false
                appLog("DataPathProbe: failed rawIP=\(result.rawIPOK) hostname=\(result.hostnameOK)")
                let baseMessage = result.failureMessage
                self.applyProbeFailure(
                    baseMessage: baseMessage,
                    diagnostics: TunnelDiagnosticFormatter.persistedSummary(
                        matchingAttemptID: attemptID
                    ),
                    connection: connection,
                    shouldStop: false
                )

                let fallbackStop = Task { @MainActor [weak self, weak connection] in
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard !Task.isCancelled, let self, let connection,
                          self.dataPathProbeID == probeID else { return }
                    self.applyProbeFailure(
                        baseMessage: baseMessage,
                        diagnostics: TunnelDiagnosticFormatter.persistedSummary(
                            matchingAttemptID: attemptID
                        ),
                        connection: connection,
                        shouldStop: true
                    )
                }
                self.requestProviderDiagnostics(
                    matchingAttemptID: attemptID
                ) { [weak self, weak connection] diagnostics in
                    fallbackStop.cancel()
                    guard let self, let connection,
                          self.dataPathProbeID == probeID else { return }
                    self.applyProbeFailure(
                        baseMessage: baseMessage,
                        diagnostics: diagnostics ?? TunnelDiagnosticFormatter.persistedSummary(
                            matchingAttemptID: attemptID
                        ),
                        connection: connection,
                        shouldStop: true
                    )
                }
            }
        }
    }

    private func requestProviderDiagnostics(
        matchingAttemptID expectedAttemptID: String?,
        completion: @escaping @MainActor (String?) -> Void
    ) {
        guard let session = providerSession else {
            completion(nil)
            return
        }
        let request = Data("{\"cmd\":\"status\"}".utf8)
        let completionBox = UncheckedBox(value: completion)
        do {
            try session.sendProviderMessage(request) { responseData in
                let responseBox = UncheckedBox(value: responseData)
                Task { @MainActor in
                    completionBox.value(TunnelDiagnosticFormatter.providerSummary(
                        from: responseBox.value,
                        matchingAttemptID: expectedAttemptID
                    ))
                }
            }
        } catch {
            completion(nil)
        }
    }

    private func applyProbeFailure(
        baseMessage: String,
        diagnostics: String?,
        connection: NEVPNConnection,
        shouldStop: Bool
    ) {
        activeStartAttemptID = nil
        startWatchdogTask?.cancel()
        startWatchdogTask = nil
        engine?.lastError = diagnostics.map { "\(baseMessage)\n诊断：\($0)" } ?? baseMessage
        guard shouldStop else { return }
        dataPathProbeID = nil
        if connection.status == .connected || connection.status == .reasserting {
            connection.stopVPNTunnel()
            engine?.applySystemStatus("disconnecting")
        }
    }

    private func reportEarlyStartFailureIfNeeded() {
        guard let attemptID = activeStartAttemptID else { return }
        activeStartAttemptID = nil
        startWatchdogTask?.cancel()
        startWatchdogTask = nil
        let diagnostics = TunnelDiagnosticFormatter.persistedSummary(matchingAttemptID: attemptID)
        let message = "连接启动失败"
        engine?.lastError = diagnostics.map { "\(message)\n诊断：\($0)" } ?? message
        appLog("TunnelManager.start: asynchronous failure diagnostics=\(diagnostics ?? "unavailable")")
    }

    // MARK: - Start / Stop (TunnelManaging)
    //
    // 旧版本曾把启动参数放进 App Group。新版本全部走一次性 start options，
    // 这里只保留同名 key 做迁移清理，避免设备升级后残留敏感配置。
    private enum LegacyAppGroupKey {
        static let config = "xdial.tunnel.config"
        static let server = "xdial.tunnel.server"
        static let username = "xdial.tunnel.username"
        static let password = "xdial.tunnel.password"
    }

    /// 把 profile 转成 NE 模式 sing-box 配置，确保系统隧道配置已保存，
    /// 再通过一次性 start options 把凭据和完整配置交给扩展，不落进 App Group。
    ///
    // TODO: 无法离线验证,真机联调时需要重点检查这里的实际行为。
    // startVPNTunnel() 需要 saveToPreferences 已成功且 NE entitlement 就绪,
    // 否则会抛 NEVPNError;这里只做结构正确性保证,运行时行为等真机验证。
    func startTunnel(profile: Profile, server: String, username: String, password: String,
                      completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        guard let groupDefaults = UserDefaults(suiteName: kAppGroupIdentifier) else {
            completion(.failure(NSError(domain: "XDial", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "App Group UserDefaults 不可用(\(kAppGroupIdentifier))"])))
            return
        }
        let basePath = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: kAppGroupIdentifier)?.path ?? ""

        let profileJSON: String
        do {
            let data = try JSONEncoder().encode(profile)
            guard let json = String(data: data, encoding: .utf8) else {
                throw NSError(domain: "XDial", code: -3, userInfo: [NSLocalizedDescriptionKey: "profile JSON 编码失败(非 UTF8)"])
            }
            profileJSON = json
        } catch {
            completion(.failure(error))
            return
        }

        // LibboxGenerateNEConfig 是 gomobile 生成的自由函数(非某个类的方法),不走
        // Swift 的 ObjC 方法错误桥接(那只对方法生效,比如 lb.start(...) 能 try 是因为
        // 它是 LibboxLibbox 这个类的方法);这里要手动传 NSErrorPointer。
        var genError: NSError?
        let configJSON = LibboxGenerateNEConfig(profileJSON, server, basePath, &genError)
        if let genError {
            completion(.failure(genError))
            return
        }

        for key in [LegacyAppGroupKey.server, LegacyAppGroupKey.username,
                    LegacyAppGroupKey.password, LegacyAppGroupKey.config] {
            groupDefaults.removeObject(forKey: key)
        }

        ensureConfigured(serverAddress: server) { [weak self] result in
            // ensureConfigured 的 completion 类型是 @Sendable,闭包字面量默认不再
            // 继承外层 TunnelManager(@MainActor)的隔离——显式 Task { @MainActor in }
            // 重新进入主 actor 才能碰 self.manager(MainActor 隔离属性)。
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success:
                    do {
                        guard let session = self.manager?.connection as? NETunnelProviderSession else {
                            throw NSError(domain: "XDial", code: -4,
                                userInfo: [NSLocalizedDescriptionKey: "系统隧道会话未加载"])
                        }
                        let options: [String: NSObject] = [
                            "server": server as NSString,
                            "username": username as NSString,
                            "password": password as NSString,
                            "configJSON": configJSON as NSString,
                        ]
                        let attemptID = UUID().uuidString
                        self.dataPathProbeTask?.cancel()
                        self.dataPathProbeTask = nil
                        self.dataPathProbeID = nil
                        self.startWatchdogTask?.cancel()
                        self.activeStartAttemptID = attemptID
                        TunnelDiagnosticFormatter.recordLaunchRequested(attemptID: attemptID)
                        var startOptions = options
                        startOptions["attemptID"] = attemptID as NSString
                        self.engine?.lastError = nil
                        self.engine?.applySystemStatus("connecting")
                        self.startWatchdogTask = Task { @MainActor [weak self, weak session] in
                            try? await Task.sleep(nanoseconds: 45_000_000_000)
                            guard !Task.isCancelled, let self,
                                  self.activeStartAttemptID == attemptID else { return }
                            self.activeStartAttemptID = nil
                            self.dataPathProbeTask?.cancel()
                            self.dataPathProbeTask = nil
                            self.dataPathProbeID = nil
                            let diagnostics = TunnelDiagnosticFormatter.persistedSummary(
                                matchingAttemptID: attemptID
                            )
                            let message = "连接启动超时"
                            self.engine?.lastError = diagnostics.map {
                                "\(message)\n诊断：\($0)"
                            } ?? message
                            session?.stopVPNTunnel()
                            self.engine?.applySystemStatus("disconnected")
                            self.startWatchdogTask = nil
                        }
                        try session.startTunnel(options: startOptions)
                        completion(.success(()))
                    } catch {
                        self.activeStartAttemptID = nil
                        self.startWatchdogTask?.cancel()
                        self.startWatchdogTask = nil
                        self.engine?.applySystemStatus("disconnected")
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    /// 停止系统级隧道。manager/connection 不可用时静默返回(语义等价「本来就没在跑」)。
    func stopTunnel() {
        activeStartAttemptID = nil
        startWatchdogTask?.cancel()
        startWatchdogTask = nil
        dataPathProbeTask?.cancel()
        dataPathProbeTask = nil
        dataPathProbeID = nil
        engine?.applySystemStatus("disconnecting")
        manager?.connection.stopVPNTunnel()
    }

    // MARK: - Convenience

    /// 从活动线路的默认出口 Line 推导一个展示用 serverAddress(纯 UI 用途)。
    /// 找不到就返回空串,由 ensureConfigured 兜底成占位。
    static func serverAddress(for profile: Profile) -> String {
        guard let mode = profile.modes.first(where: { $0.id == profile.activeModeID }),
              let line = profile.lines.first(where: { $0.id == mode.defaultLineID }) else {
            return ""
        }
        switch line.type {
        case "vpn": return line.vpnServer
        case "trojan": return line.trojanServer
        case "shadowsocks", "ss": return line.ssServer
        case "vmess": return line.vmessServer
        default: return ""  // direct 等无远端地址
        }
    }
}
