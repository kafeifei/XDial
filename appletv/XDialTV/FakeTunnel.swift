#if targetEnvironment(simulator)
import Combine
import Foundation

// MARK: - Fake Tunnel (Simulator 演示层)
//
// 这是**只在 iOS / tvOS Simulator 里编译**的演示隧道层（整个文件被
// `#if targetEnvironment(simulator)` 包裹，真机 / Release 构建不包含）。
//
// 目的：让 app 在没有 NetworkExtension entitlement、没有真机的情况下，也能在
// Simulator 里完整走通 UI 交互——连接 / 断开 / 状态转换 / 场景切换——而不真正拨号。
//
// 它替换的两个真实实现：
//   - GoEngine（走 NEVPNConnection.sendProviderMessage，Simulator 没有隧道会话）
//     → FakeTunnelEngine：纯定时器驱动的状态机。
//   - TunnelManager（NETunnelProviderManager.saveToPreferences/startVPNTunnel，
//     需要 entitlement + 用户授权弹窗）→ FakeTunnelManager：isProfileInstalled 恒 true，
//     startTunnel 直接回调成功并驱动引擎进入 connecting→connected。
//
// 互联关系（在 RootView 的 Simulator 分支里建立）：
//   FakeTunnelManager 持有 FakeTunnelEngine 的引用，startTunnel/stopTunnel 时驱动引擎
//   走状态机。这与 AppState.connect()/disconnect() 的既有语义一致——真实路径里也是
//   TunnelManager 负责拉起隧道、GoEngine 负责状态，这里只是把两者都换成假的。

/// Simulator 演示引擎：conform TunnelEngine，用定时器模拟状态转换。
///
/// 时序：
///   - start / simulateConnect → "connecting"，1.5s 后 → "connected"
///   - stop  / simulateDisconnect → "disconnecting"，0.8s 后 → "disconnected"
/// 状态用 @Published 存储，赋值自动触发 objectWillChange（AppState 订阅它感知变化）。
@MainActor
final class FakeTunnelEngine: TunnelEngine, ObservableObject {
    @Published private(set) var status: String = "disconnected"
    @Published var lastError: String?
    @Published var dataPathSummary: String?
    @Published private(set) var connectedAt: Date?
    var statusPublisher: AnyPublisher<String, Never> { $status.eraseToAnyPublisher() }

    var isConnected: Bool { status == "connected" }
    var isBusy: Bool {
        status == "connecting" || status == "disconnecting" || status == "reconnecting"
    }

    /// 用一个自增的 epoch 让「过期的」延迟回调失效：每次发起一次新的 connect/disconnect
    /// 都 +1，延迟闭包只有在 epoch 未变时才落地状态。避免「连了又立刻断」时旧定时器
    /// 把状态错误地拨回 connected。
    private var epoch: Int = 0

    /// 强持有对应的 FakeTunnelManager，让它在 AppState（只 weak 持有 tunnelManager）
    /// 之外有一个存活锚点。引用链：AppState → engine（strong）→ manager（strong），
    /// manager → engine 是 weak，不构成环。RootView 构造后调用 retain(manager:) 建立。
    private var retainedManager: FakeTunnelManager?

    func retain(manager: FakeTunnelManager) {
        retainedManager = manager
    }

    // MARK: TunnelEngine

    /// 真实引擎里 start 走 sendProviderMessage；这里退化为驱动模拟状态机。
    /// AppState.connect() 走的是 tunnelManager.startTunnel(...)，正常不会直接调这里；
    /// 但为满足协议、也为「无 tunnelManager 时的退化路径」保留一致行为。
    func start(profileJSON: String) {
        appLog("FakeTunnelEngine.start (\(profileJSON.count) bytes) — 模拟拨号")
        simulateConnect()
    }

    func stop() {
        appLog("FakeTunnelEngine.stop — 模拟断开")
        simulateDisconnect()
    }

    /// 真实引擎里 syncStatus 会查询扩展当前状态回填；Simulator 无扩展，空实现。
    func syncStatus() {}

    func selectSubscriptionMember(
        profileJSON: String,
        subscriptionID: String,
        groupName: String,
        memberName: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard isConnected else {
            completion(.failure(TunnelRuntimeError.unavailable))
            return
        }
        completion(.success(()))
    }

