import Foundation

struct Line: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var type: String  // direct / vpn / trojan / shadowsocks / vmess / tailscale
    var enabled: Bool = true
    var verified: Bool = false

    var vpnServer: String = ""
    var vpnUsername: String = ""
    var vpnPassword: String = ""

    var trojanServer: String = ""
    var trojanPort: Int = 443
    var trojanPassword: String = ""
    var trojanSNI: String = ""

    var ssServer: String = ""
    var ssPort: Int = 8388
    var ssMethod: String = "aes-256-gcm"
    var ssPassword: String = ""

    var vmessServer: String = ""
    var vmessPort: Int = 443
    var vmessUUID: String = ""
    var vmessAltID: Int = 0

    var tailscaleHostname: String = ""
    var tailscaleAcceptRoutes: Bool = true
    var tailscaleExitNode: String = ""
    var tailscaleAuthenticated: Bool = false

    var allowInsecure: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, name, type, enabled, verified
        case allowInsecure = "allow_insecure"
        case vpnServer = "vpn_server"
        case vpnUsername = "vpn_username"
        case vpnPassword = "vpn_password"
        case trojanServer = "trojan_server"
        case trojanPort = "trojan_port"
        case trojanPassword = "trojan_password"
        case trojanSNI = "trojan_sni"
        case ssServer = "ss_server"
        case ssPort = "ss_port"
        case ssMethod = "ss_method"
        case ssPassword = "ss_password"
        case vmessServer = "vmess_server"
        case vmessPort = "vmess_port"
        case vmessUUID = "vmess_uuid"
        case vmessAltID = "vmess_alt_id"
        case tailscaleHostname = "tailscale_hostname"
        case tailscaleAcceptRoutes = "tailscale_accept_routes"
        case tailscaleExitNode = "tailscale_exit_node"
        case tailscaleAuthenticated = "tailscale_authenticated"
    }

    init(id: String, name: String, type: String, enabled: Bool = true, verified: Bool = false,
         vpnServer: String = "", vpnUsername: String = "", vpnPassword: String = "",
         trojanServer: String = "", trojanPort: Int = 443, trojanPassword: String = "", trojanSNI: String = "",
         ssServer: String = "", ssPort: Int = 8388, ssMethod: String = "aes-256-gcm", ssPassword: String = "",
         vmessServer: String = "", vmessPort: Int = 443, vmessUUID: String = "", vmessAltID: Int = 0,
         tailscaleHostname: String = "", tailscaleAcceptRoutes: Bool = true, tailscaleExitNode: String = "",
         tailscaleAuthenticated: Bool = false,
         allowInsecure: Bool = false) {
        self.id = id; self.name = name; self.type = type; self.enabled = enabled; self.verified = verified
        self.vpnServer = vpnServer; self.vpnUsername = vpnUsername; self.vpnPassword = vpnPassword
        self.trojanServer = trojanServer; self.trojanPort = trojanPort; self.trojanPassword = trojanPassword; self.trojanSNI = trojanSNI
        self.ssServer = ssServer; self.ssPort = ssPort; self.ssMethod = ssMethod; self.ssPassword = ssPassword
        self.vmessServer = vmessServer; self.vmessPort = vmessPort; self.vmessUUID = vmessUUID; self.vmessAltID = vmessAltID
        self.tailscaleHostname = tailscaleHostname
        self.tailscaleAcceptRoutes = tailscaleAcceptRoutes
        self.tailscaleExitNode = tailscaleExitNode
        self.tailscaleAuthenticated = tailscaleAuthenticated
        self.allowInsecure = allowInsecure
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(String.self, forKey: .type)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        verified = try c.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        vpnServer = try c.decodeIfPresent(String.self, forKey: .vpnServer) ?? ""
        vpnUsername = try c.decodeIfPresent(String.self, forKey: .vpnUsername) ?? ""
        vpnPassword = try c.decodeIfPresent(String.self, forKey: .vpnPassword) ?? ""
        trojanServer = try c.decodeIfPresent(String.self, forKey: .trojanServer) ?? ""
        trojanPort = try c.decodeIfPresent(Int.self, forKey: .trojanPort) ?? 443
        trojanPassword = try c.decodeIfPresent(String.self, forKey: .trojanPassword) ?? ""
        trojanSNI = try c.decodeIfPresent(String.self, forKey: .trojanSNI) ?? ""
        ssServer = try c.decodeIfPresent(String.self, forKey: .ssServer) ?? ""
        ssPort = try c.decodeIfPresent(Int.self, forKey: .ssPort) ?? 8388
        ssMethod = try c.decodeIfPresent(String.self, forKey: .ssMethod) ?? "aes-256-gcm"
        ssPassword = try c.decodeIfPresent(String.self, forKey: .ssPassword) ?? ""
        vmessServer = try c.decodeIfPresent(String.self, forKey: .vmessServer) ?? ""
        vmessPort = try c.decodeIfPresent(Int.self, forKey: .vmessPort) ?? 443
        vmessUUID = try c.decodeIfPresent(String.self, forKey: .vmessUUID) ?? ""
        vmessAltID = try c.decodeIfPresent(Int.self, forKey: .vmessAltID) ?? 0
        tailscaleHostname = try c.decodeIfPresent(String.self, forKey: .tailscaleHostname) ?? ""
        tailscaleAcceptRoutes = try c.decodeIfPresent(Bool.self, forKey: .tailscaleAcceptRoutes) ?? true
        tailscaleExitNode = try c.decodeIfPresent(String.self, forKey: .tailscaleExitNode) ?? ""
        tailscaleAuthenticated = try c.decodeIfPresent(
            Bool.self,
            forKey: .tailscaleAuthenticated
        ) ?? false
        allowInsecure = try c.decodeIfPresent(Bool.self, forKey: .allowInsecure) ?? false
    }
}

