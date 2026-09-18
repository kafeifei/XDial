import CryptoKit
import Foundation
import XCTest

final class ProfileLibraryMigrationTests: XCTestCase {
    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: home) }
        return home
    }

    private func writeLegacy(_ profile: Profile, at source: ConfigurationStorage.LegacyLocation,
                             home: URL, date: Date = Date()) throws -> [URL: Data] {
        let preferences = home.appendingPathComponent(source.preferencesPath)
        let vault = home.appendingPathComponent(source.dataPath + "/vault.json")
        let files = [preferences: try PropertyListSerialization.data(
            fromPropertyList: ["xdial.profile": JSONEncoder().encode(profile), "xdial.autoConnect": true],
            format: .binary, options: 0), vault: try JSONEncoder().encode(["vpn-vpn": "saved-password"])]
        for (url, data) in files {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        return files
    }

    private func converted(_ profile: Profile, id: String) -> Profile {
        var value = profile
        value.profileID = id
        return value
    }

    func testFirstLaunchCreatesOneDefaultAndNeverWritesBackToLegacy() throws {
        let home = try temporaryHome()
        let key = SymmetricKey(size: .bits256)
        let store = ProfileLibraryStore(directory: ConfigurationStorage.directory(home: home), keyProvider: { _ in key })
        var old = ProfileRecord.empty(named: "Old").profile
        old.lines.append(Line(id: "vpn", name: "Company", type: "vpn"))
        old.scenarios[0].defaultLineID = "vpn"
        let original = try writeLegacy(old, at: ConfigurationStorage.desktopLocations[0], home: home)
        var conversions = 0
        let library = try store.loadOrCreate {
            try ProfileLibraryMigration.initialLibrary(home: home) { profile, id in
                conversions += 1
                return self.converted(profile, id: id)
            }
        }
        XCTAssertEqual(conversions, 1)
        XCTAssertEqual(library.profiles.count, 1)
        XCTAssertEqual(library.profiles[0].name, "默认配置")
        XCTAssertEqual(library.activeProfileID, library.profiles[0].id)
        XCTAssertEqual(library.editingProfileID, library.profiles[0].id)
        XCTAssertEqual(library.profiles[0].profile.lines.last?.vpnPassword, "saved-password")
        XCTAssertEqual(library.profiles[0].profile.scenarios, old.scenarios)
        var changed = library
        changed.profiles[0].profile.lines[1].name = "Edited in new version"
        try store.save(changed)
        let relaunched = ProfileLibraryStore(directory: store.directory, keyProvider: { _ in key })
        XCTAssertEqual(try relaunched.loadOrCreate { XCTFail("must not import twice"); return nil }, changed)
        for (url, data) in original { XCTAssertEqual(try Data(contentsOf: url), data) }
    }

    func testNewestSavedConfigurationWinsWithoutAChannelPriority() throws {
        let home = try temporaryHome()
        var old = ProfileRecord.empty(named: "Old").profile
        old.lines[0].name = "older formal"
        _ = try writeLegacy(old, at: ConfigurationStorage.desktopLocations[0], home: home, date: Date(timeIntervalSince1970: 100))
        old.lines[0].name = "newer debug"
        _ = try writeLegacy(old, at: ConfigurationStorage.desktopLocations[1], home: home, date: Date(timeIntervalSince1970: 200))
        let library = try XCTUnwrap(ProfileLibraryMigration.initialLibrary(home: home, convertProfile: converted))
        XCTAssertEqual(library.profiles[0].profile.lines[0].name, "newer debug")
    }

    func testExistingNextLibraryRetainsEveryProfileAndOriginalEncryptedFile() throws {
        let home = try temporaryHome()
        let key = SymmetricKey(size: .bits256)
        let source = ConfigurationStorage.desktopLocations[2]
        let oldStore = ProfileLibraryStore(directory: home.appendingPathComponent(source.dataPath), keyProvider: { _ in key })
        var original = ProfileLibrary()
        original.profiles.append(.empty(named: "Second"))
        original.activeProfileID = original.profiles[1].id
        try oldStore.save(original)
        let oldFile = oldStore.directory.appendingPathComponent("profiles.enc")
        let bytes = try Data(contentsOf: oldFile)
        let store = ProfileLibraryStore(directory: ConfigurationStorage.directory(home: home), keyProvider: { _ in key })
        let loaded = try store.loadOrCreate {
            try ProfileLibraryMigration.initialLibrary(home: home, readLibrary: { location in
                XCTAssertEqual(location, source)
                return try oldStore.load()
            }, convertProfile: { _, _ in XCTFail("already a Profile library"); return Profile() })
        }
        XCTAssertEqual(loaded, original)
        XCTAssertEqual(try Data(contentsOf: oldFile), bytes)
        XCTAssertEqual(try store.load(), original)
    }

    func testFailedConversionDoesNotCreateEmptyLibraryOrTouchSource() throws {
        let home = try temporaryHome()
        let key = SymmetricKey(size: .bits256)
        let files = try writeLegacy(ProfileRecord.empty(named: "Old").profile,
                                    at: ConfigurationStorage.desktopLocations[0], home: home)
        let store = ProfileLibraryStore(directory: ConfigurationStorage.directory(home: home), keyProvider: { _ in key })
        XCTAssertThrowsError(try store.loadOrCreate {
            try ProfileLibraryMigration.initialLibrary(home: home) { _, _ in
                throw ProfileLibraryError.invalid("cannot convert")
            }
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("profiles.enc").path))
        for (url, data) in files { XCTAssertEqual(try Data(contentsOf: url), data) }
    }

    func testCorruptSharedLibraryNeverFallsBackToOldConfiguration() throws {
        let home = try temporaryHome()
        let store = ProfileLibraryStore(directory: ConfigurationStorage.directory(home: home), keyProvider: { _ in SymmetricKey(size: .bits256) })
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let file = store.directory.appendingPathComponent("profiles.enc")
        let original = Data("corrupt shared library".utf8)
        try original.write(to: file)
        XCTAssertThrowsError(try store.loadOrCreate { XCTFail("must not migrate an unreadable existing library"); return ProfileLibrary() })
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testAnotherVersionFinishingMigrationFirstIsRetained() throws {
        let home = try temporaryHome()
        let key = SymmetricKey(size: .bits256)
        let first = ProfileLibraryStore(directory: ConfigurationStorage.directory(home: home), keyProvider: { _ in key })
        let second = ProfileLibraryStore(directory: first.directory, keyProvider: { _ in key })
        var winner = ProfileLibrary()
        winner.profiles[0].name = "Already migrated"
        let result = try first.loadOrCreate {
            try second.save(winner)
            return ProfileLibrary()
        }
        XCTAssertEqual(result, winner)
    }

    func testNoLegacyDataCreatesDefaultOnce() throws {
        let home = try temporaryHome()
        let key = SymmetricKey(size: .bits256)
        let store = ProfileLibraryStore(directory: ConfigurationStorage.directory(home: home), keyProvider: { _ in key })
        let result = try store.loadOrCreate {
            try ProfileLibraryMigration.initialLibrary(home: home) { _, _ in XCTFail(); return Profile() }
        }
        XCTAssertEqual(result.profiles.count, 1)
        XCTAssertEqual(result.profiles[0].name, "默认配置")
        XCTAssertEqual(try store.loadOrCreate { XCTFail(); return nil }, result)
    }
}
