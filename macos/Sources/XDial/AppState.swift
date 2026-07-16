import Combine
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    #if DEBUG
    static private(set) weak var current: AppState?
    #endif

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
    private let keychainPrefix = "xdial-line-"
    private let subKeychainPrefix = "xdial-sub-"
    private var cachedVault: [String: String] = [:]

    func tr(_ zh: String, _ en: String) -> String {
        language == .zh ? zh : en
    }

    var isConnected: Bool { engine.isConnected }
    var isBusy: Bool { engine.isBusy }

    var canConnect: Bool {
        guard helperInstalled, !isBusy else { return false }
        guard let s = activeMode else { return false }
        // 必须有效的 VPN 凭据（如果模式用到 VPN）
        for binding in s.bindings {
            if let line = profile.lines.first(where: { $0.id == binding.lineID }),
               line.type == "vpn",
               (line.vpnServer.isEmpty || line.vpnUsername.isEmpty || line.vpnPassword.isEmpty) {
                return false
            }
        }
        if let line = profile.lines.first(where: { $0.id == s.defaultLineID }),
           line.type == "vpn",
           (line.vpnServer.isEmpty || line.vpnUsername.isEmpty || line.vpnPassword.isEmpty) {
            return false
        }
        return true
    }

    var statusText: String {
        switch engine.status {
        case "connected": return tr("已连接", "Connected")
        case "connecting": return tr("正在连接…", "Connecting…")
        case "disconnecting": return tr("正在断开…", "Disconnecting…")
        case "reconnecting": return tr("正在重连…", "Reconnecting…")
        default:
            if let err = engine.lastError { return err }
            return tr("未连接", "Not Connected")
        }
    }

    var activeMode: Mode? {
        profile.modes.first { $0.id == profile.activeModeID }
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
                self.markUsedLinesVerified()
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
        #if DEBUG
        Self.current = self
        Self.debugServer.start()
        #endif
    }

    #if DEBUG
    private static let debugServer = DebugServer()
    #endif

    func probeNetwork() {
        guard engine.status == "connected" else { return }
        var usedIDs = Set(activeMode?.bindings.map { $0.lineID } ?? [])
        if let defaultLineID = activeMode?.defaultLineID, !defaultLineID.isEmpty {
            usedIDs.insert(defaultLineID)
        }
        let activeLines = profile.lines.filter {
            usedIDs.contains($0.id) || ($0.enabled && $0.type == "tailscale")
        }
        NetworkInfo.shared.probeAll(
            lines: activeLines,
            subscriptions: profile.subscriptions,
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
        if engine.status == "connected" || engine.status == "connecting" || engine.status == "reconnecting" {
            engine.stop()
        }
        // 2. 取消开机启动
        if launchAtLogin { launchAtLogin = false }
        // 3. 卸载 LaunchDaemon + helper（admin 权限）
        do {
            try PrivilegeManager.uninstall(deleteData: deleteData)
        } catch {
            completion(false, error.localizedDescription)
            return
        }
        // 4. 可选：删除用户数据
        if deleteData {
            UserDefaults.standard.removeObject(forKey: profileKey)
            UserDefaults.standard.removeObject(forKey: "xdial.language")
            UserDefaults.standard.removeObject(forKey: "xdial.launchAtLogin")
            // 彻底删除 ~/.xdial（明文密码所在）+ Keychain 旧数据，而不只是把 vault 覆盖成空
            KeychainStore.deleteVault()
            try? FileManager.default.removeItem(atPath: appLogPath())
        }
        helperInstalled = false
        completion(true, nil)
    }

    private var lastVerifiedAt: String = ""

    private func markUsedLinesVerified() {
        guard let s = activeMode else { return }
        let key = s.id
        if lastVerifiedAt == key { return }
        lastVerifiedAt = key

        var usedIDs = Set(s.bindings.map { $0.lineID })
        if !s.defaultLineID.isEmpty { usedIDs.insert(s.defaultLineID) }

        var changed = false
        for i in profile.lines.indices where usedIDs.contains(profile.lines[i].id) {
            if !profile.lines[i].verified {
                profile.lines[i].verified = true
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

    func loginTailscale(lineID: String) {
        save()
        if !helperInstalled || helperNeedsUpdate {
            installHelper()
        }
        guard helperInstalled, !helperNeedsUpdate else { return }
        engine.loginTailscale(lineID: lineID, profileJSON: buildProfileJSON())
    }

    func refreshTailscaleExitNodes(lineID: String) {
        save()
        if !helperInstalled || helperNeedsUpdate {
            installHelper()
        }
        guard helperInstalled, !helperNeedsUpdate else { return }
        engine.refreshTailscaleExitNodes(lineID: lineID, profileJSON: buildProfileJSON())
    }

    func installHelper(thenConnect: Bool = false) {
        do {
            try PrivilegeManager.install()
            helperInstalled = PrivilegeManager.isInstalled
            helperNeedsUpdate = false
            appLog("installHelper: success, installed=\(helperInstalled)")
            if thenConnect && helperInstalled { connect() }
        } catch {
            appLog("installHelper: FAILED: \(error.localizedDescription)")
            engine.lastError = error.localizedDescription
            helperInstalled = PrivilegeManager.isInstalled
        }
    }

    // MARK: - Persistence

    func save() {
        // 先把所有 ASCII 字段做一次全角→半角清洗（兜底）
        for i in profile.lines.indices {
            profile.lines[i].vpnServer = profile.lines[i].vpnServer.normalizedASCII()
            profile.lines[i].vpnUsername = profile.lines[i].vpnUsername.normalizedASCII()
            profile.lines[i].vpnPassword = profile.lines[i].vpnPassword.normalizedASCII()
            profile.lines[i].trojanServer = profile.lines[i].trojanServer.normalizedASCII()
            profile.lines[i].trojanPassword = profile.lines[i].trojanPassword.normalizedASCII()
            profile.lines[i].trojanSNI = profile.lines[i].trojanSNI.normalizedASCII()
            profile.lines[i].ssServer = profile.lines[i].ssServer.normalizedASCII()
            profile.lines[i].ssMethod = profile.lines[i].ssMethod.normalizedASCII()
            profile.lines[i].ssPassword = profile.lines[i].ssPassword.normalizedASCII()
            profile.lines[i].vmessServer = profile.lines[i].vmessServer.normalizedASCII()
            profile.lines[i].vmessUUID = profile.lines[i].vmessUUID.normalizedASCII()
            profile.lines[i].tailscaleHostname = profile.lines[i].tailscaleHostname.normalizedASCII()
            profile.lines[i].tailscaleExitNode = profile.lines[i].tailscaleExitNode.normalizedASCII()
        }
        for i in profile.ruleSets.indices {
            profile.ruleSets[i].url = profile.ruleSets[i].url.normalizedASCII()
        }
        // 直连恒为已验证
        for i in profile.lines.indices where profile.lines[i].type == "direct" {
            profile.lines[i].verified = true
        }

        // 所有密码收集到一个 vault dict，一次性存入 Keychain（只弹一次授权）
        var vault = [String: String]()
        var sanitized = profile

        for i in sanitized.lines.indices {
            let id = sanitized.lines[i].id
            if !sanitized.lines[i].vpnPassword.isEmpty {
                vault[id + "-vpn"] = sanitized.lines[i].vpnPassword
                sanitized.lines[i].vpnPassword = ""
            }
            if !sanitized.lines[i].trojanPassword.isEmpty {
                vault[id + "-trojan"] = sanitized.lines[i].trojanPassword
                sanitized.lines[i].trojanPassword = ""
            }
            if !sanitized.lines[i].ssPassword.isEmpty {
                vault[id + "-ss"] = sanitized.lines[i].ssPassword
                sanitized.lines[i].ssPassword = ""
            }
            if !sanitized.lines[i].vmessUUID.isEmpty {
                vault[id + "-vmess"] = sanitized.lines[i].vmessUUID
                sanitized.lines[i].vmessUUID = ""
            }
        }
        for si in sanitized.subscriptions.indices {
            let subID = sanitized.subscriptions[si].id
            for pi in sanitized.subscriptions[si].lines.indices {
                let lineID = sanitized.subscriptions[si].lines[pi].id
                let k = subID + "-" + lineID
                let line = sanitized.subscriptions[si].lines[pi]
                if !line.trojanPassword.isEmpty {
                    vault[k + "-trojan"] = line.trojanPassword
                    sanitized.subscriptions[si].lines[pi].trojanPassword = ""
                }
                if !line.ssPassword.isEmpty {
                    vault[k + "-ss"] = line.ssPassword
                    sanitized.subscriptions[si].lines[pi].ssPassword = ""
                }
                if !line.vmessUUID.isEmpty {
                    vault[k + "-vmess"] = line.vmessUUID
                    sanitized.subscriptions[si].lines[pi].vmessUUID = ""
                }
            }
        }

        if vault != cachedVault {
            KeychainStore.saveVault(vault)
            cachedVault = vault
        }

        guard let data = try? JSONEncoder().encode(sanitized) else { return }
        UserDefaults.standard.set(data, forKey: profileKey)
    }

    private func loadSaved() {
        guard let data = UserDefaults.standard.data(forKey: profileKey) else {
            appLog("loadSaved: no saved data, using bootstrap")
            return  // 第一次启动，保留 bootstrap
        }
        appLog("loadSaved: found \(data.count) bytes")

        // 先把原始 JSON 解成字典，做「旧命名 → 新命名」的精确 key 重写：
        // 比喻命名时代（ports/cargoes/cruises/active_cruise_id/cargo_id/port_id/
        // default_port_id）持久化的 profile，key 与新 CodingKeys 不一致。由于 Profile
        // 的所有 key 都是 decodeIfPresent，直接解码旧数据不会抛错、而是静默得到空 profile，
        // 因此必须在解码前把旧 key 改写成新 key（严格精确匹配，绝不子串替换，避免误伤
        // trojan_port / default_subscription_id 等含 "port" 子串的字段）。
        var rewrittenData = data
        var didKeyRewrite = false
        if let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           Self.hasLegacyMetaphorKeys(raw) {
            let migrated = Self.rewriteLegacyMetaphorKeys(raw)
            if let d = try? JSONSerialization.data(withJSONObject: migrated) {
                rewrittenData = d
                didKeyRewrite = true
                appLog("loadSaved: rewrote legacy metaphor keys → new schema")
            }
        }

        // 优先按新格式解析；失败再按更旧格式（v0.2 exits/rules/strategies）迁移
        var loaded: Profile
        do {
            loaded = try JSONDecoder().decode(Profile.self, from: rewrittenData)
            appLog("loadSaved: decoded OK, \(loaded.lines.count) lines, \(loaded.modes.count) modes, \(loaded.subscriptions.count) subs")
        } catch {
            appLog("loadSaved: decode failed: \(error)")
            if let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let migrated = Self.migrate(oldProfile: old) {
                loaded = migrated
                appLog("Profile: migrated from old schema")
            } else {
                appLog("loadSaved: migration also failed, using bootstrap")
                return
            }
        }

        // 从 vault（单条目）恢复密码，回退到旧的逐条方式（迁移）
        var vault = KeychainStore.loadVault()
        cachedVault = vault
        var didMigrate = didKeyRewrite
        if vault.isEmpty {
            didMigrate = true
            // 迁移：从旧的逐条 Keychain 读取（含旧的 "xdial-port-" 前缀）
            let oldPrefixes = [keychainPrefix, "xdial-port-", "xdial-exit-"]
            for line in loaded.lines {
                for pfx in oldPrefixes {
                    for suffix in ["vpn", "trojan", "ss", "vmess"] {
                        if let v = KeychainStore.load(account: pfx + line.id + "-" + suffix), !v.isEmpty {
                            vault[line.id + "-" + suffix] = v
                        }
                    }
                }
            }
            appLog("loadSaved: migrated \(vault.count) passwords to vault")
        }

        for i in loaded.lines.indices {
            let id = loaded.lines[i].id
            if let v = vault[id + "-vpn"] { loaded.lines[i].vpnPassword = v }
            if let v = vault[id + "-trojan"] { loaded.lines[i].trojanPassword = v }
            if let v = vault[id + "-ss"] { loaded.lines[i].ssPassword = v }
            if let v = vault[id + "-vmess"] { loaded.lines[i].vmessUUID = v }
        }
        for si in loaded.subscriptions.indices {
            let subID = loaded.subscriptions[si].id
            for pi in loaded.subscriptions[si].lines.indices {
                let lineID = loaded.subscriptions[si].lines[pi].id
                let k = subID + "-" + lineID
                if let v = vault[k + "-trojan"] { loaded.subscriptions[si].lines[pi].trojanPassword = v }
                if let v = vault[k + "-ss"] { loaded.subscriptions[si].lines[pi].ssPassword = v }
                if let v = vault[k + "-vmess"] { loaded.subscriptions[si].lines[pi].vmessUUID = v }
            }
        }

        self.profile = loaded
        if didMigrate { save() }
    }

    // MARK: - Legacy 命名 key 迁移（比喻命名 → 正式命名）
    //
    // 只做「精确 key 匹配」的重写，绝不做字符串子串替换 —— 否则会误伤 trojan_port、
    // default_subscription_id、vpn_server 这类含 "port"/"cargo"/"cruise" 子串的合法字段。

    /// 判断字典里是否存在任一比喻命名时代的顶层/内嵌 key（用于决定是否需要重写）。
    private static func hasLegacyMetaphorKeys(_ dict: [String: Any]) -> Bool {
        if dict["ports"] != nil || dict["cargoes"] != nil || dict["cruises"] != nil
            || dict["active_cruise_id"] != nil {
            return true
        }
        // 内嵌：cruises[].bindings[].{cargo_id,port_id}、cruises[].default_port_id、
        // subscriptions[].ports。逐层精确探测。
        if let cruises = dict["cruises"] as? [[String: Any]] {
            for c in cruises {
                if c["default_port_id"] != nil { return true }
                if let bs = c["bindings"] as? [[String: Any]] {
                    for b in bs where b["cargo_id"] != nil || b["port_id"] != nil { return true }
                }
            }
        }
        if let subs = dict["subscriptions"] as? [[String: Any]] {
            for s in subs where s["ports"] != nil { return true }
        }
        return false
    }

    /// 把一份比喻命名的 profile 字典按对照表精确重写成正式命名字典。
    /// 顶层：ports→lines、cargoes→rule_sets、cruises→modes、active_cruise_id→active_mode_id。
    /// mode 内嵌：default_port_id→default_line_id；binding 内嵌：cargo_id→rule_set_id、port_id→line_id。
    /// subscription 内嵌：ports→lines（其内部 Line 字段如 trojan_port 保持不变）。
    private static func rewriteLegacyMetaphorKeys(_ dict: [String: Any]) -> [String: Any] {
        var out = dict

        // 顶层 lines
        if let v = out.removeValue(forKey: "ports") { out["lines"] = v }
        // 顶层 rule_sets
        if let v = out.removeValue(forKey: "cargoes") { out["rule_sets"] = v }
        // 顶层 active_mode_id
        if let v = out.removeValue(forKey: "active_cruise_id") { out["active_mode_id"] = v }

        // 顶层 modes（含其内嵌 bindings / default_port_id 重写）
        if let cruises = out.removeValue(forKey: "cruises") as? [[String: Any]] {
            out["modes"] = cruises.map { rewriteLegacyMode($0) }
        } else if let cruises = out["cruises"] {
            // 类型不是 [[String:Any]]（异常数据）也搬过去，避免丢数据
            out.removeValue(forKey: "cruises")
            out["modes"] = cruises
        }

        // subscriptions 内嵌 ports → lines
        if let subs = out["subscriptions"] as? [[String: Any]] {
            out["subscriptions"] = subs.map { sub -> [String: Any] in
                var ns = sub
                if let v = ns.removeValue(forKey: "ports") { ns["lines"] = v }
                return ns
            }
        }

        return out
    }

    /// 重写单个 mode 字典：default_port_id → default_line_id，bindings 逐条重写。
    private static func rewriteLegacyMode(_ dict: [String: Any]) -> [String: Any] {
        var m = dict
        if let v = m.removeValue(forKey: "default_port_id") { m["default_line_id"] = v }
        if let bindings = m["bindings"] as? [[String: Any]] {
            m["bindings"] = bindings.map { b -> [String: Any] in
                var nb = b
                if let v = nb.removeValue(forKey: "cargo_id") { nb["rule_set_id"] = v }
                if let v = nb.removeValue(forKey: "port_id") { nb["line_id"] = v }
                return nb
            }
        }
        return m
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

    /// 把旧格式 profile (v0.2: exits/rules/strategies) 迁移到新格式 (lines/rule_sets/modes)
    static func migrate(oldProfile: [String: Any]) -> Profile? {
        var p = Profile()
        // 旧版本的 v0.2 里是 exits/rules/strategies
        if let oldExits = oldProfile["exits"] as? [[String: Any]] {
            p.lines = oldExits.compactMap { dict -> Line? in
                guard let data = try? JSONSerialization.data(withJSONObject: dict),
                      let line = try? JSONDecoder().decode(Line.self, from: data) else { return nil }
                return line
            }
        }
        if let oldRules = oldProfile["rules"] as? [[String: Any]] {
            p.ruleSets = oldRules.compactMap { dict -> RuleSet? in
                guard let data = try? JSONSerialization.data(withJSONObject: dict),
                      let c = try? JSONDecoder().decode(RuleSet.self, from: data) else { return nil }
                return c
            }
        }
        if let oldStrategies = oldProfile["strategies"] as? [[String: Any]] {
            p.modes = oldStrategies.compactMap { dict -> Mode? in
                // 旧 strategy.bindings 用 rule_id/exit_id；旧 default_exit_id
                var fixed = dict
                if let oldBindings = dict["bindings"] as? [[String: Any]] {
                    fixed["bindings"] = oldBindings.map { b -> [String: Any] in
                        var nb = b
                        if let r = b["rule_id"] { nb["rule_set_id"] = r; nb.removeValue(forKey: "rule_id") }
                        if let e = b["exit_id"] { nb["line_id"] = e; nb.removeValue(forKey: "exit_id") }
                        return nb
                    }
                }
                if let de = dict["default_exit_id"] {
                    fixed["default_line_id"] = de
                    fixed.removeValue(forKey: "default_exit_id")
                }
                guard let data = try? JSONSerialization.data(withJSONObject: fixed),
                      let c = try? JSONDecoder().decode(Mode.self, from: data) else { return nil }
                return c
            }
        }
        if let active = oldProfile["active_strategy_id"] as? String {
            p.activeModeID = active
        }
        return p.lines.isEmpty && p.ruleSets.isEmpty && p.modes.isEmpty ? nil : p
    }

    private func checkHelper() {
        helperInstalled = PrivilegeManager.isInstalled
        helperNeedsUpdate = PrivilegeManager.needsUpdate
    }

    // MARK: - Subscription Management

    func addSubscription(name: String, url: String, format: String, strategy: String,
                         lines: [Line], proxyGroups: [SubProxyGroup] = [], rules: [SubRule] = []) {
        let sub = Subscription(
            id: "sub-" + String(UUID().uuidString.prefix(8)).lowercased(),
            name: name,
            url: url,
            format: format,
            strategy: strategy,
            lines: lines,
            proxyGroups: proxyGroups,
            rules: rules
        )
        profile.subscriptions.append(sub)
        save()
    }

    func updateSubscription(_ id: String, with result: GoEngine.ParseResult) {
        guard let idx = profile.subscriptions.firstIndex(where: { $0.id == id }) else { return }
        profile.subscriptions[idx].lines = result.lines
        profile.subscriptions[idx].proxyGroups = result.proxyGroups ?? []
        profile.subscriptions[idx].rules = result.rules ?? []
        profile.subscriptions[idx].updatedAt = Int(Date().timeIntervalSince1970)
        save()  // vault 整体覆盖，旧条目自然消失
    }

    func deleteSubscription(_ id: String) {
        profile.subscriptions.removeAll { $0.id == id }
        for i in profile.modes.indices {
            profile.modes[i].bindings.removeAll { $0.subscriptionID == id }
            if profile.modes[i].defaultSubscriptionID == id {
                profile.modes[i].defaultSubscriptionID = ""
            }
        }
        save()
    }

    // MARK: - Mode Management

    func createMode(from template: ModeTemplate, named name: String) {
        let direct = profile.lines.first(where: { $0.type == "direct" })?.id ?? "direct"
        let vpn = profile.lines.first(where: { $0.type == "vpn" })?.id ?? "vpn"
        let ss = profile.lines.first(where: { $0.type != "direct" && $0.type != "vpn" })?.id ?? "ss"

        let manualRules = profile.ruleSets
            .filter { $0.type == "manual" && $0.enabled }
            .map { $0.id }
        let gfwRule = profile.ruleSets
            .first(where: { $0.type == "url" && $0.enabled })?.id ?? ""

        var s: Mode
        switch template {
        case .overseas:
            s = Profile.templateOverseas(
                ruleSetIDs: manualRules,
                vpnLineID: vpn,
                directLineID: direct
            )
        case .domestic:
            s = Profile.templateDomestic(
                ruleSetIDs: manualRules,
                gfwRuleSetID: gfwRule,
                vpnLineID: vpn,
                directLineID: direct
            )
        case .domesticSS:
            s = Profile.templateDomesticSS(
                ruleSetIDs: manualRules,
                gfwRuleSetID: gfwRule,
                vpnLineID: vpn,
                ssLineID: ss,
                directLineID: direct
            )
        case .blank:
            s = Mode(id: UUID().uuidString, name: name, defaultLineID: direct)
        }
        s.name = name
        profile.modes.append(s)
        if profile.activeModeID.isEmpty {
            profile.activeModeID = s.id
        }
        save()
    }

    func deleteMode(_ s: Mode) {
        profile.modes.removeAll { $0.id == s.id }
        if profile.activeModeID == s.id {
            profile.activeModeID = profile.modes.first?.id ?? ""
        }
        save()
    }

    // MARK: - Build profile JSON

    func buildProfileJSON() -> String {
        guard let data = try? JSONEncoder().encode(profile) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

enum ModeTemplate: String, CaseIterable {
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