    func testSubscriptionNode(
        profileJSON: String,
        subscriptionID: String,
        nodeID: String,
        testURL: String,
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        guard isConnected else {
            completion(.failure(TunnelRuntimeError.unavailable))
            return
        }
        let checksum = nodeID.utf8.reduce(0) { ($0 + Int($1)) % 240 }
        completion(.success(28 + checksum))
    }

    func probeSubscriptionNodeAddress(
        profileJSON: String,
        subscriptionID: String,
        nodeID: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard isConnected else {
            completion(.failure(TunnelRuntimeError.unavailable))
            return
        }
        let suffix = 1 + nodeID.utf8.reduce(0) { ($0 + Int($1)) % 253 }
        completion(.success("模拟 198.51.100.\(suffix)"))
    }

    func tailscaleStatus(
        endpointTag: String,
        completion: @escaping (Result<TailscaleRuntimeStatus, Error>) -> Void
    ) {
        guard ["connected", "action-required"].contains(status), !endpointTag.isEmpty else {
            completion(.failure(TunnelRuntimeError.unavailable))
            return
        }
        completion(.success(TailscaleRuntimeStatus(
            backendState: "NeedsLogin",
            authURL: "https://login.tailscale.com/a/xdial-simulator",
            exitNodes: [
                TailscaleRuntimeExitNode(
                    id: "simulator-online",
                    name: "家中 Mac",
                    ip: "100.64.0.8",
                    online: true,
                    os: "macOS"
                ),
                TailscaleRuntimeExitNode(
                    id: "simulator-offline",
                    name: "备用节点",
                    ip: "100.64.0.9",
                    online: false,
                    os: "linux"
                ),
            ]
        )))
    }

    func beginTailscaleLogin(
        endpointTag: String,
        completion: @escaping (Result<TailscaleRuntimeStatus, Error>) -> Void
    ) {
        tailscaleStatus(endpointTag: endpointTag, completion: completion)
    }

    // MARK: 供 FakeTunnelManager 驱动

    /// 进入 connecting，1.5s 后到 connected。若已在 connecting/connected 则忽略重复调用。
    func simulateConnect() {
        guard status != "connecting", status != "connected" else { return }
        lastError = nil
        dataPathSummary = "模拟器 FakeTunnel：未接管系统流量"
        epoch += 1
        let myEpoch = epoch
        status = "connecting"
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard self.epoch == myEpoch else { return }
            self.status = ProcessInfo.processInfo.arguments.contains(
                "-XDialUITestingTailscaleActionRequired"
            ) ? "action-required" : "connected"
            self.connectedAt = Date()
            appLog("FakeTunnelEngine → \(self.status)")
        }
    }

    /// 进入 disconnecting，0.8s 后到 disconnected。若已 disconnecting/disconnected 则忽略。
    /// AppState 通过 FakeTunnelManager.stopTunnel() 走到这里，与真机的系统管理路径一致。
    func simulateDisconnect() {
        guard status != "disconnecting", status != "disconnected" else { return }
        epoch += 1
        let myEpoch = epoch
        status = "disconnecting"
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard self.epoch == myEpoch else { return }
            self.status = "disconnected"
            self.connectedAt = nil
            appLog("FakeTunnelEngine → disconnected")
        }
    }
}

/// Simulator 中独立于正式隧道的 Tailscale 设置运行时。
///
/// 每条线路保留自己的登录状态，用来模拟真实实现按 lineID 隔离的 state directory。
/// `start` 只要求目标是 Tailscale 线路，不要求线路已启用，因此可以先完成设置再启用。
@MainActor
final class FakeTailscaleSetupRuntime: TailscaleSetupRuntime {
    private var activeLineID: String?
    private var authenticatedByLineID: [String: Bool] = [:]

    var isActive: Bool { activeLineID != nil }

    func start(
        profileJSON: String,
        lineID: String,
        completion: @escaping (Result<TailscaleRuntimeStatus, Error>) -> Void
    ) {
        guard activeLineID == nil,
              let data = profileJSON.data(using: .utf8),
              let profile = try? JSONDecoder().decode(Profile.self, from: data),
              let line = profile.lines.first(where: {
                  $0.id == lineID && $0.type == "tailscale"
              }) else {
            completion(.failure(TunnelRuntimeError.missingTarget))
            return
        }

        if authenticatedByLineID[lineID] == nil {
            authenticatedByLineID[lineID] = line.tailscaleAuthenticated
        }
        activeLineID = lineID
        completion(.success(runtimeStatus(for: lineID)))
    }

