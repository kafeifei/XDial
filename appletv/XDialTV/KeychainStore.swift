import Foundation
import Security

enum KeychainStore {
    struct Context {
        let service: String
        let vaultAccount: String
        let legacyVaultFileURL: URL
        let accessGroup: String?

        static let production = Context(
            service: "com.kafeifei.xdial",
            vaultAccount: "xdial-vault",
            legacyVaultFileURL: KeychainStore.productionLegacyVaultFileURL,
            accessGroup: nil
        )

        static func testing(identifier: String, accessGroup: String? = nil) -> Context {
            let safeIdentifier = identifier.replacingOccurrences(
                of: "[^A-Za-z0-9._-]",
                with: "-",
                options: .regularExpression
            )
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("xdial-persistence-tests", isDirectory: true)
                .appendingPathComponent(safeIdentifier, isDirectory: true)
            return Context(
                service: "com.kafeifei.xdial.tests.\(safeIdentifier)",
                vaultAccount: "xdial-vault",
                legacyVaultFileURL: base.appendingPathComponent("vault.json"),
                accessGroup: accessGroup
            )
        }
    }

    struct VaultEnvelope: Codable, Equatable {
        static let currentFormat = "xdial-secure-vault"
        static let currentSchemaVersion = 1

        let format: String
        let schemaVersion: Int
        let revision: String
        let values: [String: String]
        let quarantinedLegacyValues: [String: String]

        init(
            revision: String,
            values: [String: String],
            quarantinedLegacyValues: [String: String] = [:]
        ) {
            format = Self.currentFormat
            schemaVersion = Self.currentSchemaVersion
            self.revision = revision
            self.values = values
            self.quarantinedLegacyValues = quarantinedLegacyValues
        }

        enum CodingKeys: String, CodingKey {
            case format
            case schemaVersion = "schema_version"
            case revision
            case values
            case quarantinedLegacyValues = "quarantined_legacy_values"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            format = try container.decode(String.self, forKey: .format)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            revision = try container.decode(String.self, forKey: .revision)
            values = try container.decode([String: String].self, forKey: .values)
            quarantinedLegacyValues = try container.decodeIfPresent(
                [String: String].self,
                forKey: .quarantinedLegacyValues
            ) ?? [:]
        }

        var isValid: Bool {
            format == Self.currentFormat
                && schemaVersion == Self.currentSchemaVersion
                && !revision.isEmpty
        }
    }

    enum VaultLoadState: Equatable {
        case missing
        case available(VaultEnvelope, cleanupRequired: Bool)
        case legacy([String: String])
        case unavailable(OSStatus)
        case corrupt
    }

    enum VaultSaveResult: Equatable {
        case success
        case keychainFailure(OSStatus)
        case cleanupFailure
        case encodingFailure
    }

    enum LegacyItemLoadState: Equatable {
        case missing
        case available(String)
        case unavailable(OSStatus)
        case corrupt
    }

    private enum KeychainPayload {
        case missing
        case envelope(VaultEnvelope)
        case legacy([String: String])
        case unavailable(OSStatus)
        case corrupt
    }

    private enum LegacyFilePayload {
        case missing
        case legacy([String: String])
        case unavailable
        case corrupt
    }

