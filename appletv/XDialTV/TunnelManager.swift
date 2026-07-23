import Combine
import Foundation
import Libbox
import Security
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
private let kMaxNEConfigBytes = 2 * 1024 * 1024

/// NetworkExtension 的类型(NETunnelProviderManager 等)没有 Sendable 审计。这里的用法
/// 是"系统完成回调只调一次、拿到就立刻在同一步用掉",不存在真实并发访问——
/// 用这个 box 显式告诉 Swift 6 的 sending 检查器信任这一点,而不是引入 Task 或改变
/// 回调时序。仅用于跨越 assumeIsolated 边界搬运这几个已知安全的值。
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
}

final class OneShotContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var resolved = false
    private var resolvedValue: Value?

    init(_ continuation: CheckedContinuation<Value, Never>? = nil) {
        self.continuation = continuation
    }

    func install(_ continuation: CheckedContinuation<Value, Never>) {
        lock.lock()
        if resolved {
            let value = resolvedValue
            lock.unlock()
            if let value {
                continuation.resume(returning: value)
            }
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ value: Value) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        resolvedValue = value
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

/// 一次启动只允许一个活跃 token。状态组件只负责原子地登记/领取 completion，
/// completion 在状态修改完成后由调用方执行，避免回调重入时触发独占访问冲突。
struct TunnelStartOperationState {
    typealias Completion = @Sendable (Result<Void, Error>) -> Void

    private var activeID: UUID?
    private var activeCompletion: Completion?

    mutating func begin(completion: @escaping Completion) -> (id: UUID, cancelled: Completion?) {
        let cancelled = activeCompletion
        let id = UUID()
        activeID = id
        activeCompletion = completion
        return (id, cancelled)
    }

    func isCurrent(_ id: UUID) -> Bool {
        activeID == id
    }

    mutating func finish(_ id: UUID) -> Completion? {
        guard activeID == id else { return nil }
        let completion = activeCompletion
        activeID = nil
        activeCompletion = nil
        return completion
    }

    mutating func cancel() -> Completion? {
        let completion = activeCompletion
        activeID = nil
        activeCompletion = nil
        return completion
    }
}

/// LibboxGenerateNEConfig 会重建 App Group 内的规则目录，所有启动代际必须在同一条
/// FIFO 队列执行。取消只废弃结果，不能中断正在执行的 Go 调用。
final class TunnelConfigGenerationQueue: @unchecked Sendable {
    private let queue: DispatchQueue

    init(label: String = "com.kafeifei.xdial.config-generation") {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func submit(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }
}

struct TunnelAcceptanceTarget: Codable, Sendable, Equatable {
    let tag: String
    let label: String
}

struct TunnelAcceptancePlan: Codable, Sendable, Equatable {
    let requiresAnyConnect: Bool
    /// nil 只允许用于真正的单出口 Direct 模式。非 nil 时，它是配置页可见的
    /// 1.1.1.1 锁定规则所绑定的确定性非 Direct outbound。
    let currentRouteTag: String?
    let targets: [TunnelAcceptanceTarget]
    /// Go generator emits every enabled Tailscale line as a global endpoint
    /// because preferred_by/accept_routes may affect routing without a mode
    /// binding. Readiness must cover that exact generated endpoint set.
    let generatedTailscaleTargets: [TunnelAcceptanceTarget]

    static func make(
        profile: Profile,
        profileJSON: String,
        anyConnect: AnyConnectCredentials?
    ) throws -> TunnelAcceptancePlan {
        guard let mode = profile.modes.first(where: { $0.id == profile.activeModeID }) else {
            throw NSError(domain: "XDial", code: -6,
                userInfo: [NSLocalizedDescriptionKey: "当前模式不可用"])
        }

        struct Catalog: Decodable {
            struct Entry: Decodable {
                struct Group: Decodable {
                    let tag: String
                }
                let id: String
                let groups: [Group]
            }
            let subscriptions: [Entry]
        }

        let usesSubscriptions = !mode.defaultSubscriptionID.isEmpty
            || mode.bindings.contains { !$0.subscriptionID.isEmpty }
        var subscriptionTags: [String: String] = [:]
        if usesSubscriptions {
            var catalogError: NSError?
            let rawCatalog = LibboxSubscriptionRuntimeCatalog(profileJSON, &catalogError)
            if let catalogError { throw catalogError }
            guard let data = rawCatalog.data(using: .utf8),
                  let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else {
                throw TunnelRuntimeError.invalidCatalog
            }
            for subscription in catalog.subscriptions {
                if let tag = subscription.groups.first?.tag, !tag.isEmpty {
                    subscriptionTags[subscription.id] = tag
                }
            }
        }

        func lineTag(_ lineID: String) -> String? {
            guard let line = profile.lines.first(where: { $0.id == lineID && $0.enabled }) else {
                return nil
            }
            switch line.type {
            case "direct": return "direct"
            case "vpn": return "vpn"
            case "tailscale": return "tailscale-" + line.id
            case "trojan", "shadowsocks", "ss", "vmess": return "proxy-" + line.id
            default: return nil
            }
        }

        func targetTag(lineID: String, subscriptionID: String) -> String? {
            if !subscriptionID.isEmpty {
                return subscriptionTags[subscriptionID]
            }
            return lineTag(lineID)
        }

        func publicTargetTag(lineID: String, subscriptionID: String) -> String? {
            if !subscriptionID.isEmpty {
                return subscriptionTags[subscriptionID]
            }
            guard let line = profile.lines.first(where: {
                $0.id == lineID && $0.enabled
            }) else { return nil }
            if line.type == "tailscale", line.tailscaleExitNode.isEmpty {
                return nil
            }
            return lineTag(lineID)
        }

        let requiresAnyConnect = anyConnect != nil
        let generatedTailscaleTargets: [TunnelAcceptanceTarget] = profile.lines.compactMap {
            line -> TunnelAcceptanceTarget? in
            guard line.enabled, line.type == "tailscale" else { return nil }
            return TunnelAcceptanceTarget(
                tag: "tailscale-" + line.id,
                label: line.name.isEmpty ? "Tailscale" : line.name
            )
        }
        guard targetTag(
            lineID: mode.defaultLineID,
            subscriptionID: mode.defaultSubscriptionID
        ) != nil else {
            throw NSError(domain: "XDial", code: -6,
                userInfo: [NSLocalizedDescriptionKey: "当前模式的默认出口不可用"])
        }

        let expectedOutboundBinding = profile.connectivityOutboundBinding(for: mode)
        let configuredOutboundBinding = mode.bindings.first {
            $0.ruleSetID == RuleSet.connectivityOutboundID
        }
        guard expectedOutboundBinding?.lineID == configuredOutboundBinding?.lineID,
              expectedOutboundBinding?.subscriptionID == configuredOutboundBinding?.subscriptionID else {
            throw NSError(domain: "XDial", code: -6,
                userInfo: [NSLocalizedDescriptionKey: "非 Direct 连接验收规则绑定不正确"])
        }
        let currentRouteTag = configuredOutboundBinding.flatMap {
            targetTag(lineID: $0.lineID, subscriptionID: $0.subscriptionID)
        }
        if currentRouteTag == "direct" {
            throw NSError(domain: "XDial", code: -6,
                userInfo: [NSLocalizedDescriptionKey: "非 Direct 连接验收规则不能绑定 Direct"])
        }

        var targets: [TunnelAcceptanceTarget] = []
        var seen = Set<String>()
        func addTarget(lineID: String, subscriptionID: String) {
            guard let tag = publicTargetTag(
                lineID: lineID,
                subscriptionID: subscriptionID
            ),
                  seen.insert(tag).inserted else { return }
            let label: String
            if !subscriptionID.isEmpty {
                label = profile.subscriptions.first(where: { $0.id == subscriptionID })?.name
                    ?? subscriptionID
            } else {
                let line = profile.lines.first(where: { $0.id == lineID })
                label = line?.type == "vpn" ? "AnyConnect" : (line?.name ?? lineID)
            }
            targets.append(TunnelAcceptanceTarget(tag: tag, label: label))
        }
        addTarget(lineID: mode.defaultLineID, subscriptionID: mode.defaultSubscriptionID)
        for binding in mode.bindings {
            guard profile.ruleSets.first(where: { $0.id == binding.ruleSetID })?.enabled == true else {
                continue
            }
            addTarget(lineID: binding.lineID, subscriptionID: binding.subscriptionID)
        }
        guard !targets.isEmpty else {
            throw NSError(domain: "XDial", code: -6,
                userInfo: [NSLocalizedDescriptionKey: "当前模式没有可验收的出口"])
        }
        if targets.count > 1 && currentRouteTag == nil {
            throw NSError(domain: "XDial", code: -6,
                userInfo: [NSLocalizedDescriptionKey: "多出口模式缺少非 Direct 路由验收目标"])
        }
        if targets.count == 1 && targets[0].tag != "direct" {
            throw NSError(domain: "XDial", code: -6,
                userInfo: [NSLocalizedDescriptionKey: "单出口验收只允许 Direct 模式"])
        }
        return TunnelAcceptancePlan(
            requiresAnyConnect: requiresAnyConnect,
            currentRouteTag: currentRouteTag,
            targets: targets,
            generatedTailscaleTargets: generatedTailscaleTargets
        )
    }
}

/// 从主 App 发起探测，流量会像 Safari/其他 App 一样完整经过系统路由 → packetFlow →
/// sing-box → 实际出口。扩展进程内部自拨成功不能替代这条端到端断言。
enum DataPathProbe {
    private static let configuredDirectURLs = [
        URL(string: "https://1.0.0.1/cdn-cgi/trace")!,
    ]
    private static let hostnameURLs = [
        URL(string: "https://www.apple.com/library/test/success.html")!,
    ]
    private static let configuredAnyConnectURLs = [
        URL(string: "https://1.1.1.1/cdn-cgi/trace")!,
    ]

    struct Result: Sendable {
        let directLineEgressIP: String?
        let anyConnectLineEgressIP: String?
        let routedDirectEgressIP: String?
        let routedAnyConnectEgressIP: String?
        let hostnameOK: Bool
        let routingEvidenceOK: Bool

        var linesReachable: Bool {
            directLineEgressIP != nil && anyConnectLineEgressIP != nil
        }

        /// 公网出口地址只做展示，不做路由判定：同一线路可能使用多个 NAT 出口，
        /// 两条线路也可能恰好共用一个公网出口。分流成功以 libbox Router 对两个
        /// 固定探针目标记录的实际 outbound 命中计数为准。
        var splitRoutingOK: Bool { routingEvidenceOK }

        var isUsable: Bool { linesReachable && splitRoutingOK && hostnameOK }

        var diagnosticSummary: String {
            let directLine = directLineEgressIP ?? "不可用"
            let anyConnectLine = anyConnectLineEgressIP ?? "不可用"
            let routedDirect = routedDirectEgressIP ?? "不可用"
            let routedAnyConnect = routedAnyConnectEgressIP ?? "不可用"
            return "线路探测：Direct \(directLine) · AnyConnect \(anyConnectLine)；"
                + "分流探测：1.0.0.1→\(routedDirect) · 1.1.1.1→\(routedAnyConnect)；"
                + "路由命中：\(splitRoutingOK ? "通过" : "未通过")；DNS：\(hostnameOK ? "通过" : "未通过")"
        }

        var failureMessage: String {
            if anyConnectLineEgressIP == nil {
                return "AnyConnect 线路不通，已自动断开"
            }
            if directLineEgressIP == nil {
                return "Direct 线路不通，已自动断开"
            }
            if routedDirectEgressIP == nil || routedAnyConnectEgressIP == nil {
                return "分流测试地址不可达，已自动断开"
            }
            if !splitRoutingOK {
                return "分流器未按当前配置选择线路，已自动断开"
            }
            if !hostnameOK {
                return "系统隧道已启动，但域名解析不通，已自动断开"
            }
            return "系统隧道已启动，但出口流量不通，已自动断开"
        }

        func withRoutingEvidence(_ accepted: Bool) -> Result {
            Result(
                directLineEgressIP: directLineEgressIP,
                anyConnectLineEgressIP: anyConnectLineEgressIP,
                routedDirectEgressIP: routedDirectEgressIP,
                routedAnyConnectEgressIP: routedAnyConnectEgressIP,
                hostnameOK: hostnameOK,
                routingEvidenceOK: accepted
            )
        }
    }

    static func run(
        directLineEgressIP: String?,
        anyConnectLineEgressIP: String?,
        includeSplitTarget: Bool = true
    ) async -> Result {
        async let directTrace = firstTrace(configuredDirectURLs)
        async let hostnameOK = firstReachable(hostnameURLs)
        let anyConnect = includeSplitTarget
            ? await firstTrace(configuredAnyConnectURLs)
            : TraceResult(reachable: false, address: nil)
        let (direct, hostname) = await (directTrace, hostnameOK)
        return Result(
            directLineEgressIP: directLineEgressIP,
            anyConnectLineEgressIP: anyConnectLineEgressIP,
            routedDirectEgressIP: direct.address,
            routedAnyConnectEgressIP: anyConnect.address,
            hostnameOK: hostname,
            routingEvidenceOK: false
        )
    }

    struct TraceResult: Sendable {
        let reachable: Bool
        let address: String?
    }

    private static func firstTrace(_ urls: [URL]) async -> TraceResult {
        let configuration = probeConfiguration()
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        for url in urls {
            if Task.isCancelled { return TraceResult(reachable: false, address: nil) }
            do {
                let (data, response) = try await session.data(for: probeRequest(url))
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                   let address = parseTraceIPAddress(data) {
                    return TraceResult(reachable: true, address: address)
                }
            } catch {
                continue
            }
        }
        return TraceResult(reachable: false, address: nil)
    }

    static func parseTraceIPAddress(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.")
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("ip=") else { continue }
            let address = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty,
                  address.utf8.count <= 64,
                  address.rangeOfCharacter(from: allowed.inverted) == nil,
                  IPv4Address(address) != nil || IPv6Address(address) != nil else { return nil }
            return address
        }
        return nil
    }

    private static func firstReachable(_ urls: [URL]) async -> Bool {
        let configuration = probeConfiguration()
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        for url in urls {
            if Task.isCancelled { return false }
            do {
                let (_, response) = try await session.data(for: probeRequest(url))
                if let http = response as? HTTPURLResponse, (200..<500).contains(http.statusCode) {
                    return true
                }
            } catch {
                continue
            }
        }
        return false
    }

    private static func probeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return configuration
    }

    private static func probeRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }
}