    func status(
        lineID: String,
        completion: @escaping (Result<TailscaleRuntimeStatus, Error>) -> Void
    ) {
        guard activeLineID == lineID else {
            completion(.failure(TunnelRuntimeError.missingTarget))
            return
        }
        completion(.success(runtimeStatus(for: lineID)))
    }

    func beginLogin(
        lineID: String,
        completion: @escaping (Result<TailscaleRuntimeStatus, Error>) -> Void
    ) {
        guard activeLineID == lineID else {
            completion(.failure(TunnelRuntimeError.missingTarget))
            return
        }
        authenticatedByLineID[lineID] = true
        completion(.success(runtimeStatus(for: lineID)))
    }

    func logout(
        lineID: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard activeLineID == lineID else {
            completion(.failure(TunnelRuntimeError.missingTarget))
            return
        }
        authenticatedByLineID[lineID] = false
        completion(.success(()))
    }

    func stop(completion: @escaping () -> Void) {
        activeLineID = nil
        completion()
    }

    private func runtimeStatus(for lineID: String) -> TailscaleRuntimeStatus {
        guard authenticatedByLineID[lineID] == true else {
            return TailscaleRuntimeStatus(
                backendState: "NeedsLogin",
                authURL: "https://login.tailscale.com/a/xdial-simulator",
                exitNodes: []
            )
        }
        return TailscaleRuntimeStatus(
            backendState: "Running",
            authURL: "",
            exitNodes: [
                TailscaleRuntimeExitNode(
                    id: "simulator-mbp64k",
                    name: "mbp64k",
                    ip: "100.64.0.8",
                    online: true,
                    os: "macOS"
                ),
                TailscaleRuntimeExitNode(
                    id: "simulator-offline",
                    name: "备用节点",
                    ip: "100.64.0.9",
                    online: false,
                    os: "linux"
                ),
            ]
        )
    }
}

/// Simulator 演示管理层：conform TunnelManaging，永远「已安装」，startTunnel 直接成功。
///
/// 构造时持有 FakeTunnelEngine 的引用，startTunnel/stopTunnel 时驱动引擎状态机——
/// 与真实 TunnelManager「负责拉起/停止隧道」的职责对齐。
@MainActor
final class FakeTunnelManager: TunnelManaging, ObservableObject {
    /// Simulator 里 VPN Profile 视为始终已安装可用（对应 macOS 的 helperInstalled=true）。
    private(set) var isProfileInstalled: Bool = true
    private(set) var systemOnDemandActive = false
    @Published private(set) var systemOnDemandState: SystemOnDemandState = .disabled
    var systemOnDemandStatePublisher: AnyPublisher<SystemOnDemandState, Never> {
        $systemOnDemandState.eraseToAnyPublisher()
    }
    private var systemOnDemandRequested = false
    private var systemOnDemandSuspendedForSetup = false

    /// 被驱动的引擎。weak：存活锚点在 engine.retainedManager（engine 强持有 manager），
    /// 这里再强引用回 engine 会成环。engine 由 AppState 强持有，本 weak 不会先于它释放。
    private weak var engine: FakeTunnelEngine?

    init(engine: FakeTunnelEngine) {
        self.engine = engine
    }

    func refreshProfileStatus(completion: @escaping @Sendable (Bool) -> Void) {
        completion(true)
    }

    func setSystemOnDemandEnabled(_ enabled: Bool) {
        systemOnDemandRequested = enabled
        if !enabled {
            systemOnDemandActive = false
            systemOnDemandState = .disabled
        } else if !systemOnDemandActive {
            systemOnDemandState = .pending
        }
    }

    func setSystemOnDemandSuspendedForSetup(
        _ suspended: Bool,
        completion: @escaping () -> Void
    ) {
        systemOnDemandSuspendedForSetup = suspended
        if suspended {
            systemOnDemandActive = false
            systemOnDemandState = systemOnDemandRequested ? .pending : .disabled
        } else if systemOnDemandRequested {
            systemOnDemandState = systemOnDemandActive ? .active : .pending
        }
        completion()
    }

