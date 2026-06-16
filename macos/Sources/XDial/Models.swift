import Foundation

struct Port: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var type: String  // direct / vpn / trojan / shadowsocks / vmess
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

    enum CodingKeys: String, CodingKey {
        case id, name, type, enabled, verified
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
    }

    init(id: String, name: String, type: String, enabled: Bool = true, verified: Bool = false,
         vpnServer: String = "", vpnUsername: String = "", vpnPassword: String = "",
         trojanServer: String = "", trojanPort: Int = 443, trojanPassword: String = "", trojanSNI: String = "",
         ssServer: String = "", ssPort: Int = 8388, ssMethod: String = "aes-256-gcm", ssPassword: String = "",
         vmessServer: String = "", vmessPort: Int = 443, vmessUUID: String = "", vmessAltID: Int = 0) {
        self.id = id; self.name = name; self.type = type; self.enabled = enabled; self.verified = verified
        self.vpnServer = vpnServer; self.vpnUsername = vpnUsername; self.vpnPassword = vpnPassword
        self.trojanServer = trojanServer; self.trojanPort = trojanPort; self.trojanPassword = trojanPassword; self.trojanSNI = trojanSNI
        self.ssServer = ssServer; self.ssPort = ssPort; self.ssMethod = ssMethod; self.ssPassword = ssPassword
        self.vmessServer = vmessServer; self.vmessPort = vmessPort; self.vmessUUID = vmessUUID; self.vmessAltID = vmessAltID
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
    }
}

struct Cargo: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var type: String  // url / manual
    var enabled: Bool = true
    var url: String = ""
    var format: String = "auto"
    var domains: [String] = []
    var cidrs: [String] = []
}

struct CargoLink: Codable, Hashable, Identifiable {
    var cargoID: String
    var portID: String = ""
    var subscriptionID: String = ""

    var id: String { cargoID }

