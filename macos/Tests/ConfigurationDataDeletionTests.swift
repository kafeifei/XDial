import Foundation
import XCTest

final class ConfigurationDataDeletionTests: XCTestCase {
    func testCheckboxControlsRemovalOfCurrentAndAllLegacyConfiguration() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        var paths = ConfigurationStorage.legacyLocations.flatMap { [$0.preferencesPath, $0.dataPath + "/vault.json"] }
        paths.append(ConfigurationStorage.directoryPath + "/profiles.enc")
        for path in paths + [".unrelated/keep.txt"] {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("saved data".utf8).write(to: url)
        }
        var domains: [String] = []
        var services: [String] = []
        try ConfigurationDataDeletion.run(deleteData: false, home: home,
            removePreferences: { domains.append($0) }, removeKeychain: { services.append($0) })
        XCTAssertTrue(domains.isEmpty)
        XCTAssertTrue(services.isEmpty)
        for path in paths { XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(path).path)) }
        try ConfigurationDataDeletion.run(deleteData: true, home: home,
            removePreferences: { domains.append($0) }, removeKeychain: { services.append($0) })
        for path in paths { XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(path).path), path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".unrelated/keep.txt").path))
        XCTAssertEqual(Set(domains), Set(ConfigurationStorage.preferenceDomains))
        XCTAssertEqual(Set(services), Set(ConfigurationStorage.keychainServices))
    }

    func testOtherRunningVersionsBlockSharedDataDeletion() throws {
        for current in ["com.kafeifei.xdial.next", "com.kafeifei.xdial.debug", "com.kafeifei.xdial.app"] {
            XCTAssertNoThrow(try ConfigurationDataDeletion.validateExclusiveAccess(runningIdentifiers: [current, "com.apple.finder"], currentIdentifier: current))
            for other in ConfigurationDataDeletion.applicationIdentifiers where other != current {
                XCTAssertThrowsError(try ConfigurationDataDeletion.validateExclusiveAccess(runningIdentifiers: [current, other], currentIdentifier: current))
            }
        }
    }

    func testCredentialRemovalFailureIsReported() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try ConfigurationDataDeletion.run(deleteData: true, home: home,
            removePreferences: { _ in }, removeKeychain: { _ in throw ProfileLibraryError.invalid("locked") }))
    }
}
