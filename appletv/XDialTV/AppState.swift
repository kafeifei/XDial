import Combine
import Foundation
import os.log
import SwiftUI

// MARK: - Engine / Tunnel abstraction (iOS / tvOS)
//
// macOS 版 AppState 直接依赖 `GoEngine.shared`（通过 UNIX socket 与特权 helper 通信）
// 和 `PrivilegeManager`（安装/校验 LaunchDaemon + helper）。iOS / tvOS 上没有特权进程概念，
// VPN 通过 NETunnelProviderManager / Packet Tunnel 扩展实现。
//
// 为了不和「引擎层」这个并行任务硬耦合，这里用两个最小协议做占位：
//   - `TunnelEngine`：AppState 实际用到的引擎表面（状态 + start/stop/syncStatus）。
//     并行任务写的具体引擎类型只要 conform 这个协议即可注入。
//   - `TunnelManaging`：替代 macOS 的 PrivilegeManager，语义是「VPN Profile 是否已安装并可用」。
//     等 NETunnelProviderManager 管理层实现后在这里对接真实状态查询。

/// AppState 用到的引擎最小表面。并行的引擎实现 conform 此协议后注入即可。
/// 注意：暴露 `objectWillChange` 让 AppState 能像 macOS 版那样订阅引擎状态变化。
struct TailscaleRuntimeExitNode: Decodable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let ip: String
    let online: Bool
    let os: String?
}

struct TailscaleRuntimeStatus: Decodable, Equatable, Sendable {
    let backendState: String
    let authURL: String
    let exitNodes: [TailscaleRuntimeExitNode]

    enum CodingKeys: String, CodingKey {
        case backendState = "backend_state"
        case authURL = "auth_url"
        case exitNodes = "exit_nodes"
    }
}

struct AnyConnectCredentials: Equatable, Sendable {
    let server: String
    let username: String
    let password: String
}

@MainActor
protocol TunnelEngine: AnyObject {
    var status: String { get }
    var lastError: String? { get set }
    var dataPathSummary: String? { get set }
    var connectedAt: Date? { get }
    var isConnected: Bool { get }
    var isBusy: Bool { get }

    /// 引擎状态变化的发布器（等价于 ObservableObject.objectWillChange）。
    var objectWillChange: ObservableObjectPublisher { get }
    /// `objectWillChange` 在属性赋值前发送，不能用它读取新的状态；状态机必须订阅
    /// 这个赋值后的流，否则一次同步的 connected -> disconnected 会被合并丢失。
    var statusPublisher: AnyPublisher<String, Never> { get }

    func start(profileJSON: String)
    func stop()
    func syncStatus()
    func selectSubscriptionMember(
        profileJSON: String,
        subscriptionID: String,
        groupName: String,
        memberName: String,
        completion: @escaping (Result<Void, Error>) -> Void
    )
    func testSubscriptionNode(
        profileJSON: String,
        subscriptionID: String,
        nodeID: String,
        testURL: String,
        completion: @escaping (Result<Int, Error>) -> Void
    )
    func probeSubscriptionNodeAddress(
        profileJSON: String,
        subscriptionID: String,
        nodeID: String,
        completion: @escaping (Result<String, Error>) -> Void
    )
    func tailscaleStatus(
        endpointTag: String,
        completion: @escaping (Result<TailscaleRuntimeStatus, Error>) -> Void
    )
    func suppressNextAutomaticReconnect()
    func consumeAutomaticReconnectPermission() -> Bool
}

extension TunnelEngine {
    var connectedAt: Date? { nil }
    var statusPublisher: AnyPublisher<String, Never> {
        Just(status).eraseToAnyPublisher()
    }

    func selectSubscriptionMember(
        profileJSON: String,
        subscriptionID: String,
        groupName: String,
        memberName: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        completion(.failure(TunnelRuntimeError.unavailable))
    }

    func testSubscriptionNode(
        profileJSON: String,
        subscriptionID: String,
        nodeID: String,
        testURL: String,
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        completion(.failure(TunnelRuntimeError.unavailable))
    }

    func probeSubscriptionNodeAddress(
        profileJSON: String,
        subscriptionID: String,
        nodeID: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        completion(.failure(TunnelRuntimeError.unavailable))
    }

    func tailscaleStatus(
        endpointTag: String,
        completion: @escaping (Result<TailscaleRuntimeStatus, Error>) -> Void
    ) {
        completion(.failure(TunnelRuntimeError.unavailable))
    }

    func suppressNextAutomaticReconnect() {}
    func consumeAutomaticReconnectPermission() -> Bool { true }
}

enum TunnelRuntimeError: LocalizedError {
    case unavailable
    case invalidCatalog
    case invalidTailscaleStatus
    case missingTarget
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The connection runtime is unavailable."
        case .invalidCatalog:
            return "The runtime route catalog is invalid."
        case .invalidTailscaleStatus:
            return "The Tailscale runtime status is invalid."
        case .missingTarget:
            return "The selected runtime route is unavailable."
        case .requestFailed(let message):
            return message
        }
    }
}

/// 订阅解析结果。macOS 版是 `GoEngine.ParseResult`，这里抽成独立类型，
/// 引擎层解析订阅后回填给 `updateSubscription`。
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

/// 替代 macOS PrivilegeManager 的占位协议：查询 VPN Profile 是否已安装并可用，
/// 并负责真正把系统级 VPN 隧道拉起来/停下去。
/// TODO: 等 NETunnelProviderManager 管理层实现后，用真实的 NETunnelProviderManager
/// 状态查询实现此协议（是否已 saveToPreferences、是否 enabled 等）。
enum SystemOnDemandState: Equatable {
    case disabled
    case pending
    case active
    case failed(String)
}

@MainActor
protocol TunnelManaging: AnyObject {
    /// VPN Profile 是否已安装并可用（对应 macOS 的 helperInstalled 语义）。
    var isProfileInstalled: Bool { get }
    /// 系统当前是否已经接管意外断线重连；仅代表已落入系统偏好的实际状态。
    var systemOnDemandActive: Bool { get }
    var systemOnDemandState: SystemOnDemandState { get }
    var systemOnDemandStatePublisher: AnyPublisher<SystemOnDemandState, Never> { get }

    /// 从系统偏好重新读取 VPN Profile 状态。首次安装时尚未存在 Profile，
    /// 但这不妨碍用户点击连接；真正的 Profile 会在 startTunnel 里创建。
    func refreshProfileStatus(completion: @escaping @Sendable (Bool) -> Void)

    /// 把当前 profile 转成 NE 模式配置、连同 AnyConnect 凭据一起交给系统拉起隧道
    /// （NETunnelProviderManager.saveToPreferences + startVPNTunnel）。
    /// 这是唯一真正触发系统级连接的入口——`TunnelEngine.start(profileJSON:)`
    /// 走的是 sendProviderMessage，只有隧道已经在跑时才有意义，不能从冷启动拉起隧道。
    func startTunnel(profile: Profile, anyConnect: AnyConnectCredentials?,
                      completion: @escaping @Sendable (Result<Void, Error>) -> Void)
    /// 保存用户的系统级重连意图。启用请求只会在连接验收通过且安全启动包可用后生效。
    func setSystemOnDemandEnabled(_ enabled: Bool)

    /// 停止系统级隧道（NETunnelProviderManager.connection.stopVPNTunnel()）。
    func stopTunnel()
    func removeProfile(completion: @escaping @Sendable (Result<Void, Error>) -> Void)

}

extension TunnelManaging {
    var systemOnDemandActive: Bool { false }
    var systemOnDemandState: SystemOnDemandState { .disabled }
    var systemOnDemandStatePublisher: AnyPublisher<SystemOnDemandState, Never> {
        Just(systemOnDemandState).eraseToAnyPublisher()
    }

    func setSystemOnDemandEnabled(_ enabled: Bool) {}

    func removeProfile(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        completion(.failure(TunnelRuntimeError.unavailable))
    }
}

private let appOSLog = OSLog(subsystem: "com.kafeifei.xdial.mobile", category: "app")

func appLog(_ msg: String) {
    os_log("%{public}@", log: appOSLog, type: .info, msg)
    #if DEBUG
    print("[xdial] \(msg)")
    #endif
}

/// 内部协议或系统错误偶尔会带出旧技术名。产品界面统一使用 AnyConnect；
/// iOS 自己的授权弹窗由系统生成，不经过这个显示层。
func userFacingConnectionText(_ value: String) -> String {
    value.replacingOccurrences(of: "VPN", with: "AnyConnect", options: [.caseInsensitive])
}

// 全角 ASCII → 半角。macOS 版定义在 ASCIIField.swift（含 SwiftUI 视图），
// tvOS 这里只需要纯字符串归一化逻辑，独立复制一份，语义完全一致。
extension String {
    /// 把全角 ASCII（U+FF01-U+FF5E）转半角，全角空格转半角空格。
    /// 用于密码、URL、服务器地址等只允许 ASCII 的字段。
    func normalizedASCII() -> String {
        var out = ""
        out.reserveCapacity(self.unicodeScalars.count)
        for ch in self.unicodeScalars {
            let v = ch.value
            if v >= 0xFF01 && v <= 0xFF5E {
                if let s = Unicode.Scalar(v - 0xFEE0) {
                    out.append(Character(s))
                }
            } else if v == 0x3000 {
                out.append(" ")
            } else {
                out.unicodeScalars.append(ch)
            }
        }
        return out
    }
}

@MainActor
struct AppPersistenceContext {
    let defaults: UserDefaults
    let defaultsSuiteName: String?
    let keychain: KeychainStore.Context
    let profileKey: String
    let languageKey: String
    let autoReconnectKey: String
    let systemOnDemandKey: String

    static let production = AppPersistenceContext(
        defaults: .standard,
        defaultsSuiteName: nil,
        keychain: .production,
        profileKey: "xdial.profile",
        languageKey: "xdial.language",
        autoReconnectKey: "xdial.auto-reconnect",
        systemOnDemandKey: "xdial.system-on-demand"
    )

