import Foundation

struct Line: Codable, Identifiable, Hashable {
    var groupMembers: [String] = []
    var groupDefault: String = ""
    var groupURL: String = ""
    var groupInterval: String = ""
    var nativeOptions: JSONValue?
    var isGroup: Bool { type == "selector" || type == "urltest" }

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
        case groupMembers = "group_members"
        case groupDefault = "group_default"
        case groupURL = "group_url"
        case groupInterval = "group_interval"
        case nativeOptions = "native_options"
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
        groupMembers = try c.decodeIfPresent([String].self, forKey: .groupMembers) ?? []
        groupDefault = try c.decodeIfPresent(String.self, forKey: .groupDefault) ?? ""
        groupURL = try c.decodeIfPresent(String.self, forKey: .groupURL) ?? ""
        groupInterval = try c.decodeIfPresent(String.self, forKey: .groupInterval) ?? ""
        nativeOptions = try c.decodeIfPresent(JSONValue.self, forKey: .nativeOptions)
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

    init(hostname: String = "") { self.hostname = hostname }

    enum CodingKeys: String, CodingKey { case hostname }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Go omits an unset hostname and emits an empty identity object.
        hostname = try values.decodeIfPresent(String.self, forKey: .hostname) ?? ""
    }
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

/// 一个被用户选入应用 RuleSet 的 App Bundle。Bundle ID 用于 macOS 直接提供的
/// source-app 归因，规范化 Bundle 路径用于 audit token 可解析时的交叉验证和兜底。
struct ApplicationRuleApplication: Codable, Identifiable, Hashable {
    var name: String
    var path: String
    var bundleIdentifier: String?
    private var containedLegacyIdentities = false

    var id: String { path }

    init(name: String, path: String, bundleIdentifier: String? = nil) {
        self.name = name
        self.path = path
        self.bundleIdentifier = bundleIdentifier
    }

    enum CodingKeys: String, CodingKey {
        case name
        case path
        case bundleIdentifier = "bundle_identifier"
        case identities
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        path = try values.decode(String.self, forKey: .path)
        bundleIdentifier = try values.decodeIfPresent(
            String.self,
            forKey: .bundleIdentifier
        )
        // 旧版递归持久化的 signing identities 不再参与匹配。保留这个内存标记
        // 只为让 loadSaved 的清洗迁移检测到差异并立即回写，新的编码永不输出它们。
        containedLegacyIdentities = values.contains(.identities)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
        try values.encode(path, forKey: .path)
        try values.encodeIfPresent(
            bundleIdentifier,
            forKey: .bundleIdentifier
        )
    }
}

struct RuleSet: Codable, Identifiable, Hashable {
    var conditions: [RuleSet] = []
    var matchingResources: [RuleSet] { type == "group" ? conditions : [self] }
    func contentSummary(chinese: Bool) -> String {
        var domains = 0, ips = 0, apps = 0, remote = 0
        func countNative(_ value: JSONValue) {
            guard case let .object(fields) = value else { return }
            for (key, value) in fields {
                if key == "rules", case let .array(children) = value { children.forEach(countNative); continue }
                let count: Int
                if case let .array(items) = value { count = items.count }
                else if case .string = value { count = 1 }
                else { count = 0 }
                if key.hasPrefix("domain") { domains += count }
                if key == "ip_cidr" { ips += count }
            }
        }
        for item in matchingResources {
            domains += item.domains.count; ips += item.cidrs.count
            apps += item.applications.count + item.processes.count
            if item.type == "url" { remote += 1 }
            if let native = item.nativeRule { countNative(native) }
        }
        let parts = [(chinese ? "域名" : "Domains", domains), ("IP", ips),
                     (chinese ? "应用" : "Apps", apps), (chinese ? "远程" : "Remote", remote)]
            .filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? (chinese ? "待添加匹配内容" : "Add matching content") : parts.joined(separator: " · ")
    }
    /// Search the predicates directly, without formatting large JSON documents.
    func matchesSearch(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        func contains(_ value: String) -> Bool { value.localizedCaseInsensitiveContains(query) }
        func searchJSON(_ value: JSONValue) -> Bool {
            switch value {
            case let .string(text): return contains(text)
            case let .array(values): return values.contains(where: searchJSON)
            case let .object(fields): return fields.contains { contains($0.key) || searchJSON($0.value) }
            default: return false
            }
        }
        return contains(name) || domains.contains(where: contains) || cidrs.contains(where: contains)
            || processes.contains(where: contains) || applications.contains { contains($0.name) || contains($0.path) }
            || contains(url) || nativeRule.map(searchJSON) == true
            || conditions.contains { $0.matchesSearch(query) }
    }