enum SplitRoutingAcceptanceState: String, Sendable, Equatable {
    case passed
    case failed
    case notApplicable
}

struct ConfiguredDataPathResult: Sendable {
    let targetAddresses: [String: String]
    let targets: [TunnelAcceptanceTarget]
    let unavailableTargets: [TunnelAcceptanceTarget]
    let routedDirectEgressIP: String?
    let routedCurrentEgressIP: String?
    let hostnameOK: Bool
    let routingEvidenceOK: Bool
    let currentRouteTag: String?

    init(
        targetAddresses: [String: String],
        targets: [TunnelAcceptanceTarget] = [],
        unavailableTargets: [TunnelAcceptanceTarget],
        routedDirectEgressIP: String?,
        routedCurrentEgressIP: String?,
        hostnameOK: Bool,
        routingEvidenceOK: Bool,
        currentRouteTag: String?
    ) {
        self.targetAddresses = targetAddresses
        self.targets = targets
        self.unavailableTargets = unavailableTargets
        self.routedDirectEgressIP = routedDirectEgressIP
        self.routedCurrentEgressIP = routedCurrentEgressIP
        self.hostnameOK = hostnameOK
        self.routingEvidenceOK = routingEvidenceOK
        self.currentRouteTag = currentRouteTag
    }