struct RuleSet: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var type: String  // url / manual
    var enabled: Bool = true
    var url: String = ""
    var format: String = "auto"
    var domains: [String] = []
    var cidrs: [String] = []

    static let connectivityDirectID = "xdial-connectivity-direct"
    static let connectivityAnyConnectID = "xdial-connectivity-anyconnect"
    /// 保留旧持久化 ID，避免升级时短暂出现第三条规则；语义已经从
    /// “AnyConnect”迁移为当前模式中确定选出的非 Direct 验收出口。
    static let connectivityOutboundID = connectivityAnyConnectID

    static func isConnectivityTestRuleID(_ id: String) -> Bool {
        id == connectivityDirectID || id == connectivityOutboundID
    }

    var isConnectivityTestRule: Bool {
        Self.isConnectivityTestRuleID(id)
    }
}

struct RuleBinding: Codable, Hashable, Identifiable {
    var ruleSetID: String
    var lineID: String = ""
    var subscriptionID: String = ""

    var id: String { ruleSetID }

    var targetID: String {
        get { subscriptionID.isEmpty ? "port:\(lineID)" : "sub:\(subscriptionID)" }
        set {
            if newValue.hasPrefix("sub:") {
                subscriptionID = String(newValue.dropFirst(4)); lineID = ""
            } else {
                lineID = newValue.hasPrefix("port:") ? String(newValue.dropFirst(5)) : newValue
                subscriptionID = ""
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case ruleSetID = "rule_set_id"
        case lineID = "line_id"
        case subscriptionID = "subscription_id"
    }

    init(ruleSetID: String, lineID: String = "", subscriptionID: String = "") {
        self.ruleSetID = ruleSetID
        self.lineID = lineID
        self.subscriptionID = subscriptionID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ruleSetID = try c.decode(String.self, forKey: .ruleSetID)
        lineID = try c.decodeIfPresent(String.self, forKey: .lineID) ?? ""
        subscriptionID = try c.decodeIfPresent(String.self, forKey: .subscriptionID) ?? ""
    }
}

struct SubProxyGroup: Codable, Hashable {
    var name: String
    var type: String
    var proxies: [String] = []
    var selected: String = ""
    var url: String = ""
    var interval: Int = 0

    init(
        name: String,
        type: String,
        proxies: [String] = [],
        selected: String = "",
        url: String = "",
        interval: Int = 0
    ) {
        self.name = name
        self.type = type
        self.proxies = proxies
        self.selected = selected
        self.url = url
        self.interval = interval
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(String.self, forKey: .type)
        proxies = try c.decodeIfPresent([String].self, forKey: .proxies) ?? []
        selected = try c.decodeIfPresent(String.self, forKey: .selected) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        interval = try c.decodeIfPresent(Int.self, forKey: .interval) ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case name, type, proxies, selected, url, interval
    }
}

struct SubRule: Codable, Hashable {
    var type: String
    var value: String = ""
    var group: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        group = try c.decode(String.self, forKey: .group)
    }

    enum CodingKeys: String, CodingKey {
        case type, value, group
    }
}

struct Subscription: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var url: String
    var format: String = "auto"
    var enabled: Bool = true
    var strategy: String = "urltest"
    var selected: String = ""
    var lines: [Line] = []
    var proxyGroups: [SubProxyGroup] = []
    var rules: [SubRule] = []
    var updatedAt: Int = 0
    var testURL: String = "https://www.gstatic.com/generate_204"
    var testInterval: Int = 300

