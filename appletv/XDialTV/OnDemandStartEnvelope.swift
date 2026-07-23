import Foundation
import Security

struct OnDemandStartEnvelope: Codable, Equatable, Sendable {
    static let currentFormat = "xdial-on-demand-start"
    // v3: acceptance_plan 同时记录所有生成的 Tailscale endpoint readiness；
    // 公网探针只记录适用的显式出口。拒绝旧计划，避免按需恢复漏验 endpoint。
    static let currentSchemaVersion = 3
    static let maxConfigBytes = 2 * 1024 * 1024

    let format: String
    let schemaVersion: Int
    let transport: String
    let parameters: [String: String]
    let configJSON: String

    init(
        transport: String,
        parameters: [String: String],
        configJSON: String
    ) {
        format = Self.currentFormat
        schemaVersion = Self.currentSchemaVersion
        self.transport = transport
        self.parameters = parameters
        self.configJSON = configJSON
    }

    enum CodingKeys: String, CodingKey {
        case format
        case schemaVersion = "schema_version"
        case transport
        case parameters
        case configJSON = "config_json"
    }

    var isValid: Bool {
        format == Self.currentFormat
            && schemaVersion == Self.currentSchemaVersion
            && !transport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !configJSON.isEmpty
            && configJSON.utf8.count <= Self.maxConfigBytes
    }
}

enum OnDemandStartEnvelopeFailurePolicy {
    static func shouldClear(
        startedFromSecureEnvelope: Bool,
        startOrRuntimeFailed: Bool
    ) -> Bool {
        startedFromSecureEnvelope && startOrRuntimeFailed
    }
}

enum OnDemandManualStartContract {
    static func isComplete(
        configJSON: String?,
        usesAnyConnect: Bool?,
        server: String?,
        username: String?,
        password: String?
    ) -> Bool {
        guard let configJSON, !configJSON.isEmpty, let usesAnyConnect else {
            return false
        }
        guard usesAnyConnect else { return true }
        return [server, username, password].allSatisfy {
            guard let value = $0 else { return false }
            return !value.isEmpty
        }
    }
}

final class OneShotNetworkSettingsResult: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var error: Error?

    @discardableResult
    func finish(_ error: Error?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        self.error = error
        return true
    }

    func snapshot() -> (completed: Bool, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (completed, error)
    }
}

enum OnDemandStartEnvelopeStore {
    enum LoadResult: Equatable {
        case missing
        case available(OnDemandStartEnvelope)
        case unavailable(OSStatus)
        case corrupt
    }

    private static let infoKey = "XDialSharedKeychainAccessGroup"
    private static let productionAccessGroup = "UVZM439VGU.com.kafeifei.xdial.shared"
    private static let service = "com.kafeifei.xdial.on-demand"
    private static let account = "start-envelope-v1"

    static func load(bundle: Bundle = .main) -> LoadResult {
        guard let accessGroup = accessGroup(bundle: bundle) else {
            return .unavailable(errSecMissingEntitlement)
        }
        var query = baseQuery(accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var output: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &output)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess else { return .unavailable(status) }
        guard let data = output as? Data,
              let envelope = try? JSONDecoder().decode(OnDemandStartEnvelope.self, from: data),
              envelope.isValid else {
            return .corrupt
        }
        return .available(envelope)
    }

    @discardableResult
    static func save(_ envelope: OnDemandStartEnvelope, bundle: Bundle = .main) -> OSStatus {
        guard envelope.isValid,
              let data = try? JSONEncoder().encode(envelope) else {
            return errSecParam
        }
        guard let accessGroup = accessGroup(bundle: bundle) else {
            return errSecMissingEntitlement
        }

        let query = baseQuery(accessGroup: accessGroup)
        let values: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if updateStatus == errSecSuccess { return errSecSuccess }
        guard updateStatus == errSecItemNotFound else { return updateStatus }

        var item = query
        item.merge(values) { _, newValue in newValue }
        return SecItemAdd(item as CFDictionary, nil)
    }

    @discardableResult
    static func clear(bundle: Bundle = .main) -> OSStatus {
        guard let accessGroup = accessGroup(bundle: bundle) else {
            return errSecMissingEntitlement
        }
        let status = SecItemDelete(baseQuery(accessGroup: accessGroup) as CFDictionary)
        return status == errSecItemNotFound ? errSecSuccess : status
    }

    private static func accessGroup(bundle: Bundle) -> String? {
        let configured = bundle.object(forInfoDictionaryKey: infoKey) as? String
        let trimmed = configured?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmed.isEmpty && !trimmed.contains("$(") ? trimmed : productionAccessGroup
    }

    private static func baseQuery(accessGroup: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }
}
