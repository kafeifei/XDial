import AppKit
import Foundation
import Security

enum ConfigurationDataDeletion {
    static let applicationIdentifiers: Set<String> = [
        "com.kafeifei.xdial", "com.kafeifei.xdial.app", "com.kafeifei.xdial.debug",
        "com.kafeifei.xdial.next", "com.kafeifei.xdial.ne-probe",
    ]

    static func validateExclusiveAccess(
        runningIdentifiers: Set<String> = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)),
        currentIdentifier: String = XDialBuildIdentity.applicationIdentifier
    ) throws {
        guard runningIdentifiers.intersection(applicationIdentifiers).subtracting([currentIdentifier]).isEmpty else {
            throw ProfileLibraryError.invalid("请先退出其他版本的 XDial，再删除新旧版本的配置与密码")
        }
    }

    /// Only the explicit uninstall checkbox reaches this operation. The source
    /// directories used for migration are the same bounded set removed here.
    static func run(
        deleteData: Bool,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        removePreferences: (String) throws -> Void = { domain in
            UserDefaults.standard.removePersistentDomain(forName: domain)
        },
        removeKeychain: (String) throws -> Void = removeKeychainService
    ) throws {
        guard deleteData else { return }
        // Clear the preference daemon's cached domains as well as their files;
        // otherwise an old cached profile could reappear on the next launch.
        for domain in ConfigurationStorage.preferenceDomains {
            try removePreferences(domain)
        }
        let paths = Set(ConfigurationStorage.legacyLocations.flatMap { [$0.preferencesPath, $0.dataPath] })
        for path in paths.sorted() {
            let url = home.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        // The shared library lives inside .xdial. Delete the keys last so a
        // filesystem failure cannot strand an otherwise intact encrypted file.
        for service in ConfigurationStorage.keychainServices {
            try removeKeychain(service)
        }
    }

    private static func removeKeychainService(_ service: String) throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProfileLibraryError.invalid("未能删除保存的凭据（\(status)），卸载尚未完成")
        }
    }
}
