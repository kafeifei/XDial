import Combine
import Foundation
import Libbox
// NetworkExtension 的类型(NETunnelProviderManager 等)还没有做 Sendable 审计,
// 完成 handler 里从系统线程切回 @MainActor 时 Swift 6 严格并发检查会报「sending
// 风险」。@preconcurrency 是 Apple 系统框架里这类未审计类型的标准处理方式。
@preconcurrency import NetworkExtension

// MARK: - TunnelManager (tvOS)
//
// macOS 版靠 PrivilegeManager 安装 LaunchDaemon + helper,再用 AF_UNIX socket 拨号。
// tvOS 上没有特权进程:VPN 逻辑跑在 NEPacketTunnelProvider 扩展进程里,由系统托管。
// App 侧只做两件事:
//   1. 通过 NETunnelProviderManager 把一份 VPN 配置写进系统偏好(saveToPreferences),
//      让系统「知道有这么一个隧道可以拨」——这一步会触发用户授权弹窗。
//   2. 通过 manager.connection(即 NETunnelProviderSession)与扩展进程收发 JSON 消息
//      (sendProviderMessage),复用 GoEngine 里那套 wire 协议。
//
// 本文件是「薄骨架」:核心运行时行为(授权弹窗 / on-demand 状态机 / 真实拨号)
// 在没有 NetworkExtension entitlement 和真机之前完全无法离线验证,凡是受签名/
// entitlement 影响的地方都标了 TODO,真机联调时按标记逐一核对。
//
// 依赖对接:
//   - conform `TunnelManaging`(AppState.swift):暴露 isProfileInstalled 供 checkHelper() 读。
//   - 持有一个 `TunnelProviderSession`(conform GoEngine.swift 的 `TunnelSession`),
//     注入给 GoEngine.session,让 GoEngine 的 sendProviderMessage 落到真实扩展会话上。

/// 扩展的 bundle id(打包时 Packet Tunnel 扩展 target 的 bundle identifier 必须与此一致)。
private let kTunnelBundleIdentifier = "com.kafeifei.xdialtv.tunnel"

/// App Group,与 XDialTV.entitlements 中一致。扩展进程同样加入此 group 后可共享 UserDefaults/
/// 文件容器,用于传大块配置(避免塞进 providerConfiguration)。骨架阶段仅记录,未真正使用。
private let kAppGroupIdentifier = "group.com.kafeifei.xdialtv"

/// providerConfiguration 里携带的隧道自身描述名。
private let kTunnelLocalizedDescription = "XDial"

/// NetworkExtension 的类型(NETunnelProviderManager 等)没有 Sendable 审计。这里的用法
/// 是"系统完成回调只调一次、拿到就立刻在同一步用掉",不存在真实并发访问——
/// 用这个 box 显式告诉 Swift 6 的 sending 检查器信任这一点,而不是引入 Task 或改变
/// 回调时序。仅用于跨越 assumeIsolated 边界搬运这几个已知安全的值。
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
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
                          userInfo: [NSLocalizedDescriptionKey: "VPN 隧道会话不可用(未加载/未拨起)"])
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

    /// 已保存并可用的隧道配置是否存在。AppState.checkHelper() 读它填 helperInstalled。
    @Published private(set) var isProfileInstalled: Bool = false

    /// 包给 GoEngine 用的会话封装。每次 manager/connection 变化时重建并重新注入。
    private(set) var providerSession: TunnelProviderSession?

    /// GoEngine 引用,用于注入 session。弱引用避免环(GoEngine 也不强持有本类)。
    private weak var engine: GoEngine?

    init(engine: GoEngine? = nil) {
        self.engine = engine
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

    // MARK: - Configure & Save

    /// 确保系统里有一份「与 profile 对应」的隧道配置:
    /// 已有则更新其 protocolConfiguration,没有则新建一个 manager,然后 saveToPreferences。
    /// serverAddress 从 profile 的活动线路默认出口推导(仅用于系统 UI 展示,真实拨号参数
    /// 由 GoEngine 通过 sendProviderMessage 下发的 profile JSON 决定)。
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
        // providerConfiguration 只放最基本的 key。大块配置(完整 profile JSON)不塞这里,
        // 运行时通过 sendProviderMessage 下发;这里仅放扩展启动即需要的最小元信息。
        // TODO: 无法离线验证,真机联调时需要重点检查这里的实际行为。
        // providerConfiguration 有大小与类型限制(只接受 plist 可序列化类型),
        // 且系统对其可见,不应放密码等敏感数据(密码走 App Group / Keychain)。
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
    }

    // MARK: - Start / Stop (TunnelManaging)
    //
    // 这几个 key 必须与 PacketTunnelProvider.swift 里的私有常量(configKey/serverKey/
    // usernameKey/passwordKey)保持完全一致——两个 target 各自持有一份字面量,没有
    // 共享文件可 import(App Group 只共享数据,不共享代码)。TODO:后续把这几个 key
    // 抽到一个双 target 都编译进去的小文件(Shared/AppGroupKeys.swift)里去重。
    private enum AppGroupKey {
        static let config = "xdial.tunnel.config"
        static let server = "xdial.tunnel.server"
        static let username = "xdial.tunnel.username"
        static let password = "xdial.tunnel.password"
    }

    /// 把 profile 转成 NE 模式 sing-box 配置、连同凭据写进 App Group,
    /// 确保系统隧道配置已保存,再调用 `startVPNTunnel()` 真正拉起隧道。
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

        groupDefaults.set(server, forKey: AppGroupKey.server)
        groupDefaults.set(username, forKey: AppGroupKey.username)
        groupDefaults.set(password, forKey: AppGroupKey.password)
        groupDefaults.set(configJSON, forKey: AppGroupKey.config)

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
                        // startVPNTunnel() 需要一个真实的 NEVPNConnection;manager.connection
                        // 在 saveToPreferences 之后应当可用。凭据/配置已写进 App Group,
                        // 这里不再通过 options 重复传递(避免大字符串塞进系统 IPC)。
                        try self.manager?.connection.startVPNTunnel()
                        completion(.success(()))
                    } catch {
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    /// 停止系统级隧道。manager/connection 不可用时静默返回(语义等价「本来就没在跑」)。
    func stopTunnel() {
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