    var matchItemCount: Int? {
        switch type {
        case "manual": return domains.count + cidrs.count
        case "application": return applications.count + processes.count
        case "native":
            func count(_ value: JSONValue) -> Int {
                guard case let .object(fields) = value else { return 0 }
                return fields.reduce(0) { total, entry in
                    if entry.key == "rules", case let .array(children) = entry.value {
                        return total + children.reduce(0) { $0 + count($1) }
                    }
                    guard ["domain", "domain_suffix", "domain_keyword", "domain_regex", "ip_cidr"].contains(entry.key) else { return total }
                    if case let .array(items) = entry.value { return total + items.count }
                    if case .string = entry.value { return total + 1 }
                    return total
                }
            }
            return nativeRule.map(count)
        default: return nil // Remote contents are only available after preparation.
        }
    }
    var nativeRule: JSONValue?
    var noResolve: Bool = false
    var id: String
    var name: String
    var type: String  // url / manual / application
    var enabled: Bool = true
    var url: String = ""
    var format: String = "auto"
    var fetchLineID: String = "direct"
    /// 仅用于 URL RuleSet。true 表示匹配远程列表之外的目标，例如
    /// “海外 IP”复用国内 IP 列表并取反，不需要维护一份容易漂移的世界 CIDR 副本。
    var invert: Bool = false
    var domains: [String] = []
    var cidrs: [String] = []
    var applications: [ApplicationRuleApplication] = []
    /// Surge PROCESS-NAME expressions. A bare value matches the executable
    /// filename (with `*`/`?`), an absolute path matches exactly, and an
    /// absolute path ending in `/` matches by prefix.
    var processes: [String] = []

    init(
        id: String,
        name: String,
        type: String,
        enabled: Bool = true,
        url: String = "",
        format: String = "auto",
        fetchLineID: String = "direct",
        invert: Bool = false,
        domains: [String] = [],
        cidrs: [String] = [],
        applications: [ApplicationRuleApplication] = [],
        processes: [String] = [],
        conditions: [RuleSet] = []
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.enabled = enabled
        self.url = url
        self.format = format
        self.fetchLineID = fetchLineID
        self.invert = invert
        self.domains = domains
        self.cidrs = cidrs
        self.applications = applications
        self.processes = processes
        self.conditions = conditions
    }