    var splitRoutingState: SplitRoutingAcceptanceState {
        if currentRouteTag == nil {
            return .notApplicable
        }
        return routingEvidenceOK ? .passed : .failed
    }

    var isUsable: Bool {
        unavailableTargets.isEmpty
            && routedDirectEgressIP != nil
            && (currentRouteTag == nil || routedCurrentEgressIP != nil)
            && hostnameOK
            && routingEvidenceOK
    }

    var diagnosticSummary: String {
        let targetLabels = Dictionary(
            uniqueKeysWithValues: targets.map { ($0.tag, $0.label) }
        )
        let checkedTargets = targetAddresses.keys.sorted().map { tag in
            let label = targetLabels[tag] ?? Self.safeTargetLabel(for: tag)
            return "\(label) \(targetAddresses[tag] ?? "不可用")"
        }.joined(separator: " · ")
        let unavailable = unavailableTargets.map(\.label).joined(separator: "、")
        let lineSummary = unavailable.isEmpty
            ? checkedTargets
            : "\(checkedTargets)；不可用：\(unavailable)"
        if currentRouteTag == nil, isUsable {
            return "线路探测：\(lineSummary)；公网双出口不适用；线路与DNS通过，未执行双出口分流验收"
        }
        let currentRouteLabel = currentRouteTag.map {
            targetLabels[$0] ?? Self.safeTargetLabel(for: $0)
        } ?? "不适用"
        return "线路探测：\(lineSummary)；分流探测：1.0.0.1→"
            + "\(routedDirectEgressIP ?? "不可用") · 1.1.1.1→"
            + "\(routedCurrentEgressIP ?? "不可用")（\(currentRouteLabel)）；"
            + "路由命中：\(routingEvidenceOK ? "通过" : "未通过")；"
            + "DNS：\(hostnameOK ? "通过" : "未通过")"
    }

    private static func safeTargetLabel(for tag: String) -> String {
        if tag == "direct" { return "Direct" }
        if tag == "vpn" { return "AnyConnect" }
        if tag.hasPrefix("tailscale-") { return "Tailscale" }
        if tag.hasPrefix("proxy-") { return "Proxy" }
        return "Subscription"
    }

    var failureMessage: String {
        if !unavailableTargets.isEmpty {
            return "线路“\(unavailableTargets.map(\.label).joined(separator: "、"))”不通，已自动断开"
        }
        if routedDirectEgressIP == nil
            || (currentRouteTag != nil && routedCurrentEgressIP == nil) {
            return "连接验收地址不可达，已自动断开"
        }
        if !routingEvidenceOK {
            return currentRouteTag == nil
                ? "Direct 路由验收失败，已自动断开"
                : "分流器未按当前配置选择线路，已自动断开"
        }
        if !hostnameOK {
            return "系统隧道已启动，但域名解析不通，已自动断开"
        }
        return "系统隧道已启动，但出口流量不通，已自动断开"
    }
}

struct RoutingProbeSnapshot: Decodable, Sendable, Equatable {
    let directTargetDirect: Int64
    let directTargetVPN: Int64
    let directTargetOther: Int64
    let anyConnectTargetDirect: Int64
    let anyConnectTargetVPN: Int64
    let anyConnectTargetOther: Int64
    let directTargetTags: [String: Int64]
    let anyConnectTargetTags: [String: Int64]

    enum CodingKeys: String, CodingKey {
        case directTargetDirect = "direct_target_direct"
        case directTargetVPN = "direct_target_vpn"
        case directTargetOther = "direct_target_other"
        case anyConnectTargetDirect = "anyconnect_target_direct"
        case anyConnectTargetVPN = "anyconnect_target_vpn"
        case anyConnectTargetOther = "anyconnect_target_other"
        case directTargetTags = "direct_target_tags"
        case anyConnectTargetTags = "anyconnect_target_tags"
    }

    init(
        directTargetDirect: Int64,
        directTargetVPN: Int64,
        directTargetOther: Int64,
        anyConnectTargetDirect: Int64,
        anyConnectTargetVPN: Int64,
        anyConnectTargetOther: Int64,
        directTargetTags: [String: Int64] = [:],
        anyConnectTargetTags: [String: Int64] = [:]
    ) {
        self.directTargetDirect = directTargetDirect
        self.directTargetVPN = directTargetVPN
        self.directTargetOther = directTargetOther
        self.anyConnectTargetDirect = anyConnectTargetDirect
        self.anyConnectTargetVPN = anyConnectTargetVPN
        self.anyConnectTargetOther = anyConnectTargetOther
        self.directTargetTags = directTargetTags
        self.anyConnectTargetTags = anyConnectTargetTags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        directTargetDirect = try container.decode(Int64.self, forKey: .directTargetDirect)
        directTargetVPN = try container.decode(Int64.self, forKey: .directTargetVPN)
        directTargetOther = try container.decode(Int64.self, forKey: .directTargetOther)
        anyConnectTargetDirect = try container.decode(Int64.self, forKey: .anyConnectTargetDirect)
        anyConnectTargetVPN = try container.decode(Int64.self, forKey: .anyConnectTargetVPN)
        anyConnectTargetOther = try container.decode(Int64.self, forKey: .anyConnectTargetOther)
        directTargetTags = try container.decodeIfPresent(
            [String: Int64].self,
            forKey: .directTargetTags
        ) ?? [:]
        anyConnectTargetTags = try container.decodeIfPresent(
            [String: Int64].self,
            forKey: .anyConnectTargetTags
        ) ?? [:]
    }

    /// 兼容旧的 Direct + AnyConnect 计数断言；新路径使用下面按 exact tag 的证据。
    func provesConfiguredRouting(after current: RoutingProbeSnapshot) -> Bool {
        func delta(_ newer: Int64, _ older: Int64) -> Int64? {
            guard newer >= older else { return nil }
            return newer - older
        }
        guard let directExpected = delta(current.directTargetDirect, directTargetDirect),
              let directWrongVPN = delta(current.directTargetVPN, directTargetVPN),
              let directWrongOther = delta(current.directTargetOther, directTargetOther),
              let anyWrongDirect = delta(current.anyConnectTargetDirect, anyConnectTargetDirect),
              let anyExpected = delta(current.anyConnectTargetVPN, anyConnectTargetVPN),
              let anyWrongOther = delta(current.anyConnectTargetOther, anyConnectTargetOther) else {
            return false
        }
        return directExpected > 0 && anyExpected > 0
            && directWrongVPN == 0 && directWrongOther == 0
            && anyWrongDirect == 0 && anyWrongOther == 0
    }

