import Foundation
import Security

enum KeychainStore {
    private static let service = "com.kafeifei.xdial"
    private static let vaultAccount = "xdial-vault"

    private static var vaultDir: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".xdial")
        // 目录 0700：只有属主能进入，保护里面的明文凭据文件。
        // createDirectory 的 attributes 只对新建目录生效；旧版本可能已用默认 0755 建过，
        // 所以再显式 setAttributes 一次，把升级用户的旧目录也收紧。
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    // vault 文件路径（优先用文件，Keychain 作为回退）
    private static var vaultFileURL: URL {
        vaultDir.appendingPathComponent("vault.json")
    }

    // MARK: - Vault 接口

    static func saveVault(_ dict: [String: String]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        writeVaultFile(data)
    }

    // 写入后立即收紧为 0600：文件是明文密码，绝不能世界可读（之前默认 0644）
    private static func writeVaultFile(_ data: Data) {
        let url = vaultFileURL
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func loadVault() -> [String: String] {
        // 优先从文件读（不弹窗）
        if let data = try? Data(contentsOf: vaultFileURL),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            return dict
        }
        // 回退到 Keychain（首次迁移时弹一次）
        if let dict = loadFromKeychain() {
            // 迁移到文件，以后不再弹
            if let data = try? JSONEncoder().encode(dict) {
                writeVaultFile(data)
            }
            return dict
        }
        return [:]
    }

    /// 把 macOS Packet Tunnel 试验版容器里的凭据合并回普通桌面用户目录。
    /// 合并而不是替换：保留旧桌面版本已有的订阅凭据；同名条目以较新的容器
    /// 快照为准。全程不记录 key、value 或正文。
    static func importSandboxVaultIfNeeded() {
        let marker = "xdial.migratedFromSandboxVaultV1"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: marker) else { return }

        let source = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/com.kafeifei.xdial/Data/.xdial/vault.json"
            )
        guard let data = try? Data(contentsOf: source),
              let sandboxVault = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }

        var merged = loadVault()
        merged.merge(sandboxVault) { _, sandboxValue in sandboxValue }
        saveVault(merged)
        defaults.set(true, forKey: marker)
        appLog("merged Packet Tunnel sandbox vault into desktop helper vault")
    }

    // 卸载"删除所有数据"时调用：彻底移除 ~/.xdial（明文密码所在）并清 Keychain 旧迁移数据
    static func deleteVault() {
        try? FileManager.default.removeItem(at: vaultDir)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Keychain（回退/迁移）

    private static func saveToKeychain(data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultAccount,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func loadFromKeychain() -> [String: String]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess,
              let data = out as? Data,
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return dict
    }

    // MARK: - 旧接口（迁移用）

    static func save(password: String, account: String) {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess,
              let data = out as? Data,
              let s = String(data: data, encoding: .utf8)
        else { return nil }
        return s
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
