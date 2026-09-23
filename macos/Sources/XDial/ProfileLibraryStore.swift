import CryptoKit
import Darwin
import Foundation
import Security

/// The complete local working copy (including subscription URLs and baselines)
/// is authenticated and encrypted. Only a random AES key lives in Keychain.
/// A locked/missing key or corrupt file is an error, never an empty new library.
final class ProfileLibraryStore {
    let directory: URL
    private let keyProvider: ((Bool) throws -> SymmetricKey)?
    private var cachedKey: SymmetricKey?
    private let keychainService: String
    private var loadedDigest: Data?
    private var needsSchemaBackup = false
    private var fileURL: URL { directory.appendingPathComponent("profiles.enc") }

    init(directory: URL = ConfigurationStorage.directory(),
         keychainService: String = ConfigurationStorage.keychainService,
         keyProvider: ((Bool) throws -> SymmetricKey)? = nil) {
        self.directory = directory
        self.keychainService = keychainService
        self.keyProvider = keyProvider
    }

    func load() throws -> ProfileLibrary? {
        guard let data = try readEncryptedFile() else {
            loadedDigest = nil
            return nil
        }
        let box = try AES.GCM.SealedBox(combined: data)
        let plaintext = try AES.GCM.open(box, using: key(create: false),
                                        authenticating: Data("XDial Profile Library v1".utf8))
        let decoded = try JSONDecoder().decode(ProfileLibrary.self, from: plaintext)
        needsSchemaBackup = decoded.schemaVersion < 3
        let library = try decoded.validated()
        loadedDigest = Data(SHA256.hash(data: data))
        return library
    }

    /// Only an absent library permits migration. An unreadable existing library
    /// is never replaced by a legacy snapshot or an empty default.
    func loadOrCreate(migrate: () throws -> ProfileLibrary?) throws -> ProfileLibrary {
        if let existing = try load() { return existing }
        let library = try migrate() ?? ProfileLibrary()
        // Another version may have finished first while conversion was running.
        if let existing = try load() { return existing }
        try save(library)
        return library
    }

    func save(_ library: ProfileLibrary) throws {
        let data = try JSONEncoder().encode(library.validated())
        guard data.count <= 32 * 1024 * 1024 else {
            throw ProfileLibraryError.invalid("配置库超过大小限制")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.appendingPathComponent("profiles.lock").path,
                              O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw ProfileLibraryError.invalid("无法锁定共享配置库，配置尚未保存") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw ProfileLibraryError.invalid("其他版本正在保存共享配置，请稍后重试")
        }
        defer { flock(descriptor, LOCK_UN) }
        let current = try readEncryptedFile()
        let currentDigest = current.map { Data(SHA256.hash(data: $0)) }
        guard currentDigest == loadedDigest else {
            throw ProfileLibraryError.invalid("共享配置已被其他版本更新或删除，当前修改未保存；请重新打开应用后再编辑")
        }
        if needsSchemaBackup, let current {
            let backup = directory.appendingPathComponent("profiles-before-global-" + UUID().uuidString + ".enc")
            try current.write(to: backup, options: [.withoutOverwriting])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            needsSchemaBackup = false
        }
        let sealed = try AES.GCM.seal(data, using: key(create: current == nil),
                                      authenticating: Data("XDial Profile Library v1".utf8))
        guard let combined = sealed.combined else {
            throw ProfileLibraryError.invalid("无法加密配置库")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try combined.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        loadedDigest = Data(SHA256.hash(data: combined))
    }

    private func readEncryptedFile() throws -> Data? {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return nil }
        defer { try? handle.close() }
        let limit = 32 * 1024 * 1024 + 28
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ProfileLibraryError.invalid("配置库超过大小限制") }
        return data
    }

    private func key(create: Bool) throws -> SymmetricKey {
        if let cachedKey { return cachedKey }
        let result: SymmetricKey
        if let keyProvider {
            result = try keyProvider(create)
        } else {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: "profile-library-key-v1",
            ]
            var read = query
            read[kSecReturnData as String] = true
            read[kSecMatchLimit as String] = kSecMatchLimitOne
            var output: CFTypeRef?
            let status = SecItemCopyMatching(read as CFDictionary, &output)
            if status == errSecSuccess, let bytes = output as? Data, bytes.count == 32 {
                result = SymmetricKey(data: bytes)
            } else if status == errSecItemNotFound && create {
                result = SymmetricKey(size: .bits256)
                var add = query
                add[kSecValueData as String] = result.withUnsafeBytes { Data($0) }
                add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                let added = SecItemAdd(add as CFDictionary, nil)
                guard added == errSecSuccess else { throw ProfileLibraryError.keychain(added) }
            } else {
                throw ProfileLibraryError.keychain(status == errSecSuccess ? errSecDecode : status)
            }
        }
        cachedKey = result
        return result
    }
}
