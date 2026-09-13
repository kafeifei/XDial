import CryptoKit
import Foundation
import XCTest

final class ProfileLibraryTests: XCTestCase {
    func testImportedCoreProfileAllowsEmptyTailscaleIdentity() throws {
        let coreJSON = #"{"profile_id":"company","lines":[{"id":"direct","name":"Direct","type":"direct","enabled":true}],"rule_sets":null,"scenarios":[{"id":"scene","name":"Default","bindings":null,"default_line_id":"direct"}],"active_scenario_id":"scene","tailscale":{}}"#
        let profile = try JSONDecoder().decode(Profile.self, from: Data(coreJSON.utf8))
        XCTAssertEqual(profile.tailscale.hostname, "")
        XCTAssertEqual(profile.scenarios.first?.defaultLineID, "direct")
        XCTAssertEqual(profile.ruleSets, [])
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile)), profile)
    }

    func testEncryptedRoundTripAndTamperRejection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let store = ProfileLibraryStore(directory: directory, keyProvider: { _ in key })
        var library = ProfileLibrary()
        library.profiles[0].profile.lines.append(Line(id: "vpn", name: "private-line", type: "vpn", vpnPassword: "secret-password"))
        library.profiles[0].source = ProfileSource(url: "https://example.com/?token=private-token")
        try store.save(library)
        XCTAssertEqual(try store.load(), library)
        let path = directory.appendingPathComponent("profiles.enc")
        var data = try Data(contentsOf: path)
        for secret in ["secret-password", "private-token", "private-line"] {
            XCTAssertNil(data.range(of: Data(secret.utf8)))
        }
        data[data.count / 2] ^= 1
        try data.write(to: path)
        XCTAssertThrowsError(try store.load())
    }

    func testMissingKeyCannotOverwriteExistingLibrary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let store = ProfileLibraryStore(directory: directory, keyProvider: { _ in key })
        let original = ProfileLibrary()
        try store.save(original)
        let locked = ProfileLibraryStore(directory: directory, keyProvider: { create in
            XCTAssertFalse(create)
            throw ProfileLibraryError.keychain(-25308)
        })
        XCTAssertThrowsError(try locked.load())
        XCTAssertThrowsError(try locked.save(ProfileLibrary()))
        XCTAssertEqual(try store.load(), original)
    }

    func testRefreshKeepsLocalScenarioAndRejectsRemovedDependency() throws {
        var record = ProfileRecord.empty(named: "Company")
        record.profile.lines.append(Line(id: "company-vpn", name: "VPN", type: "vpn"))
        record.baseline = record.profile
        let local = Scenario(id: "local", name: "Home", defaultLineID: "company-vpn")
        record.profile.scenarios.append(local)
        let refreshed = try record.refreshed(with: record.baseline!)
        XCTAssertEqual(refreshed.profile.scenarios.last, local)
        var missing = record.baseline!
        missing.lines.removeAll { $0.id == "company-vpn" }
        XCTAssertThrowsError(try record.refreshed(with: missing))
        XCTAssertEqual(record.profile.scenarios.last, local)
    }

    func testRefreshPreservesUserSelectorChoiceAndRejectsItsRemoval() throws {
        var record = ProfileRecord.empty(named: "Source")
        record.profile.lines += [Line(id: "a", name: "A", type: "trojan"), Line(id: "b", name: "B", type: "trojan")]
        var group = Line(id: "group", name: "Select", type: "selector")
        group.groupMembers = ["a", "b"]
        group.groupDefault = "a"
        record.profile.lines.append(group)
        record.baseline = record.profile
        record.profile.lines[3].groupDefault = "b"
        let result = try record.refreshed(with: record.baseline!)
        XCTAssertEqual(result.profile.lines[3].groupDefault, "b")
        var missing = record.baseline!
        missing.lines[3].groupMembers = ["a"]
        XCTAssertThrowsError(try record.refreshed(with: missing))
    }

    func testProfileLibraryRequiresExistingEditorAndRuntimeSelections() throws {
        var library = ProfileLibrary()
        XCTAssertNotEqual(library.profiles[0].id, ProfileLibrary().profiles[0].id)
        library.editingProfileID = "missing"
        XCTAssertThrowsError(try library.validated())
        library.editingProfileID = library.profiles[0].id
        library.activeProfileID = "missing"
        XCTAssertThrowsError(try library.validated())
    }
}