    private static var productionLegacyVaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("xdial", isDirectory: true)
            .appendingPathComponent("vault.json")
    }

    // 保留给迁移测试和旧调用方；新代码应通过 Context 取得路径。
    static var legacyVaultFileURL: URL { Context.production.legacyVaultFileURL }

    static func loadVaultState(context: Context = .production) -> VaultLoadState {
        let keychain = loadKeychainPayload(context: context)
        let legacyFile = loadLegacyFile(context: context)

        switch legacyFile {
        case .corrupt:
            return .corrupt
        case .unavailable:
            return .unavailable(errSecIO)
        case .legacy(let fileValues):
            switch keychain {
            case .envelope(let envelope):
                // 一旦存在带 revision 的新 vault，它就是唯一事实源。旧文件只能清理，
                // 绝不能再覆盖新凭据；删除失败则交给 AppState fail closed。
                let cleaned = cleanupLegacyArtifacts(context: context)
                return .available(envelope, cleanupRequired: !cleaned)
            case .legacy, .missing:
                // 无 revision 的旧时代以文件为较新的事实源，交给 AppState 和旧 profile
                // 一起迁移为同 revision 的两份 envelope。
                return .legacy(fileValues)
            case .unavailable(let status):
                return .unavailable(status)
            case .corrupt:
                return .corrupt
            }
        case .missing:
            switch keychain {
            case .missing:
                return .missing
            case .envelope(let envelope):
                return .available(envelope, cleanupRequired: false)
            case .legacy(let values):
                return .legacy(values)
            case .unavailable(let status):
                return .unavailable(status)
            case .corrupt:
                return .corrupt
            }
        }
    }

    static func saveVault(
        values: [String: String],
        revision: String,
        quarantinedLegacyValues: [String: String] = [:],
        context: Context = .production
    ) -> VaultSaveResult {
        let envelope = VaultEnvelope(
            revision: revision,
            values: values,
            quarantinedLegacyValues: quarantinedLegacyValues
        )
        guard let data = try? JSONEncoder().encode(envelope) else {
            return .encodingFailure
        }
        let status = saveToKeychain(data: data, context: context)
        guard status == errSecSuccess else {
            return .keychainFailure(status)
        }
        guard cleanupLegacyArtifacts(context: context) else {
            return .cleanupFailure
        }
        return .success
    }

    static func loadLegacyItem(account: String, context: Context = .production) -> LegacyItemLoadState {
        var query = baseQuery(account: account, context: context)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess else { return .unavailable(status) }
        guard let data = out as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return .corrupt
        }
        return .available(value)
    }

    @discardableResult
    static func clear(context: Context) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: context.service,
        ]
        if let accessGroup = context.accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        let status = SecItemDelete(query as CFDictionary)
        let keychainCleared = status == errSecSuccess || status == errSecItemNotFound
        return removeLegacyVaultFile(context: context) && keychainCleared
    }

    // MARK: - 旧接口（仅迁移使用）

    static func save(password: String, account: String, context: Context = .production) {
        let data = Data(password.utf8)
        let query = baseQuery(account: account, context: context)
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(account: String, context: Context = .production) -> String? {
        guard case .available(let value) = loadLegacyItem(account: account, context: context) else {
            return nil
        }
        return value
    }

    static func delete(account: String, context: Context = .production) {
        SecItemDelete(baseQuery(account: account, context: context) as CFDictionary)
    }

    #if DEBUG
    @discardableResult
    static func writeRawVaultDataForTesting(_ data: Data, context: Context) -> OSStatus {
        saveToKeychain(data: data, context: context)
    }
    #endif

    // MARK: - Keychain implementation

    private static func loadKeychainPayload(context: Context) -> KeychainPayload {
        var query = baseQuery(account: context.vaultAccount, context: context)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess else { return .unavailable(status) }
        guard let data = out as? Data else { return .corrupt }

        if let envelope = try? JSONDecoder().decode(VaultEnvelope.self, from: data) {
            return envelope.isValid ? .envelope(envelope) : .corrupt
        }
        if let values = try? JSONDecoder().decode([String: String].self, from: data) {
            return .legacy(values)
        }
        return .corrupt
    }

    private static func saveToKeychain(data: Data, context: Context) -> OSStatus {
        let query = baseQuery(account: context.vaultAccount, context: context)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return errSecSuccess }
        guard updateStatus == errSecItemNotFound else { return updateStatus }

        var add = query
        add.merge(update) { _, new in new }
        return SecItemAdd(add as CFDictionary, nil)
    }

    private static func baseQuery(account: String, context: Context) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: context.service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup = context.accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private static func loadLegacyFile(context: Context) -> LegacyFilePayload {
        let url = context.legacyVaultFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .unavailable
        }
        guard let values = try? JSONDecoder().decode([String: String].self, from: data) else {
            return .corrupt
        }
        return .legacy(values)
    }

    private static func cleanupLegacyArtifacts(context: Context) -> Bool {
        let fileRemoved = removeLegacyVaultFile(context: context)
        let keychainItemsRemoved = removeLegacyKeychainItems(context: context)
        return fileRemoved && keychainItemsRemoved
    }

    private static func removeLegacyVaultFile(context: Context) -> Bool {
        let url = context.legacyVaultFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    private static func removeLegacyKeychainItems(context: Context) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: context.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        if let accessGroup = context.accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return true }
        guard status == errSecSuccess else { return false }

        let items: [[String: Any]]
        if let multiple = out as? [[String: Any]] {
            items = multiple
        } else if let single = out as? [String: Any] {
            items = [single]
        } else {
            return false
        }

        let prefixes = ["xdial-line-", "xdial-port-", "xdial-exit-", "xdial-sub-"]
        var allRemoved = true
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account != context.vaultAccount,
                  account == "xdial-vpn" || prefixes.contains(where: account.hasPrefix)
            else { continue }

            let deleteStatus = SecItemDelete(baseQuery(account: account, context: context) as CFDictionary)
            if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
                allRemoved = false
            }
        }
        return allRemoved
    }
}
