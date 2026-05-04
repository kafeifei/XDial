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
    var portID: String

    var id: String { cargoID }

    enum CodingKeys: String, CodingKey {
        case cargoID = "cargo_id"
        case portID = "port_id"
    }
}

struct Cruise: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var bindings: [CargoLink] = []
    var defaultPortID: String = ""

    enum CodingKeys: String, CodingKey {
        case id, name, bindings
        case defaultPortID = "default_port_id"
    }
}

struct Profile: Codable {
    var ports: [Port] = []
    var cargoes: [Cargo] = []
    var cruises: [Cruise] = []
    var activeCruiseID: String = ""

    enum CodingKeys: String, CodingKey {
        case ports, cargoes, cruises
        case activeCruiseID = "active_cruise_id"
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