    enum CodingKeys: String, CodingKey {
        case conditions
        case nativeRule = "native_rule"
        case noResolve = "no_resolve"
        case id
        case name
        case type
        case enabled
        case url
        case format
        case fetchLineID = "fetch_line_id"
        case invert
        case domains
        case cidrs
        case applications
        case processes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        conditions = try values.decodeIfPresent([RuleSet].self, forKey: .conditions) ?? []
        nativeRule = try values.decodeIfPresent(JSONValue.self, forKey: .nativeRule)
        noResolve = try values.decodeIfPresent(Bool.self, forKey: .noResolve) ?? false
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
        fetchLineID = try values.decodeIfPresent(
            String.self,
            forKey: .fetchLineID
        ) ?? "direct"
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
        processes = try values.decodeIfPresent(
            [String].self,
            forKey: .processes
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
            let persistedBundleIdentifier = application.bundleIdentifier
                .map(sanitizeEntry)
                .flatMap { Self.isValidBundleIdentifier($0) ? $0 : nil }
            let discoveredBundleIdentifier = Bundle(
                url: URL(fileURLWithPath: path)
            )?.bundleIdentifier.flatMap {
                Self.isValidBundleIdentifier($0) ? $0 : nil
            }
            let normalized = ApplicationRuleApplication(
                name: name.isEmpty
                    ? URL(fileURLWithPath: path).deletingPathExtension()
                        .lastPathComponent
                    : name,
                path: path,
                bundleIdentifier: persistedBundleIdentifier
                    ?? discoveredBundleIdentifier
            )
            if applicationsByPath[path] == nil {
                applicationsByPath[path] = normalized
            }
        }
        return applicationsByPath.values.sorted { lhs, rhs in
            lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    static func isValidBundleIdentifier(_ value: String) -> Bool {
        guard
            !value.isEmpty,
            value.utf8.count <= 255,
            value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value < 128
                && !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
    }

    static func sanitizeProcesses(_ processes: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in processes {
            let expression = sanitizeEntry(raw)
            guard
                !expression.isEmpty,
                expression.utf8.count <= 4096
            else { continue }

            let normalized: String
            if !expression.hasPrefix("/") {
                guard
                    !expression.contains("/"),
                    expression.utf8.count <= 255
                else { continue }
                normalized = expression
            } else if expression.hasSuffix("/") {
                let prefix = String(expression.dropLast())
                guard
                    !prefix.isEmpty,
                    (prefix as NSString).standardizingPath == prefix
                else { continue }
                normalized = prefix + "/"
            } else {
                guard (expression as NSString).standardizingPath == expression
                else { continue }
                normalized = expression
            }

            if seen.insert(normalized).inserted {
                result.append(normalized)
            }
        }
        return result
    }
}

struct RuleBinding: Codable, Hashable, Identifiable {
    var conditionIDs: [String] = []
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
        case conditionIDs = "condition_ids"
        case ruleSetID = "rule_set_id"
        case lineID = "line_id"
        case subscriptionID = "subscription_id"
    }

    init(
        ruleSetID: String,
        lineID: String = "",
        subscriptionID: String = "",
        conditionIDs: [String] = []
    ) {
        self.ruleSetID = ruleSetID
        self.lineID = lineID
        self.subscriptionID = subscriptionID
        self.conditionIDs = conditionIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ruleSetID = try c.decode(String.self, forKey: .ruleSetID)
        lineID = try c.decodeIfPresent(String.self, forKey: .lineID) ?? ""
        subscriptionID = try c.decodeIfPresent(String.self, forKey: .subscriptionID) ?? ""
        conditionIDs = try c.decodeIfPresent([String].self, forKey: .conditionIDs) ?? []
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
    var options: String = ""
    var type: String
    var value: String = ""
    var group: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        options = try c.decodeIfPresent(String.self, forKey: .options) ?? ""
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        group = try c.decode(String.self, forKey: .group)
    }

    enum CodingKeys: String, CodingKey {
        case type, value, group, options
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
    var geoIPRuleSetURLTemplate: String = ""

    enum CodingKeys: String, CodingKey {
        case id, name, url, format, enabled, strategy, selected, rules
        case lines = "lines"
        case proxyGroups = "proxy_groups"
        case updatedAt = "updated_at"
        case testURL = "test_url"
        case testInterval = "test_interval"
        case geoIPRuleSetURLTemplate = "geoip_rule_set_url_template"
    }

