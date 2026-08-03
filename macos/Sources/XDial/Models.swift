import Foundation

struct Line: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var type: String  // direct / vpn / trojan / shadowsocks / vmess / anytls / tailscale
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

    var anytlsServer: String = ""
    var anytlsPort: Int = 443
    var anytlsPassword: String = ""
    var anytlsSNI: String = ""
    var anytlsClientFingerprint: String = "chrome"
    var anytlsALPN: [String] = ["h2"]
    var anytlsIdleSessionCheckInterval: Int = 30
    var anytlsIdleSessionTimeout: Int = 30
    var anytlsMinIdleSession: Int = 0

    // 通用拨号能力。订阅导入必须无损保留；具体协议是否允许由生成阶段
    // fail-closed 校验，不能在 Swift decode 时静默丢掉。
    var udp: Bool = false
    var tfo: Bool = false

    // Tailscale 身份由 Profile 全局共享；Line 选择本线路使用的
    // exit node，并显式决定是否启用 MagicDNS 与节点路由。
    var tailscaleExitNode: String = ""
    var tailscaleMagicDNS: Bool = false

    // 跳过 TLS 证书验证（自签场景显式开启）。默认 false=验证证书。
    var allowInsecure: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, name, type, enabled, verified
        case udp, tfo
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
        case anytlsServer = "anytls_server"
        case anytlsPort = "anytls_port"
        case anytlsPassword = "anytls_password"
        case anytlsSNI = "anytls_sni"
        case anytlsClientFingerprint = "anytls_client_fingerprint"
        case anytlsALPN = "anytls_alpn"
        case anytlsIdleSessionCheckInterval =
            "anytls_idle_session_check_interval"
        case anytlsIdleSessionTimeout = "anytls_idle_session_timeout"
        case anytlsMinIdleSession = "anytls_min_idle_session"
        case tailscaleExitNode = "tailscale_exit_node"
        case tailscaleMagicDNS = "tailscale_magic_dns"
    }

    init(id: String, name: String, type: String, enabled: Bool = true, verified: Bool = false,
         vpnServer: String = "", vpnUsername: String = "", vpnPassword: String = "",
         trojanServer: String = "", trojanPort: Int = 443, trojanPassword: String = "", trojanSNI: String = "",
         ssServer: String = "", ssPort: Int = 8388, ssMethod: String = "aes-256-gcm", ssPassword: String = "",
         vmessServer: String = "", vmessPort: Int = 443, vmessUUID: String = "", vmessAltID: Int = 0,
         anytlsServer: String = "", anytlsPort: Int = 443, anytlsPassword: String = "", anytlsSNI: String = "",
         anytlsClientFingerprint: String = "chrome", anytlsALPN: [String] = ["h2"],
         anytlsIdleSessionCheckInterval: Int = 30, anytlsIdleSessionTimeout: Int = 30,
         anytlsMinIdleSession: Int = 0,
         udp: Bool? = nil, tfo: Bool = false,
         tailscaleExitNode: String = "", tailscaleMagicDNS: Bool = false,
         allowInsecure: Bool = false) {
        self.id = id; self.name = name; self.type = type; self.enabled = enabled; self.verified = verified
        self.vpnServer = vpnServer; self.vpnUsername = vpnUsername; self.vpnPassword = vpnPassword
        self.trojanServer = trojanServer; self.trojanPort = trojanPort; self.trojanPassword = trojanPassword; self.trojanSNI = trojanSNI
        self.ssServer = ssServer; self.ssPort = ssPort; self.ssMethod = ssMethod; self.ssPassword = ssPassword
        self.vmessServer = vmessServer; self.vmessPort = vmessPort; self.vmessUUID = vmessUUID; self.vmessAltID = vmessAltID
        self.anytlsServer = anytlsServer; self.anytlsPort = anytlsPort; self.anytlsPassword = anytlsPassword; self.anytlsSNI = anytlsSNI
        self.anytlsClientFingerprint = anytlsClientFingerprint
        self.anytlsALPN = anytlsALPN
        self.anytlsIdleSessionCheckInterval = anytlsIdleSessionCheckInterval
        self.anytlsIdleSessionTimeout = anytlsIdleSessionTimeout
        self.anytlsMinIdleSession = anytlsMinIdleSession
        // AnyTLS always exposes native UoT in the embedded sing-box runtime.
        // Keep an explicitly imported false as source metadata, but make new
        // manually created AnyTLS Lines describe their real capability.
        self.udp = udp ?? (type == "anytls")
        self.tfo = tfo
        self.tailscaleExitNode = tailscaleExitNode
        self.tailscaleMagicDNS = tailscaleMagicDNS
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
        anytlsServer = try c.decodeIfPresent(String.self, forKey: .anytlsServer) ?? ""
        anytlsPort = try c.decodeIfPresent(Int.self, forKey: .anytlsPort) ?? 443
        anytlsPassword = try c.decodeIfPresent(String.self, forKey: .anytlsPassword) ?? ""
        anytlsSNI = try c.decodeIfPresent(String.self, forKey: .anytlsSNI) ?? ""
        // 缺少这些 key 表示旧版 Profile。不能把新建线路的推荐值强行
        // 注入存量线路，否则一次升级就会静默改变 TLS ClientHello / ALPN。
        anytlsClientFingerprint = try c.decodeIfPresent(
            String.self,
            forKey: .anytlsClientFingerprint
        ) ?? ""
        anytlsALPN = try c.decodeIfPresent(
            [String].self,
            forKey: .anytlsALPN
        ) ?? []
        anytlsIdleSessionCheckInterval = try c.decodeIfPresent(
            Int.self,
            forKey: .anytlsIdleSessionCheckInterval
        ) ?? 0
        anytlsIdleSessionTimeout = try c.decodeIfPresent(
            Int.self,
            forKey: .anytlsIdleSessionTimeout
        ) ?? 0
        anytlsMinIdleSession = try c.decodeIfPresent(
            Int.self,
            forKey: .anytlsMinIdleSession
        ) ?? 0
        udp = try c.decodeIfPresent(Bool.self, forKey: .udp) ?? false
        tfo = try c.decodeIfPresent(Bool.self, forKey: .tfo) ?? false
        tailscaleExitNode = try c.decodeIfPresent(String.self, forKey: .tailscaleExitNode) ?? ""
        tailscaleMagicDNS = try c.decodeIfPresent(Bool.self, forKey: .tailscaleMagicDNS) ?? false
        allowInsecure = try c.decodeIfPresent(Bool.self, forKey: .allowInsecure) ?? false
    }

    /// sing-box 当前 `uTLSClientHelloID` 实际接受的值。`chrome_*`
    /// 已被上游废弃，但仍会明确兼容映射到 Chrome；保留它们可避免旧订阅
    /// 因 UI 保存而被无声改写。
    static let anyTLSSupportedClientFingerprints = [
        "",
        "chrome",
        "firefox",
        "edge",
        "safari",
        "360",
        "qq",
        "ios",
        "android",
        "random",
        "randomized",
        "chrome_psk",
        "chrome_psk_shuffle",
        "chrome_padding_psk_shuffle",
        "chrome_pq",
        "chrome_pq_psk",
    ]

    static let anyTLSIdleSessionIntervalRange = 6...3600
    static let anyTLSMinIdleSessionRange = 0...64
    static let anyTLSMaximumALPNCount = 8

    /// 空数组表示不显式指定 ALPN。非空值按 RFC 7301 的协议名长度约束
    /// 校验；协议名是 opaque byte string，因此不能擅自限制为 ASCII。
    static func validateAnyTLSALPN(_ protocols: [String]) -> String? {
        guard protocols.count <= anyTLSMaximumALPNCount else {
            return "ALPN 最多只能填写 \(anyTLSMaximumALPNCount) 项"
        }
        var seen = Set<String>()
        for value in protocols {
            guard !value.isEmpty else {
                return "ALPN 协议名不能为空"
            }
            guard value.utf8.count <= 255 else {
                return "单个 ALPN 协议名不能超过 255 字节"
            }
            guard value.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            }) else {
                return "ALPN 协议名不能包含控制字符"
            }
            guard seen.insert(value).inserted else {
                return "ALPN 协议名不能重复"
            }
        }
        return nil
    }

    /// 返回当前 AnyTLS 传输选项的首个可见问题。0 秒只作为旧 Profile
    /// 的“未显式指定”哨兵；新建线路仍明确写入推荐的 30 秒。
    var anyTLSOptionsValidationIssue: String? {
        guard type == "anytls" else { return nil }
        if tfo {
            return "AnyTLS 不支持 TCP Fast Open，请关闭 TFO"
        }
        if !Self.anyTLSSupportedClientFingerprints.contains(
            anytlsClientFingerprint
        ) {
            return "不支持的 TLS 客户端指纹"
        }
        if let issue = Self.validateAnyTLSALPN(anytlsALPN) {
            return issue
        }
        if anytlsIdleSessionCheckInterval != 0,
           !Self.anyTLSIdleSessionIntervalRange.contains(
               anytlsIdleSessionCheckInterval
           ) {
            return "空闲检查间隔必须是 6–3600 秒，或 0 表示使用协议默认值"
        }
        if anytlsIdleSessionTimeout != 0,
           !Self.anyTLSIdleSessionIntervalRange.contains(
               anytlsIdleSessionTimeout
           ) {
            return "空闲超时必须是 6–3600 秒，或 0 表示使用协议默认值"
        }
        if !Self.anyTLSMinIdleSessionRange.contains(anytlsMinIdleSession) {
            return "最少空闲会话数必须是 0–64"
        }
        return nil
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

/// 一个被用户选入应用 RuleSet 的 App Bundle。数据面按规范化 Bundle 路径前缀
/// 匹配 audit token 对应的真实可执行文件，与 Surge Mac 的 App Bundle 模式一致。
struct ApplicationRuleApplication: Codable, Identifiable, Hashable {
    var name: String
    var path: String
    private var containedLegacyIdentities = false

    var id: String { path }

    init(name: String, path: String) {
        self.name = name
        self.path = path
    }

    enum CodingKeys: String, CodingKey {
        case name
        case path
        case identities
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        path = try values.decode(String.self, forKey: .path)
        // 旧版递归持久化的 signing identities 不再参与匹配。保留这个内存标记
        // 只为让 loadSaved 的清洗迁移检测到差异并立即回写，新的编码永不输出它们。
        containedLegacyIdentities = values.contains(.identities)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
        try values.encode(path, forKey: .path)
    }
}

struct RuleSet: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var type: String  // url / manual / application
    var enabled: Bool = true
    var url: String = ""
    var format: String = "auto"
    /// 仅用于 URL RuleSet。true 表示匹配远程列表之外的目标，例如
    /// “海外 IP”复用国内 IP 列表并取反，不需要维护一份容易漂移的世界 CIDR 副本。
    var invert: Bool = false
    var domains: [String] = []
    var cidrs: [String] = []
    var applications: [ApplicationRuleApplication] = []

    init(
        id: String,
        name: String,
        type: String,
        enabled: Bool = true,
        url: String = "",
        format: String = "auto",
        invert: Bool = false,
        domains: [String] = [],
        cidrs: [String] = [],
        applications: [ApplicationRuleApplication] = []
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
        self.applications = applications
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
        case applications
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
        applications = try values.decodeIfPresent(
            [ApplicationRuleApplication].self,
            forKey: .applications
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

    static func sanitizeApplications(
        _ applications: [ApplicationRuleApplication]
    ) -> [ApplicationRuleApplication] {
        var applicationsByPath: [String: ApplicationRuleApplication] = [:]
        for application in applications {
            let rawPath = application.path.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard rawPath.hasPrefix("/") else { continue }
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            guard
                path == rawPath,
                URL(fileURLWithPath: path).pathExtension
                    .localizedCaseInsensitiveCompare("app") == .orderedSame,
                URL(fileURLWithPath: path).deletingPathExtension()
                    .lastPathComponent.isEmpty == false
            else { continue }
            let name = sanitizeEntry(application.name)
            let normalized = ApplicationRuleApplication(
                name: name.isEmpty
                    ? URL(fileURLWithPath: path).deletingPathExtension()
                        .lastPathComponent
                    : name,
                path: path
            )
            if applicationsByPath[path] == nil {
                applicationsByPath[path] = normalized
            }
        }
        return applicationsByPath.values.sorted { lhs, rhs in
            lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
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

struct Profile: Codable, Hashable {
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
