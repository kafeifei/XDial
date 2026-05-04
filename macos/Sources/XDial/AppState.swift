import Combine
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var profile: Profile

    @Published var helperInstalled: Bool = false
    @Published var helperNeedsUpdate: Bool = false

    @Published var language: Lang {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "xdial.language")
            NetworkInfo.shared.language = language
        }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "xdial.launchAtLogin")
            updateLaunchAtLogin()
        }
    }

    let engine = GoEngine.shared
    private var engineSub: AnyCancellable?

    private let profileKey = "xdial.profile"
    private let keychainPrefix = "xdial-port-"

    func tr(_ zh: String, _ en: String) -> String {
        language == .zh ? zh : en
    }

    var isConnected: Bool { engine.isConnected }
    var isBusy: Bool { engine.isBusy }

    var canConnect: Bool {
        guard helperInstalled, !isBusy else { return false }
        guard let s = activeCruise else { return false }
        // 必须有效的 VPN 凭据（如果策略用到 VPN）
        for binding in s.bindings {
            if let port = profile.ports.first(where: { $0.id == binding.portID }),
               port.type == "vpn",
               (port.vpnServer.isEmpty || port.vpnUsername.isEmpty || port.vpnPassword.isEmpty) {
                return false
            }
        }
        if let port = profile.ports.first(where: { $0.id == s.defaultPortID }),
           port.type == "vpn",
           (port.vpnServer.isEmpty || port.vpnUsername.isEmpty || port.vpnPassword.isEmpty) {
            return false
        }
        return true
    }

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

    var activeCruise: Cruise? {
        profile.cruises.first { $0.id == profile.activeCruiseID }
    }

    init() {
        // 先用 bootstrap 初始化，loadSaved 后会被覆盖
        self.profile = Profile.bootstrap()

        // 语言：先读已保存，没有则用系统语言
        if let savedLang = UserDefaults.standard.string(forKey: "xdial.language"),
           let lang = Lang(rawValue: savedLang) {
            self.language = lang
        } else {
            self.language = .system
        }
        self.launchAtLogin = UserDefaults.standard.bool(forKey: "xdial.launchAtLogin")

        var lastStatus = ""
        engineSub = engine.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            self.objectWillChange.send()
            let cur = self.engine.status
            // 只在变成 connected 时探测；断开不测
            if cur != lastStatus && cur == "connected" {
                lastStatus = cur
                self.probeNetwork()
                self.markUsedPortsVerified()
            } else if cur != lastStatus {
                lastStatus = cur
            }
        }
        loadSaved()
        checkHelper()
        engine.syncStatus()
        // 启动时如果已连接（helper 一直在跑）也探测一次
        if engine.status == "connected" {
            probeNetwork()
        }
    }

    func probeNetwork() {
        guard engine.status == "connected" else { return }
        NetworkInfo.shared.probeAll(
            ports: profile.ports,
            helperConnected: true
        )
    }

    private func updateLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                engine.lastError = tr("设置开机启动失败: \(error.localizedDescription)",
                                      "Failed to update login item: \(error.localizedDescription)")
            }
        }
    }

    func uninstall(deleteData: Bool, completion: @escaping (Bool, String?) -> Void) {
        // 1. 断开连接
        if engine.status == "connected" || engine.status == "connecting" {
            engine.stop()
        }
        // 2. 取消开机启动
        if launchAtLogin { launchAtLogin = false }
        // 3. 卸载 LaunchDaemon + helper（admin 权限）
        do {
            try PrivilegeManager.uninstall()
        } catch {
            completion(false, error.localizedDescription)
            return
        }
        // 4. 可选：删除用户数据
        if deleteData {
            UserDefaults.standard.removeObject(forKey: profileKey)
            UserDefaults.standard.removeObject(forKey: "xdial.language")
            UserDefaults.standard.removeObject(forKey: "xdial.launchAtLogin")
            // 删除 Keychain 里所有 xdial-port-* 项
            for port in profile.ports {
                KeychainStore.delete(account: keychainPrefix + port.id + "-vpn")
                KeychainStore.delete(account: keychainPrefix + port.id + "-trojan")
                KeychainStore.delete(account: keychainPrefix + port.id + "-ss")
                KeychainStore.delete(account: keychainPrefix + port.id + "-vmess")
            }
        }
        helperInstalled = false
        completion(true, nil)
    }

    private var lastVerifiedAt: String = ""

    private func markUsedPortsVerified() {
        guard let s = activeCruise else { return }
        let key = s.id
        if lastVerifiedAt == key { return }
        lastVerifiedAt = key

        var usedIDs = Set(s.bindings.map { $0.portID })
        if !s.defaultPortID.isEmpty { usedIDs.insert(s.defaultPortID) }

        var changed = false
        for i in profile.ports.indices where usedIDs.contains(profile.ports[i].id) {
            if !profile.ports[i].verified {
                profile.ports[i].verified = true
                changed = true
            }
        }
        if changed { save() }
    }

    // MARK: - Connect

    func connect() {
        guard canConnect else { return }
        if helperNeedsUpdate {
            installHelper(thenConnect: true)
            return
        }
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
        // 先把所有 ASCII 字段做一次全角→半角清洗（兜底）
        for i in profile.ports.indices {
            profile.ports[i].vpnServer = profile.ports[i].vpnServer.normalizedASCII()
            profile.ports[i].vpnUsername = profile.ports[i].vpnUsername.normalizedASCII()
            profile.ports[i].vpnPassword = profile.ports[i].vpnPassword.normalizedASCII()
            profile.ports[i].trojanServer = profile.ports[i].trojanServer.normalizedASCII()
            profile.ports[i].trojanPassword = profile.ports[i].trojanPassword.normalizedASCII()
            profile.ports[i].trojanSNI = profile.ports[i].trojanSNI.normalizedASCII()
            profile.ports[i].ssServer = profile.ports[i].ssServer.normalizedASCII()
            profile.ports[i].ssMethod = profile.ports[i].ssMethod.normalizedASCII()
            profile.ports[i].ssPassword = profile.ports[i].ssPassword.normalizedASCII()
            profile.ports[i].vmessServer = profile.ports[i].vmessServer.normalizedASCII()
            profile.ports[i].vmessUUID = profile.ports[i].vmessUUID.normalizedASCII()
        }
        for i in profile.cargoes.indices {
            profile.cargoes[i].url = profile.cargoes[i].url.normalizedASCII()
        }
        // 直连恒为已验证
        for i in profile.ports.indices where profile.ports[i].type == "direct" {
            profile.ports[i].verified = true
        }

        // Profile 中的密码字段拷贝到 Keychain，存储时清空
        var sanitized = profile
        for i in sanitized.ports.indices {
            let id = sanitized.ports[i].id
            if !sanitized.ports[i].vpnPassword.isEmpty {
                KeychainStore.save(password: sanitized.ports[i].vpnPassword,
                                   account: keychainPrefix + id + "-vpn")
                sanitized.ports[i].vpnPassword = ""
            }
            if !sanitized.ports[i].trojanPassword.isEmpty {
                KeychainStore.save(password: sanitized.ports[i].trojanPassword,
                                   account: keychainPrefix + id + "-trojan")
                sanitized.ports[i].trojanPassword = ""
            }
            if !sanitized.ports[i].ssPassword.isEmpty {
                KeychainStore.save(password: sanitized.ports[i].ssPassword,
                                   account: keychainPrefix + id + "-ss")
                sanitized.ports[i].ssPassword = ""
            }
            if !sanitized.ports[i].vmessUUID.isEmpty {
                KeychainStore.save(password: sanitized.ports[i].vmessUUID,
                                   account: keychainPrefix + id + "-vmess")
                sanitized.ports[i].vmessUUID = ""
            }
        }

        guard let data = try? JSONEncoder().encode(sanitized) else { return }
        UserDefaults.standard.set(data, forKey: profileKey)
    }

    private func loadSaved() {
        guard let data = UserDefaults.standard.data(forKey: profileKey) else {
            return  // 第一次启动，保留 bootstrap
        }
        // 优先按新格式解析；失败再按旧格式迁移
        var loaded: Profile
        if let p = try? JSONDecoder().decode(Profile.self, from: data) {
            loaded = p
        } else if let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let migrated = Self.migrate(oldProfile: old) {
            loaded = migrated
            appLog("Profile: migrated from old schema")
        } else {
            return
        }

        // 从 Keychain 恢复密码：先试新 prefix，再试旧 prefix（迁移）
        let oldPrefixes = ["xdial-exit-"]  // 历史 prefix
        for i in loaded.ports.indices {
            let id = loaded.ports[i].id
            loaded.ports[i].vpnPassword = loadKeychain(id: id, suffix: "vpn", oldPrefixes: oldPrefixes)
            loaded.ports[i].trojanPassword = loadKeychain(id: id, suffix: "trojan", oldPrefixes: oldPrefixes)
            loaded.ports[i].ssPassword = loadKeychain(id: id, suffix: "ss", oldPrefixes: oldPrefixes)
            loaded.ports[i].vmessUUID = loadKeychain(id: id, suffix: "vmess", oldPrefixes: oldPrefixes)
        }
        self.profile = loaded
        save()  // 保存为新格式
    }

    private func loadKeychain(id: String, suffix: String, oldPrefixes: [String]) -> String {
        if let v = KeychainStore.load(account: keychainPrefix + id + "-" + suffix), !v.isEmpty {
            return v
        }
        // 回退到旧 prefix
        for old in oldPrefixes {
            if let v = KeychainStore.load(account: old + id + "-" + suffix), !v.isEmpty {
                return v
            }
        }
        return ""
    }

    /// 把旧格式 profile (v0.2: exits/rules/strategies) 迁移到新格式 (ports/cargoes/cruises)
    static func migrate(oldProfile: [String: Any]) -> Profile? {
        var p = Profile()
        // 旧版本的 v0.2 里是 exits/rules/strategies
        if let oldExits = oldProfile["exits"] as? [[String: Any]] {
            p.ports = oldExits.compactMap { dict -> Port? in
                guard let data = try? JSONSerialization.data(withJSONObject: dict),
                      let port = try? JSONDecoder().decode(Port.self, from: data) else { return nil }
                return port
            }
        }
        if let oldRules = oldProfile["rules"] as? [[String: Any]] {
            p.cargoes = oldRules.compactMap { dict -> Cargo? in
                guard let data = try? JSONSerialization.data(withJSONObject: dict),
                      let c = try? JSONDecoder().decode(Cargo.self, from: data) else { return nil }
                return c
            }
        }
        if let oldStrategies = oldProfile["strategies"] as? [[String: Any]] {
            p.cruises = oldStrategies.compactMap { dict -> Cruise? in
                // 旧 strategy.bindings 用 rule_id/exit_id；旧 default_exit_id
                var fixed = dict
                if let oldBindings = dict["bindings"] as? [[String: Any]] {
                    fixed["bindings"] = oldBindings.map { b -> [String: Any] in
                        var nb = b
                        if let r = b["rule_id"] { nb["cargo_id"] = r; nb.removeValue(forKey: "rule_id") }
                        if let e = b["exit_id"] { nb["port_id"] = e; nb.removeValue(forKey: "exit_id") }
                        return nb
                    }
                }
                if let de = dict["default_exit_id"] {
                    fixed["default_port_id"] = de
                    fixed.removeValue(forKey: "default_exit_id")
                }
                guard let data = try? JSONSerialization.data(withJSONObject: fixed),
                      let c = try? JSONDecoder().decode(Cruise.self, from: data) else { return nil }
                return c
            }
        }
        if let active = oldProfile["active_strategy_id"] as? String {
            p.activeCruiseID = active
        }
        return p.ports.isEmpty && p.cargoes.isEmpty && p.cruises.isEmpty ? nil : p
    }

    private func checkHelper() {
        helperInstalled = PrivilegeManager.isInstalled
        helperNeedsUpdate = PrivilegeManager.needsUpdate
    }

    // MARK: - Cruise Management

    func createCruise(from template: CruiseTemplate, named name: String) {
        let direct = profile.ports.first(where: { $0.type == "direct" })?.id ?? "direct"
        let vpn = profile.ports.first(where: { $0.type == "vpn" })?.id ?? "vpn"
        let ss = profile.ports.first(where: { $0.type != "direct" && $0.type != "vpn" })?.id ?? "ss"

        let manualRules = profile.cargoes
            .filter { $0.type == "manual" && $0.enabled }
            .map { $0.id }
        let gfwRule = profile.cargoes
            .first(where: { $0.type == "url" && $0.enabled })?.id ?? ""

        var s: Cruise
        switch template {
        case .overseas:
            s = Profile.templateOverseas(
                cargoIDs: manualRules,
                vpnPortID: vpn,
                directPortID: direct
            )
        case .domestic:
            s = Profile.templateDomestic(
                cargoIDs: manualRules,
                gfwCargoID: gfwRule,
                vpnPortID: vpn,
                directPortID: direct
            )
        case .domesticSS:
            s = Profile.templateDomesticSS(
                cargoIDs: manualRules,
                gfwCargoID: gfwRule,
                vpnPortID: vpn,
                ssPortID: ss,
                directPortID: direct
            )
        case .blank:
            s = Cruise(id: UUID().uuidString, name: name, defaultPortID: direct)
        }
        s.name = name
        profile.cruises.append(s)
        if profile.activeCruiseID.isEmpty {
            profile.activeCruiseID = s.id
        }
        save()
    }

    func deleteCruise(_ s: Cruise) {
        profile.cruises.removeAll { $0.id == s.id }
        if profile.activeCruiseID == s.id {
            profile.activeCruiseID = profile.cruises.first?.id ?? ""
        }
        save()
    }

    // MARK: - Build profile JSON

    func buildProfileJSON() -> String {
        guard let data = try? JSONEncoder().encode(profile) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

enum CruiseTemplate: String, CaseIterable {
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