    init(id: String, name: String, url: String, format: String = "auto",
         strategy: String = "urltest", lines: [Line] = [],
         proxyGroups: [SubProxyGroup] = [], rules: [SubRule] = [], selected: String = "",
         geoIPRuleSetURLTemplate: String = "") {
        self.id = id; self.name = name; self.url = url; self.format = format
        self.strategy = strategy; self.lines = lines
        self.selected = selected
        self.proxyGroups = proxyGroups; self.rules = rules
        self.geoIPRuleSetURLTemplate = geoIPRuleSetURLTemplate
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
        geoIPRuleSetURLTemplate = try c.decodeIfPresent(
            String.self,
            forKey: .geoIPRuleSetURLTemplate
        ) ?? ""
    }
}

struct Scenario: Codable, Identifiable, Hashable {
    var matchOrder: [String] = []
    var id: String
    var name: String
    /// 稳定的语义图标 Key；nil 表示根据名称与已保存 SSID 自动选择。
    /// 这里不保存 SF Symbol 名，避免把平台绘制细节写进配置契约。
    var iconOverride: String?
    var matchSSIDs: [String] = []
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
        case matchOrder = "match_order"
        case iconOverride = "icon"
        case matchSSIDs = "match_ssids"
        case defaultLineID = "default_line_id"
        case defaultSubscriptionID = "default_subscription_id"
    }

    init(id: String, name: String, matchSSIDs: [String] = [], bindings: [RuleBinding] = [], defaultLineID: String = "", defaultSubscriptionID: String = "", iconOverride: String? = nil, matchOrder: [String] = []) {
        self.id = id; self.name = name; self.iconOverride = iconOverride
        self.matchSSIDs = matchSSIDs
        self.bindings = bindings
        self.matchOrder = matchOrder
        self.defaultLineID = defaultLineID; self.defaultSubscriptionID = defaultSubscriptionID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        iconOverride = try c.decodeIfPresent(String.self, forKey: .iconOverride)
        if iconOverride?.isEmpty == true { iconOverride = nil }
        matchSSIDs = try c.decodeIfPresent(
            [String].self,
            forKey: .matchSSIDs
        ) ?? []
        bindings = try c.decodeIfPresent([RuleBinding].self, forKey: .bindings) ?? []
        matchOrder = try c.decodeIfPresent([String].self, forKey: .matchOrder) ?? []
        defaultLineID = try c.decodeIfPresent(String.self, forKey: .defaultLineID) ?? ""
        defaultSubscriptionID = try c.decodeIfPresent(String.self, forKey: .defaultSubscriptionID) ?? ""
    }
}

struct Profile: Codable, Hashable {
    var profileID: String = ""
    var importWarnings: [SubRule] = []
    var lines: [Line] = []
    var ruleSets: [RuleSet] = []
    var scenarios: [Scenario] = []
    var subscriptions: [Subscription] = []
    var activeScenarioID: String = ""
    var tailscale = TailscaleIdentity()

    enum CodingKeys: String, CodingKey {
        case profileID = "profile_id"
        case importWarnings = "import_warnings"
        case lines = "lines"
        case ruleSets = "rule_sets"
        case scenarios = "scenarios"
        case subscriptions
        case activeScenarioID = "active_scenario_id"
        case tailscale
    }

    init() {}

    /// Called after an explicit editor change, never during subscription validation.
    /// Removing a selected condition must not turn a partial binding into an all-rule binding.
    mutating func reconcileMatchingReferences() {
        let members = Dictionary(uniqueKeysWithValues: ruleSets.map { ($0.id, Set($0.matchingResources.map(\.id))) })
        for index in scenarios.indices {
            scenarios[index].bindings = scenarios[index].bindings.compactMap { binding in
                guard !binding.conditionIDs.isEmpty else { return binding }
                var copy = binding
                copy.conditionIDs = binding.conditionIDs.filter { members[binding.ruleSetID]?.contains($0) == true }
                return copy.conditionIDs.isEmpty ? nil : copy
            }
            let selected = Set(scenarios[index].bindings.flatMap { binding in
                binding.conditionIDs.isEmpty ? Array(members[binding.ruleSetID] ?? []) : binding.conditionIDs
            })
            scenarios[index].matchOrder.removeAll { !selected.contains($0) }
        }
    }