    static func testing(identifier: String) -> AppPersistenceContext {
        let safeIdentifier = identifier.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "-",
            options: .regularExpression
        )
        let suiteName = "com.kafeifei.xdial.tests.\(safeIdentifier)"
        return AppPersistenceContext(
            defaults: UserDefaults(suiteName: suiteName)!,
            defaultsSuiteName: suiteName,
            keychain: .testing(identifier: safeIdentifier),
            profileKey: "xdial.profile",
            languageKey: "xdial.language",
            autoReconnectKey: "xdial.auto-reconnect",
            systemOnDemandKey: "xdial.system-on-demand"
        )
    }

    static let uiTesting = testing(identifier: "ui")

    /// 只允许清理显式测试 namespace，生产 context 永不响应这个入口。
    @discardableResult
    func clearForTesting() -> Bool {
        guard let defaultsSuiteName else { return false }
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return KeychainStore.clear(context: keychain)
    }
}

struct ProfilePersistenceEnvelope: Codable {
    static let currentFormat = "xdial-profile"
    static let currentSchemaVersion = 1

    let format: String
    let schemaVersion: Int
    let revision: String
    let profile: Profile

    init(revision: String, profile: Profile) {
        format = Self.currentFormat
        schemaVersion = Self.currentSchemaVersion
        self.revision = revision
        self.profile = profile
    }

    enum CodingKeys: String, CodingKey {
        case format
        case schemaVersion = "schema_version"
        case revision
        case profile
    }

    var isValid: Bool {
        format == Self.currentFormat
            && schemaVersion == Self.currentSchemaVersion
            && !revision.isEmpty
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var profile: Profile

    /// VPN Profile 是否已安装并可用（对应 macOS 的 helperInstalled）。
    /// 由 tunnelManager.refreshProfileStatus() 刷新为真实系统状态。
    @Published var helperInstalled: Bool = false

    @Published var language: Lang {
        didSet {
            persistence.defaults.set(language.rawValue, forKey: persistence.languageKey)
        }
    }

    @Published var autoReconnectEnabled: Bool {
        didSet {
            persistence.defaults.set(autoReconnectEnabled, forKey: persistence.autoReconnectKey)
            if !autoReconnectEnabled {
                autoReconnectTask?.cancel()
                autoReconnectTask = nil
            }
        }
    }

    @Published var systemOnDemandEnabled: Bool {
        didSet {
            persistence.defaults.set(systemOnDemandEnabled, forKey: persistence.systemOnDemandKey)
            // 该开关决定系统在主 App 不运行时是否接管连接。切换后可能马上被系统
            // 挂起或终止，必须在调用系统配置前把用户意图同步落盘。
            persistence.defaults.synchronize()
            tunnelManager?.setSystemOnDemandEnabled(systemOnDemandEnabled)
        }
    }
    @Published private(set) var systemOnDemandState: SystemOnDemandState = .disabled

    /// 引擎引用。默认注入一个空实现（NoopEngine），等并行的引擎层实现好后
    /// 通过 init(engine:) 或后续绑定替换成真实引擎。
    let engine: TunnelEngine
    private var engineSub: AnyCancellable?
    private var engineStatusSub: AnyCancellable?

    /// 系统连接管理层必须与 AppState 同生命周期；其反向 engine 引用是 weak，不成环。
    private let tunnelManager: TunnelManaging?
    private var onDemandStateSub: AnyCancellable?

    private let persistence: AppPersistenceContext
    private let keychainPrefix = "xdial-line-"
    private let subKeychainPrefix = "xdial-sub-"
    private var persistedRevision: String?
    private var persistedVault: [String: String] = [:]
    private var quarantinedLegacyValues: [String: String] = [:]
    @Published private(set) var persistenceRequiresRecovery = false
    @Published private(set) var hasPendingRuntimeChanges = false
    /// 所有编辑入口最终都调用 save()，但不少 SwiftUI 回调无法同步展示返回值。
    /// 保留最后一次确认落盘的完整配置；任何持久化失败都统一回滚，避免 UI 看似保存、
    /// 重启后才发现账号或模式消失。
    private var lastPersistedProfile = Profile.bootstrap()
    private var runningProfileSnapshot: Profile?
    private var reconnectAfterDisconnect = false
    private var observedEngineStatus = "disconnected"
    private var disconnectRequested = false
    private var autoReconnectAttempt = 0
    private var autoReconnectTask: Task<Void, Never>?

    func tr(_ zh: String, _ en: String) -> String {
        language == .zh ? zh : en
    }

    var isConnected: Bool { engine.isConnected }
    var requiresUserAction: Bool { engine.status == "action-required" }
    var hasActiveTunnel: Bool { isConnected || requiresUserAction }
    var isBusy: Bool { engine.isBusy }
    var canMutateConfiguration: Bool { !isBusy && !hasActiveTunnel }

    var isConnectionConfigured: Bool {
        guard !persistenceRequiresRecovery else { return false }
        guard tunnelManager != nil else { return false }
        guard activeMode != nil else { return false }
        return activeConfigurationIssues.isEmpty
    }

    var canConnect: Bool {
        !isBusy && !hasActiveTunnel && isConnectionConfigured
    }

    /// 当前数据面只有一个 AnyConnect bridge；一个模式可以多处引用同一线路，
    /// 但不能同时引用不同的 AnyConnect 线路，否则所有 tag 会被折叠到错误凭据上。
    var activeAnyConnectLineIDs: Set<String> {
        guard let mode = activeMode else { return [] }
        let referenced = effectiveReferencedLineIDs(in: mode)
        return Set(profile.lines.compactMap { line in
            guard referenced.contains(line.id), line.enabled, line.type == "vpn" else { return nil }
            return line.id
        })
    }

    /// 当前模式实际引用且已启用的 Tailscale 线路，用于识别 Tailscale-only 启动。
    var activeTailscaleLineIDs: Set<String> {
        guard let mode = activeMode else { return [] }
        let referenced = effectiveReferencedLineIDs(in: mode)
        return Set(profile.lines.compactMap { line in
            guard referenced.contains(line.id), line.enabled, line.type == "tailscale" else { return nil }
            return line.id
        })
    }

    /// 当前模式不能安全启动的原因。生成器会跳过无效目标并回落到 direct，移动端必须
    /// 在启动前拦住这些配置，避免 UI 显示成功而真实流量走了意外出口。
    var activeConfigurationIssues: [String] {
        if persistenceRequiresRecovery {
            return [persistenceRecoveryMessage]
        }
        guard let mode = activeMode else {
            return [tr("尚未选择模式", "No mode is selected")]
        }

        var issues: [String] = []
        appendConnectivityAcceptanceIssues(for: mode, to: &issues)
        appendTargetIssue(
            lineID: mode.defaultLineID,
            subscriptionID: mode.defaultSubscriptionID,
            label: tr("默认出口", "Default route"),
            to: &issues
        )

        for binding in mode.bindings {
            guard let rule = profile.ruleSets.first(where: { $0.id == binding.ruleSetID }) else {
                issues.append(tr("模式引用了已删除的规则", "The mode references a deleted rule"))
                continue
            }
            guard rule.enabled else { continue }
            if rule.type == "url" && rule.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(tr("规则“\(rule.name)”缺少地址", "Rule “\(rule.name)” has no address"))
                continue
            }
            if rule.type == "url" && !isHTTPSRemoteAddress(rule.url) {
                issues.append(tr("规则“\(rule.name)”必须使用 HTTPS 地址", "Rule “\(rule.name)” must use an HTTPS address"))
                continue
            }
            if rule.type == "url" && !["", "auto", "srs", "json", "text"].contains(rule.format) {
                issues.append(tr("规则“\(rule.name)”格式不受支持", "Rule “\(rule.name)” uses an unsupported format"))
                continue
            }
            appendTargetIssue(
                lineID: binding.lineID,
                subscriptionID: binding.subscriptionID,
                label: tr("规则“\(rule.name)”", "Rule “\(rule.name)”"),
                to: &issues
            )
        }

        if activeAnyConnectLineIDs.count > 1 {
            issues.append(tr(
                "当前模式一次只能使用一条 AnyConnect 线路",
                "This mode can use only one AnyConnect line at a time"
            ))
        }
        var seen = Set<String>()
        return issues.filter { seen.insert($0).inserted }
    }

    private func appendConnectivityAcceptanceIssues(for mode: Mode, to issues: inout [String]) {
        let directRuleIsExact = profile.ruleSets.contains {
            $0.id == RuleSet.connectivityDirectID && $0.enabled && $0.type == "manual"
                && $0.domains.isEmpty && $0.cidrs == ["1.0.0.1/32"]
        }
        let outboundRuleIsExact = profile.ruleSets.contains {
            $0.id == RuleSet.connectivityOutboundID && $0.enabled && $0.type == "manual"
                && $0.domains.isEmpty && $0.cidrs == ["1.1.1.1/32"]
        }
        let directBindingIsValid = mode.bindings.contains { binding in
            guard binding.ruleSetID == RuleSet.connectivityDirectID,
                  binding.subscriptionID.isEmpty else { return false }
            return profile.lines.contains {
                $0.id == binding.lineID && $0.type == "direct" && $0.enabled
            }
        }
        let expectedOutboundBinding = profile.connectivityOutboundBinding(for: mode)
        let configuredOutboundBinding = mode.bindings.first {
            $0.ruleSetID == RuleSet.connectivityOutboundID
        }
        let outboundBindingIsValid =
            expectedOutboundBinding?.lineID == configuredOutboundBinding?.lineID
            && expectedOutboundBinding?.subscriptionID == configuredOutboundBinding?.subscriptionID
        guard directRuleIsExact, outboundRuleIsExact,
              directBindingIsValid, outboundBindingIsValid else {
            issues.append(tr(
                "当前模式缺少完整的 Direct / 非 Direct 出口连接验收规则与绑定",
                "This mode is missing the complete Direct / non-Direct acceptance rules and bindings"
            ))
            return
        }
    }

