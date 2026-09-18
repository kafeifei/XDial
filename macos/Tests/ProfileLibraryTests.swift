import CryptoKit
import Darwin
import Foundation
import XCTest

final class ProfileLibraryTests: XCTestCase {
    func testWriterMustHoldSharedFileLock() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let store = ProfileLibraryStore(directory: directory, keyProvider: { _ in key })
        let original = ProfileLibrary()
        try store.save(original)
        let fd = open(directory.appendingPathComponent("profiles.lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        defer { flock(fd, LOCK_UN) }
        var edited = original
        edited.profiles[0].name = "Blocked concurrent edit"
        XCTAssertThrowsError(try store.save(edited))
        XCTAssertEqual(try store.load(), original)
    }

    func testConcurrentVersionsCannotOverwriteEachOthersEdits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let first = ProfileLibraryStore(directory: directory, keyProvider: { _ in key })
        let second = ProfileLibraryStore(directory: directory, keyProvider: { _ in key })
        try first.save(ProfileLibrary())
        var a = try XCTUnwrap(first.load())
        var b = try XCTUnwrap(second.load())
        a.profiles[0].name = "New edit"
        try first.save(a)
        b.profiles[0].name = "Stale edit"
        XCTAssertThrowsError(try second.save(b))
        XCTAssertEqual(try first.load(), a)
        XCTAssertEqual(try second.load(), a)
        try second.save(a)
    }

    func testOpenVersionCannotRecreateDeletedConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let store = ProfileLibraryStore(directory: directory, keyProvider: { _ in key })
        let library = ProfileLibrary()
        try store.save(library)
        let file = directory.appendingPathComponent("profiles.enc")
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try store.save(library))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testRefreshKeepsIndependentSceneExitOverrides() throws {
        var record = ProfileRecord.empty(named: "Source")
        record.profile.lines += [Line(id: "a", name: "A", type: "anytls"), Line(id: "b", name: "B", type: "anytls")]
        record.profile.ruleSets = [RuleSet(id: "ai", name: "AI", type: "manual", domains: ["ai.example"]), RuleSet(id: "video", name: "Video", type: "manual", domains: ["video.example"])]
        record.profile.scenarios[0].bindings = [RuleBinding(ruleSetID: "ai", lineID: "a"), RuleBinding(ruleSetID: "video", lineID: "a")]
        record.baseline = record.profile
        record.profile.scenarios[0].bindings[0].lineID = "b"
        record.profile.scenarios[0].defaultLineID = "b"
        var incoming = record.baseline!
        incoming.ruleSets[0].domains.append("new.example")
        let updated = try record.refreshed(with: incoming)
        XCTAssertEqual(updated.profile.scenarios[0].bindings.map(\.lineID), ["b", "a"])
        XCTAssertEqual(updated.profile.scenarios[0].defaultLineID, "b")
        XCTAssertEqual(updated.profile.ruleSets[0].domains, incoming.ruleSets[0].domains)
        incoming.lines.removeAll { $0.id == "b" }
        XCTAssertThrowsError(try record.refreshed(with: incoming))
        incoming = record.baseline!
        incoming.scenarios[0].bindings.removeFirst()
        XCTAssertThrowsError(try record.refreshed(with: incoming))
    }

    func testLibraryPromotesOldSchemaAndRejectsFutureSchemas() throws {
        var library = ProfileLibrary()
        library.schemaVersion = 1
        XCTAssertEqual(try library.validated().schemaVersion, 2)
        library.schemaVersion = 3
        XCTAssertThrowsError(try library.validated())
    }
    func testGroupedRuleEditingKeepsScopeAndRemovesDeletedReferences() throws {
        var profile = ProfileRecord.empty(named: "Test").profile
        let a = RuleSet(id: "a", name: "Domain", type: "manual", domains: ["example.com"])
        let b = RuleSet(id: "b", name: "App", type: "application", processes: ["Example"])
        profile.ruleSets = [RuleSet(id: "all", name: "Example", type: "group", conditions: [a,b])]
        profile.scenarios[0].bindings = [RuleBinding(ruleSetID: "all", lineID: "direct", conditionIDs: ["a"])]
        profile.scenarios[0].matchOrder = ["a"]
        XCTAssertEqual(profile.ruleSets[0].contentSummary(chinese: true), "域名 1 · 应用 1")
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile)), profile)
        profile.ruleSets[0].conditions.removeFirst()
        profile.reconcileMatchingReferences()
        XCTAssertTrue(profile.scenarios[0].bindings.isEmpty, "Removing the last selected item must not broaden to all content")
        XCTAssertTrue(profile.scenarios[0].matchOrder.isEmpty)
    }

    func testAddingDifferentMatchingTypeWrapsExistingRuleAndRetainsScenario() {
        var profile = ProfileRecord.empty(named: "Test").profile
        profile.ruleSets = [RuleSet(id: "rule", name: "Company", type: "manual", enabled: false, domains: ["company.example"])]
        profile.scenarios[0].bindings = [RuleBinding(ruleSetID: "rule", lineID: "direct")]
        profile.scenarios[0].matchOrder = ["rule"]
        profile.appendMatchingContent(RuleSet(id: "app", name: "App", type: "application", processes: ["Example"]), to: "rule")
        let rule = profile.ruleSets[0]
        XCTAssertEqual(rule.id, "rule")
        XCTAssertFalse(rule.enabled)
        XCTAssertEqual(rule.conditions.count, 2)
        XCTAssertEqual(rule.conditions[0].domains, ["company.example"])
        XCTAssertEqual(profile.scenarios[0].bindings[0].ruleSetID, "rule")
        XCTAssertEqual(profile.scenarios[0].matchOrder, [rule.conditions[0].id])
    }

    func testRefreshRejectsLostLocalPartialMatchScope() throws {
        var record = ProfileRecord.empty(named: "Source")
        let a = RuleSet(id: "a", name: "A", type: "manual", domains: ["a.example"])
        let b = RuleSet(id: "b", name: "B", type: "manual", domains: ["b.example"])
        record.profile.ruleSets = [RuleSet(id: "rule", name: "Example", type: "group", conditions: [a,b])]
        record.baseline = record.profile
        record.profile.scenarios.append(Scenario(id: "local", name: "Local", bindings: [RuleBinding(ruleSetID: "rule", lineID: "direct", conditionIDs: ["a"])], defaultLineID: "direct", matchOrder: ["a"]))
        XCTAssertEqual(try record.refreshed(with: record.baseline!).profile.scenarios.last, record.profile.scenarios.last)
        var incoming = record.baseline!
        incoming.ruleSets[0].conditions.removeFirst()
        XCTAssertThrowsError(try record.refreshed(with: incoming))
    }

    func testRuleSearchUsesMatchingContentAndCountsNestedExpressions() {
        var rule = RuleSet(id: "predicate", name: "Reusable", type: "native")
        rule.nativeRule = .object([
            "type": .string("logical"), "mode": .string("or"),
            "rules": .array([
                .object(["domain_suffix": .array([.string("apple.com"), .string("example.com")])]),
                .object(["ip_cidr": .array([.string("192.0.2.0/24")]), "invert": .bool(true)])
            ])
        ])
        XCTAssertEqual(rule.matchItemCount, 3)
        XCTAssertTrue(rule.matchesSearch("APPLE.COM"))
        XCTAssertTrue(rule.matchesSearch("192.0.2"))
        XCTAssertFalse(rule.matchesSearch("Proxies"))
        let group = RuleSet(id: "custom", name: "Custom", type: "group", conditions: [rule])
        XCTAssertTrue(group.matchesSearch("example.com"))
        let remote = RuleSet(id: "remote", name: "Remote", type: "url", url: "https://example.com/rules.srs")
        XCTAssertNil(remote.matchItemCount)
    }

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
    func testSubscriptionImportMetadataSurvivesSwiftRoundTrip() throws {
        let data = Data(#"{"lines":[],"rule_sets":[{"id":"ip","name":"IP","type":"native","no_resolve":true,"native_rule":{"ip_cidr":["192.0.2.0/24"]}}],"import_warnings":[{"type":"USER-AGENT","value":"Example*","group":"Proxy","options":""}],"import_adjustments":[{"code":"anytls-tfo-disabled","count":141}]}"#.utf8)
        let profile = try JSONDecoder().decode(Profile.self, from: data)
        XCTAssertTrue(profile.ruleSets[0].noResolve)
        XCTAssertEqual(profile.importWarnings[0].value, "Example*")
        XCTAssertEqual(profile.importAdjustments, [ImportAdjustment(code: "anytls-tfo-disabled", count: 141)])
        let copy = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(copy, profile)
    }

    func testRefreshRejectsNewUnsupportedRulesButRetainsReviewedOnes() throws {
        var record = ProfileRecord.empty(named: "Source")
        let warning = try JSONDecoder().decode(SubRule.self, from: Data(#"{"type":"USER-AGENT","value":"Example*","group":"Proxy"}"#.utf8))
        var incoming = record.profile
        incoming.importWarnings = [warning]
        XCTAssertThrowsError(try record.refreshed(with: incoming))
        record.profile = incoming
        record.baseline = incoming
        XCTAssertEqual(try record.refreshed(with: incoming).profile.importWarnings, [warning])
        incoming.importWarnings = []
        XCTAssertEqual(try record.refreshed(with: incoming).profile.importWarnings, [])
    }

    func testRefreshRetainsTransportAdjustmentsWithoutTreatingThemAsDroppedRules() throws {
        let record = ProfileRecord.empty(named: "Source")
        var incoming = record.profile
        incoming.importAdjustments = [ImportAdjustment(code: "anytls-tfo-disabled", count: 2)]
        let refreshed = try record.refreshed(with: incoming)
        XCTAssertEqual(refreshed.profile.importAdjustments, incoming.importAdjustments)
        XCTAssertEqual(refreshed.baseline?.importAdjustments, incoming.importAdjustments)
        XCTAssertTrue(refreshed.profile.importWarnings.isEmpty)
    }

    func testGroupedConditionsSurviveStorageAndSourceRefresh() throws {
        var record = ProfileRecord.empty(named: "Source")
        var ip = RuleSet(id: "ip", name: "IP", type: "native")
        ip.nativeRule = .object(["ip_cidr": .array([.string("192.0.2.0/24")])])
        ip.noResolve = true
        record.profile.ruleSets = [RuleSet(id: "rules", name: "AI", type: "group", conditions: [ip])]
        record.baseline = record.profile
        let local = Scenario(id: "local", name: "Local", bindings: [RuleBinding(ruleSetID: "rules", lineID: "direct")], defaultLineID: "direct")
        record.profile.scenarios.append(local)
        var incoming = record.baseline!
        incoming.ruleSets[0].conditions.append(RuleSet(id: "app", name: "App", type: "application", processes: ["Example*"]))
        let refreshed = try record.refreshed(with: incoming)
        XCTAssertEqual(refreshed.profile.scenarios.last, local)
        XCTAssertEqual(refreshed.profile.matchingResources.count, 2)
        XCTAssertTrue(refreshed.profile.matchingResources[0].noResolve)
        XCTAssertEqual(try JSONDecoder().decode(ProfileRecord.self, from: JSONEncoder().encode(refreshed)), refreshed)
        var edited = refreshed.profile
        XCTAssertTrue(edited.updateMatchingResource(id: "ip") { $0.name = "Changed" })
        XCTAssertEqual(edited.ruleSets[0].conditions[0].name, "Changed")
        XCTAssertEqual(refreshed.profile.ruleSets[0].conditions[0].name, "IP")
    }

}

extension ProfileLibraryTests {
    func testGroupMembershipSharesLinesAndPreservesMemberOrder() throws {
        var profile = Profile()
        profile.lines = [Line(id: "a", name: "A", type: "anytls"),
                         Line(id: "b", name: "B", type: "anytls"),
                         Line(id: "auto", name: "Auto", type: "urltest"),
                         Line(id: "manual", name: "Manual", type: "selector")]
        try profile.addLineGroupMember("b", to: "auto")
        try profile.addLineGroupMember("a", to: "auto")
        try profile.addLineGroupMember("a", to: "manual")
        XCTAssertEqual(profile.lines.count, 4)
        XCTAssertEqual(profile.lines[2].groupMembers, ["b", "a"])
        XCTAssertThrowsError(try profile.addLineGroupMember("a", to: "auto"))
        profile.lines[3].groupDefault = "a"
        profile.removeLineGroupMember("a", from: "manual")
        XCTAssertEqual(profile.lines[3].groupDefault, "")
        XCTAssertEqual(profile.lines[2].groupMembers, ["b", "a"])
        XCTAssertEqual(profile.lines.count, 4)
    }

    func testNestedURLTestAndSharedSubgroupsRejectCyclesAtomically() throws {
        var profile = Profile()
        profile.lines = [Line(id: "node", name: "Node", type: "anytls"),
                         Line(id: "child", name: "Child", type: "urltest"),
                         Line(id: "left", name: "Left", type: "urltest"),
                         Line(id: "right", name: "Right", type: "selector"),
                         Line(id: "root", name: "Root", type: "urltest")]
        try profile.addLineGroupMember("node", to: "child")
        try profile.addLineGroupMember("child", to: "left")
        try profile.addLineGroupMember("child", to: "right")
        try profile.addLineGroupMember("left", to: "root")
        try profile.addLineGroupMember("right", to: "root")
        let original = profile
        XCTAssertThrowsError(try profile.addLineGroupMember("root", to: "child"))
        XCTAssertThrowsError(try profile.addLineGroupMember("child", to: "child"))
        XCTAssertEqual(profile, original)
    }

    func testGroupEditorChecksDirectAndPlatformLinesThroughAncestors() throws {
        var profile = Profile()
        profile.lines = [Line(id: "direct", name: "Direct", type: "direct"),
                         Line(id: "vpn", name: "VPN", type: "vpn"),
                         Line(id: "tailscale", name: "Tailscale", type: "tailscale"),
                         Line(id: "auto", name: "Auto", type: "urltest"),
                         Line(id: "child", name: "Child", type: "selector"),
                         Line(id: "unrelated", name: "Draft", type: "urltest")]
        // Unrelated empty drafts do not prevent incrementally building another group.
        try profile.addLineGroupMember("child", to: "auto")
        XCTAssertThrowsError(try profile.addLineGroupMember("direct", to: "child"))
        XCTAssertThrowsError(try profile.addLineGroupMember("vpn", to: "child"))
        XCTAssertThrowsError(try profile.addLineGroupMember("tailscale", to: "child"))
        XCTAssertThrowsError(try profile.addLineGroupMember("missing", to: "child"))
        profile.removeLineGroupMember("child", from: "auto")
        try profile.addLineGroupMember("direct", to: "child")
        XCTAssertThrowsError(try profile.addLineGroupMember("child", to: "auto"))
    }
}

extension ProfileLibraryTests {
    func testGroupEditorBoundsDeepSharedGraphs() throws {
        var profile = Profile()
        profile.lines = [Line(id: "node", name: "Node", type: "anytls")]
        for index in 0..<33 {
            var group = Line(id: "g\(index)", name: "Group", type: "urltest")
            group.groupMembers = index == 0 ? ["node"] : ["g\(index - 1)"]
            if index > 1 { group.groupMembers.append("g\(index - 2)") }
            profile.lines.append(group)
        }
        profile.lines.append(Line(id: "parent", name: "Parent", type: "urltest"))
        XCTAssertNil(profile.lineGroupMemberIssue("g30", addingTo: "parent"))
        XCTAssertNotNil(profile.lineGroupMemberIssue("g31", addingTo: "parent"))
    }
}