    enum CodingKeys: String, CodingKey {
        case id, name, url, format, enabled, strategy, selected, rules
        case lines = "lines"
        case proxyGroups = "proxy_groups"
        case updatedAt = "updated_at"
        case testURL = "test_url"
        case testInterval = "test_interval"
    }

    init(id: String, name: String, url: String, format: String = "auto",
         strategy: String = "urltest", lines: [Line] = [],
         proxyGroups: [SubProxyGroup] = [], rules: [SubRule] = [], selected: String = "") {
        self.id = id; self.name = name; self.url = url; self.format = format
        self.strategy = strategy; self.lines = lines
        self.selected = selected
        self.proxyGroups = proxyGroups; self.rules = rules
        self.updatedAt = Int(Date().timeIntervalSince1970)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(String.self, forKey: .url)
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? "auto"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        strategy = try c.decodeIfPresent(String.self, forKey: .strategy) ?? "urltest"
        selected = try c.decodeIfPresent(String.self, forKey: .selected) ?? ""
        lines = try c.decodeIfPresent([Line].self, forKey: .lines) ?? []
        proxyGroups = try c.decodeIfPresent([SubProxyGroup].self, forKey: .proxyGroups) ?? []
        rules = try c.decodeIfPresent([SubRule].self, forKey: .rules) ?? []
        updatedAt = try c.decodeIfPresent(Int.self, forKey: .updatedAt) ?? 0
        testURL = try c.decodeIfPresent(String.self, forKey: .testURL) ?? "https://www.gstatic.com/generate_204"
        testInterval = try c.decodeIfPresent(Int.self, forKey: .testInterval) ?? 300
    }
}

struct Mode: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var bindings: [RuleBinding] = []
    var defaultLineID: String = ""
    var defaultSubscriptionID: String = ""

    var defaultTargetID: String {
        get { defaultSubscriptionID.isEmpty ? "port:\(defaultLineID)" : "sub:\(defaultSubscriptionID)" }
        set {
            if newValue.hasPrefix("sub:") {
                defaultSubscriptionID = String(newValue.dropFirst(4)); defaultLineID = ""
            } else {
                defaultLineID = newValue.hasPrefix("port:") ? String(newValue.dropFirst(5)) : newValue
                defaultSubscriptionID = ""
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, bindings
        case defaultLineID = "default_line_id"
        case defaultSubscriptionID = "default_subscription_id"
    }

    init(id: String, name: String, bindings: [RuleBinding] = [], defaultLineID: String = "", defaultSubscriptionID: String = "") {
        self.id = id; self.name = name; self.bindings = bindings
        self.defaultLineID = defaultLineID; self.defaultSubscriptionID = defaultSubscriptionID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        bindings = try c.decodeIfPresent([RuleBinding].self, forKey: .bindings) ?? []
        defaultLineID = try c.decodeIfPresent(String.self, forKey: .defaultLineID) ?? ""
        defaultSubscriptionID = try c.decodeIfPresent(String.self, forKey: .defaultSubscriptionID) ?? ""
    }
}

struct Profile: Codable, Equatable {
    var lines: [Line] = []
    var ruleSets: [RuleSet] = []
    var modes: [Mode] = []
    var subscriptions: [Subscription] = []
    var activeModeID: String = ""

    enum CodingKeys: String, CodingKey {
        case lines = "lines"
        case ruleSets = "rule_sets"
        case modes = "modes"
        case subscriptions
        case activeModeID = "active_mode_id"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lines = try c.decodeIfPresent([Line].self, forKey: .lines) ?? []
        ruleSets = try c.decodeIfPresent([RuleSet].self, forKey: .ruleSets) ?? []
        modes = try c.decodeIfPresent([Mode].self, forKey: .modes) ?? []
        subscriptions = try c.decodeIfPresent([Subscription].self, forKey: .subscriptions) ?? []
        activeModeID = try c.decodeIfPresent(String.self, forKey: .activeModeID) ?? ""
    }
}

struct ActiveRouteTargetSummary: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let type: String
    let isSubscription: Bool
}

