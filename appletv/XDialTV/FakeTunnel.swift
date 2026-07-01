#if targetEnvironment(simulator)
import Combine
import Foundation

// MARK: - Fake Tunnel (Simulator 演示层)
//
// 这是**只在 tvOS Simulator 里编译**的演示隧道层（整个文件被
// `#if targetEnvironment(simulator)` 包裹，真机 / Release 构建不包含）。
//
// 目的：让 app 在没有 NetworkExtension entitlement、没有真机的情况下，也能在
// Simulator 里完整走通 UI 交互——连接 / 断开 / 状态转换 / 模式切换——而不真正拨号。
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

    // MARK: 供 FakeTunnelManager 驱动

    /// 进入 connecting，1.5s 后到 connected。若已在 connecting/connected 则忽略重复调用。
    func simulateConnect() {
        guard status != "connecting", status != "connected" else { return }
        lastError = nil
        epoch += 1
        let myEpoch = epoch
        status = "connecting"
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard self.epoch == myEpoch else { return }
            self.status = "connected"
            appLog("FakeTunnelEngine → connected")
        }
    }

    /// 进入 disconnecting，0.8s 后到 disconnected。若已 disconnecting/disconnected 则忽略。
    /// disconnect() 里 tunnelManager.stopTunnel() 与 engine.stop() 会各调一次，靠这个
    /// guard 保证幂等（第二次调用是 no-op）。
    func simulateDisconnect() {
        guard status != "disconnecting", status != "disconnected" else { return }
        epoch += 1
        let myEpoch = epoch
        status = "disconnecting"
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard self.epoch == myEpoch else { return }
            self.status = "disconnected"
            appLog("FakeTunnelEngine → disconnected")
        }
    }
}

/// Simulator 演示管理层：conform TunnelManaging，永远「已安装」，startTunnel 直接成功。
///
/// 构造时持有 FakeTunnelEngine 的引用，startTunnel/stopTunnel 时驱动引擎状态机——
/// 与真实 TunnelManager「负责拉起/停止隧道」的职责对齐。
@MainActor
final class FakeTunnelManager: TunnelManaging, ObservableObject {
    /// Simulator 里 VPN Profile 视为始终已安装可用（对应 macOS 的 helperInstalled=true）。
    let isProfileInstalled: Bool = true

    /// 被驱动的引擎。weak：存活锚点在 engine.retainedManager（engine 强持有 manager），
    /// 这里再强引用回 engine 会成环。engine 由 AppState 强持有，本 weak 不会先于它释放。
    private weak var engine: FakeTunnelEngine?

    init(engine: FakeTunnelEngine) {
        self.engine = engine
    }

    /// 记录一条日志（server/username，**不打印密码**），0.3s 后回调成功，
    /// 并立即驱动引擎进入 connecting→connected。
    func startTunnel(profile: Profile, server: String, username: String, password: String,
                     completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        appLog("FakeTunnelManager.startTunnel server=\(server) username=\(username) — 模拟拉起隧道")
        // 立即驱动引擎切到 connecting，UI 马上能看到「正在连接…」。
        engine?.simulateConnect()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            completion(.success(()))
        }
    }

    func stopTunnel() {
        appLog("FakeTunnelManager.stopTunnel — 模拟停止隧道")
        engine?.simulateDisconnect()
    }
}

// MARK: - Simulator 演示数据

extension AppState {
    /// 演示凭据：仅用于 Simulator，让 canConnect 通过、UI 能走完连接流程。
    enum DemoCredentials {
        static let server = "vpn.demo.example.com"
        static let username = "demo"
        static let password = "demo123"
    }

    /// 在 Simulator 分支下补齐演示数据，让 app 一进来就处于「可连接」且有内容可切换的状态：
    ///   1. VPN 类型 Line 凭据为空则填入演示值。
    ///   2. 没有模式则种入 2 条（海外 / 国内），并设一个为 active。
    ///
    /// 只在 RootView 的 Simulator 分支调用，不污染真实路径的 AppState 逻辑。
    /// 幂等：已填过凭据 / 已有模式就不重复写，避免每次启动都改动。
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

        // 2. 种模式（至少 2 条，ModePickerView 才有东西可选）
        if profile.modes.isEmpty {
            let directID = profile.lines.first(where: { $0.type == "direct" })?.id ?? "direct"
            let vpnID = profile.lines.first(where: { $0.type == "vpn" })?.id ?? "vpn"
            let manualRuleSetIDs = profile.ruleSets
                .filter { $0.type == "manual" }
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
            profile.modes = [overseas, domestic]
            profile.activeModeID = overseas.id
            changed = true
        } else if profile.activeModeID.isEmpty {
            profile.activeModeID = profile.modes.first?.id ?? ""
            changed = true
        }

        if changed {
            save()
            // save() 只改 profile / Keychain，不刷新 helperInstalled；
            // 真正的 helperInstalled 由注入的 FakeTunnelManager.isProfileInstalled=true 决定，
            // 已在 AppState.init 的 checkHelper() 里读到，这里无需再动。
        }
    }
}
#endif
