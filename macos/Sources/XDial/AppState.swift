import Combine
import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var profile: Profile

    @Published var helperInstalled: Bool = false
    @Published var helperNeedsUpdate: Bool = false

    let engine = GoEngine.shared
    private var engineSub: AnyCancellable?

    private let profileKey = "xdial.profile"
    private let keychainPrefix = "xdial-exit-"

    var isConnected: Bool { engine.isConnected }
    var isBusy: Bool { engine.isBusy }

    var canConnect: Bool {
        guard helperInstalled, !isBusy else { return false }
        guard let s = activeStrategy else { return false }
        // 必须有效的 VPN 凭据（如果策略用到 VPN）
        for binding in s.bindings {
            if let exit = profile.exits.first(where: { $0.id == binding.exitID }),
               exit.type == "vpn",
               (exit.vpnServer.isEmpty || exit.vpnUsername.isEmpty || exit.vpnPassword.isEmpty) {
                return false
            }
        }
        if let exit = profile.exits.first(where: { $0.id == s.defaultExitID }),
           exit.type == "vpn",
           (exit.vpnServer.isEmpty || exit.vpnUsername.isEmpty || exit.vpnPassword.isEmpty) {
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

    var activeStrategy: Strategy? {
        profile.strategies.first { $0.id == profile.activeStrategyID }
    }

    init() {
        // 先用 bootstrap 初始化，loadSaved 后会被覆盖
        self.profile = Profile.bootstrap()

        engineSub = engine.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        loadSaved()
        checkHelper()
        engine.syncStatus()
    }

    // MARK: - Connect

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
        // Profile 中的密码字段拷贝到 Keychain，存储时用 "***"
        var sanitized = profile
        for i in sanitized.exits.indices {
            let id = sanitized.exits[i].id
            if !sanitized.exits[i].vpnPassword.isEmpty {
                KeychainStore.save(password: sanitized.exits[i].vpnPassword,
                                   account: keychainPrefix + id + "-vpn")
                sanitized.exits[i].vpnPassword = ""
            }
            if !sanitized.exits[i].trojanPassword.isEmpty {
                KeychainStore.save(password: sanitized.exits[i].trojanPassword,
                                   account: keychainPrefix + id + "-trojan")
                sanitized.exits[i].trojanPassword = ""
            }
            if !sanitized.exits[i].ssPassword.isEmpty {
                KeychainStore.save(password: sanitized.exits[i].ssPassword,
                                   account: keychainPrefix + id + "-ss")
                sanitized.exits[i].ssPassword = ""
            }
            if !sanitized.exits[i].vmessUUID.isEmpty {
                KeychainStore.save(password: sanitized.exits[i].vmessUUID,
                                   account: keychainPrefix + id + "-vmess")
                sanitized.exits[i].vmessUUID = ""
            }
        }

        guard let data = try? JSONEncoder().encode(sanitized) else { return }
        UserDefaults.standard.set(data, forKey: profileKey)
    }

    private func loadSaved() {
        guard let data = UserDefaults.standard.data(forKey: profileKey),
              var loaded = try? JSONDecoder().decode(Profile.self, from: data) else {
            // 第一次启动，保留 bootstrap
            return
        }
        // 从 Keychain 恢复密码
        for i in loaded.exits.indices {
            let id = loaded.exits[i].id
            loaded.exits[i].vpnPassword =
                KeychainStore.load(account: keychainPrefix + id + "-vpn") ?? ""
            loaded.exits[i].trojanPassword =
                KeychainStore.load(account: keychainPrefix + id + "-trojan") ?? ""
            loaded.exits[i].ssPassword =
                KeychainStore.load(account: keychainPrefix + id + "-ss") ?? ""
            loaded.exits[i].vmessUUID =
                KeychainStore.load(account: keychainPrefix + id + "-vmess") ?? ""
        }
        self.profile = loaded
    }

    private func checkHelper() {
        helperInstalled = PrivilegeManager.isInstalled
        helperNeedsUpdate = PrivilegeManager.needsUpdate
    }

    // MARK: - Strategy Management

    func createStrategy(from template: StrategyTemplate, named name: String) {
        let direct = profile.exits.first(where: { $0.type == "direct" })?.id ?? "direct"
        let vpn = profile.exits.first(where: { $0.type == "vpn" })?.id ?? "vpn"
        let ss = profile.exits.first(where: { $0.type != "direct" && $0.type != "vpn" })?.id ?? "ss"

        let manualRules = profile.rules
            .filter { $0.type == "manual" && $0.enabled }
            .map { $0.id }
        let gfwRule = profile.rules
            .first(where: { $0.type == "url" && $0.enabled })?.id ?? ""

        var s: Strategy
        switch template {
        case .overseas:
            s = Profile.templateOverseas(
                domainRuleIDs: manualRules,
                vpnExitID: vpn,
                directExitID: direct
            )
        case .domestic:
            s = Profile.templateDomestic(
                domainRuleIDs: manualRules,
                gfwRuleID: gfwRule,
                vpnExitID: vpn,
                directExitID: direct
            )
        case .domesticSS:
            s = Profile.templateDomesticSS(
                domainRuleIDs: manualRules,
                gfwRuleID: gfwRule,
                vpnExitID: vpn,
                ssExitID: ss,
                directExitID: direct
            )
        case .blank:
            s = Strategy(id: UUID().uuidString, name: name, defaultExitID: direct)
        }
        s.name = name
        profile.strategies.append(s)
        if profile.activeStrategyID.isEmpty {
            profile.activeStrategyID = s.id
        }
        save()
    }

    func deleteStrategy(_ s: Strategy) {
        profile.strategies.removeAll { $0.id == s.id }
        if profile.activeStrategyID == s.id {
            profile.activeStrategyID = profile.strategies.first?.id ?? ""
        }
        save()
    }

    // MARK: - Build profile JSON

    func buildProfileJSON() -> String {
        guard let data = try? JSONEncoder().encode(profile) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

enum StrategyTemplate: String, CaseIterable {
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
