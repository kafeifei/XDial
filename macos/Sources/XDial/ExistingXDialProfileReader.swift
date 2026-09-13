import Foundation
import Security

/// Explicit, read-only copy from the desktop Debug channel. In particular, do
/// not use KeychainStore.loadVault(): its legacy fallback writes to the source.
enum ExistingXDialProfileReader {
    static func readDebug(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                          keychainVault: () throws -> Data? = readDebugKeychainVault) throws -> Profile {
        let preferences = home.appendingPathComponent("Library/Preferences/com.kafeifei.xdial.debug.plist")
        let vaultURL = home.appendingPathComponent(".xdial-debug/vault.json")
        func profileData() throws -> Data {
            let plist = try PropertyListSerialization.propertyList(
                from: boundedRead(preferences), format: nil) as? [String: Any]
            guard let data = plist?["xdial.profile"] as? Data else {
                throw ProfileLibraryError.invalid("没有找到 XDail Debug 的已保存配置")
            }
            return data
        }
        func vaultData() throws -> Data? {
            if FileManager.default.fileExists(atPath: vaultURL.path) {
                return try boundedRead(vaultURL)
            }
            return try keychainVault()
        }
        // The old app persists preferences and its vault separately. Refuse a
        // changing snapshot; never stop that app to obtain one.
        for _ in 0..<3 {
            let data = try profileData()
            let vault = try vaultData()
            guard data == (try profileData()), vault == (try vaultData()) else { continue }
            return try restore(profileData: data, vaultData: vault)
        }
        throw ProfileLibraryError.invalid("XDail Debug 正在保存配置，请稍后重新导入")
    }

    static func restore(profileData: Data, vaultData: Data?) throws -> Profile {
        guard let root = try JSONSerialization.jsonObject(with: profileData) as? [String: Any],
              root["lines"] is [Any], root["scenarios"] is [Any] else {
            throw ProfileLibraryError.invalid("该版本的 XDial 配置尚不支持迁移，原配置已保留")
        }
        var profile = try JSONDecoder().decode(Profile.self, from: profileData)
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.kafeifei.xdial.debug",
            kSecAttrAccount as String: "xdial-vault",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var output: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &output)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = output as? Data else {
            throw ProfileLibraryError.invalid("无法读取 XDail Debug 的旧凭据，未修改任何配置（\(status)）")
        }
        return data
    }
}
