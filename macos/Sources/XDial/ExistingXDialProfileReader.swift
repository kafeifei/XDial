import Foundation
import Security

/// Read-only snapshots used for the first shared-library conversion. In particular, do
/// not use KeychainStore.loadVault(): its legacy fallback writes to the source.
enum ExistingXDialProfileReader {
    static func readDebug(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                          keychainVault: @escaping () throws -> Data? = readDebugKeychainVault) throws -> Profile {
        let source = ConfigurationStorage.desktopLocations.first { $0.keychainService == "com.kafeifei.xdial.debug" }!
        guard let profile = try read(source, home: home, keychainVault: keychainVault) else {
            throw ProfileLibraryError.invalid("没有找到 XDail Debug 的已保存配置")
        }
        return profile
    }

    static func profileData(at source: ConfigurationStorage.LegacyLocation, home: URL) throws -> Data? {
        let preferences = home.appendingPathComponent(source.preferencesPath)
        guard FileManager.default.fileExists(atPath: preferences.path) else { return nil }
        let plist = try PropertyListSerialization.propertyList(
            from: boundedRead(preferences), format: nil) as? [String: Any]
        guard let value = plist?["xdial.profile"] else { return nil }
        guard let data = value as? Data else {
            throw ProfileLibraryError.invalid("旧版配置格式无效，原文件已保留")
        }
        return data
    }

    static func read(_ source: ConfigurationStorage.LegacyLocation,
                     home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     keychainVault: (() throws -> Data?)? = nil) throws -> Profile? {
        let vaultURL = home.appendingPathComponent(source.dataPath).appendingPathComponent("vault.json")
        func vaultData() throws -> Data? {
            if FileManager.default.fileExists(atPath: vaultURL.path) {
                return try boundedRead(vaultURL)
            }
            if let keychainVault { return try keychainVault() }
            return try readKeychainVault(service: source.keychainService)
        }
        // Preferences and credentials were saved separately by older releases.
        // Copy a stable snapshot without stopping or writing to the old app.
        for _ in 0..<3 {
            guard let data = try profileData(at: source, home: home) else { return nil }
            let vault = try vaultData()
            guard data == (try profileData(at: source, home: home)), vault == (try vaultData()) else { continue }
            return try restore(profileData: data, vaultData: vault)
        }
        throw ProfileLibraryError.invalid("旧版正在保存配置，请稍后重试；原文件已保留")
    }

    static func restore(profileData: Data, vaultData: Data?) throws -> Profile {
        guard var root = try JSONSerialization.jsonObject(with: profileData) as? [String: Any] else {
            throw ProfileLibraryError.invalid("旧版配置格式无效，原文件已保留")
        }
        // v0.2 used exits/rules/strategies. Rename fields without compactMap:
        // every object must decode, so one malformed entry cannot disappear.
        if root["lines"] == nil, root["exits"] != nil {
            root["lines"] = root.removeValue(forKey: "exits")
            root["rule_sets"] = root.removeValue(forKey: "rules")
            if let strategies = root.removeValue(forKey: "strategies") as? [[String: Any]] {
                root["scenarios"] = strategies.map { original -> [String: Any] in
                    var scenario = original
                    if let value = scenario.removeValue(forKey: "default_exit_id") { scenario["default_line_id"] = value }
                    if let bindings = scenario["bindings"] as? [[String: Any]] {
                        scenario["bindings"] = bindings.map { original -> [String: Any] in
                            var binding = original
                            if let value = binding.removeValue(forKey: "rule_id") { binding["rule_set_id"] = value }
                            if let value = binding.removeValue(forKey: "exit_id") { binding["line_id"] = value }
                            return binding
                        }
                    }
                    return scenario
                }
            }
            if let value = root.removeValue(forKey: "active_strategy_id") { root["active_scenario_id"] = value }
        }
        guard root["lines"] is [Any], root["scenarios"] is [Any] else {
            throw ProfileLibraryError.invalid("该版本的 XDial 配置尚不支持迁移，原配置已保留")
        }
        var profile = try JSONDecoder().decode(Profile.self, from: JSONSerialization.data(withJSONObject: root))
        guard profile.subscriptions.isEmpty else {
            throw ProfileLibraryError.invalid("该配置包含旧版嵌套订阅，尚不能完整迁移；没有导入部分内容")
        }
        let vault = try vaultData.map { try JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        for index in profile.lines.indices {
            let id = profile.lines[index].id
            if let value = vault[id + "-vpn"] { profile.lines[index].vpnPassword = value }
            if let value = vault[id + "-trojan"] { profile.lines[index].trojanPassword = value }
            if let value = vault[id + "-ss"] { profile.lines[index].ssPassword = value }
            if let value = vault[id + "-vmess"] { profile.lines[index].vmessUUID = value }
            if let value = vault[id + "-anytls"] { profile.lines[index].anytlsPassword = value }
            // A successful connection in Debug is not a verified Next line.
            profile.lines[index].verified = profile.lines[index].type == "direct"
        }
        return profile
    }

    private static func boundedRead(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 8 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 8 * 1024 * 1024 else {
            throw ProfileLibraryError.invalid("现有配置超过迁移大小限制")
        }
        return data
    }

    static func readDebugKeychainVault() throws -> Data? {
        try readKeychainVault(service: "com.kafeifei.xdial.debug")
    }

    static func readKeychainVault(service: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "xdial-vault",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var output: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &output)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = output as? Data else {
            throw ProfileLibraryError.invalid("无法读取旧版凭据，未修改任何配置（\(status)）")
        }
        return data
    }
}
