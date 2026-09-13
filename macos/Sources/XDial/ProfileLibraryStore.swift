import CryptoKit
import Foundation
import Security

/// The complete local working copy (including subscription URLs and baselines)
/// is authenticated and encrypted. Only a random AES key lives in Keychain.
/// A locked/missing key or corrupt file is an error, never an empty new library.
final class ProfileLibraryStore {
    let directory: URL
    private let keyProvider: ((Bool) throws -> SymmetricKey)?
    private var cachedKey: SymmetricKey?
    private var fileURL: URL { directory.appendingPathComponent("profiles.enc") }

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(XDialBuildIdentity.userDataDirectoryName),
         keyProvider: ((Bool) throws -> SymmetricKey)? = nil) {
        self.directory = directory
        self.keyProvider = keyProvider
    }

    func load() throws -> ProfileLibrary? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        guard data.count <= 32 * 1024 * 1024 + 28 else {
            throw ProfileLibraryError.invalid("配置库超过大小限制")
        }
        let box = try AES.GCM.SealedBox(combined: data)
        let plaintext = try AES.GCM.open(box, using: key(create: false),
                                        authenticating: Data("XDial Profile Library v1".utf8))
        return try JSONDecoder().decode(ProfileLibrary.self, from: plaintext).validated()
    }

    func save(_ library: ProfileLibrary) throws {
        let data = try JSONEncoder().encode(library.validated())
        guard data.count <= 32 * 1024 * 1024 else {
            throw ProfileLibraryError.invalid("配置库超过大小限制")
        }
        let sealed = try AES.GCM.seal(data, using: key(create: !FileManager.default.fileExists(atPath: fileURL.path)),
                                      authenticating: Data("XDial Profile Library v1".utf8))
        guard let combined = sealed.combined else {
            throw ProfileLibraryError.invalid("无法加密配置库")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try combined.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func removeKeyOnExplicitDataDeletion() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: XDialBuildIdentity.dataIdentifier,
            kSecAttrAccount as String: "profile-library-key-v1",
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func key(create: Bool) throws -> SymmetricKey {
        if let cachedKey { return cachedKey }
        let result: SymmetricKey
        if let keyProvider {
            result = try keyProvider(create)
        } else {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: XDialBuildIdentity.dataIdentifier,
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