    /// 记录不含连接参数的日志，0.3s 后回调成功，并立即驱动引擎进入
    /// connecting→connected。
    func startTunnel(profile: Profile, anyConnect: AnyConnectCredentials?,
                     allowSystemOnDemand: Bool,
                     completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        appLog("FakeTunnelManager.startTunnel — 模拟拉起隧道")
        isProfileInstalled = true
        if !allowSystemOnDemand {
            systemOnDemandActive = false
        }
        // 立即驱动引擎切到 connecting，UI 马上能看到「正在连接…」。
        engine?.simulateConnect()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            systemOnDemandActive = allowSystemOnDemand
                && systemOnDemandRequested
                && !systemOnDemandSuspendedForSetup
            systemOnDemandState = systemOnDemandRequested
                ? (systemOnDemandActive ? .active : .pending)
                : .disabled
            completion(.success(()))
        }
    }

    func stopTunnel() {
        appLog("FakeTunnelManager.stopTunnel — 模拟停止隧道")
        systemOnDemandActive = false
        systemOnDemandState = systemOnDemandRequested ? .pending : .disabled
        engine?.simulateDisconnect()
    }

    func removeProfile(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        guard engine?.isConnected != true, engine?.isBusy != true else {
            completion(.failure(TunnelRuntimeError.unavailable))
            return
        }
        isProfileInstalled = false
        completion(.success(()))
    }

}

// MARK: - Simulator 演示数据

extension AppState {
    /// 演示凭据：仅用于 Simulator，让 canConnect 通过、UI 能走完连接流程。
    enum DemoCredentials {
        static let server = "connect.demo.example.com"
        static let username = "demo"
        static let password = "demo123"
    }

