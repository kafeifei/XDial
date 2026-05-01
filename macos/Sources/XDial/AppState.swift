import Combine
import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    // VPN credentials
    @Published var server: String = ""
    @Published var username: String = ""
    @Published var password: String = ""
    @Published var rememberPassword: Bool = true
    @Published var activePreset: String = "overseas"

    // Company domains
    @Published var companyDomains: String = ""

    // Airport line
    @Published var airportEnabled: Bool = false
    @Published var airportType: String = "trojan"
    @Published var trojanServer: String = ""
    @Published var trojanPort: String = "443"
    @Published var trojanPassword: String = ""
    @Published var trojanSNI: String = ""
    @Published var ssServer: String = ""
    @Published var ssPort: String = "8388"
    @Published var ssMethod: String = "aes-256-gcm"
    @Published var ssPassword: String = ""
    @Published var vmessServer: String = ""
    @Published var vmessPort: String = "443"
    @Published var vmessUUID: String = ""
    @Published var vmessAltID: String = "0"

    // Custom rules
    @Published var customDomains: String = ""
    @Published var customCIDRs: String = ""
    @Published var customLineID: String = "company_vpn"

    @Published var helperInstalled: Bool = false
    @Published var helperNeedsUpdate: Bool = false

    let engine = GoEngine.shared
    private var engineSub: AnyCancellable?

    private let keychainVPN = "xdial-vpn"
    private let keychainTrojan = "xdial-trojan"
    private let keychainSS = "xdial-ss"
    private let keychainVMess = "xdial-vmess"

    var isConnected: Bool { engine.isConnected }
    var isBusy: Bool { engine.isBusy }
    var canConnect: Bool { !server.isEmpty && !username.isEmpty && !password.isEmpty && helperInstalled && !isBusy }

    var statusText: String {
        switch engine.status {
        case "connected": return "已连接"
        case "connecting": return "正在连接…"
        case "disconnecting": return "正在断开…"
        default:
            if let err = engine.lastError { return err }
            return "未连接"
        }
    }

    init() {
        engineSub = engine.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        loadSaved()
        checkHelper()
        engine.syncStatus()
    }

    func connect() {
        guard canConnect else { return }
        save()
        engine.start(profileJSON: buildProfileJSON())
    }

    func disconnect() {
        engine.stop()
    }

    func installHelper(thenConnect: Bool = false) {
        do {
            try PrivilegeManager.install()
            helperInstalled = PrivilegeManager.isInstalled
            helperNeedsUpdate = false
            if thenConnect && helperInstalled { connect() }
        } catch {
            engine.lastError = error.localizedDescription
            helperInstalled = PrivilegeManager.isInstalled
        }
    }

    // MARK: - Persistence

    func save() {
        let d = UserDefaults.standard
        d.set(server, forKey: "xdial.server")
        d.set(username, forKey: "xdial.username")
        d.set(activePreset, forKey: "xdial.preset")
        d.set(companyDomains, forKey: "xdial.companyDomains")
        d.set(airportEnabled, forKey: "xdial.airportEnabled")
        d.set(airportType, forKey: "xdial.airportType")
        d.set(trojanServer, forKey: "xdial.trojanServer")
        d.set(trojanPort, forKey: "xdial.trojanPort")
        d.set(trojanSNI, forKey: "xdial.trojanSNI")
        d.set(ssServer, forKey: "xdial.ssServer")
        d.set(ssPort, forKey: "xdial.ssPort")
        d.set(ssMethod, forKey: "xdial.ssMethod")
        d.set(vmessServer, forKey: "xdial.vmessServer")
        d.set(vmessPort, forKey: "xdial.vmessPort")
        d.set(vmessAltID, forKey: "xdial.vmessAltID")
        d.set(customDomains, forKey: "xdial.customDomains")
        d.set(customCIDRs, forKey: "xdial.customCIDRs")
        d.set(customLineID, forKey: "xdial.customLineID")

        if rememberPassword {
            KeychainStore.save(password: password, account: keychainVPN)
        } else {
            KeychainStore.delete(account: keychainVPN)
        }
        KeychainStore.save(password: trojanPassword, account: keychainTrojan)
        KeychainStore.save(password: ssPassword, account: keychainSS)
        KeychainStore.save(password: vmessUUID, account: keychainVMess)
    }

    private func loadSaved() {
        let d = UserDefaults.standard
        server = d.string(forKey: "xdial.server") ?? ""
        username = d.string(forKey: "xdial.username") ?? ""
        activePreset = d.string(forKey: "xdial.preset") ?? "overseas"
        companyDomains = d.string(forKey: "xdial.companyDomains") ?? ""
        airportEnabled = d.bool(forKey: "xdial.airportEnabled")
        airportType = d.string(forKey: "xdial.airportType") ?? "trojan"
        trojanServer = d.string(forKey: "xdial.trojanServer") ?? ""
        trojanPort = d.string(forKey: "xdial.trojanPort") ?? "443"
        trojanSNI = d.string(forKey: "xdial.trojanSNI") ?? ""
        ssServer = d.string(forKey: "xdial.ssServer") ?? ""
        ssPort = d.string(forKey: "xdial.ssPort") ?? "8388"
        ssMethod = d.string(forKey: "xdial.ssMethod") ?? "aes-256-gcm"
        vmessServer = d.string(forKey: "xdial.vmessServer") ?? ""
        vmessPort = d.string(forKey: "xdial.vmessPort") ?? "443"
        vmessAltID = d.string(forKey: "xdial.vmessAltID") ?? "0"
        customDomains = d.string(forKey: "xdial.customDomains") ?? ""
        customCIDRs = d.string(forKey: "xdial.customCIDRs") ?? ""
        customLineID = d.string(forKey: "xdial.customLineID") ?? "company_vpn"

        if rememberPassword {
            password = KeychainStore.load(account: keychainVPN) ?? ""
        }
        trojanPassword = KeychainStore.load(account: keychainTrojan) ?? ""
        ssPassword = KeychainStore.load(account: keychainSS) ?? ""
        vmessUUID = KeychainStore.load(account: keychainVMess) ?? ""
    }

    private func checkHelper() {
        helperInstalled = PrivilegeManager.isInstalled
        helperNeedsUpdate = PrivilegeManager.needsUpdate
    }

    // MARK: - Profile JSON

    private func parseDomains(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isNewline || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func buildProfileJSON() -> String {
        let companyDomainList = parseDomains(companyDomains)
        let customDomainList = parseDomains(customDomains)
        let customCIDRList = parseDomains(customCIDRs)

        var airportLine: [String: Any] = [
            "id": "airport",
            "name": "机场",
            "type": airportType,
            "enabled": airportEnabled,
        ]
        switch airportType {
        case "trojan":
            airportLine["trojan_server"] = trojanServer
            airportLine["trojan_port"] = Int(trojanPort) ?? 443
            airportLine["trojan_password"] = trojanPassword
            airportLine["trojan_sni"] = trojanSNI
        case "shadowsocks":
            airportLine["ss_server"] = ssServer
            airportLine["ss_port"] = Int(ssPort) ?? 8388
            airportLine["ss_method"] = ssMethod
            airportLine["ss_password"] = ssPassword
        case "vmess":
            airportLine["vmess_server"] = vmessServer
            airportLine["vmess_port"] = Int(vmessPort) ?? 443
            airportLine["vmess_uuid"] = vmessUUID
            airportLine["vmess_alt_id"] = Int(vmessAltID) ?? 0
        default: break
        }

        var diverters: [[String: Any]] = [
            [
                "id": "company_domains",
                "name": "公司域名",
                "type": "company_domains",
                "enabled": !companyDomainList.isEmpty,
                "domains": companyDomainList,
            ],
            [
                "id": "gfw",
                "name": "GFW",
                "type": "gfw",
                "enabled": true,
            ],
            [
                "id": "china_ip",
                "name": "国内 IP",
                "type": "china_ip",
                "enabled": true,
            ],
        ]

        if !customDomainList.isEmpty || !customCIDRList.isEmpty {
            var custom: [String: Any] = [
                "id": "custom",
                "name": "自定义规则",
                "type": "custom",
                "enabled": true,
            ]
            if !customDomainList.isEmpty { custom["domains"] = customDomainList }
            if !customCIDRList.isEmpty { custom["cidrs"] = customCIDRList }
            diverters.append(custom)
        }

        var presets = defaultPresets()
        if !customDomainList.isEmpty || !customCIDRList.isEmpty {
            for i in presets.indices {
                var bindings = presets[i]["bindings"] as? [[String: String]] ?? []
                bindings.append(["diverter_id": "custom", "line_id": customLineID])
                presets[i]["bindings"] = bindings
            }
        }

        let profile: [String: Any] = [
            "lines": [
                [
                    "id": "company_vpn",
                    "name": "公司 VPN",
                    "type": "company_vpn",
                    "enabled": true,
                    "vpn_server": server,
                    "vpn_username": username,
                    "vpn_password": password,
                ],
                airportLine,
                [
                    "id": "direct",
                    "name": "直连",
                    "type": "direct",
                    "enabled": true,
                ],
            ],
            "diverters": diverters,
            "presets": presets,
            "active_preset_id": activePreset,
            "default_line_id": "direct",
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: profile) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func defaultPresets() -> [[String: Any]] {
        [
            [
                "id": "overseas",
                "name": "国外",
                "bindings": [
                    ["diverter_id": "company_domains", "line_id": "company_vpn"],
                    ["diverter_id": "gfw", "line_id": "direct"],
                ] as [[String: String]],
            ],
            [
                "id": "domestic",
                "name": "国内",
                "bindings": [
                    ["diverter_id": "company_domains", "line_id": "company_vpn"],
                    ["diverter_id": "gfw", "line_id": "company_vpn"],
                ] as [[String: String]],
            ],
            [
                "id": "domestic_airport",
                "name": "国内+机场",
                "bindings": [
                    ["diverter_id": "company_domains", "line_id": "company_vpn"],
                    ["diverter_id": "gfw", "line_id": "airport"],
                ] as [[String: String]],
            ],
        ]
    }
}