    func provesConfiguredRouting(
        after current: RoutingProbeSnapshot,
        directTag: String,
        currentRouteTag: String
    ) -> Bool {
        func provesOnlyExpectedTag(
            before: [String: Int64],
            after: [String: Int64],
            expectedTag: String
        ) -> Bool {
            let tags = Set(before.keys).union(after.keys)
            var expectedDelta: Int64 = 0
            for tag in tags {
                let oldValue = before[tag] ?? 0
                let newValue = after[tag] ?? 0
                guard newValue >= oldValue else { return false }
                let delta = newValue - oldValue
                if tag == expectedTag {
                    expectedDelta = delta
                } else if delta != 0 {
                    return false
                }
            }
            return expectedDelta > 0
        }
        return provesOnlyExpectedTag(
            before: directTargetTags,
            after: current.directTargetTags,
            expectedTag: directTag
        ) && provesOnlyExpectedTag(
            before: anyConnectTargetTags,
            after: current.anyConnectTargetTags,
            expectedTag: currentRouteTag
        )
    }

    /// 单出口 Direct 模式仍证明系统 URLSession 确实经过配置中的 Direct 规则，
    /// 但不把这条单路由证据包装成“分流通过”。
    func provesConfiguredDirectRouting(
        after current: RoutingProbeSnapshot,
        directTag: String
    ) -> Bool {
        let tags = Set(directTargetTags.keys).union(current.directTargetTags.keys)
        var expectedDelta: Int64 = 0
        for tag in tags {
            let oldValue = directTargetTags[tag] ?? 0
            let newValue = current.directTargetTags[tag] ?? 0
            guard newValue >= oldValue else { return false }
            let delta = newValue - oldValue
            if tag == directTag {
                expectedDelta = delta
            } else if delta != 0 {
                return false
            }
        }
        return expectedDelta > 0
    }
}

enum ProbeFailureReconnectPolicy {
    /// A diagnostics-only failure pass must never affect a later connection.
    /// Suppression belongs only to the branch that is about to stop an active
    /// tunnel because this acceptance attempt failed.
    static func shouldSuppressAutomaticReconnect(shouldStop: Bool, tunnelIsActive: Bool) -> Bool {
        shouldStop && tunnelIsActive
    }
}

enum SystemOnDemandReconnectPolicy {
    static func shouldArm(
        userEnabled: Bool,
        dataPathVerified: Bool,
        hasStartEnvelope: Bool
    ) -> Bool {
        userEnabled && dataPathVerified && hasStartEnvelope
    }