    /// 在 Simulator 分支下补齐演示数据，让 app 一进来就处于「可连接」且有内容可切换的状态：
    ///   1. VPN 类型 Line 凭据为空则填入演示值。
    ///   2. 没有场景则种入 2 条（海外 / 国内），并设一个为 active。
    ///
    /// 只在 RootView 的 Simulator 分支调用，不污染真实路径的 AppState 逻辑。
    /// 幂等：已填过凭据 / 已有场景就不重复写，避免每次启动都改动。
    func seedDemoDataForSimulator() {
        var changed = false

        // 1. 补 VPN 凭据
        for i in profile.lines.indices where profile.lines[i].type == "vpn" {
            if profile.lines[i].vpnServer.isEmpty {
                profile.lines[i].vpnServer = DemoCredentials.server
                changed = true
            }
            if profile.lines[i].vpnUsername.isEmpty {
                profile.lines[i].vpnUsername = DemoCredentials.username
                changed = true
            }
            if profile.lines[i].vpnPassword.isEmpty {
                profile.lines[i].vpnPassword = DemoCredentials.password
                changed = true
            }
        }

        // 2. 种场景（至少 2 条，ScenarioPickerView 才有东西可选）
        if profile.scenarios.isEmpty {
            let directID = profile.lines.first(where: { $0.type == "direct" })?.id ?? "direct"
            let vpnID = profile.lines.first(where: { $0.type == "vpn" })?.id ?? "vpn"
            let manualRuleSetIDs = profile.ruleSets
                .filter { $0.type == "manual" && !$0.isConnectivityTestRule }
                .map { $0.id }
            let gfwRuleSetID = profile.ruleSets
                .first(where: { $0.type == "url" && $0.enabled })?.id ?? ""

            let overseas = Profile.templateOverseas(
                ruleSetIDs: manualRuleSetIDs,
                vpnLineID: vpnID,
                directLineID: directID
            )
            let domestic = Profile.templateDomestic(
                ruleSetIDs: manualRuleSetIDs,
                gfwRuleSetID: gfwRuleSetID,
                vpnLineID: vpnID,
                directLineID: directID
            )
            profile.scenarios = [overseas, domestic]
            profile.activeScenarioID = overseas.id
            changed = true
        } else if profile.activeScenarioID.isEmpty {
            profile.activeScenarioID = profile.scenarios.first?.id ?? ""
            changed = true
        }

        if ProcessInfo.processInfo.arguments.contains("-XDialUITestingIncompleteLine"),
           let scenarioIndex = profile.scenarios.firstIndex(where: { $0.id == profile.activeScenarioID }) {
            let lineID = "incomplete-ui-line"
            if !profile.lines.contains(where: { $0.id == lineID }) {
                profile.lines.append(Line(
                    id: lineID,
                    name: "待配置线路",
                    type: "vpn"
                ))
            }
            profile.scenarios[scenarioIndex].defaultLineID = lineID
            profile.scenarios[scenarioIndex].defaultSubscriptionID = ""
            changed = true
        }

        // UI 自动化需要一份不依赖公网下载的订阅，覆盖无策略组 selector、节点延迟和
        // 出口地址入口。仅测试进程注入，普通 Simulator 不会看到演示订阅。
        let isUITesting = ProcessInfo.processInfo.arguments.contains("-XDialUITesting")
            || ProcessInfo.processInfo.arguments.contains("-XDialUITestingReset")
        let testsOfflineTailscaleSetup = ProcessInfo.processInfo.arguments.contains(
            "-XDialUITestingOfflineTailscaleSetup"
        )
        if isUITesting
            && !testsOfflineTailscaleSetup
            && !profile.lines.contains(where: { $0.type == "tailscale" }) {
            profile.lines.append(Line(
                id: "tailscale-ui-demo",
                name: "Tailscale 演示",
                type: "tailscale",
                enabled: true,
                tailscaleAuthenticated: true
            ))
            // 设备名现在是 Profile 全局的一份，不再挂在线路上。
            profile.tailscale.hostname = "xdial-simulator"
            changed = true
        }
        if testsOfflineTailscaleSetup,
           !profile.lines.contains(where: { $0.id == "tailscale-offline-setup" }) {
            profile.lines.removeAll { $0.type == "tailscale" }
            profile.lines.append(Line(
                id: "tailscale-offline-setup",
                name: "Tailscale 首次设置",
                type: "tailscale",
                enabled: true
            ))
            profile.scenarios = [Scenario(
                id: "tailscale-offline-scenario",
                name: "Tailscale 首次设置",
                defaultLineID: "tailscale-offline-setup"
            )]
            profile.activeScenarioID = "tailscale-offline-scenario"
            profile.ensureConnectivityTestConfiguration()
            changed = true
        }
        if ProcessInfo.processInfo.arguments.contains("-XDialUITestingConnectedInactiveTailscale"),
           !profile.lines.contains(where: { $0.id == "tailscale-inactive-ui" }) {
            profile.lines.append(Line(
                id: "tailscale-inactive-ui",
                name: "Tailscale 待设置",
                type: "tailscale",
                enabled: false
            ))
            changed = true
        }
        if ProcessInfo.processInfo.arguments.contains("-XDialUITestingTailscaleActionRequired"),
           let scenarioIndex = profile.scenarios.firstIndex(where: { $0.id == profile.activeScenarioID }) {
            let ruleID = "tailscale-ui-login-rule"
            if !profile.ruleSets.contains(where: { $0.id == ruleID }) {
                profile.ruleSets.append(RuleSet(
                    id: ruleID,
                    name: "Tailscale 登录演示",
                    type: "manual",
                    domains: ["login-demo.invalid"]
                ))
                changed = true
            }
            if !profile.scenarios[scenarioIndex].bindings.contains(where: {
                $0.ruleSetID == ruleID
            }) {
                profile.scenarios[scenarioIndex].bindings.append(RuleBinding(
                    ruleSetID: ruleID,
                    lineID: "tailscale-ui-demo"
                ))
                changed = true
            }
        }
        if isUITesting && profile.subscriptions.isEmpty {
            profile.subscriptions = [Subscription(
                id: "sub-ui-demo",
                name: "UI 测试订阅",
                url: "",
                format: "clash",
                strategy: "selector",
                lines: [
                    Line(
                        id: "ui-node-one",
                        name: "演示节点一",
                        type: "shadowsocks",
                        ssServer: "one.example.invalid",
                        ssPassword: "demo"
                    ),
                    Line(
                        id: "ui-node-two",
                        name: "演示节点二",
                        type: "shadowsocks",
                        ssServer: "two.example.invalid",
                        ssPassword: "demo"
                    ),
                ],
                selected: "演示节点一"
            )]
            changed = true
        }
        if ProcessInfo.processInfo.arguments.contains("-XDialUITestingSubscriptionSummary"),
           let scenarioIndex = profile.scenarios.firstIndex(where: { $0.id == profile.activeScenarioID }) {
            profile.scenarios[scenarioIndex].defaultLineID = ""
            profile.scenarios[scenarioIndex].defaultSubscriptionID = "sub-ui-demo"
            changed = true
        }

        if changed {
            save()
            // save() 只改 profile / Keychain，不刷新 helperInstalled；
            // 真正的 helperInstalled 由注入的 FakeTunnelManager.isProfileInstalled=true 决定，
            // 已在 AppState.init 的 refreshTunnelProfileStatus() 里读到，这里无需再动。
        }
    }
}
#endif