    mutating func appendMatchingContent(_ content: RuleSet, to ruleID: String) {
        guard let index = ruleSets.firstIndex(where: { $0.id == ruleID }) else { return }
        if ruleSets[index].type != "group" {
            var original = ruleSets[index]
            original.id = UUID().uuidString
            original.enabled = true
            ruleSets[index] = RuleSet(id: ruleID, name: ruleSets[index].name, type: "group", enabled: ruleSets[index].enabled, conditions: [original])
            for scene in scenarios.indices {
                scenarios[scene].matchOrder = scenarios[scene].matchOrder.map { $0 == ruleID ? original.id : $0 }
                for binding in scenarios[scene].bindings.indices {
                    scenarios[scene].bindings[binding].conditionIDs = scenarios[scene].bindings[binding].conditionIDs.map { $0 == ruleID ? original.id : $0 }
                }
            }
        }
        ruleSets[index].conditions.append(content)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try c.decodeIfPresent(String.self, forKey: .profileID) ?? ""
        importWarnings = try c.decodeIfPresent([SubRule].self, forKey: .importWarnings) ?? []
        lines = try c.decodeIfPresent([Line].self, forKey: .lines) ?? []
        ruleSets = try c.decodeIfPresent([RuleSet].self, forKey: .ruleSets) ?? []
        scenarios = try c.decodeIfPresent(
            [Scenario].self,
            forKey: .scenarios
        ) ?? []
        subscriptions = try c.decodeIfPresent([Subscription].self, forKey: .subscriptions) ?? []
        activeScenarioID = try c.decodeIfPresent(
            String.self,
            forKey: .activeScenarioID
        ) ?? ""
        tailscale = try c.decodeIfPresent(TailscaleIdentity.self, forKey: .tailscale) ?? TailscaleIdentity()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(profileID, forKey: .profileID)
        if !importWarnings.isEmpty { try c.encode(importWarnings, forKey: .importWarnings) }
        try c.encode(lines, forKey: .lines)
        try c.encode(ruleSets, forKey: .ruleSets)
        try c.encode(scenarios, forKey: .scenarios)
        try c.encode(subscriptions, forKey: .subscriptions)
        try c.encode(activeScenarioID, forKey: .activeScenarioID)
        try c.encode(tailscale, forKey: .tailscale)
    }
}

extension Profile {
    var usesSSIDScenarioMatching: Bool {
        scenarios.contains { scenario in
            scenario.matchSSIDs.contains {
                !$0.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            }
        }
    }

    func scenario(matchingSSID ssid: String) -> Scenario? {
        scenarios.first { $0.matchSSIDs.contains(ssid) }
    }

    static func bootstrap() -> Profile {
        var p = Profile()
        p.lines = [
            Line(id: "direct", name: "直连", type: "direct", verified: true),
            Line(id: "vpn", name: "VPN", type: "vpn"),
            Line(id: "ss", name: "SS 节点", type: "trojan", enabled: false),
        ]
        p.ruleSets = [
            RuleSet(id: "internal", name: "内部域名", type: "manual"),
        ]
        return p
    }

    static func templateOverseas(ruleSetIDs: [String], vpnLineID: String, directLineID: String) -> Scenario {
        Scenario(
            id: UUID().uuidString,
            name: "海外",
            bindings: ruleSetIDs.map { RuleBinding(ruleSetID: $0, lineID: vpnLineID) },
            defaultLineID: directLineID
        )
    }

    static func templateDomestic(ruleSetIDs: [String], remoteRuleSetID: String, vpnLineID: String, directLineID: String) -> Scenario {
        var bindings = ruleSetIDs.map { RuleBinding(ruleSetID: $0, lineID: vpnLineID) }
        if !remoteRuleSetID.isEmpty {
            bindings.append(RuleBinding(ruleSetID: remoteRuleSetID, lineID: vpnLineID))
        }
        return Scenario(
            id: UUID().uuidString,
            name: "国内",
            bindings: bindings,
            defaultLineID: directLineID
        )
    }

