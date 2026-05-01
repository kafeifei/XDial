import Foundation

struct Exit: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var type: String  // direct / vpn / trojan / shadowsocks / vmess
    var enabled: Bool = true

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
        case id, name, type, enabled
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
}

struct Rule: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var type: String  // url / manual
    var enabled: Bool = true
    var url: String = ""
    var format: String = "auto"
    var domains: [String] = []
    var cidrs: [String] = []
}

struct RouteBinding: Codable, Hashable, Identifiable {
    var ruleID: String
    var exitID: String

    var id: String { ruleID }

    enum CodingKeys: String, CodingKey {
        case ruleID = "rule_id"
        case exitID = "exit_id"
    }
}

struct Strategy: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var bindings: [RouteBinding] = []
    var defaultExitID: String = ""

    enum CodingKeys: String, CodingKey {
        case id, name, bindings
        case defaultExitID = "default_exit_id"
    }
}

struct Profile: Codable {
    var exits: [Exit] = []
    var rules: [Rule] = []
    var strategies: [Strategy] = []
    var activeStrategyID: String = ""

    enum CodingKeys: String, CodingKey {
        case exits, rules, strategies
        case activeStrategyID = "active_strategy_id"
    }
}

extension Profile {
    static func bootstrap() -> Profile {
        var p = Profile()
        p.exits = [
            Exit(id: "direct", name: "直连", type: "direct"),
            Exit(id: "vpn", name: "VPN", type: "vpn"),
            Exit(id: "ss", name: "SS 节点", type: "trojan", enabled: false),
        ]
        p.rules = [
            Rule(id: "internal", name: "内部域名", type: "manual"),
            Rule(id: "gfw", name: "GFW",
                 type: "url",
                 url: "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-gfw.srs",
                 format: "srs"),
            Rule(id: "cnip", name: "国内 IP", type: "url", enabled: false,
                 url: "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-cn.srs",
                 format: "srs"),
        ]
        return p
    }

    static func templateOverseas(domainRuleIDs: [String], vpnExitID: String, directExitID: String) -> Strategy {
        Strategy(
            id: UUID().uuidString,
            name: "海外",
            bindings: domainRuleIDs.map { RouteBinding(ruleID: $0, exitID: vpnExitID) },
            defaultExitID: directExitID
        )
    }

    static func templateDomestic(domainRuleIDs: [String], gfwRuleID: String, vpnExitID: String, directExitID: String) -> Strategy {
        var bindings = domainRuleIDs.map { RouteBinding(ruleID: $0, exitID: vpnExitID) }
        if !gfwRuleID.isEmpty {
            bindings.append(RouteBinding(ruleID: gfwRuleID, exitID: vpnExitID))
        }
        return Strategy(
            id: UUID().uuidString,
            name: "国内",
            bindings: bindings,
            defaultExitID: directExitID
        )
    }

    static func templateDomesticSS(domainRuleIDs: [String], gfwRuleID: String, vpnExitID: String, ssExitID: String, directExitID: String) -> Strategy {
        var bindings = domainRuleIDs.map { RouteBinding(ruleID: $0, exitID: vpnExitID) }
        if !gfwRuleID.isEmpty {
            bindings.append(RouteBinding(ruleID: gfwRuleID, exitID: ssExitID))
        }
        return Strategy(
            id: UUID().uuidString,
            name: "国内+SS",
            bindings: bindings,
            defaultExitID: directExitID
        )
    }
}