    private func isHTTPSRemoteAddress(_ rawValue: String) -> Bool {
        guard let components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), !host.isEmpty else { return false }
        return host != "localhost" && !host.hasSuffix(".localhost") && !host.hasSuffix(".local")
    }

    private func effectiveReferencedLineIDs(in mode: Mode) -> Set<String> {
        var ids = Set<String>()
        if !mode.defaultLineID.isEmpty { ids.insert(mode.defaultLineID) }
        for binding in mode.bindings {
            guard !binding.lineID.isEmpty,
                  profile.ruleSets.first(where: { $0.id == binding.ruleSetID })?.enabled == true else { continue }
            ids.insert(binding.lineID)
        }
        return ids
    }

    func isUsableRouteLine(_ line: Line) -> Bool {
        guard line.enabled else { return false }
        switch line.type {
        case "direct":
            return true
        case "vpn":
            return !line.vpnServer.isEmpty && !line.vpnUsername.isEmpty && !line.vpnPassword.isEmpty
        case "trojan":
            return !line.trojanServer.isEmpty && (1...65_535).contains(line.trojanPort)
                && !line.trojanPassword.isEmpty
        case "shadowsocks":
            return !line.ssServer.isEmpty && (1...65_535).contains(line.ssPort)
                && !line.ssMethod.isEmpty && !line.ssPassword.isEmpty
        case "vmess":
            return !line.vmessServer.isEmpty && (1...65_535).contains(line.vmessPort)
                && UUID(uuidString: line.vmessUUID) != nil
        case "tailscale":
            return true
        default:
            return false
        }
    }

    func isUsableSubscription(_ subscription: Subscription) -> Bool {
        guard subscription.enabled else { return false }
        guard ["selector", "urltest", "url-test"].contains(subscription.strategy.lowercased()) else {
            return false
        }
        let lineNames = subscription.lines.map(\.name)
        guard lineNames.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(lineNames).count == lineNames.count else { return false }
        let usableLineNames = Set(subscription.lines.compactMap { line -> String? in
            guard ["trojan", "shadowsocks", "vmess"].contains(line.type),
                  isUsableRouteLine(line) else { return nil }
            return line.name
        })
        guard !usableLineNames.isEmpty else { return false }
        let supportedRuleTypes = Set([
            "DOMAIN-SUFFIX", "DOMAIN", "DOMAIN-KEYWORD", "IP-CIDR", "IP-CIDR6", "GEOIP", "FINAL",
        ])
        guard subscription.rules.allSatisfy({ supportedRuleTypes.contains($0.type.uppercased()) }) else {
            return false
        }
        guard !subscription.proxyGroups.isEmpty else { return subscription.rules.isEmpty }

        let groupNames = subscription.proxyGroups.map(\.name)
        guard groupNames.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(groupNames).count == groupNames.count,
              subscription.proxyGroups.allSatisfy({
                  ["select", "selector", "url-test", "urltest"].contains($0.type.lowercased())
              }) else { return false }

        var availableMembers = usableLineNames.union(["DIRECT", "Direct"])
        var outboundGroups = Set<String>()
        var rejectGroups = Set<String>()
        var changed = true
        while changed {
            changed = false
            for group in subscription.proxyGroups
            where !outboundGroups.contains(group.name) && !rejectGroups.contains(group.name) {
                let hasUsableMember = group.proxies.contains {
                    availableMembers.contains($0) || outboundGroups.contains($0)
                }
                if hasUsableMember {
                    outboundGroups.insert(group.name)
                    availableMembers.insert(group.name)
                    changed = true
                } else if group.proxies.contains(where: {
                    ["REJECT", "REJECT-DROP", "REJECT-TINYGIF", "BLOCK"].contains($0.uppercased())
                        || rejectGroups.contains($0)
                }) {
                    rejectGroups.insert(group.name)
                    changed = true
                }
            }
        }
        guard !outboundGroups.isEmpty else { return false }
        return subscription.rules.allSatisfy { rule in
            let target = rule.group
            return outboundGroups.contains(target) || rejectGroups.contains(target)
                || target.uppercased() == "DIRECT"
                || ["REJECT", "REJECT-DROP", "REJECT-TINYGIF", "BLOCK"].contains(target.uppercased())
        }
    }

    func canCreateMode(from template: ModeTemplate) -> Bool {
        let hasDirect = profile.lines.contains { $0.type == "direct" && isUsableRouteLine($0) }
        let hasAnyConnect = profile.lines.contains { $0.type == "vpn" && isUsableRouteLine($0) }
        switch template {
        case .overseas, .domestic:
            return hasDirect && hasAnyConnect
        case .domesticSS:
            let hasProxy = profile.lines.contains {
                $0.type != "direct" && $0.type != "vpn" && isUsableRouteLine($0)
            }
            return hasDirect && hasAnyConnect && hasProxy
        case .blank:
            return hasDirect
        }
    }

    private func appendTargetIssue(
        lineID: String,
        subscriptionID: String,
        label: String,
        to issues: inout [String]
    ) {
        let hasLine = !lineID.isEmpty
        let hasSubscription = !subscriptionID.isEmpty
        guard hasLine != hasSubscription else {
            issues.append(tr("\(label)没有唯一目标", "\(label) does not have exactly one target"))
            return
        }

        if hasSubscription {
            guard let subscription = profile.subscriptions.first(where: { $0.id == subscriptionID }) else {
                issues.append(tr("\(label)引用的订阅已删除", "\(label) references a deleted subscription"))
                return
            }
            if !isUsableSubscription(subscription) {
                issues.append(tr(
                    "\(label)使用的订阅“\(subscription.name)”没有可用节点",
                    "Subscription “\(subscription.name)” used by \(label) has no usable nodes"
                ))
            }
            return
        }

        guard let line = profile.lines.first(where: { $0.id == lineID }) else {
            issues.append(tr("\(label)引用的线路已删除", "\(label) references a deleted line"))
            return
        }
        if !isUsableRouteLine(line) {
            issues.append(tr(
                "\(label)使用的线路“\(line.name)”已停用或配置不完整",
                "Line “\(line.name)” used by \(label) is disabled or incomplete"
            ))
        }
    }

    var statusText: String {
        switch engine.status {
        case "connected": return tr("已连接", "Connected")
        case "connecting": return tr("正在连接…", "Connecting…")
        case "checking": return tr("正在验证数据链路…", "Checking data path…")
        case "action-required": return tr("需要登录 Tailscale", "Tailscale Sign-in Required")
        case "disconnecting": return tr("正在断开…", "Disconnecting…")
        case "reconnecting": return tr("正在重连…", "Reconnecting…")
        default:
            if let err = engine.lastError { return userFacingConnectionText(err) }
            return tr("未连接", "Not Connected")
        }
    }

    var activeMode: Mode? {
        profile.modes.first { $0.id == profile.activeModeID }
    }

    init(
        engine: TunnelEngine = NoopTunnelEngine(),
        tunnelManager: TunnelManaging? = nil,
        persistence: AppPersistenceContext = .production
    ) {
        self.engine = engine
        self.tunnelManager = tunnelManager
        self.persistence = persistence

        // 先用 bootstrap 初始化，loadSaved 后会被覆盖
        self.profile = Profile.bootstrap()

        // 语言：先读已保存，没有则用系统语言
        if let savedLang = persistence.defaults.string(forKey: persistence.languageKey),
           let lang = Lang(rawValue: savedLang) {
            self.language = lang
        } else {
            self.language = .system
        }
        self.autoReconnectEnabled = persistence.defaults.object(forKey: persistence.autoReconnectKey) as? Bool ?? true
        self.systemOnDemandEnabled = persistence.defaults.object(
            forKey: persistence.systemOnDemandKey
        ) as? Bool ?? false
        self.systemOnDemandState = tunnelManager?.systemOnDemandState
            ?? (systemOnDemandEnabled ? .failed("系统连接管理层不可用") : .disabled)
        onDemandStateSub = tunnelManager?.systemOnDemandStatePublisher
            .removeDuplicates()
            .sink { [weak self] state in
                self?.systemOnDemandState = state
            }
        tunnelManager?.setSystemOnDemandEnabled(systemOnDemandEnabled)

        observedEngineStatus = engine.status
        engineSub = engine.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            self.objectWillChange.send()
        }
        engineStatusSub = engine.statusPublisher
            .removeDuplicates()
            .sink { [weak self] status in
                self?.handleEngineStatusChange(status)
            }
        loadSaved()
        if !persistenceRequiresRecovery {
            profile.ensureConnectivityTestConfiguration()
        }
        refreshTunnelProfileStatus()
        engine.syncStatus()
    }

    private func handleEngineStatusChange(_ current: String) {
        guard current != observedEngineStatus else { return }
        let previous = observedEngineStatus
        observedEngineStatus = current

        if current == "connected" {
            autoReconnectAttempt = 0
            autoReconnectTask?.cancel()
            autoReconnectTask = nil
            disconnectRequested = false
            if runningProfileSnapshot == nil {
                runningProfileSnapshot = profile
                updatePendingRuntimeChanges()
            }
            markUsedLinesVerified()
            return
        }

        guard current == "disconnected" else { return }
        let hadRunningConfiguration = runningProfileSnapshot != nil
        runningProfileSnapshot = nil
        hasPendingRuntimeChanges = false
        if reconnectAfterDisconnect {
            reconnectAfterDisconnect = false
            disconnectRequested = false
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self else { return }
                if self.canConnect {
                    self.connect()
                } else {
                    self.engine.lastError = self.activeConfigurationIssues.prefix(3).joined(
                        separator: self.tr("；", "; ")
                    )
                }
            }
            return
        }
        if disconnectRequested {
            disconnectRequested = false
            autoReconnectAttempt = 0
            autoReconnectTask?.cancel()
            autoReconnectTask = nil
            return
        }
        guard engine.consumeAutomaticReconnectPermission() else {
            autoReconnectAttempt = 0
            autoReconnectTask?.cancel()
            autoReconnectTask = nil
            return
        }
        let wasUnexpected = hadRunningConfiguration
            || ["connected", "checking", "action-required", "reconnecting"].contains(previous)
            || (previous == "connecting" && autoReconnectAttempt > 0)
        // 系统已经接管时不再从主 App 同时 start，避免两个恢复路径竞争同一会话。
        guard tunnelManager?.systemOnDemandActive != true else { return }
        // @Published emits during willSet, so engine.status can still expose the
        // previous "connected" value while this callback handles "disconnected".
        // Validate configuration here and let the delayed task use canConnect
        // after the new runtime status has settled.
        guard autoReconnectEnabled,
              wasUnexpected,
              !engine.isBusy,
              isConnectionConfigured,
              autoReconnectAttempt < 3 else { return }
        autoReconnectAttempt += 1
        let delaySeconds = [1, 2, 5][autoReconnectAttempt - 1]
        engine.lastError = tr(
            "连接中断，\(delaySeconds) 秒后自动重试（\(autoReconnectAttempt)/3）",
            "Connection interrupted; retrying in \(delaySeconds)s (\(autoReconnectAttempt)/3)"
        )
        autoReconnectTask?.cancel()
        autoReconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard !Task.isCancelled, let self, self.autoReconnectEnabled, self.canConnect else { return }
            self.autoReconnectTask = nil
            self.startConnection(resetAutoReconnectAttempt: false)
        }
    }

    private func startConnection(resetAutoReconnectAttempt: Bool) {
        if resetAutoReconnectAttempt {
            autoReconnectAttempt = 0
            autoReconnectTask?.cancel()
            autoReconnectTask = nil
        }
        disconnectRequested = false
        performConnectionStart()
    }

    private func performConnectionStart() {
        guard canConnect else { return }
        guard save() else { return }
        // persist() normalizes and upgrades the profile (including the visible
        // acceptance bindings). Revalidate the resulting configuration instead
        // of starting with assumptions checked against the pre-save profile.
        guard activeConfigurationIssues.isEmpty else {
            engine.lastError = activeConfigurationIssues.joined(separator: "\n")
            return
        }
        let anyConnect = activeVPNCredentials()
        runningProfileSnapshot = profile
        hasPendingRuntimeChanges = false
        guard let tunnelManager else {
            engine.start(profileJSON: buildProfileJSON())
            return
        }
        tunnelManager.startTunnel(profile: profile, anyConnect: anyConnect) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch result {
                case .success:
                    self.helperInstalled = true
                    self.engine.syncStatus()
                case .failure(let error):
                    guard !(error is CancellationError) else { return }
                    self.runningProfileSnapshot = nil
                    self.hasPendingRuntimeChanges = false
                    self.engine.lastError = error.localizedDescription
                }
            }
        }
    }

    private var lastVerifiedAt: String = ""

    private func markUsedLinesVerified() {
        guard let s = activeMode else { return }
        let key = s.id
        if lastVerifiedAt == key { return }
        lastVerifiedAt = key

        var usedIDs = Set(s.bindings.map { $0.lineID })
        if !s.defaultLineID.isEmpty { usedIDs.insert(s.defaultLineID) }

        var changed = false
        for i in profile.lines.indices where usedIDs.contains(profile.lines[i].id) {
            if !profile.lines[i].verified {
                profile.lines[i].verified = true
                changed = true
            }
        }
        if changed { save() }
    }

    // MARK: - Connect

    func connect() {
        startConnection(resetAutoReconnectAttempt: true)
    }

    func disconnect() {
        disconnectRequested = true
        autoReconnectTask?.cancel()
        autoReconnectTask = nil
        if let tunnelManager {
            tunnelManager.stopTunnel()
        } else {
            engine.stop()
        }
    }

    func reconnectToApplyChanges() {
        guard isConnected, hasPendingRuntimeChanges else { return }
        reconnectAfterDisconnect = true
        disconnectRequested = false
        disconnect()
        disconnectRequested = false
    }

    func removeTunnelProfile(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        guard !hasActiveTunnel, !isBusy, let tunnelManager else {
            completion(.failure(TunnelRuntimeError.unavailable))
            return
        }
        tunnelManager.removeProfile { [weak self] result in
            MainActor.assumeIsolated {
                if case .success = result {
                    self?.helperInstalled = false
                }
                completion(result)
            }
        }
    }

    /// 只有活动模式恰好引用一条可用 AnyConnect 线路时才返回凭据。
    private func activeVPNCredentials() -> AnyConnectCredentials? {
        guard !persistenceRequiresRecovery else { return nil }
        guard activeAnyConnectLineIDs.count == 1,
              let id = activeAnyConnectLineIDs.first,
              let line = profile.lines.first(where: { $0.id == id }),
              isUsableRouteLine(line) else { return nil }
        return AnyConnectCredentials(
            server: line.vpnServer,
            username: line.vpnUsername,
            password: line.vpnPassword
        )
    }

    // MARK: - Persistence

    /// Vault key 使用带长度的结构化组件，避免用户可控 ID 通过 `-` 拼接产生碰撞，
    /// 导致一条线路在重启后拿到另一条线路的密码。
    private static func vaultKey(_ components: [String]) -> String {
        "v2" + components.map { "|\($0.utf8.count):\($0)" }.joined()
    }

    private static func vaultKey(_ components: String...) -> String {
        vaultKey(components)
    }

    @discardableResult
    func save() -> Bool {
        persist(replacingConflictedState: false)
    }

    /// 导入与重置是用户明确要求丢弃冲突状态的入口；普通编辑不能越过 revision 冲突。
    @discardableResult
    func replaceProfileAndSave(_ replacement: Profile) -> Bool {
        profile = replacement
        return persist(replacingConflictedState: true)
    }

    private func persist(replacingConflictedState: Bool) -> Bool {
        guard !persistenceRequiresRecovery || replacingConflictedState else {
            engine.lastError = persistenceRecoveryMessage
            profile = lastPersistedProfile
            return false
        }

        profile.ensureConnectivityTestConfiguration()

        // 先把所有 ASCII 字段做一次全角→半角清洗（兜底）
        for i in profile.lines.indices {
            profile.lines[i].vpnServer = profile.lines[i].vpnServer.normalizedASCII()
            profile.lines[i].vpnUsername = profile.lines[i].vpnUsername.normalizedASCII()
            profile.lines[i].vpnPassword = profile.lines[i].vpnPassword.normalizedASCII()
            profile.lines[i].trojanServer = profile.lines[i].trojanServer.normalizedASCII()
            profile.lines[i].trojanPassword = profile.lines[i].trojanPassword.normalizedASCII()
            profile.lines[i].trojanSNI = profile.lines[i].trojanSNI.normalizedASCII()
            profile.lines[i].ssServer = profile.lines[i].ssServer.normalizedASCII()
            profile.lines[i].ssMethod = profile.lines[i].ssMethod.normalizedASCII()
            profile.lines[i].ssPassword = profile.lines[i].ssPassword.normalizedASCII()
            profile.lines[i].vmessServer = profile.lines[i].vmessServer.normalizedASCII()
            profile.lines[i].vmessUUID = profile.lines[i].vmessUUID.normalizedASCII()
            profile.lines[i].tailscaleHostname = profile.lines[i].tailscaleHostname.normalizedASCII()
            profile.lines[i].tailscaleExitNode = profile.lines[i].tailscaleExitNode.normalizedASCII()
        }
        for i in profile.ruleSets.indices {
            profile.ruleSets[i].url = profile.ruleSets[i].url.normalizedASCII()
        }
        // 直连恒为已验证
        for i in profile.lines.indices where profile.lines[i].type == "direct" {
            profile.lines[i].verified = true
        }

        let split = splitSensitiveValues(from: profile)
        let revision = UUID().uuidString.lowercased()
        let profileEnvelope = ProfilePersistenceEnvelope(revision: revision, profile: split.sanitized)
        guard let data = try? JSONEncoder().encode(profileEnvelope) else {
            appLog("save: profile encoding failed")
            engine.lastError = tr(
                "无法保存配置，请重试",
                "Could not save the configuration. Please try again."
            )
            profile = lastPersistedProfile
            return false
        }

        let quarantine = replacingConflictedState ? [:] : quarantinedLegacyValues
        switch KeychainStore.saveVault(
            values: split.vault,
            revision: revision,
            quarantinedLegacyValues: quarantine,
            context: persistence.keychain
        ) {
        case .success:
            break
        case .cleanupFailure:
            appLog("save: legacy secure-data cleanup failed")
            persistenceRequiresRecovery = true
            engine.lastError = persistenceRecoveryMessage
            profile = lastPersistedProfile
            return false
        case .keychainFailure(let status):
            appLog("save: secure vault write failed (status=\(status))")
            engine.lastError = tr(
                "无法安全保存连接凭据，请解锁设备后重试",
                "Could not securely save connection credentials. Unlock the device and try again."
            )
            profile = lastPersistedProfile
            return false
        case .encodingFailure:
            appLog("save: secure vault encoding failed")
            engine.lastError = tr("无法保存安全数据，请重试", "Could not save secure data. Please try again.")
            profile = lastPersistedProfile
            return false
        }

        persistence.defaults.set(data, forKey: persistence.profileKey)
        guard persistence.defaults.data(forKey: persistence.profileKey) == data else {
            // Keychain 已经写入新 revision；profile 未确认落盘时必须阻止后续普通保存，
            // 否则会把两代数据继续混合。
            appLog("save: profile envelope write verification failed")
            persistenceRequiresRecovery = true
            engine.lastError = persistenceRecoveryMessage
            profile = lastPersistedProfile
            return false
        }

        persistedRevision = revision
        persistedVault = split.vault
        quarantinedLegacyValues = quarantine
        persistenceRequiresRecovery = false
        lastPersistedProfile = profile
        updatePendingRuntimeChanges()
        return true
    }

    private func updatePendingRuntimeChanges() {
        guard let runningProfileSnapshot else {
            hasPendingRuntimeChanges = false
            return
        }
        hasPendingRuntimeChanges = runtimeProfileData(profile) != runtimeProfileData(runningProfileSnapshot)
    }

    private func runtimeProfileData(_ source: Profile) -> Data? {
        var normalized = source
        for index in normalized.lines.indices {
            normalized.lines[index].verified = false
        }
        for subscriptionIndex in normalized.subscriptions.indices {
            for lineIndex in normalized.subscriptions[subscriptionIndex].lines.indices {
                normalized.subscriptions[subscriptionIndex].lines[lineIndex].verified = false
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(normalized)
    }

    private var persistenceRecoveryMessage: String {
        tr(
            "安全配置版本不一致，已停止使用凭据。请在设置中重新导入或重置配置。",
            "Secure configuration versions do not match. Credentials are disabled; re-import or reset in Settings."
        )
    }

    private func splitSensitiveValues(from source: Profile) -> (sanitized: Profile, vault: [String: String]) {
        var sanitized = source
        var vault: [String: String] = [:]

        func store(_ value: inout String, key: String) {
            guard !value.isEmpty else { return }
            vault[key] = value
            value = ""
        }

        func storeLine(_ line: inout Line, scope: [String]) {
            store(&line.vpnServer, key: Self.vaultKey(scope + ["vpn-server"]))
            store(&line.vpnUsername, key: Self.vaultKey(scope + ["vpn-username"]))
            store(&line.vpnPassword, key: Self.vaultKey(scope + ["vpn-password"]))
            store(&line.trojanServer, key: Self.vaultKey(scope + ["trojan-server"]))
            store(&line.trojanPassword, key: Self.vaultKey(scope + ["trojan"]))
            store(&line.trojanSNI, key: Self.vaultKey(scope + ["trojan-sni"]))
            store(&line.ssServer, key: Self.vaultKey(scope + ["ss-server"]))
            store(&line.ssPassword, key: Self.vaultKey(scope + ["ss"]))
            store(&line.vmessServer, key: Self.vaultKey(scope + ["vmess-server"]))
            store(&line.vmessUUID, key: Self.vaultKey(scope + ["vmess"]))
            store(&line.tailscaleHostname, key: Self.vaultKey(scope + ["tailscale-hostname"]))
            store(&line.tailscaleExitNode, key: Self.vaultKey(scope + ["tailscale-exit-node"]))
        }

        for index in sanitized.ruleSets.indices where sanitized.ruleSets[index].type == "url" {
            let id = sanitized.ruleSets[index].id
            store(&sanitized.ruleSets[index].url, key: Self.vaultKey("rule", id, "url"))
        }
        for index in sanitized.lines.indices {
            let id = sanitized.lines[index].id
            storeLine(&sanitized.lines[index], scope: ["line", id])
        }
        for subscriptionIndex in sanitized.subscriptions.indices {
            let subID = sanitized.subscriptions[subscriptionIndex].id
            store(
                &sanitized.subscriptions[subscriptionIndex].url,
                key: Self.vaultKey("subscription", subID, "url")
            )
            store(
                &sanitized.subscriptions[subscriptionIndex].testURL,
                key: Self.vaultKey("subscription", subID, "test-url")
            )
            for groupIndex in sanitized.subscriptions[subscriptionIndex].proxyGroups.indices {
                store(
                    &sanitized.subscriptions[subscriptionIndex].proxyGroups[groupIndex].url,
                    key: Self.vaultKey("subscription", subID, "group", "\(groupIndex)", "url")
                )
            }
            for ruleIndex in sanitized.subscriptions[subscriptionIndex].rules.indices
            where sanitized.subscriptions[subscriptionIndex].rules[ruleIndex].type.uppercased() == "RULE-SET" {
                store(
                    &sanitized.subscriptions[subscriptionIndex].rules[ruleIndex].value,
                    key: Self.vaultKey("subscription", subID, "rule", "\(ruleIndex)", "url")
                )
            }
            for lineIndex in sanitized.subscriptions[subscriptionIndex].lines.indices {
                let lineID = sanitized.subscriptions[subscriptionIndex].lines[lineIndex].id
                storeLine(
                    &sanitized.subscriptions[subscriptionIndex].lines[lineIndex],
                    scope: ["subscription", subID, "line", lineID]
                )
            }
        }
        return (sanitized, vault)
    }

    private enum StoredProfileState {
        case missing
        case envelope(ProfilePersistenceEnvelope)
        case legacy(Profile)
        case corrupt
    }

    private func loadSaved() {
        let profileState = loadStoredProfile()
        let vaultState = KeychainStore.loadVaultState(context: persistence.keychain)

        switch profileState {
        case .missing:
            lastPersistedProfile = profile
            guard vaultState == .missing else {
                blockPersistence(with: profile, log: "profile missing while secure vault exists or is unreadable")
                return
            }
            appLog("loadSaved: no saved data, using bootstrap")

        case .corrupt:
            blockPersistence(with: profile, log: "profile envelope is corrupt")

        case .envelope(let profileEnvelope):
            var loaded = profileEnvelope.profile
            lastPersistedProfile = loaded
            guard case .available(let vaultEnvelope, let cleanupRequired) = vaultState,
                  vaultEnvelope.revision == profileEnvelope.revision else {
                blockPersistence(with: loaded, log: "profile/vault revision mismatch")
                return
            }

            let containedPlaintext = containsSensitiveValues(loaded)
            restoreStructuredValues(vaultEnvelope.values, into: &loaded)
            profile = loaded
            lastPersistedProfile = loaded
            persistedRevision = profileEnvelope.revision
            persistedVault = vaultEnvelope.values
            quarantinedLegacyValues = vaultEnvelope.quarantinedLegacyValues

            guard !cleanupRequired else {
                blockPersistence(with: loaded, log: "legacy secure-data cleanup is incomplete")
                return
            }
            if containedPlaintext {
                // 早期 envelope 或中断迁移可能仍把账号/URL 留在 UserDefaults；
                // revision 已匹配，可以安全地重写为严格脱敏格式。
                if !save() {
                    // 明文清理失败不能只提示后继续连接，否则敏感字段仍会长期留在
                    // UserDefaults。恢复入口只允许用户显式导入或重置。
                    persistenceRequiresRecovery = true
                    engine.lastError = persistenceRecoveryMessage
                }
            }

        case .legacy(var loaded):
            var legacyValues: [String: String]
            var preexistingQuarantine: [String: String] = [:]
            switch vaultState {
            case .missing:
                switch loadLegacyPerItemValues(for: loaded) {
                case .success(let result):
                    legacyValues = result.values
                    preexistingQuarantine = result.quarantine
                case .failure:
                    blockPersistence(with: loaded, log: "legacy Keychain items are unavailable or corrupt")
                    return
                }
            case .legacy(let values):
                legacyValues = values
            case .available:
                blockPersistence(with: loaded, log: "legacy profile cannot be paired with revisioned vault")
                return
            case .unavailable(let status):
                blockPersistence(with: loaded, log: "secure vault unavailable (status=\(status))")
                return
            case .corrupt:
                blockPersistence(with: loaded, log: "secure vault is corrupt")
                return
            }

            let migration = restoreLegacyValues(legacyValues, into: &loaded)
            preexistingQuarantine.merge(migration.quarantine) { current, _ in current }
            normalizeLegacyProfile(&loaded)
            profile = loaded
            lastPersistedProfile = loaded
            quarantinedLegacyValues = preexistingQuarantine
            persistenceRequiresRecovery = false
            if save(), migration.hadCollision || !preexistingQuarantine.isEmpty {
                engine.lastError = tr(
                    "旧版安全数据存在重名，相关凭据未自动迁移，请重新填写。",
                    "Some legacy secure data was ambiguous and was not migrated. Re-enter the affected credentials."
                )
            }
        }
    }

    private func loadStoredProfile() -> StoredProfileState {
        guard let data = persistence.defaults.data(forKey: persistence.profileKey) else {
            return .missing
        }
        appLog("loadSaved: found \(data.count) bytes")

        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           root["format"] != nil || root["revision"] != nil || root["profile"] != nil {
            guard let envelope = try? JSONDecoder().decode(ProfilePersistenceEnvelope.self, from: data),
                  envelope.isValid else { return .corrupt }
            return .envelope(envelope)
        }

        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .corrupt
        }
        let rewritten = Self.hasLegacyMetaphorKeys(raw) ? Self.rewriteLegacyMetaphorKeys(raw) : raw
        // Profile 的 Codable 兼容层会把缺失字段默认为空。持久化恢复不能因此把任意
        // JSON（例如 `{}` 或一次截断写入）当成合法配置并覆盖现有数据。
        let requiredCollections = ["lines", "rule_sets", "modes", "subscriptions"]
        let hasCurrentShape = requiredCollections.allSatisfy { rewritten[$0] is [Any] }
            && rewritten["active_mode_id"] is String
        if hasCurrentShape,
           let rewrittenData = try? JSONSerialization.data(withJSONObject: rewritten),
           let decoded = try? JSONDecoder().decode(Profile.self, from: rewrittenData) {
            return .legacy(decoded)
        }
        if let migrated = Self.migrate(oldProfile: raw) {
            return .legacy(migrated)
        }
        return .corrupt
    }

    private func blockPersistence(with fallback: Profile, log message: String) {
        appLog("loadSaved: \(message)")
        profile = fallback
        lastPersistedProfile = fallback
        persistenceRequiresRecovery = true
        engine.lastError = persistenceRecoveryMessage
    }

    private func containsSensitiveValues(_ profile: Profile) -> Bool {
        func lineContainsSensitiveValue(_ line: Line) -> Bool {
            !line.vpnServer.isEmpty || !line.vpnUsername.isEmpty || !line.vpnPassword.isEmpty
                || !line.trojanServer.isEmpty || !line.trojanPassword.isEmpty || !line.trojanSNI.isEmpty
                || !line.ssServer.isEmpty || !line.ssPassword.isEmpty
                || !line.vmessServer.isEmpty || !line.vmessUUID.isEmpty
                || !line.tailscaleHostname.isEmpty || !line.tailscaleExitNode.isEmpty
        }
        if profile.lines.contains(where: lineContainsSensitiveValue) { return true }
        if profile.ruleSets.contains(where: { $0.type == "url" && !$0.url.isEmpty }) { return true }
        return profile.subscriptions.contains { subscription in
            !subscription.url.isEmpty || !subscription.testURL.isEmpty
                || subscription.proxyGroups.contains(where: { !$0.url.isEmpty })
                || subscription.rules.contains(where: {
                    $0.type.uppercased() == "RULE-SET" && !$0.value.isEmpty
                })
                || subscription.lines.contains(where: lineContainsSensitiveValue)
        }
    }

    private func restoreStructuredValues(_ vault: [String: String], into profile: inout Profile) {
        func restore(_ value: inout String, key: String) {
            if let stored = vault[key] { value = stored }
        }

        func restoreLine(_ line: inout Line, scope: [String]) {
            restore(&line.vpnServer, key: Self.vaultKey(scope + ["vpn-server"]))
            restore(&line.vpnUsername, key: Self.vaultKey(scope + ["vpn-username"]))
            restore(&line.vpnPassword, key: Self.vaultKey(scope + ["vpn-password"]))
            restore(&line.trojanServer, key: Self.vaultKey(scope + ["trojan-server"]))
            restore(&line.trojanPassword, key: Self.vaultKey(scope + ["trojan"]))
            restore(&line.trojanSNI, key: Self.vaultKey(scope + ["trojan-sni"]))
            restore(&line.ssServer, key: Self.vaultKey(scope + ["ss-server"]))
            restore(&line.ssPassword, key: Self.vaultKey(scope + ["ss"]))
            restore(&line.vmessServer, key: Self.vaultKey(scope + ["vmess-server"]))
            restore(&line.vmessUUID, key: Self.vaultKey(scope + ["vmess"]))
            restore(&line.tailscaleHostname, key: Self.vaultKey(scope + ["tailscale-hostname"]))
            restore(&line.tailscaleExitNode, key: Self.vaultKey(scope + ["tailscale-exit-node"]))
        }

        for index in profile.ruleSets.indices where profile.ruleSets[index].type == "url" {
            restore(&profile.ruleSets[index].url, key: Self.vaultKey("rule", profile.ruleSets[index].id, "url"))
        }
        for index in profile.lines.indices {
            let id = profile.lines[index].id
            restoreLine(&profile.lines[index], scope: ["line", id])
        }
        for subscriptionIndex in profile.subscriptions.indices {
            let subID = profile.subscriptions[subscriptionIndex].id
            restore(&profile.subscriptions[subscriptionIndex].url, key: Self.vaultKey("subscription", subID, "url"))
            restore(
                &profile.subscriptions[subscriptionIndex].testURL,
                key: Self.vaultKey("subscription", subID, "test-url")
            )
            for groupIndex in profile.subscriptions[subscriptionIndex].proxyGroups.indices {
                restore(
                    &profile.subscriptions[subscriptionIndex].proxyGroups[groupIndex].url,
                    key: Self.vaultKey("subscription", subID, "group", "\(groupIndex)", "url")
                )
            }
            for ruleIndex in profile.subscriptions[subscriptionIndex].rules.indices
            where profile.subscriptions[subscriptionIndex].rules[ruleIndex].type.uppercased() == "RULE-SET" {
                restore(
                    &profile.subscriptions[subscriptionIndex].rules[ruleIndex].value,
                    key: Self.vaultKey("subscription", subID, "rule", "\(ruleIndex)", "url")
                )
            }
            for lineIndex in profile.subscriptions[subscriptionIndex].lines.indices {
                let lineID = profile.subscriptions[subscriptionIndex].lines[lineIndex].id
                restoreLine(
                    &profile.subscriptions[subscriptionIndex].lines[lineIndex],
                    scope: ["subscription", subID, "line", lineID]
                )
            }
        }
    }

    private struct LegacyMigrationResult {
        let quarantine: [String: String]
        let hadCollision: Bool
    }

    private func restoreLegacyValues(_ vault: [String: String], into profile: inout Profile) -> LegacyMigrationResult {
        let ownerCounts = legacyOwnerCounts(for: profile)
        let ambiguousKeys = Set(ownerCounts.compactMap { key, count in
            count > 1 && vault[key] != nil ? key : nil
        })
        var quarantine = Dictionary(uniqueKeysWithValues: ambiguousKeys.compactMap { key in
            vault[key].map { (key, $0) }
        })

        func restore(_ value: inout String, structuredKey: String, legacyKey: String?) {
            if let stored = vault[structuredKey] {
                value = stored
                return
            }
            guard value.isEmpty,
                  let legacyKey,
                  !ambiguousKeys.contains(legacyKey),
                  let stored = vault[legacyKey] else { return }
            value = stored
        }

        for index in profile.ruleSets.indices where profile.ruleSets[index].type == "url" {
            let id = profile.ruleSets[index].id
            restore(
                &profile.ruleSets[index].url,
                structuredKey: Self.vaultKey("rule", id, "url"),
                legacyKey: "rule-\(id)-url"
            )
        }
        for index in profile.lines.indices {
            let id = profile.lines[index].id
            restore(
                &profile.lines[index].vpnUsername,
                structuredKey: Self.vaultKey("line", id, "vpn-username"),
                legacyKey: nil
            )
            restore(
                &profile.lines[index].vpnPassword,
                structuredKey: Self.vaultKey("line", id, "vpn-password"),
                legacyKey: "\(id)-vpn"
            )
            for (suffix, keyPath) in [
                ("trojan", \Line.trojanPassword),
                ("ss", \Line.ssPassword),
                ("vmess", \Line.vmessUUID),
            ] {
                restore(
                    &profile.lines[index][keyPath: keyPath],
                    structuredKey: Self.vaultKey("line", id, suffix),
                    legacyKey: "\(id)-\(suffix)"
                )
            }
        }
        for subscriptionIndex in profile.subscriptions.indices {
            let subID = profile.subscriptions[subscriptionIndex].id
            restore(
                &profile.subscriptions[subscriptionIndex].url,
                structuredKey: Self.vaultKey("subscription", subID, "url"),
                legacyKey: "subscription-\(subID)-url"
            )
            restore(
                &profile.subscriptions[subscriptionIndex].testURL,
                structuredKey: Self.vaultKey("subscription", subID, "test-url"),
                legacyKey: "subscription-\(subID)-test-url"
            )
            for groupIndex in profile.subscriptions[subscriptionIndex].proxyGroups.indices {
                restore(
                    &profile.subscriptions[subscriptionIndex].proxyGroups[groupIndex].url,
                    structuredKey: Self.vaultKey("subscription", subID, "group", "\(groupIndex)", "url"),
                    legacyKey: "subscription-\(subID)-group-\(groupIndex)-url"
                )
            }
            for ruleIndex in profile.subscriptions[subscriptionIndex].rules.indices
            where profile.subscriptions[subscriptionIndex].rules[ruleIndex].type.uppercased() == "RULE-SET" {
                restore(
                    &profile.subscriptions[subscriptionIndex].rules[ruleIndex].value,
                    structuredKey: Self.vaultKey("subscription", subID, "rule", "\(ruleIndex)", "url"),
                    legacyKey: "subscription-\(subID)-rule-\(ruleIndex)-url"
                )
            }
            for lineIndex in profile.subscriptions[subscriptionIndex].lines.indices {
                let lineID = profile.subscriptions[subscriptionIndex].lines[lineIndex].id
                let prefix = "\(subID)-\(lineID)"
                restore(
                    &profile.subscriptions[subscriptionIndex].lines[lineIndex].vpnUsername,
                    structuredKey: Self.vaultKey("subscription", subID, "line", lineID, "vpn-username"),
                    legacyKey: nil
                )
                restore(
                    &profile.subscriptions[subscriptionIndex].lines[lineIndex].vpnPassword,
                    structuredKey: Self.vaultKey("subscription", subID, "line", lineID, "vpn-password"),
                    legacyKey: "\(prefix)-vpn"
                )
                for (suffix, keyPath) in [
                    ("trojan", \Line.trojanPassword),
                    ("ss", \Line.ssPassword),
                    ("vmess", \Line.vmessUUID),
                ] {
                    restore(
                        &profile.subscriptions[subscriptionIndex].lines[lineIndex][keyPath: keyPath],
                        structuredKey: Self.vaultKey("subscription", subID, "line", lineID, suffix),
                        legacyKey: "\(prefix)-\(suffix)"
                    )
                }
            }
        }

        // 未识别但已明确判定冲突的值只进隔离区，永不绑定到运行线路。
        for key in ambiguousKeys where quarantine[key] == nil {
            quarantine[key] = vault[key]
        }
        return LegacyMigrationResult(quarantine: quarantine, hadCollision: !ambiguousKeys.isEmpty)
    }

    private func legacyOwnerCounts(for profile: Profile) -> [String: Int] {
        var owners: [String: Int] = [:]
        func register(_ key: String) { owners[key, default: 0] += 1 }

        for line in profile.lines {
            for suffix in ["vpn", "trojan", "ss", "vmess"] { register("\(line.id)-\(suffix)") }
        }
        for rule in profile.ruleSets where rule.type == "url" { register("rule-\(rule.id)-url") }
        for subscription in profile.subscriptions {
            let subID = subscription.id
            register("subscription-\(subID)-url")
            register("subscription-\(subID)-test-url")
            for index in subscription.proxyGroups.indices {
                register("subscription-\(subID)-group-\(index)-url")
            }
            for index in subscription.rules.indices
            where subscription.rules[index].type.uppercased() == "RULE-SET" {
                register("subscription-\(subID)-rule-\(index)-url")
            }
            for line in subscription.lines {
                for suffix in ["vpn", "trojan", "ss", "vmess"] {
                    register("\(subID)-\(line.id)-\(suffix)")
                }
            }
        }
        return owners
    }

    private enum LegacyItemMigrationError: Error {
        case unavailable
    }

    private func loadLegacyPerItemValues(
        for profile: Profile
    ) -> Result<(values: [String: String], quarantine: [String: String]), LegacyItemMigrationError> {
        var values: [String: String] = [:]
        var quarantine: [String: String] = [:]
        let ownerCounts = legacyOwnerCounts(for: profile)

        func readAccounts(
            _ accounts: [String],
            structuredKey: String,
            legacyOwnerKey: String
        ) -> Bool {
            var found: [(String, String)] = []
            for account in accounts {
                switch KeychainStore.loadLegacyItem(account: account, context: persistence.keychain) {
                case .missing:
                    continue
                case .available(let value):
                    if !value.isEmpty { found.append((account, value)) }
                case .unavailable, .corrupt:
                    return false
                }
            }
            let distinct = Set(found.map(\.1))
            if ownerCounts[legacyOwnerKey, default: 0] > 1 {
                // 旧 account 把多个用户可控 ID 用 `-` 拼在一起；同一个 account 可能
                // 同时属于两条线路。先判冲突再读取，只保留到隔离区，绝不自动绑定。
                for (account, value) in found { quarantine["legacy-account:\(account)"] = value }
            } else if distinct.count == 1, let value = distinct.first {
                values[structuredKey] = value
            } else if distinct.count > 1 {
                for (account, value) in found { quarantine["legacy-account:\(account)"] = value }
            }
            return true
        }

        for line in profile.lines {
            for (suffix, structuredSuffix) in [
                ("vpn", "vpn-password"), ("trojan", "trojan"), ("ss", "ss"), ("vmess", "vmess"),
            ] {
                let accounts = [keychainPrefix, "xdial-port-", "xdial-exit-"].map {
                    $0 + line.id + "-" + suffix
                }
                guard readAccounts(
                    accounts,
                    structuredKey: Self.vaultKey("line", line.id, structuredSuffix),
                    legacyOwnerKey: "\(line.id)-\(suffix)"
                ) else {
                    return .failure(.unavailable)
                }
            }
        }
        for subscription in profile.subscriptions {
            for line in subscription.lines {
                for (suffix, structuredSuffix) in [
                    ("vpn", "vpn-password"), ("trojan", "trojan"), ("ss", "ss"), ("vmess", "vmess"),
                ] {
                    let account = subKeychainPrefix + subscription.id + "-" + line.id + "-" + suffix
                    guard readAccounts(
                        [account],
                        structuredKey: Self.vaultKey(
                            "subscription", subscription.id, "line", line.id, structuredSuffix
                        ),
                        legacyOwnerKey: "\(subscription.id)-\(line.id)-\(suffix)"
                    ) else {
                        return .failure(.unavailable)
                    }
                }
            }
        }
        return .success((values, quarantine))
    }

    private func normalizeLegacyProfile(_ profile: inout Profile) {
        for index in profile.lines.indices {
            if profile.lines[index].type == "ss" { profile.lines[index].type = "shadowsocks" }
            if profile.lines[index].type == "vpn", profile.lines[index].name == "VPN" {
                profile.lines[index].name = "AnyConnect"
            }
        }
        for subscriptionIndex in profile.subscriptions.indices {
            for lineIndex in profile.subscriptions[subscriptionIndex].lines.indices
            where profile.subscriptions[subscriptionIndex].lines[lineIndex].type == "ss" {
                profile.subscriptions[subscriptionIndex].lines[lineIndex].type = "shadowsocks"
            }
        }
    }

    // MARK: - Legacy 命名 key 迁移（比喻命名 → 正式命名）
    //
    // 只做「精确 key 匹配」的重写，绝不做字符串子串替换 —— 否则会误伤 trojan_port、
    // default_subscription_id、vpn_server 这类含 "port"/"cargo"/"cruise" 子串的合法字段。

    /// 判断字典里是否存在任一比喻命名时代的顶层/内嵌 key（用于决定是否需要重写）。
    private static func hasLegacyMetaphorKeys(_ dict: [String: Any]) -> Bool {
        if dict["ports"] != nil || dict["cargoes"] != nil || dict["cruises"] != nil
            || dict["active_cruise_id"] != nil {
            return true
        }
        // 内嵌：cruises[].bindings[].{cargo_id,port_id}、cruises[].default_port_id、
        // subscriptions[].ports。逐层精确探测。
        if let cruises = dict["cruises"] as? [[String: Any]] {
            for c in cruises {
                if c["default_port_id"] != nil { return true }
                if let bs = c["bindings"] as? [[String: Any]] {
                    for b in bs where b["cargo_id"] != nil || b["port_id"] != nil { return true }
                }
            }
        }
        if let subs = dict["subscriptions"] as? [[String: Any]] {
            for s in subs where s["ports"] != nil { return true }
        }
        return false
    }

    /// 把一份比喻命名的 profile 字典按对照表精确重写成正式命名字典。
    /// 顶层：ports→lines、cargoes→rule_sets、cruises→modes、active_cruise_id→active_mode_id。
    /// mode 内嵌：default_port_id→default_line_id；binding 内嵌：cargo_id→rule_set_id、port_id→line_id。
    /// subscription 内嵌：ports→lines（其内部 Line 字段如 trojan_port 保持不变）。
    private static func rewriteLegacyMetaphorKeys(_ dict: [String: Any]) -> [String: Any] {
        var out = dict

        // 顶层 lines
        if let v = out.removeValue(forKey: "ports") { out["lines"] = v }
        // 顶层 rule_sets
        if let v = out.removeValue(forKey: "cargoes") { out["rule_sets"] = v }
        // 顶层 active_mode_id
        if let v = out.removeValue(forKey: "active_cruise_id") { out["active_mode_id"] = v }

        // 顶层 modes（含其内嵌 bindings / default_port_id 重写）
        if let cruises = out.removeValue(forKey: "cruises") as? [[String: Any]] {
            out["modes"] = cruises.map { rewriteLegacyMode($0) }
        } else if let cruises = out["cruises"] {
            // 类型不是 [[String:Any]]（异常数据）也搬过去，避免丢数据
            out.removeValue(forKey: "cruises")
            out["modes"] = cruises
        }

        // subscriptions 内嵌 ports → lines
        if let subs = out["subscriptions"] as? [[String: Any]] {
            out["subscriptions"] = subs.map { sub -> [String: Any] in
                var ns = sub
                if let v = ns.removeValue(forKey: "ports") { ns["lines"] = v }
                return ns
            }
        }

        return out
    }

    /// 重写单个 mode 字典：default_port_id → default_line_id，bindings 逐条重写。
    private static func rewriteLegacyMode(_ dict: [String: Any]) -> [String: Any] {
        var m = dict
        if let v = m.removeValue(forKey: "default_port_id") { m["default_line_id"] = v }
        if let bindings = m["bindings"] as? [[String: Any]] {
            m["bindings"] = bindings.map { b -> [String: Any] in
                var nb = b
                if let v = nb.removeValue(forKey: "cargo_id") { nb["rule_set_id"] = v }
                if let v = nb.removeValue(forKey: "port_id") { nb["line_id"] = v }
                return nb
            }
        }
        return m
    }

    /// 把旧格式 profile (v0.2: exits/rules/strategies) 迁移到新格式 (lines/rule_sets/modes)
    static func migrate(oldProfile: [String: Any]) -> Profile? {
        var p = Profile()
        // 旧版本的 v0.2 里是 exits/rules/strategies
        if let oldExits = oldProfile["exits"] as? [[String: Any]] {
            p.lines = oldExits.compactMap { dict -> Line? in
                guard let data = try? JSONSerialization.data(withJSONObject: dict),
                      let line = try? JSONDecoder().decode(Line.self, from: data) else { return nil }
                return line
            }
        }
        if let oldRules = oldProfile["rules"] as? [[String: Any]] {
            p.ruleSets = oldRules.compactMap { dict -> RuleSet? in
                guard let data = try? JSONSerialization.data(withJSONObject: dict),
                      let c = try? JSONDecoder().decode(RuleSet.self, from: data) else { return nil }
                return c
            }
        }
        if let oldStrategies = oldProfile["strategies"] as? [[String: Any]] {
            p.modes = oldStrategies.compactMap { dict -> Mode? in
                // 旧 strategy.bindings 用 rule_id/exit_id；旧 default_exit_id
                var fixed = dict
                if let oldBindings = dict["bindings"] as? [[String: Any]] {
                    fixed["bindings"] = oldBindings.map { b -> [String: Any] in
                        var nb = b
                        if let r = b["rule_id"] { nb["rule_set_id"] = r; nb.removeValue(forKey: "rule_id") }
                        if let e = b["exit_id"] { nb["line_id"] = e; nb.removeValue(forKey: "exit_id") }
                        return nb
                    }
                }
                if let de = dict["default_exit_id"] {
                    fixed["default_line_id"] = de
                    fixed.removeValue(forKey: "default_exit_id")
                }
                guard let data = try? JSONSerialization.data(withJSONObject: fixed),
                      let c = try? JSONDecoder().decode(Mode.self, from: data) else { return nil }
                return c
            }
        }
        if let active = oldProfile["active_strategy_id"] as? String {
            p.activeModeID = active
        }
        return p.lines.isEmpty && p.ruleSets.isEmpty && p.modes.isEmpty ? nil : p
    }

    func refreshTunnelProfileStatus() {
        guard let tunnelManager else {
            helperInstalled = false
            return
        }
        tunnelManager.refreshProfileStatus { [weak self] installed in
            Task { @MainActor in
                self?.helperInstalled = installed
            }
        }
    }

    // MARK: - Subscription Management

    func addSubscription(name: String, url: String, format: String, strategy: String,
                         lines: [Line], proxyGroups: [SubProxyGroup] = [], rules: [SubRule] = []) {
        guard canMutateConfiguration else { return }
        let sub = Subscription(
            id: "sub-" + String(UUID().uuidString.prefix(8)).lowercased(),
            name: name,
            url: url,
            format: format,
            strategy: strategy,
            lines: lines,
            proxyGroups: proxyGroups,
            rules: rules
        )
        profile.subscriptions.append(sub)
        save()
    }

    func updateSubscription(_ id: String, with result: ParseResult) {
        guard canMutateConfiguration,
              let idx = profile.subscriptions.firstIndex(where: { $0.id == id }) else { return }
        let previousDefaultSelection = profile.subscriptions[idx].selected
        var previousSelections: [String: String] = [:]
        for group in profile.subscriptions[idx].proxyGroups where previousSelections[group.name] == nil {
            previousSelections[group.name] = group.selected
        }
        var groups = result.proxyGroups ?? []
        for groupIndex in groups.indices {
            guard let selected = previousSelections[groups[groupIndex].name],
                  groups[groupIndex].proxies.contains(selected) else { continue }
            groups[groupIndex].selected = selected
        }
        profile.subscriptions[idx].lines = result.lines
        profile.subscriptions[idx].proxyGroups = groups
        profile.subscriptions[idx].selected = result.lines.contains(where: {
            $0.name == previousDefaultSelection
        }) ? previousDefaultSelection : ""
        profile.subscriptions[idx].rules = result.rules ?? []
        profile.subscriptions[idx].updatedAt = Int(Date().timeIntervalSince1970)
        save()  // vault 整体覆盖，旧条目自然消失
    }

    @discardableResult
    func updateSubscriptionSelection(subscriptionID: String, groupName: String, selected: String) -> Bool {
        guard canChangeSubscriptionSelection,
              let subscriptionIndex = profile.subscriptions.firstIndex(where: { $0.id == subscriptionID }) else {
            return false
        }
        if groupName == "__default__" {
            guard profile.subscriptions[subscriptionIndex].proxyGroups.isEmpty,
                  profile.subscriptions[subscriptionIndex].lines.contains(where: { $0.name == selected }) else {
                return false
            }
            profile.subscriptions[subscriptionIndex].selected = selected
            return save()
        }
        guard let groupIndex = profile.subscriptions[subscriptionIndex].proxyGroups.firstIndex(where: {
                  $0.name == groupName
              }),
              profile.subscriptions[subscriptionIndex].proxyGroups[groupIndex].proxies.contains(selected) else {
            return false
        }
        profile.subscriptions[subscriptionIndex].proxyGroups[groupIndex].selected = selected
        return save()
    }

    func markSubscriptionSelectionApplied(subscriptionID: String, groupName: String, selected: String) {
        guard var snapshot = runningProfileSnapshot,
              let subscriptionIndex = snapshot.subscriptions.firstIndex(where: { $0.id == subscriptionID }) else {
            return
        }
        if groupName == "__default__" {
            snapshot.subscriptions[subscriptionIndex].selected = selected
            runningProfileSnapshot = snapshot
            updatePendingRuntimeChanges()
            return
        }
        guard let groupIndex = snapshot.subscriptions[subscriptionIndex].proxyGroups.firstIndex(where: {
            $0.name == groupName
        }) else { return }
        snapshot.subscriptions[subscriptionIndex].proxyGroups[groupIndex].selected = selected
        runningProfileSnapshot = snapshot
        updatePendingRuntimeChanges()
    }

    func selectSubscriptionMember(
        subscriptionID: String,
        groupName: String,
        selected: String,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        guard canChangeSubscriptionSelection else {
            completion?(.failure(TunnelRuntimeError.unavailable))
            return
        }
        guard updateSubscriptionSelection(
            subscriptionID: subscriptionID,
            groupName: groupName,
            selected: selected
        ) else {
            completion?(.failure(TunnelRuntimeError.missingTarget))
            return
        }
        guard isConnected else {
            completion?(.success(()))
            return
        }
        engine.selectSubscriptionMember(
            profileJSON: buildProfileJSON(),
            subscriptionID: subscriptionID,
            groupName: groupName,
            memberName: selected
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.markSubscriptionSelectionApplied(
                    subscriptionID: subscriptionID,
                    groupName: groupName,
                    selected: selected
                )
            case .failure(let error):
                self.engine.lastError = userFacingConnectionText(error.localizedDescription)
            }
            completion?(result)
        }
    }

    /// Selector choices are runtime controls, not topology edits. They remain
    /// available for an established tunnel and are persisted as the next
    /// connection's default; all structural subscription edits stay locked.
    private var canChangeSubscriptionSelection: Bool {
        !isBusy && (!hasActiveTunnel || isConnected)
    }

    func testSubscriptionNode(
        subscriptionID: String,
        nodeID: String,
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        guard isConnected,
              let subscription = profile.subscriptions.first(where: { $0.id == subscriptionID }),
              subscription.lines.contains(where: { $0.id == nodeID }) else {
            completion(.failure(TunnelRuntimeError.unavailable))
            return
        }
        engine.testSubscriptionNode(
            profileJSON: buildProfileJSON(),
            subscriptionID: subscriptionID,
            nodeID: nodeID,
            testURL: subscription.testURL,
            completion: completion
        )
    }

    func probeSubscriptionNodeAddress(
        subscriptionID: String,
        nodeID: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard isConnected,
              let subscription = profile.subscriptions.first(where: { $0.id == subscriptionID }),
              subscription.lines.contains(where: { $0.id == nodeID }) else {
            completion(.failure(TunnelRuntimeError.unavailable))
            return
        }
        engine.probeSubscriptionNodeAddress(
            profileJSON: buildProfileJSON(),
            subscriptionID: subscriptionID,
            nodeID: nodeID,
            completion: completion
        )
    }

    static func tailscaleEndpointTag(lineID: String) -> String {
        "tailscale-" + lineID
    }

    var canQueryTailscaleRuntime: Bool {
        isConnected || requiresUserAction
    }

    func isTailscaleLineGeneratedByRunningProfile(_ lineID: String) -> Bool {
        guard let runningProfileSnapshot else { return false }
        // Keep this identical to core/config: every enabled Tailscale line is a
        // generated global endpoint, even without an explicit mode binding.
        return runningProfileSnapshot.lines.contains {
            $0.id == lineID && $0.enabled && $0.type == "tailscale"
        }
    }

    /// Tailscale 的 LocalAPI 只存在于正在运行的 Packet Tunnel 内。
    /// 主 App 不自行启动第二份实例，只向当前连接已注册的 endpoint 查询脱敏状态。
    func refreshTailscaleStatus(
        lineID: String,
        completion: @escaping (Result<TailscaleRuntimeStatus, Error>) -> Void
    ) {
        guard canQueryTailscaleRuntime else {
            completion(.failure(TunnelRuntimeError.unavailable))
            return
        }
        guard isTailscaleLineGeneratedByRunningProfile(lineID) else {
            completion(.failure(TunnelRuntimeError.missingTarget))
            return
        }
        engine.tailscaleStatus(
            endpointTag: Self.tailscaleEndpointTag(lineID: lineID),
            completion: completion
        )
    }

    /// Exit-node selection is a persisted runtime choice. It may change while
    /// fully connected so the UI can offer an explicit reconnect-to-apply
    /// workflow, but remains locked while the tunnel is starting/stopping or
    /// waiting for first-time Tailscale sign-in.
    @discardableResult
    func updateTailscaleExitSelection(lineID: String, selected: String) -> Bool {
        guard !isBusy,
              !hasActiveTunnel || isConnected,
              let index = profile.lines.firstIndex(where: {
                  $0.id == lineID && $0.enabled && $0.type == "tailscale"
              }) else { return false }
        guard profile.lines[index].tailscaleExitNode != selected else { return true }
        profile.lines[index].tailscaleExitNode = selected
        profile.lines[index].verified = false
        return save()
    }

    func deleteSubscription(_ id: String) {
        guard canMutateConfiguration else { return }
        profile.subscriptions.removeAll { $0.id == id }
        // 保留模式里的悬空引用，让连接前校验明确报错；静默删除绑定或改为直连会改变路由语义。
        save()
    }

    // MARK: - Mode Management

    func createMode(from template: ModeTemplate, named name: String) {
        guard canMutateConfiguration, canCreateMode(from: template) else { return }
        let direct = profile.lines.first(where: { $0.type == "direct" && isUsableRouteLine($0) })?.id ?? ""
        let vpn = profile.lines.first(where: { $0.type == "vpn" && isUsableRouteLine($0) })?.id ?? ""
        let ss = profile.lines.first(where: {
            $0.type != "direct" && $0.type != "vpn" && isUsableRouteLine($0)
        })?.id ?? ""

        let manualRules = profile.ruleSets
            .filter { $0.type == "manual" && $0.enabled && !$0.isConnectivityTestRule }
            .map { $0.id }
        let gfwRule = profile.ruleSets
            .first(where: { $0.type == "url" && $0.enabled })?.id ?? ""

        var s: Mode
        switch template {
        case .overseas:
            s = Profile.templateOverseas(
                ruleSetIDs: manualRules,
                vpnLineID: vpn,
                directLineID: direct
            )
        case .domestic:
            s = Profile.templateDomestic(
                ruleSetIDs: manualRules,
                gfwRuleSetID: gfwRule,
                vpnLineID: vpn,
                directLineID: direct
            )
        case .domesticSS:
            s = Profile.templateDomesticSS(
                ruleSetIDs: manualRules,
                gfwRuleSetID: gfwRule,
                vpnLineID: vpn,
                ssLineID: ss,
                directLineID: direct
            )
        case .blank:
            s = Mode(id: UUID().uuidString, name: name, defaultLineID: direct)
        }
        s.name = name
        profile.modes.append(s)
        if profile.activeModeID.isEmpty {
            profile.activeModeID = s.id
        }
        save()
    }

    func deleteMode(_ s: Mode) {
        guard canMutateConfiguration else { return }
        profile.modes.removeAll { $0.id == s.id }
        if profile.activeModeID == s.id {
            profile.activeModeID = profile.modes.first?.id ?? ""
        }
        save()
    }

    // MARK: - Build profile JSON

    func buildProfileJSON() -> String {
        guard let data = try? JSONEncoder().encode(profile) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - Noop engine (占位默认引擎)
//
// 在真实引擎层注入之前，AppState 需要一个满足 TunnelEngine 的默认引擎，
// 保证状态机语义完整（能读 status、start/stop 只切状态、不做真实拨号）。
// 并行引擎任务写好后，用 AppState(engine:) 注入真实引擎替换它。
@MainActor
final class NoopTunnelEngine: TunnelEngine, ObservableObject {
    @Published private(set) var status: String = "disconnected"
    @Published var lastError: String?
    @Published var dataPathSummary: String?
    var statusPublisher: AnyPublisher<String, Never> { $status.eraseToAnyPublisher() }

    var isConnected: Bool { status == "connected" }
    var isBusy: Bool { status == "connecting" || status == "disconnecting" || status == "reconnecting" }

    func start(profileJSON: String) {
        // TODO: 真实引擎接入后由具体实现完成拨号；占位仅记录调用点。
        appLog("NoopTunnelEngine.start called (\(profileJSON.count) bytes) — no real engine bound")
    }

    func stop() {
        appLog("NoopTunnelEngine.stop called — no real engine bound")
    }

    func syncStatus() {
        // 占位：真实引擎会查询扩展/NEVPNManager 的当前状态并回填 status。
    }
}

enum ModeTemplate: String, CaseIterable {
    case overseas, domestic, domesticSS, blank

    var displayName: String {
        switch self {
        case .overseas: return "海外"
        case .domestic: return "国内"
        case .domesticSS: return "国内+SS"
        case .blank: return "空白"
        }
    }
}
