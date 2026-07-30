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

    // Tailscale 身份由 Profile 全局共享；Line 只选择本线路使用的 exit node。
    var tailscaleExitNode: String = ""

    // 跳过 TLS 证书验证（自签场景显式开启）。默认 false=验证证书。
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
        case tailscaleExitNode = "tailscale_exit_node"
    }

    init(id: String, name: String, type: String, enabled: Bool = true, verified: Bool = false,
         vpnServer: String = "", vpnUsername: String = "", vpnPassword: String = "",
         trojanServer: String = "", trojanPort: Int = 443, trojanPassword: String = "", trojanSNI: String = "",
         ssServer: String = "", ssPort: Int = 8388, ssMethod: String = "aes-256-gcm", ssPassword: String = "",
         vmessServer: String = "", vmessPort: Int = 443, vmessUUID: String = "", vmessAltID: Int = 0,
         tailscaleExitNode: String = "",
         allowInsecure: Bool = false) {
        self.id = id; self.name = name; self.type = type; self.enabled = enabled; self.verified = verified
        self.vpnServer = vpnServer; self.vpnUsername = vpnUsername; self.vpnPassword = vpnPassword
        self.trojanServer = trojanServer; self.trojanPort = trojanPort; self.trojanPassword = trojanPassword; self.trojanSNI = trojanSNI
        self.ssServer = ssServer; self.ssPort = ssPort; self.ssMethod = ssMethod; self.ssPassword = ssPassword
        self.vmessServer = vmessServer; self.vmessPort = vmessPort; self.vmessUUID = vmessUUID; self.vmessAltID = vmessAltID
        self.tailscaleExitNode = tailscaleExitNode
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
        tailscaleExitNode = try c.decodeIfPresent(String.self, forKey: .tailscaleExitNode) ?? ""
        allowInsecure = try c.decodeIfPresent(Bool.self, forKey: .allowInsecure) ?? false
    }
}

struct TailscaleIdentity: Codable, Hashable {
    var hostname: String = ""
}

struct TailscaleRuntimeExitNode: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let ip: String
    let online: Bool
    let os: String
}

struct TailscaleRuntimeStatus: Decodable, Hashable {
    let backendState: String
    let authURL: String
    let exitNodes: [TailscaleRuntimeExitNode]

    enum CodingKeys: String, CodingKey {
        case backendState = "backend_state"
        case authURL = "auth_url"
        case exitNodes = "exit_nodes"
    }

    var isRunning: Bool { backendState.lowercased() == "running" }
}

struct RuleSet: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var type: String  // url / manual
    var enabled: Bool = true
    var url: String = ""
    var format: String = "auto"
    /// 仅用于 URL RuleSet。true 表示匹配远程列表之外的目标，例如
    /// “海外 IP”复用国内 IP 列表并取反，不需要维护一份容易漂移的世界 CIDR 副本。
    var invert: Bool = false
    var domains: [String] = []
    var cidrs: [String] = []

    init(
        id: String,
        name: String,
        type: String,
        enabled: Bool = true,
        url: String = "",
        format: String = "auto",
        invert: Bool = false,
        domains: [String] = [],
        cidrs: [String] = []
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.enabled = enabled
        self.url = url
        self.format = format
        self.invert = invert
        self.domains = domains
        self.cidrs = cidrs
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case type
        case enabled
        case url
        case format
        case invert
        case domains
        case cidrs
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        type = try values.decode(String.self, forKey: .type)
        enabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .enabled
        ) ?? true
        url = try values.decodeIfPresent(
            String.self,
            forKey: .url
        ) ?? ""
        format = try values.decodeIfPresent(
            String.self,
            forKey: .format
        ) ?? "auto"
        invert = try values.decodeIfPresent(
            Bool.self,
            forKey: .invert
        ) ?? false
        domains = try values.decodeIfPresent(
            [String].self,
            forKey: .domains
        ) ?? []
        cidrs = try values.decodeIfPresent(
            [String].self,
            forKey: .cidrs
        ) ?? []
    }

    /// 清洗单条域名/CIDR 条目：剥掉所有控制与格式类字符（粘贴常混入
    /// \u{03}、零宽空格、BOM 等，Cc/Cf 两类都在 controlCharacters 集合里），
    /// 再去首尾空白。这类字符一旦写进 domain_suffix，规则永远匹配不中，
    /// 且在 UI 里不可见——用户以为绑定了实际没绑上。
    static func sanitizeEntry(_ raw: String) -> String {
        let stripped = String(String.UnicodeScalarView(
            raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        return stripped.trimmingCharacters(in: .whitespaces)
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

struct Profile: Codable {
    var lines: [Line] = []
    var ruleSets: [RuleSet] = []
    var modes: [Mode] = []
    var subscriptions: [Subscription] = []
    var activeModeID: String = ""
    var tailscale = TailscaleIdentity()

    enum CodingKeys: String, CodingKey {
        case lines = "lines"
        case ruleSets = "rule_sets"
        case modes = "modes"
        case subscriptions
        case activeModeID = "active_mode_id"
        case tailscale
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lines = try c.decodeIfPresent([Line].self, forKey: .lines) ?? []
        ruleSets = try c.decodeIfPresent([RuleSet].self, forKey: .ruleSets) ?? []
        modes = try c.decodeIfPresent([Mode].self, forKey: .modes) ?? []
        subscriptions = try c.decodeIfPresent([Subscription].self, forKey: .subscriptions) ?? []
        activeModeID = try c.decodeIfPresent(String.self, forKey: .activeModeID) ?? ""
        tailscale = try c.decodeIfPresent(TailscaleIdentity.self, forKey: .tailscale) ?? TailscaleIdentity()
    }
}

extension Profile {
    static func bootstrap() -> Profile {
        var p = Profile()
        p.lines = [
            Line(id: "direct", name: "直连", type: "direct", verified: true),
            Line(id: "vpn", name: "VPN", type: "vpn"),
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
        ]
        return p
    }

    static func templateOverseas(ruleSetIDs: [String], vpnLineID: String, directLineID: String) -> Mode {
        Mode(
            id: UUID().uuidString,
            name: "海外",
            bindings: ruleSetIDs.map { RuleBinding(ruleSetID: $0, lineID: vpnLineID) },
            defaultLineID: directLineID
        )
    }

    static func templateDomestic(ruleSetIDs: [String], gfwRuleSetID: String, vpnLineID: String, directLineID: String) -> Mode {
        var bindings = ruleSetIDs.map { RuleBinding(ruleSetID: $0, lineID: vpnLineID) }
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
        var bindings = ruleSetIDs.map { RuleBinding(ruleSetID: $0, lineID: vpnLineID) }
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
