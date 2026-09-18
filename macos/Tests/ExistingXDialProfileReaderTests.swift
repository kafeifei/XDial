import Foundation
import XCTest

final class ExistingXDialProfileReaderTests: XCTestCase {
    func testConvertsOldFieldNamesWithoutLosingReferences() throws {
        let data = Data(#"{"exits":[{"id":"direct","name":"Direct","type":"direct"}],"rules":[{"id":"rule","name":"Rule","type":"manual","domains":["example.com"]}],"strategies":[{"id":"scene","name":"Scene","bindings":[{"rule_id":"rule","exit_id":"direct"}],"default_exit_id":"direct"}],"active_strategy_id":"scene"}"#.utf8)
        let profile = try ExistingXDialProfileReader.restore(profileData: data, vaultData: nil)
        XCTAssertEqual(profile.activeScenarioID, "scene")
        XCTAssertEqual(profile.scenarios[0].defaultLineID, "direct")
        XCTAssertEqual(profile.scenarios[0].bindings[0].ruleSetID, "rule")
        XCTAssertEqual(profile.scenarios[0].bindings[0].lineID, "direct")
        XCTAssertEqual(profile.ruleSets[0].domains, ["example.com"])
        let malformed = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"exits\":[{", with: "\"exits\":[12,{").utf8)
        XCTAssertThrowsError(try ExistingXDialProfileReader.restore(profileData: malformed, vaultData: nil))
    }

    func testCopiesCredentialsWithoutChangingSourceFilesOrCreatingRuntimeState() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let preferences = home.appendingPathComponent("Library/Preferences/com.kafeifei.xdial.debug.plist")
        let vaultURL = home.appendingPathComponent(".xdial-debug/vault.json")
        for url in [preferences, vaultURL] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var source = ProfileRecord.empty(named: "Original").profile
        source.lines.append(Line(id: "vpn", name: "Company", type: "vpn", verified: true))
        source.lines.append(Line(id: "tls", name: "Proxy", type: "anytls", verified: true))
        source.scenarios[0].defaultLineID = "vpn"
        let profileData = try JSONEncoder().encode(source)
        let preferencesData = try PropertyListSerialization.data(
            fromPropertyList: ["xdial.profile": profileData, "xdial.autoConnect": true], format: .binary, options: 0)
        let vaultData = try JSONEncoder().encode(["vpn-vpn": "vpn-secret", "tls-anytls": "proxy-secret"])
        try preferencesData.write(to: preferences)
        try vaultData.write(to: vaultURL)

        let imported = try ExistingXDialProfileReader.readDebug(home: home, keychainVault: {
            XCTFail("A file-backed vault must not access Keychain")
            return nil
        })
        XCTAssertEqual(imported.lines[1].vpnPassword, "vpn-secret")
        XCTAssertEqual(imported.lines[2].anytlsPassword, "proxy-secret")
        XCTAssertFalse(imported.lines[1].verified)
        XCTAssertTrue(imported.lines[0].verified)
        XCTAssertEqual(imported.scenarios, source.scenarios)
        XCTAssertEqual(try Data(contentsOf: preferences), preferencesData)
        XCTAssertEqual(try Data(contentsOf: vaultURL), vaultData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".xdial-next").path))
    }

    func testKeychainFallbackDoesNotCreateSourceVault() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let preferences = home.appendingPathComponent("Library/Preferences/com.kafeifei.xdial.debug.plist")
        try FileManager.default.createDirectory(at: preferences.deletingLastPathComponent(), withIntermediateDirectories: true)
        var source = ProfileRecord.empty(named: "Original").profile
        source.lines.append(Line(id: "vmess", name: "Proxy", type: "vmess"))
        let data = try PropertyListSerialization.data(fromPropertyList: ["xdial.profile": JSONEncoder().encode(source)], format: .binary, options: 0)
        try data.write(to: preferences)
        let imported = try ExistingXDialProfileReader.readDebug(home: home, keychainVault: {
            try JSONEncoder().encode(["vmess-vmess": "private-uuid"])
        })
        XCTAssertEqual(imported.lines[1].vmessUUID, "private-uuid")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".xdial-debug").path))
        XCTAssertEqual(try Data(contentsOf: preferences), data)
    }

    func testRejectsChangingSnapshotAndMalformedVault() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let preferences = home.appendingPathComponent("Library/Preferences/com.kafeifei.xdial.debug.plist")
        try FileManager.default.createDirectory(at: preferences.deletingLastPathComponent(), withIntermediateDirectories: true)
        let source = ProfileRecord.empty(named: "Original").profile
        let data = try JSONEncoder().encode(source)
        try PropertyListSerialization.data(fromPropertyList: ["xdial.profile": data], format: .binary, options: 0).write(to: preferences)
        var generation = 0
        XCTAssertThrowsError(try ExistingXDialProfileReader.readDebug(home: home, keychainVault: {
            generation += 1
            return try JSONEncoder().encode(["vpn-vpn": "revision-\(generation)"])
        }))
        XCTAssertThrowsError(try ExistingXDialProfileReader.restore(profileData: data, vaultData: Data("broken".utf8)))
        XCTAssertThrowsError(try ExistingXDialProfileReader.restore(profileData: Data(#"{"lines":[],"schemes":[]}"#.utf8), vaultData: nil))
    }
}