    static func templateDomesticSS(ruleSetIDs: [String], remoteRuleSetID: String, vpnLineID: String, ssLineID: String, directLineID: String) -> Scenario {
        var bindings = ruleSetIDs.map { RuleBinding(ruleSetID: $0, lineID: vpnLineID) }
        if !remoteRuleSetID.isEmpty {
            bindings.append(RuleBinding(ruleSetID: remoteRuleSetID, lineID: ssLineID))
        }
        return Scenario(
            id: UUID().uuidString,
            name: "国内+SS",
            bindings: bindings,
            defaultLineID: directLineID
        )
    }
}

// Group membership is private to its shared RuleSet; editors can still validate
// a leaf change against the complete Profile without exposing extra navigation.
extension Profile {
    var matchingResources: [RuleSet] { ruleSets.flatMap(\.matchingResources) }
    mutating func updateMatchingResource(id: String, update: (inout RuleSet) -> Void) -> Bool {
        for i in ruleSets.indices {
            if ruleSets[i].id == id { update(&ruleSets[i]); return true }
            if let j = ruleSets[i].conditions.firstIndex(where: { $0.id == id }) {
                update(&ruleSets[i].conditions[j]); return true
            }
        }
        return false
    }
}

extension Profile {
    /// Editor guard for membership references, including ancestors affected by this edge.
    /// Empty groups remain editable drafts; Go validates complete documents and runtime readiness.
    func lineGroupMemberIssue(_ memberID: String, addingTo groupID: String) -> String? {
        guard let group = lines.first(where: { $0.id == groupID }), group.isGroup else {
            return "线路组已不存在"
        }
        guard !group.groupMembers.contains(memberID) else { return "此成员已在组内" }
        guard memberID != groupID else { return "不能将组添加到自身" }
        var resources = Dictionary(lines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        resources[groupID]?.groupMembers.append(memberID)
        var affected: Set<String> = [groupID]
        var changed = true
        while changed {
            changed = false
            for item in lines where item.isGroup && !affected.contains(item.id) {
                if item.groupMembers.contains(where: { affected.contains($0) }) {
                    affected.insert(item.id)
                    changed = true
                }
            }
        }
        var checked: Set<String> = []
        func visit(_ id: String, path: Set<String>, underURLTest: Bool) -> String? {
            if path.contains(id) { return "添加后会形成循环引用" }
            if path.count > 32 { return "组嵌套不能超过 32 层" }
            if id == "direct" {
                return underURLTest ? "测速组暂不支持包含直连，包括子组中的直连" : nil
            }
            guard let item = resources[id] else { return "包含已不存在的线路" }
            if item.type == "vpn" || item.type == "tailscale" {
                return "VPN 和 Tailscale 需直接用于场景"
            }
            if item.type == "direct", underURLTest {
                return "测速组暂不支持包含直连，包括子组中的直连"
            }
            guard item.isGroup else { return nil }
            let key = "\(path.count)/\(underURLTest)/\(id)"
            if checked.contains(key) { return nil }
            var next = path
            next.insert(id)
            for child in item.groupMembers {
                if let issue = visit(child, path: next, underURLTest: underURLTest || item.type == "urltest") {
                    return issue
                }
            }
            checked.insert(key)
            return nil
        }
        for id in affected.sorted() {
            if let issue = visit(id, path: [], underURLTest: false) { return issue }
        }
        return nil
    }

    mutating func addLineGroupMember(_ memberID: String, to groupID: String) throws {
        if let issue = lineGroupMemberIssue(memberID, addingTo: groupID) {
            throw LineGroupMembershipError(errorDescription: issue)
        }
        guard let index = lines.firstIndex(where: { $0.id == groupID }) else { return }
        lines[index].groupMembers.append(memberID)
    }

    mutating func removeLineGroupMember(_ memberID: String, from groupID: String) {
        guard let index = lines.firstIndex(where: { $0.id == groupID && $0.isGroup }) else { return }
        lines[index].groupMembers.removeAll { $0 == memberID }
        if lines[index].groupDefault == memberID { lines[index].groupDefault = "" }
    }
}

private struct LineGroupMembershipError: LocalizedError {
    let errorDescription: String?
}