extension Profile {
    private static var connectivityRuleSets: [RuleSet] {
        [
            RuleSet(
                id: RuleSet.connectivityDirectID,
                name: "连接验收 · Direct",
                type: "manual",
                cidrs: ["1.0.0.1/32"]
            ),
            RuleSet(
                id: RuleSet.connectivityOutboundID,
                name: "连接验收 · 非 Direct 出口",
                type: "manual",
                cidrs: ["1.1.1.1/32"]
            ),
        ]
    }

    static func connectivityBindings(outboundLineID: String, directLineID: String) -> [RuleBinding] {
        var bindings: [RuleBinding] = []
        if !directLineID.isEmpty {
            bindings.append(RuleBinding(
                ruleSetID: RuleSet.connectivityDirectID,
                lineID: directLineID
            ))
        }
        if !outboundLineID.isEmpty && outboundLineID != directLineID {
            bindings.append(RuleBinding(
                ruleSetID: RuleSet.connectivityOutboundID,
                lineID: outboundLineID
            ))
        }
        return bindings
    }

    /// 返回模式中用于双出口路由验收的非 Direct 目标。选择顺序是协议的一部分：
    /// 非 Direct 默认出口优先；否则按普通、已启用规则绑定的原始顺序取首个。
    /// 锁定验收规则自身不会参与选择，避免旧错误绑定把迁移继续带错。
    func connectivityOutboundBinding(for mode: Mode) -> RuleBinding? {
        func isAvailableNonDirect(_ binding: RuleBinding) -> Bool {
            if !binding.subscriptionID.isEmpty {
                return subscriptions.contains {
                    $0.id == binding.subscriptionID && $0.enabled
                        && $0.lines.contains(where: { $0.enabled })
                }
            }
            guard !binding.lineID.isEmpty,
                  let line = lines.first(where: {
                      $0.id == binding.lineID && $0.enabled
                  }) else { return false }
            if line.type == "tailscale" {
                // An overlay-only endpoint is globally generated for subnet
                // routes, but it is not a public egress for the 1.1.1.1 probe.
                return !line.tailscaleExitNode
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            }
            return line.type != "direct"
        }

        let defaultBinding = RuleBinding(
            ruleSetID: RuleSet.connectivityOutboundID,
            lineID: mode.defaultLineID,
            subscriptionID: mode.defaultSubscriptionID
        )
        if isAvailableNonDirect(defaultBinding) {
            return defaultBinding
        }

        for binding in mode.bindings where !binding.ruleSetID.isEmpty {
            guard !RuleSet.isConnectivityTestRuleID(binding.ruleSetID),
            ruleSets.first(where: { $0.id == binding.ruleSetID })?.enabled == true,
            isAvailableNonDirect(binding) else {
                continue
            }
            return RuleBinding(
                ruleSetID: RuleSet.connectivityOutboundID,
                lineID: binding.lineID,
                subscriptionID: binding.subscriptionID
            )
        }
        return nil
    }

    /// 与生成器的活动目标语义一致：默认出口始终计入；只有 enabled 规则的绑定
    /// 计入；线路和订阅统一去重。主页使用这一份摘要，避免订阅模式被误显示成
    /// “没有线路”，也避免 disabled 规则把未运行目标带进来。
    func activeRouteTargetSummaries(for mode: Mode) -> [ActiveRouteTargetSummary] {
        var result: [ActiveRouteTargetSummary] = []
        var seen = Set<String>()

        func append(lineID: String, subscriptionID: String) {
            if !subscriptionID.isEmpty {
                let key = "sub:\(subscriptionID)"
                guard seen.insert(key).inserted,
                      let subscription = subscriptions.first(where: {
                          $0.id == subscriptionID && $0.enabled
                              && $0.lines.contains(where: { $0.enabled })
                      }) else { return }
                result.append(ActiveRouteTargetSummary(
                    id: key,
                    name: subscription.name,
                    type: "subscription",
                    isSubscription: true
                ))
                return
            }
            let key = "port:\(lineID)"
            guard !lineID.isEmpty, seen.insert(key).inserted,
                  let line = lines.first(where: {
                      $0.id == lineID && $0.enabled
                  }) else { return }
            result.append(ActiveRouteTargetSummary(
                id: key,
                name: line.name,
                type: line.type,
                isSubscription: false
            ))
        }

        append(
            lineID: mode.defaultLineID,
            subscriptionID: mode.defaultSubscriptionID
        )
        for binding in mode.bindings {
            guard ruleSets.first(where: { $0.id == binding.ruleSetID })?.enabled == true else {
                continue
            }
            append(lineID: binding.lineID, subscriptionID: binding.subscriptionID)
        }
        return result
    }

