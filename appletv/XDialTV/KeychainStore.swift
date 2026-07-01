import Foundation
import Security

enum KeychainStore {
    private static let service = "com.kafeifei.xdial"
    private static let vaultAccount = "xdial-vault"

    // vault 文件路径（优先用文件，Keychain 作为回退）。
    // macOS 版用 homeDirectoryForCurrentUser + ".xdial"，但这个 API 在 tvOS 上不可用
    // （tvOS 沙盒没有传统意义上的用户主目录）；改用 Application Support 目录，
    // 语义等价（app 私有、持久化、不对用户可见）。
    private static var vaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("xdial")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("vault.json")
    }

    // MARK: - Vault 接口

    static func saveVault(_ dict: [String: String]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: vaultFileURL, options: [.atomic])
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
                try? data.write(to: vaultFileURL, options: [.atomic])
            }
            return dict
        }
        return [:]
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