    static func shouldSuspendActiveProfile(
        systemOnDemandActive: Bool,
        userEnabled: Bool,
        hasStartEnvelope: Bool
    ) -> Bool {
        systemOnDemandActive && (!userEnabled || !hasStartEnvelope)
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

    private static let configGenerationQueue = TunnelConfigGenerationQueue()

    /// 当前持有的 manager。loadAllFromPreferences 拿到已有的,或 ensure 时新建。
    @Published private(set) var manager: NETunnelProviderManager?

    /// 已保存并可用的隧道配置是否存在。AppState 用它更新 helperInstalled。
    @Published private(set) var isProfileInstalled: Bool = false
    @Published private(set) var systemOnDemandActive = false
    @Published private(set) var systemOnDemandState: SystemOnDemandState = .disabled
    var systemOnDemandStatePublisher: AnyPublisher<SystemOnDemandState, Never> {
        $systemOnDemandState.eraseToAnyPublisher()
    }

    /// 包给 GoEngine 用的会话封装。每次 manager/connection 变化时重建并重新注入。
    private(set) var providerSession: TunnelProviderSession?

    /// GoEngine 引用,用于注入 session。弱引用避免环(GoEngine 也不强持有本类)。
    private weak var engine: GoEngine?
    private var statusSubscription: AnyCancellable?
    private var observedSystemStatus: NEVPNStatus = .invalid
    private var dataPathProbeTask: Task<Void, Never>?
    private var dataPathProbeID: UUID?
    private var dataPathVerified = false
    private var startOperationState = TunnelStartOperationState()
    private var activeStartAttemptID: String?
    private(set) var activeAcceptancePlan: TunnelAcceptancePlan?
    private var systemOnDemandRequested = false
    private var pendingOnDemandEnvelope: OnDemandStartEnvelope?
    private var startWatchdogTask: Task<Void, Never>?

    init(engine: GoEngine? = nil) {
        self.engine = engine
        // 新版本的启动参数只通过 startTunnel(options:) 一次性交付。应用一启动就
        // 清掉旧版留在 App Group 的明文，不能等到用户下次连接才迁移；否则升级后
        // 长期不连接的设备会一直保留旧账号、密码与完整配置。
        clearLegacyStartOptions()
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
    func loadFromPreferences(
        operationID: UUID? = nil,
        completion: (@Sendable (Result<Void, Error>) -> Void)? = nil
    ) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            let box = UncheckedBox(value: (managers, error))
            Task { @MainActor in
                guard let self else { return }
                guard self.isCurrentStartOperation(operationID) else { return }
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
                self.systemOnDemandActive = mine?.isOnDemandEnabled == true
                self.systemOnDemandState = self.systemOnDemandActive
                    ? .active
                    : (self.systemOnDemandRequested ? .pending : .disabled)
                let hasSecureEnvelope = self.restoreAcceptancePlanFromSecureEnvelopeIfNeeded()
                appLog("TunnelManager.load: found \((managers ?? []).count) managers, mine=\(mine != nil)")
                self.injectSession()
                if SystemOnDemandReconnectPolicy.shouldSuspendActiveProfile(
                    systemOnDemandActive: self.systemOnDemandActive,
                    userEnabled: self.systemOnDemandRequested,
                    hasStartEnvelope: hasSecureEnvelope
                ) {
                    self.suspendSystemOnDemand(clearEnvelope: true) {}
                }
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

    func removeProfile(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        pendingOnDemandEnvelope = nil
        systemOnDemandActive = false
        systemOnDemandState = systemOnDemandRequested ? .pending : .disabled
        _ = OnDemandStartEnvelopeStore.clear()
        guard let manager else {
            isProfileInstalled = false
            injectSession()
            completion(.success(()))
            return
        }
        guard manager.connection.status == .disconnected || manager.connection.status == .invalid else {
            completion(.failure(NSError(
                domain: "XDial",
                code: -20,
                userInfo: [NSLocalizedDescriptionKey: "请先断开连接再移除系统描述文件"]
            )))
            return
        }
        manager.removeFromPreferences { [weak self] error in
            let errorBox = UncheckedBox(value: error)
            Task { @MainActor in
                guard let self else { return }
                if let error = errorBox.value {
                    completion(.failure(error))
                    return
                }
                self.manager = nil
                self.isProfileInstalled = false
                self.injectSession()
                completion(.success(()))
            }
        }
    }

    func setSystemOnDemandEnabled(_ enabled: Bool) {
        systemOnDemandRequested = enabled
        if enabled {
            if !systemOnDemandActive {
                systemOnDemandState = .pending
            }
            armSystemOnDemandIfReady()
        } else {
            systemOnDemandState = .disabled
            suspendSystemOnDemand(clearEnvelope: true) {}
        }
    }

    static func makeSystemOnDemandRules() -> [NEOnDemandRule] {
        let connect = NEOnDemandRuleConnect()
        connect.interfaceTypeMatch = .any
        return [connect]
    }

    @discardableResult
    private func restoreAcceptancePlanFromSecureEnvelopeIfNeeded() -> Bool {
        guard case .available(let envelope) = OnDemandStartEnvelopeStore.load(),
              envelope.isValid,
              ["anyconnect", "standalone"].contains(envelope.transport),
              let rawPlan = envelope.parameters["acceptance_plan"],
              let data = rawPlan.data(using: .utf8),
              let plan = try? JSONDecoder().decode(TunnelAcceptancePlan.self, from: data) else {
            return false
        }
        if activeAcceptancePlan == nil {
            activeAcceptancePlan = plan
        }
        return true
    }

    private func armSystemOnDemandIfReady() {
        let envelope: OnDemandStartEnvelope?
        if let pendingOnDemandEnvelope {
            envelope = pendingOnDemandEnvelope
        } else if case .available(let stored) = OnDemandStartEnvelopeStore.load() {
            envelope = stored
        } else {
            envelope = nil
        }
        guard SystemOnDemandReconnectPolicy.shouldArm(
            userEnabled: systemOnDemandRequested,
            dataPathVerified: dataPathVerified,
            hasStartEnvelope: envelope != nil
        ), let envelope, let manager else {
            return
        }
        let keychainStatus = OnDemandStartEnvelopeStore.save(envelope)
        guard keychainStatus == errSecSuccess else {
            systemOnDemandActive = false
            let message = "无法安全保存系统级按需重连启动包"
            systemOnDemandState = .failed(message)
            engine?.lastError = message
            appLog("TunnelManager.onDemand: secure envelope save failed status=\(keychainStatus)")
            return
        }
        manager.onDemandRules = Self.makeSystemOnDemandRules()
        manager.isOnDemandEnabled = true
        manager.saveToPreferences { [weak self] error in
            let box = UncheckedBox(value: error)
            Task { @MainActor in
                guard let self, let manager = self.manager else { return }
                if let error = box.value {
                    manager.isOnDemandEnabled = false
                    self.systemOnDemandActive = false
                    let message = "启用系统级按需重连失败：\(error.localizedDescription)"
                    self.systemOnDemandState = .failed(message)
                    self.engine?.lastError = message
                    _ = OnDemandStartEnvelopeStore.clear()
                    appLog("TunnelManager.onDemand: enable failed \(error.localizedDescription)")
                    return
                }
                self.systemOnDemandActive = true
                self.systemOnDemandState = .active
                appLog("TunnelManager.onDemand: armed after data-path acceptance")
            }
        }
    }

    private func suspendSystemOnDemand(
        clearEnvelope: Bool,
        completion: @escaping @MainActor () -> Void
    ) {
        if clearEnvelope {
            pendingOnDemandEnvelope = nil
            _ = OnDemandStartEnvelopeStore.clear()
        }
        systemOnDemandActive = false
        systemOnDemandState = systemOnDemandRequested ? .pending : .disabled
        guard let manager else {
            completion()
            return
        }
        manager.isOnDemandEnabled = false
        let completionBox = UncheckedBox(value: completion)
        manager.saveToPreferences { [weak self] error in
            let errorBox = UncheckedBox(value: error)
            Task { @MainActor in
                if let error = errorBox.value {
                    appLog("TunnelManager.onDemand: suspend failed \(error.localizedDescription)")
                    let message = "无法停用系统级按需重连：\(error.localizedDescription)"
                    self?.systemOnDemandState = .failed(message)
                    self?.engine?.lastError = message
                }
                completionBox.value()
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
    func ensureConfigured(
        serverAddress: String,
        operationID: UUID? = nil,
        completion: (@Sendable (Result<Void, Error>) -> Void)? = nil
    ) {
        guard isCurrentStartOperation(operationID) else { return }
        let mgr = manager ?? NETunnelProviderManager()

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = kTunnelBundleIdentifier
        // serverAddress 不能为空,否则系统会拒绝保存;空则用占位。
        proto.serverAddress = Self.systemProfileServerAddress(serverAddress)
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
        // 手动启动期间先暂停系统接管，避免保存配置与携带一次性 options 的
        // startVPNTunnel 之间被系统抢先冷启动。
        mgr.onDemandRules = Self.makeSystemOnDemandRules()
        mgr.isOnDemandEnabled = false
        systemOnDemandActive = false
        systemOnDemandState = systemOnDemandRequested ? .pending : .disabled

        let mgrBox = UncheckedBox(value: mgr)
        mgr.saveToPreferences { [weak self] error in
            let box = UncheckedBox(value: error)
            Task { @MainActor in
                guard let self else { return }
                guard self.isCurrentStartOperation(operationID) else { return }
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
                self.loadFromPreferences(operationID: operationID) { result in
                    completion?(result)
                }
            }
        }
    }

    private func isCurrentStartOperation(_ operationID: UUID?) -> Bool {
        guard let operationID else { return true }
        return startOperationState.isCurrent(operationID)
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
        // 控制面已经 connected，从这里开始给数据面验收一个独立时限。
        // 不能继续消耗 AnyConnect 握手前就开始的 45 秒，否则慢网会在
        // 线路已通、正验收分流时被误判为启动超时。
        startWatchdogTask?.cancel()
        let probeID = UUID()
        dataPathProbeID = probeID
        let attemptID = activeStartAttemptID
        let acceptancePlan = activeAcceptancePlan
        dataPathVerified = false
        engine?.dataPathSummary = acceptancePlan?.requiresAnyConnect == true
            ? "正在检测 Direct、AnyConnect 与分流规则"
            : "正在检测活动线路、域名解析与分流规则"
        engine?.applySystemStatus("checking", connectedAt: connection.connectedDate)
        appLog("DataPathProbe: begin")

        armDataPathWatchdog(
            probeID: probeID,
            attemptID: attemptID,
            connection: connection
        )

        dataPathProbeTask = Task { [weak self, weak connection] in
            guard let self else { return }
            let outcome: ProbeOutcome
            if let acceptancePlan {
                switch await self.waitForActiveTailscaleReadiness(
                    plan: acceptancePlan,
                    probeID: probeID,
                    attemptID: attemptID,
                    connection: connection
                ) {
                case .ready:
                    outcome = await self.probeConfiguredDataPath(plan: acceptancePlan)
                case .failed(let message):
                    outcome = ProbeOutcome(
                        isUsable: false,
                        summary: message,
                        failureMessage: "\(message)，已自动断开",
                        logSummary: "tailscale-readiness-failed"
                    )
                }
            } else {
                outcome = ProbeOutcome(
                    isUsable: false,
                    summary: "连接验收计划不可用",
                    failureMessage: "连接验收计划不可用，已自动断开",
                    logSummary: "acceptance-plan-missing"
                )
            }
            guard !Task.isCancelled, let connection,
                  self.dataPathProbeID == probeID,
                  connection === self.manager?.connection,
                  connection.status == .connected else { return }

            self.dataPathProbeTask = nil
            self.engine?.dataPathSummary = outcome.summary
            if outcome.isUsable {
                self.dataPathProbeID = nil
                self.dataPathVerified = true
                self.activeStartAttemptID = nil
                self.startWatchdogTask?.cancel()
                self.startWatchdogTask = nil
                self.armSystemOnDemandIfReady()
                self.engine?.applySystemStatus("connected", connectedAt: connection.connectedDate)
                appLog("DataPathProbe: passed \(outcome.logSummary)")
            } else {
                self.dataPathVerified = false
                appLog("DataPathProbe: failed \(outcome.logSummary)")
                let baseMessage = outcome.failureMessage
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

    private func armDataPathWatchdog(
        probeID: UUID,
        attemptID: String?,
        connection: NEVPNConnection
    ) {
        startWatchdogTask?.cancel()
        startWatchdogTask = Task { @MainActor [weak self, weak connection] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard !Task.isCancelled, let self, let connection,
                  self.dataPathProbeID == probeID else { return }
            self.dataPathProbeTask?.cancel()
            self.dataPathProbeTask = nil
            self.applyProbeFailure(
                baseMessage: "连接验收超时",
                diagnostics: TunnelDiagnosticFormatter.persistedSummary(
                    matchingAttemptID: attemptID
                ),
                connection: connection,
                shouldStop: true
            )
        }
    }

    private enum TailscaleReadiness {
        case ready
        case failed(String)
    }

    private enum TailscaleStatusFetchResult: Sendable {
        case success(TailscaleRuntimeStatus)
        case failure(String)
        case cancelled
    }

    /// tsnet endpoint 在首次启动时必须先保持 provider 存活，才能暴露 LocalAPI
    /// authURL。这里在任何“线路不通”探针之前识别 NeedsLogin，进入明确的等待授权
    /// 状态；授权完成后重新从完整数据面验收起点开始。
    private func waitForActiveTailscaleReadiness(
        plan: TunnelAcceptancePlan,
        probeID: UUID,
        attemptID: String?,
        connection: NEVPNConnection?
    ) async -> TailscaleReadiness {
        let tags = plan.generatedTailscaleTargets.map(\.tag)
        guard !tags.isEmpty else { return .ready }

        var enteredActionRequired = false
        var transientPolls = 0
        var consecutiveStatusFailures = 0
        while !Task.isCancelled {
            guard dataPathProbeID == probeID,
                  let connection,
                  connection === manager?.connection,
                  connection.status == .connected else {
                return .failed("Tailscale 登录等待已取消")
            }

            var allRunning = true
            var needsLogin = false
            var sawTransient = false
            var statusRequestFailed = false
            for tag in tags {
                let result = await requestTailscaleRuntimeStatus(endpointTag: tag)
                switch result {
                case .failure:
                    allRunning = false
                    sawTransient = true
                    statusRequestFailed = true
                case .cancelled:
                    return .failed("Tailscale 登录等待已取消")
                case .success(let status):
                    switch status.backendState.lowercased() {
                    case "running":
                        continue
                    case "needslogin", "needs_login":
                        allRunning = false
                        if Self.isValidTailscaleAuthURL(status.authURL) {
                            needsLogin = true
                        } else {
                            sawTransient = true
                        }
                    case "starting", "stopped", "nostate", "no_state":
                        allRunning = false
                        sawTransient = true
                    default:
                        allRunning = false
                        if enteredActionRequired {
                            sawTransient = true
                        } else {
                            return .failed("Tailscale 状态异常：\(status.backendState)")
                        }
                    }
                }
            }
            consecutiveStatusFailures = statusRequestFailed
                ? consecutiveStatusFailures + 1
                : 0
            if enteredActionRequired && consecutiveStatusFailures >= 5 {
                engine?.dataPathSummary = "持续无法读取 Tailscale 登录状态"
                return .failed("持续无法读取 Tailscale 登录状态")
            }

            if allRunning {
                if enteredActionRequired {
                    engine?.dataPathSummary = "Tailscale 已登录，正在重新执行完整连接验收"
                    engine?.applySystemStatus("checking", connectedAt: connection.connectedDate)
                    armDataPathWatchdog(
                        probeID: probeID,
                        attemptID: attemptID,
                        connection: connection
                    )
                }
                return .ready
            }

            if needsLogin {
                enteredActionRequired = true
                transientPolls = 0
                startWatchdogTask?.cancel()
                startWatchdogTask = nil
                engine?.lastError = nil
                engine?.dataPathSummary = "Tailscale 需要登录；隧道保持运行，登录后将自动重新验收"
                engine?.applySystemStatus(
                    "action-required",
                    connectedAt: connection.connectedDate
                )
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }

            if sawTransient {
                transientPolls += 1
                if !enteredActionRequired && transientPolls >= 30 {
                    return .failed("Tailscale 未能进入可登录或已运行状态")
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
        }
        return .failed("Tailscale 登录等待已取消")
    }

    private static func isValidTailscaleAuthURL(_ rawValue: String) -> Bool {
        guard let components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty else { return false }
        return true
    }

    private func requestTailscaleRuntimeStatus(
        endpointTag: String
    ) async -> TailscaleStatusFetchResult {
        guard let session = providerSession,
              let request = try? JSONSerialization.data(withJSONObject: [
                  "cmd": "tailscale-status",
                  "endpoint_tag": endpointTag,
              ]) else {
            return .failure("Tailscale 状态接口不可用")
        }
        let oneShot = OneShotContinuation<TailscaleStatusFetchResult>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                oneShot.install(continuation)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                    oneShot.finish(.failure("读取 Tailscale 状态超时"))
                }
                do {
                    try session.sendProviderMessage(request) { responseData in
                        guard let responseData,
                              let response = try? JSONDecoder().decode(
                                  DaemonResponse.self,
                                  from: responseData
                              ),
                              response.ok == true,
                              let rawStatus = response.data,
                              let data = rawStatus.data(using: .utf8),
                              let status = try? JSONDecoder().decode(
                                  TailscaleRuntimeStatus.self,
                                  from: data
                              ) else {
                            oneShot.finish(.failure("Tailscale 状态响应无效"))
                            return
                        }
                        oneShot.finish(.success(status))
                    }
                } catch {
                    oneShot.finish(.failure(error.localizedDescription))
                }
            }
        } onCancel: {
            oneShot.finish(.cancelled)
        }
    }

    private struct ProbeOutcome {
        let isUsable: Bool
        let summary: String
        let failureMessage: String
        let logSummary: String
    }

    private func probeConfiguredDataPath(plan: TunnelAcceptancePlan) async -> ProbeOutcome {
        var addresses: [String: String] = [:]
        var unavailable: [TunnelAcceptanceTarget] = []
        for target in plan.targets {
            guard !Task.isCancelled else {
                return ProbeOutcome(
                    isUsable: false, summary: "", failureMessage: "", logSummary: "cancelled"
                )
            }
            if let address = await requestOutboundAddress(outboundTag: target.tag) {
                addresses[target.tag] = address
            } else {
                unavailable.append(target)
            }
        }
        let routingBefore = await requestRoutingProbeSnapshot()
        let routed = await DataPathProbe.run(
            directLineEgressIP: nil,
            anyConnectLineEgressIP: nil,
            includeSplitTarget: plan.currentRouteTag != nil
        )
        let routingAfter = await requestRoutingProbeSnapshot()
        let routingEvidenceOK = routingBefore.flatMap { before in
            routingAfter.map {
                if let currentRouteTag = plan.currentRouteTag {
                    return before.provesConfiguredRouting(
                        after: $0,
                        directTag: "direct",
                        currentRouteTag: currentRouteTag
                    )
                }
                return before.provesConfiguredDirectRouting(
                    after: $0,
                    directTag: "direct"
                )
            }
        } ?? false
        let result = ConfiguredDataPathResult(
            targetAddresses: addresses,
            targets: plan.targets,
            unavailableTargets: unavailable,
            routedDirectEgressIP: routed.routedDirectEgressIP,
            routedCurrentEgressIP: routed.routedAnyConnectEgressIP,
            hostnameOK: routed.hostnameOK,
            routingEvidenceOK: routingEvidenceOK,
            currentRouteTag: plan.currentRouteTag
        )
        return ProbeOutcome(
            isUsable: result.isUsable,
            summary: result.diagnosticSummary,
            failureMessage: result.failureMessage,
            logSummary: "targets=\(addresses.count)/\(plan.targets.count) "
                + "route=\(plan.currentRouteTag ?? "not-applicable") "
                + "split=\(result.splitRoutingState.rawValue) routeEvidence=\(routingEvidenceOK) "
                + "dns=\(routed.hostnameOK) routedDirect="
                + "\(routed.routedDirectEgressIP ?? "unavailable") routedCurrent="
                + "\(routed.routedAnyConnectEgressIP ?? "unavailable")"
        )
    }

    /// 直接让 libbox 通过指定 outbound 访问出口地址，这一层绕过 route matcher，
    /// 只回答“这条线路本身通不通”。后续主 App 的 URLSession 探针才回答
    /// “配置里的分流规则有没有把系统流量送到它”。
    private func requestOutboundAddress(outboundTag: String) async -> String? {
        guard let session = providerSession,
              let request = try? JSONSerialization.data(withJSONObject: [
                "cmd": "probe-outbound-address",
                "outbound_tag": outboundTag,
                "timeout_ms": "7000",
              ]) else { return nil }

        return await withCheckedContinuation { continuation in
            let oneShot = OneShotContinuation<String?>(continuation)
            // 取消旧验收时，provider 中已经开始的一条最多还会占用 7s。
            // 留出“一条旧任务 + 本任务”的上界，不把排队当成线路超时。
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 16) {
                oneShot.finish(nil)
            }
            do {
                try session.sendProviderMessage(request) { responseData in
                    guard let responseData,
                          let response = try? JSONDecoder().decode(DaemonResponse.self, from: responseData),
                          response.ok == true,
                          let address = response.data,
                          !address.isEmpty,
                          IPv4Address(address) != nil || IPv6Address(address) != nil else {
                        oneShot.finish(nil)
                        return
                    }
                    oneShot.finish(address)
                }
            } catch {
                oneShot.finish(nil)
            }
        }
    }

    private func requestRoutingProbeSnapshot() async -> RoutingProbeSnapshot? {
        guard let session = providerSession else { return nil }
        let request = Data("{\"cmd\":\"routing-probe-snapshot\"}".utf8)
        let raw: String? = await withCheckedContinuation { continuation in
            let oneShot = OneShotContinuation<String?>(continuation)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                oneShot.finish(nil)
            }
            do {
                try session.sendProviderMessage(request) { responseData in
                    guard let responseData,
                          let response = try? JSONDecoder().decode(DaemonResponse.self, from: responseData),
                          response.ok == true else {
                        oneShot.finish(nil)
                        return
                    }
                    oneShot.finish(response.data)
                }
            } catch {
                oneShot.finish(nil)
            }
        }
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RoutingProbeSnapshot.self, from: data)
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
        let tunnelIsActive = connection.status == .connected || connection.status == .reasserting
        if ProbeFailureReconnectPolicy.shouldSuppressAutomaticReconnect(
            shouldStop: shouldStop,
            tunnelIsActive: tunnelIsActive
        ) {
            // Only consume the next disconnected event when this exact failure
            // actually initiates a stop. A diagnostics-only first pass must not
            // leave a suppression flag behind if a newer probe supersedes it.
            engine?.suppressNextAutomaticReconnect()
            engine?.applySystemStatus("disconnecting")
            suspendSystemOnDemand(clearEnvelope: true) {
                connection.stopVPNTunnel()
            }
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

    private func clearLegacyStartOptions() {
        guard let defaults = UserDefaults(suiteName: kAppGroupIdentifier) else { return }
        for key in [LegacyAppGroupKey.server, LegacyAppGroupKey.username,
                    LegacyAppGroupKey.password, LegacyAppGroupKey.config] {
            defaults.removeObject(forKey: key)
        }
    }

    private func beginStartOperation(
        completion: @escaping TunnelStartOperationState.Completion
    ) -> UUID {
        let registration = startOperationState.begin(completion: completion)
        registration.cancelled?(.failure(CancellationError()))
        return registration.id
    }

    @discardableResult
    private func finishStartOperation(
        _ operationID: UUID,
        result: Result<Void, Error>
    ) -> Bool {
        guard let completion = startOperationState.finish(operationID) else { return false }
        completion(result)
        return true
    }

    /// 把 profile 转成 NE 模式 sing-box 配置，确保系统隧道配置已保存，
    /// 再通过一次性 start options 把凭据和完整配置交给扩展，不落进 App Group。
    ///
    // TODO: 无法离线验证,真机联调时需要重点检查这里的实际行为。
    // startVPNTunnel() 需要 saveToPreferences 已成功且 NE entitlement 就绪,
    // 否则会抛 NEVPNError;这里只做结构正确性保证,运行时行为等真机验证。
    func startTunnel(profile: Profile, anyConnect: AnyConnectCredentials?,
                      completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        let operationID = beginStartOperation(completion: completion)
        guard isCurrentStartOperation(operationID) else { return }
        guard UserDefaults(suiteName: kAppGroupIdentifier) != nil else {
            finishStartOperation(operationID, result: .failure(NSError(domain: "XDial", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "App Group UserDefaults 不可用(\(kAppGroupIdentifier))"])))
            return
        }
        let basePath = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: kAppGroupIdentifier)?.path ?? ""

        let profileJSON: String
        let allowInsecure: Bool
        let acceptancePlan: TunnelAcceptancePlan
        do {
            if let anyConnect {
                allowInsecure = try selectedAnyConnectLine(
                    in: profile,
                    credentials: anyConnect
                ).allowInsecure
            } else {
                allowInsecure = false
            }
            let data = try JSONEncoder().encode(profile)
            guard let json = String(data: data, encoding: .utf8) else {
                throw NSError(domain: "XDial", code: -3, userInfo: [NSLocalizedDescriptionKey: "profile JSON 编码失败(非 UTF8)"])
            }
            profileJSON = json
            acceptancePlan = try TunnelAcceptancePlan.make(
                profile: profile,
                profileJSON: json,
                anyConnect: anyConnect
            )
        } catch {
            finishStartOperation(operationID, result: .failure(error))
            return
        }
        activeAcceptancePlan = acceptancePlan
        let server = anyConnect?.server ?? ""

        // 远程规则会在这里通过严格链路预取并落为 App Group 本地文件；绝不能在
        // MainActor 同步等待网络。准备期间立即进入 connecting，完成后再保存系统配置。
        engine?.lastError = nil
        engine?.applySystemStatus("connecting")
        let owner = UncheckedBox(value: self)
        Self.configGenerationQueue.submit {
            var genError: NSError?
            let configJSON = LibboxGenerateNEConfig(profileJSON, server, basePath, &genError)
            let outcome: Result<String, NSError>
            if let genError {
                outcome = .failure(genError)
            } else if configJSON.utf8.count > kMaxNEConfigBytes {
                outcome = .failure(NSError(domain: "XDial", code: -5,
                    userInfo: [NSLocalizedDescriptionKey: "连接配置过大，无法安全启动"]))
            } else {
                outcome = .success(configJSON)
            }
            let outcomeBox = UncheckedBox(value: outcome)
            Task { @MainActor in
                let manager = owner.value
                guard manager.isCurrentStartOperation(operationID) else { return }
                switch outcomeBox.value {
                case .failure(let error):
                    manager.engine?.applySystemStatus("disconnected")
                    manager.finishStartOperation(operationID, result: .failure(error))
                case .success(let configJSON):
                    manager.startPreparedTunnel(
                        operationID: operationID,
                        configJSON: configJSON,
                        allowInsecure: allowInsecure,
                        anyConnect: anyConnect
                    )
                }
            }
        }
    }

    private func startPreparedTunnel(
        operationID: UUID,
        configJSON: String,
        allowInsecure: Bool,
        anyConnect: AnyConnectCredentials?
    ) {
        guard isCurrentStartOperation(operationID) else { return }
        guard UserDefaults(suiteName: kAppGroupIdentifier) != nil else {
            engine?.applySystemStatus("disconnected")
            finishStartOperation(operationID, result: .failure(NSError(domain: "XDial", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "App Group UserDefaults 不可用(\(kAppGroupIdentifier))"])))
            return
        }

        clearLegacyStartOptions()
        _ = OnDemandStartEnvelopeStore.clear()
        if let activeAcceptancePlan,
           let planData = try? JSONEncoder().encode(activeAcceptancePlan),
           let planJSON = String(data: planData, encoding: .utf8) {
            var parameters = [
                "acceptance_plan": planJSON,
                "allow_insecure": allowInsecure ? "true" : "false",
            ]
            if let anyConnect {
                parameters["server"] = anyConnect.server
                parameters["username"] = anyConnect.username
                parameters["password"] = anyConnect.password
            }
            pendingOnDemandEnvelope = OnDemandStartEnvelope(
                transport: anyConnect == nil ? "standalone" : "anyconnect",
                parameters: parameters,
                configJSON: configJSON
            )
        } else {
            pendingOnDemandEnvelope = nil
        }

        ensureConfigured(
            serverAddress: anyConnect?.server ?? "XDial",
            operationID: operationID
        ) { [weak self] result in
            // ensureConfigured 的 completion 类型是 @Sendable,闭包字面量默认不再
            // 继承外层 TunnelManager(@MainActor)的隔离——显式 Task { @MainActor in }
            // 重新进入主 actor 才能碰 self.manager(MainActor 隔离属性)。
            Task { @MainActor in
                guard let self else { return }
                guard self.isCurrentStartOperation(operationID) else { return }
                switch result {
                case .failure(let error):
                    self.engine?.applySystemStatus("disconnected")
                    self.finishStartOperation(operationID, result: .failure(error))
                case .success:
                    do {
                        guard self.isCurrentStartOperation(operationID) else { return }
                        guard let session = self.manager?.connection as? NETunnelProviderSession else {
                            throw NSError(domain: "XDial", code: -4,
                                userInfo: [NSLocalizedDescriptionKey: "系统隧道会话未加载"])
                        }
                        var options: [String: NSObject] = [
                            "configJSON": configJSON as NSString,
                            "usesAnyConnect": NSNumber(value: anyConnect != nil),
                            "allowInsecure": NSNumber(value: allowInsecure),
                        ]
                        if let anyConnect {
                            options["server"] = anyConnect.server as NSString
                            options["username"] = anyConnect.username as NSString
                            options["password"] = anyConnect.password as NSString
                        }
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
                            self.engine?.suppressNextAutomaticReconnect()
                            self.engine?.applySystemStatus("disconnecting")
                            self.suspendSystemOnDemand(clearEnvelope: true) {
                                session?.stopVPNTunnel()
                            }
                            self.startWatchdogTask = nil
                        }
                        try session.startTunnel(options: startOptions)
                        self.finishStartOperation(operationID, result: .success(()))
                    } catch {
                        guard self.isCurrentStartOperation(operationID) else { return }
                        self.activeStartAttemptID = nil
                        self.startWatchdogTask?.cancel()
                        self.startWatchdogTask = nil
                        self.engine?.applySystemStatus("disconnected")
                        self.finishStartOperation(operationID, result: .failure(error))
                    }
                }
            }
        }
    }

    private func selectedAnyConnectLine(
        in profile: Profile,
        credentials: AnyConnectCredentials
    ) throws -> Line {
        guard let mode = profile.modes.first(where: { $0.id == profile.activeModeID }) else {
            throw NSError(domain: "XDial", code: -6,
                userInfo: [NSLocalizedDescriptionKey: "当前模式不可用"])
        }

        var referencedLineIDs = Set<String>()
        if !mode.defaultLineID.isEmpty {
            referencedLineIDs.insert(mode.defaultLineID)
        }
        for binding in mode.bindings {
            guard !binding.lineID.isEmpty,
                  profile.ruleSets.first(where: { $0.id == binding.ruleSetID })?.enabled == true else {
                continue
            }
            referencedLineIDs.insert(binding.lineID)
        }

        let lines = profile.lines.filter {
            referencedLineIDs.contains($0.id) && $0.enabled && $0.type == "vpn"
        }
        guard lines.count == 1,
              let line = lines.first,
              line.vpnServer == credentials.server,
              line.vpnUsername == credentials.username,
              line.vpnPassword == credentials.password else {
            throw NSError(domain: "XDial", code: -6,
                userInfo: [NSLocalizedDescriptionKey: "当前模式的 AnyConnect 线路不唯一或凭据不匹配"])
        }
        return line
    }

    /// 停止系统级隧道。manager/connection 不可用时静默返回(语义等价「本来就没在跑」)。
    func stopTunnel() {
        let cancelledCompletion = startOperationState.cancel()
        activeStartAttemptID = nil
        startWatchdogTask?.cancel()
        startWatchdogTask = nil
        dataPathProbeTask?.cancel()
        dataPathProbeTask = nil
        dataPathProbeID = nil
        engine?.applySystemStatus("disconnecting")
        let connection = manager?.connection
        suspendSystemOnDemand(clearEnvelope: true) {
            connection?.stopVPNTunnel()
        }
        cancelledCompletion?(.failure(CancellationError()))
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

    /// 系统连接描述只需要一个可识别的主机名。绝不能把 URL userinfo、路径或
    /// query 持久化进系统偏好；真实拨号仍使用一次性 start options 里的原值。
    static func systemProfileServerAddress(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "XDial" }

        func hostAndPort(from components: URLComponents?) -> String? {
            guard let components, let host = components.host, !host.isEmpty else { return nil }
            let renderedHost = host.contains(":") ? "[\(host)]" : host
            return components.port.map { "\(renderedHost):\($0)" } ?? renderedHost
        }

        if let value = hostAndPort(from: URLComponents(string: trimmed)) {
            return value
        }
        if let value = hostAndPort(from: URLComponents(string: "https://" + trimmed)) {
            return value
        }
        return "XDial"
    }
}