    var targetID: String {
        get { subscriptionID.isEmpty ? "port:\(portID)" : "sub:\(subscriptionID)" }
        set {
            if newValue.hasPrefix("sub:") {
                subscriptionID = String(newValue.dropFirst(4)); portID = ""
            } else {
                portID = newValue.hasPrefix("port:") ? String(newValue.dropFirst(5)) : newValue
                subscriptionID = ""
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case cargoID = "cargo_id"
        case portID = "port_id"
        case subscriptionID = "subscription_id"
    }

    init(cargoID: String, portID: String = "", subscriptionID: String = "") {
        self.cargoID = cargoID
        self.portID = portID
        self.subscriptionID = subscriptionID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cargoID = try c.decode(String.self, forKey: .cargoID)
        portID = try c.decodeIfPresent(String.self, forKey: .portID) ?? ""
        subscriptionID = try c.decodeIfPresent(String.self, forKey: .subscriptionID) ?? ""
    }
}

struct SubProxyGroup: Codable, Hashable {
    var name: String
    var type: String
    var proxies: [String] = []
    var url: String = ""
    var interval: Int = 0

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(String.self, forKey: .type)
        proxies = try c.decodeIfPresent([String].self, forKey: .proxies) ?? []
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        interval = try c.decodeIfPresent(Int.self, forKey: .interval) ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case name, type, proxies, url, interval
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
    var ports: [Port] = []
    var proxyGroups: [SubProxyGroup] = []
    var rules: [SubRule] = []
    var updatedAt: Int = 0
    var testURL: String = "https://www.gstatic.com/generate_204"
    var testInterval: Int = 300

    enum CodingKeys: String, CodingKey {
        case id, name, url, format, enabled, strategy, ports, rules
        case proxyGroups = "proxy_groups"
        case updatedAt = "updated_at"
        case testURL = "test_url"
        case testInterval = "test_interval"
    }

    init(id: String, name: String, url: String, format: String = "auto",
         strategy: String = "urltest", ports: [Port] = [],
         proxyGroups: [SubProxyGroup] = [], rules: [SubRule] = []) {
        self.id = id; self.name = name; self.url = url; self.format = format
        self.strategy = strategy; self.ports = ports
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
        ports = try c.decodeIfPresent([Port].self, forKey: .ports) ?? []
        proxyGroups = try c.decodeIfPresent([SubProxyGroup].self, forKey: .proxyGroups) ?? []
        rules = try c.decodeIfPresent([SubRule].self, forKey: .rules) ?? []
        updatedAt = try c.decodeIfPresent(Int.self, forKey: .updatedAt) ?? 0
        testURL = try c.decodeIfPresent(String.self, forKey: .testURL) ?? "https://www.gstatic.com/generate_204"
        testInterval = try c.decodeIfPresent(Int.self, forKey: .testInterval) ?? 300
    }
}

struct Cruise: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var bindings: [CargoLink] = []
    var defaultPortID: String = ""
    var defaultSubscriptionID: String = ""

    var defaultTargetID: String {
        get { defaultSubscriptionID.isEmpty ? "port:\(defaultPortID)" : "sub:\(defaultSubscriptionID)" }
        set {
            if newValue.hasPrefix("sub:") {
                defaultSubscriptionID = String(newValue.dropFirst(4)); defaultPortID = ""
            } else {
                defaultPortID = newValue.hasPrefix("port:") ? String(newValue.dropFirst(5)) : newValue
                defaultSubscriptionID = ""
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, bindings
        case defaultPortID = "default_port_id"
        case defaultSubscriptionID = "default_subscription_id"
    }

    init(id: String, name: String, bindings: [CargoLink] = [], defaultPortID: String = "", defaultSubscriptionID: String = "") {
        self.id = id; self.name = name; self.bindings = bindings
        self.defaultPortID = defaultPortID; self.defaultSubscriptionID = defaultSubscriptionID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        bindings = try c.decodeIfPresent([CargoLink].self, forKey: .bindings) ?? []
        defaultPortID = try c.decodeIfPresent(String.self, forKey: .defaultPortID) ?? ""
        defaultSubscriptionID = try c.decodeIfPresent(String.self, forKey: .defaultSubscriptionID) ?? ""
    }
}

struct Profile: Codable {
    var ports: [Port] = []
    var cargoes: [Cargo] = []
    var cruises: [Cruise] = []
    var subscriptions: [Subscription] = []
    var activeCruiseID: String = ""

    enum CodingKeys: String, CodingKey {
        case ports, cargoes, cruises, subscriptions
        case activeCruiseID = "active_cruise_id"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ports = try c.decodeIfPresent([Port].self, forKey: .ports) ?? []
        cargoes = try c.decodeIfPresent([Cargo].self, forKey: .cargoes) ?? []
        cruises = try c.decodeIfPresent([Cruise].self, forKey: .cruises) ?? []
        subscriptions = try c.decodeIfPresent([Subscription].self, forKey: .subscriptions) ?? []
        activeCruiseID = try c.decodeIfPresent(String.self, forKey: .activeCruiseID) ?? ""
    }
}

extension Profile {
    static func bootstrap() -> Profile {
        var p = Profile()
        p.ports = [
            Port(id: "direct", name: "直连", type: "direct", verified: true),
            Port(id: "vpn", name: "VPN", type: "vpn"),
            Port(id: "ss", name: "SS 节点", type: "trojan", enabled: false),
        ]
        p.cargoes = [
            Cargo(id: "internal", name: "内部域名", type: "manual"),
            Cargo(id: "gfw", name: "GFW",
                  type: "url",
                  url: "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-gfw.srs",
                  format: "srs"),
            Cargo(id: "cnip", name: "国内 IP", type: "url", enabled: false,
                  url: "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-cn.srs",
                  format: "srs"),
        ]
        return p
    }

    static func templateOverseas(cargoIDs: [String], vpnPortID: String, directPortID: String) -> Cruise {
        Cruise(
            id: UUID().uuidString,
            name: "海外",
            bindings: cargoIDs.map { CargoLink(cargoID: $0, portID: vpnPortID) },
            defaultPortID: directPortID
        )
    }

    static func templateDomestic(cargoIDs: [String], gfwCargoID: String, vpnPortID: String, directPortID: String) -> Cruise {
        var bindings = cargoIDs.map { CargoLink(cargoID: $0, portID: vpnPortID) }
        if !gfwCargoID.isEmpty {
            bindings.append(CargoLink(cargoID: gfwCargoID, portID: vpnPortID))
        }
        return Cruise(
            id: UUID().uuidString,
            name: "国内",
            bindings: bindings,
            defaultPortID: directPortID
        )
    }

    static func templateDomesticSS(cargoIDs: [String], gfwCargoID: String, vpnPortID: String, ssPortID: String, directPortID: String) -> Cruise {
        var bindings = cargoIDs.map { CargoLink(cargoID: $0, portID: vpnPortID) }
        if !gfwCargoID.isEmpty {
            bindings.append(CargoLink(cargoID: gfwCargoID, portID: ssPortID))
        }
        return Cruise(
            id: UUID().uuidString,
            name: "国内+SS",
            bindings: bindings,
            defaultPortID: directPortID
        )
    }
}