    /// 连接验收规则是真实 profile 的一部分，会在配置页展示，而不是生成器
    /// 暗中注入的路由。旧 profile 升级时会恢复两条精确 CIDR；第二条只绑定
    /// 确定选出的非 Direct 活动目标。纯 Direct 模式不伪造第二个出口。
    @discardableResult
    mutating func ensureConnectivityTestConfiguration() -> Bool {
        let before = self

        for expected in Self.connectivityRuleSets {
            if let index = ruleSets.firstIndex(where: { $0.id == expected.id }) {
                ruleSets[index] = expected
            } else {
                ruleSets.append(expected)
            }
        }

        let directLineID = lines.first(where: { $0.type == "direct" && $0.enabled })?.id ?? ""
        for index in modes.indices {
            let ordinaryBindings = modes[index].bindings.filter {
                $0.ruleSetID != RuleSet.connectivityDirectID
                    && $0.ruleSetID != RuleSet.connectivityOutboundID
            }
            var selectionMode = modes[index]
            selectionMode.bindings = ordinaryBindings
            let outboundBinding = connectivityOutboundBinding(for: selectionMode)
            var acceptanceBindings: [RuleBinding] = []
            if !directLineID.isEmpty {
                acceptanceBindings.append(RuleBinding(
                    ruleSetID: RuleSet.connectivityDirectID,
                    lineID: directLineID
                ))
            }
            if let outboundBinding {
                acceptanceBindings.append(outboundBinding)
            }
            modes[index].bindings = acceptanceBindings + ordinaryBindings
        }

        return self != before
    }

    static func bootstrap() -> Profile {
        var p = Profile()
        p.lines = [
            Line(id: "direct", name: "直连", type: "direct", verified: true),
            Line(id: "vpn", name: "AnyConnect", type: "vpn"),
            Line(id: "ss", name: "SS 节点", type: "trojan", enabled: false),
        ]
        p.ruleSets = [
            RuleSet(id: "internal", name: "内部域名", type: "manual"),
            RuleSet(id: "gfw", name: "GFW",
                  type: "url",
                  url: "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-gfw.srs",
                  format: "srs"),
            RuleSet(id: "cnip", name: "国内 IP", type: "url", enabled: false,
                  url: "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-cn.srs",
                  format: "srs"),
        ] + connectivityRuleSets
        return p
    }

    static func templateOverseas(ruleSetIDs: [String], vpnLineID: String, directLineID: String) -> Mode {
        Mode(
            id: UUID().uuidString,
            name: "海外",
            bindings: connectivityBindings(outboundLineID: vpnLineID, directLineID: directLineID)
                + ruleSetIDs.filter { id in
                    id != RuleSet.connectivityDirectID && id != RuleSet.connectivityAnyConnectID
                }.map { RuleBinding(ruleSetID: $0, lineID: vpnLineID) },
            defaultLineID: directLineID
        )
    }

    static func templateDomestic(ruleSetIDs: [String], gfwRuleSetID: String, vpnLineID: String, directLineID: String) -> Mode {
        var bindings = connectivityBindings(outboundLineID: vpnLineID, directLineID: directLineID)
            + ruleSetIDs.filter { id in
                id != RuleSet.connectivityDirectID && id != RuleSet.connectivityAnyConnectID
            }.map { RuleBinding(ruleSetID: $0, lineID: vpnLineID) }
        if !gfwRuleSetID.isEmpty {
            bindings.append(RuleBinding(ruleSetID: gfwRuleSetID, lineID: vpnLineID))
        }
        return Mode(
            id: UUID().uuidString,
            name: "国内",
            bindings: bindings,
            defaultLineID: directLineID
        )
    }

    static func templateDomesticSS(ruleSetIDs: [String], gfwRuleSetID: String, vpnLineID: String, ssLineID: String, directLineID: String) -> Mode {
        var bindings = connectivityBindings(outboundLineID: ssLineID, directLineID: directLineID)
            + ruleSetIDs.filter { id in
                id != RuleSet.connectivityDirectID && id != RuleSet.connectivityAnyConnectID
            }.map { RuleBinding(ruleSetID: $0, lineID: vpnLineID) }
        if !gfwRuleSetID.isEmpty {
            bindings.append(RuleBinding(ruleSetID: gfwRuleSetID, lineID: ssLineID))
        }
        return Mode(
            id: UUID().uuidString,
            name: "国内+SS",
            bindings: bindings,
            defaultLineID: directLineID
        )
    }
}
