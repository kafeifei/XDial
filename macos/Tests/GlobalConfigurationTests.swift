import CryptoKit
import Foundation
import XCTest

final class GlobalConfigurationTests: XCTestCase {
    private func source(_ id: String = "source-a") -> ProfileRecord {
        var profile = Profile()
        profile.profileID = id
        profile.lines = [Line(id: "direct", name: "Direct", type: "direct"), Line(id: "a", name: "Same name", type: "trojan"), Line(id: "b", name: "B", type: "trojan")]
        var group = Line(id: "pool", name: "Pool", type: "selector")
        group.groupMembers = ["a", "b"]; group.groupDefault = "a"
        profile.lines.append(group)
        profile.ruleSets = [RuleSet(id: "rule", name: "Rule", type: "group", conditions: [RuleSet(id: "condition", name: "Domain", type: "manual", domains: ["example.test"])])]
        profile.scenarios = [Scenario(id: "scene", name: "Source scene", bindings: [RuleBinding(ruleSetID: "rule", lineID: "pool")], defaultLineID: "pool")]
        profile.scenarios[0].matchOrder = ["condition"]
        profile.activeScenarioID = "scene"
        return ProfileRecord(id: id, name: id, profile: profile, source: ProfileSource(url: "https://example.test/sub"), baseline: profile)
    }

    private func legacy(_ records: [ProfileRecord]) -> ProfileLibrary {
        var library = ProfileLibrary()
        library.schemaVersion = 2
        library.profiles = records
        library.groups = []; library.scenarios = []; library.activeScenarioID = ""
        library.activeProfileID = records.last!.id
        library.editingProfileID = records.first!.id
        return library
    }

    func testMigrationKeepsSeparateIdentitiesAndEveryReference() throws {
        let original = legacy([source(), source("source-b")])
        let result = try original.validated()
        XCTAssertEqual(result.schemaVersion, 3)
        XCTAssertTrue(result.profiles.allSatisfy { $0.profile.scenarios.isEmpty && !$0.profile.lines.contains(where: \.isGroup) })
        XCTAssertEqual(result.groups.count, 2)
        XCTAssertEqual(result.scenarios.map(\.name), ["Source scene", "Source scene"])
        XCTAssertEqual(result.activeScenarioID, result.scenarios[1].id)
        XCTAssertNotEqual(result.scenarios[0].id, result.scenarios[1].id)
        let second = result.profiles[1]
        XCTAssertEqual(result.scenarios[1].bindings[0].ruleSetID, second.profile.ruleSets[0].id)
        XCTAssertEqual(result.scenarios[1].matchOrder, second.profile.ruleSets[0].conditions.map(\.id))
        XCTAssertEqual(result.groups[1].groupDefault, second.profile.lines[1].id)
        let refreshed = try result.refreshing(profileID: second.id, incoming: source(second.id).profile)
        XCTAssertEqual(refreshed.snapshot(), result.snapshot())
    }

    func testMigrationRejectsSSIDConflictWithoutAlteringInput() throws {
        var a = source(), b = source("b")
        a.profile.scenarios[0].matchSSIDs = ["home"]
        b.profile.scenarios[0].matchSSIDs = ["home"]
        let library = legacy([a, b])
        XCTAssertThrowsError(try library.validated())
        XCTAssertEqual(library.profiles[1].profile.scenarios[0].matchSSIDs, ["home"])
    }

    func testInitialImportNamesTemplatesAndResourceOnlyImportAddsNoScene() throws {
        var library = ProfileLibrary()
        try library.insert(source())
        XCTAssertEqual(library.scenarios.last?.name, "source-a")
        XCTAssertEqual(library.groupSources["pool"]?.profileID, "source-a")
        var local = ProfileRecord.empty(named: "Local")
        local.profile = ProfileLibrary.resourcesOnly(local.profile)
        let count = library.scenarios.count
        try library.insert(local)
        XCTAssertEqual(library.scenarios.count, count)
        var multi = source("multi")
        multi.profile.scenarios.append(Scenario(id: "extra", name: "Work", defaultLineID: "direct"))
        try library.insert(multi)
        XCTAssertTrue(library.scenarios.contains { $0.name == "multi · Work" })
    }

    func testCrossSourceDraftKeepsResourceOwnershipAndIdentity() throws {
        var library = try legacy([source(), source("source-b")]).validated()
        library.profiles[1].profile.tailscale.hostname = "xdial-existing"
        let otherLine = library.profiles[1].profile.lines[1].id
        var draft = library.snapshot()
        draft.lines[draft.lines.firstIndex { $0.id == "pool" }!].groupMembers.append(otherLine)
        draft.scenarios[0].bindings[0].ruleSetID = library.profiles[1].profile.ruleSets[0].id
        draft.scenarios[0].matchOrder = []
        library.applyDraft(draft, editingProfileID: library.profiles[0].id)
        try library.validateReferences()
        XCTAssertEqual(library.owner(ofLine: otherLine)?.id, "source-b")
        XCTAssertEqual(library.snapshot().lines.first { $0.id == otherLine }?.identityHostname, "xdial-existing")
        XCTAssertTrue(library.profiles.allSatisfy { $0.profile.lines.allSatisfy { $0.identityProfileID.isEmpty } })
        XCTAssertThrowsError(try library.removingProfile("source-b"))
    }

    func testRefreshPreservesEntireSceneChoiceProbeAndManualMembers() throws {
        var library = try legacy([source()]).validated()
        library.profiles[0].profile.lines.append(Line(id: "manual", name: "Manual", type: "trojan"))
        library.groups[0].name = "My group"; library.groups[0].groupDefault = "b"
        library.groups[0].groupURL = "https://test.example/probe"; library.groups[0].groupInterval = "9m"
        library.groups[0].groupMembers.append("manual")
        library.scenarios[0].name = "My scene"; library.scenarios[0].defaultLineID = "manual"
        library.scenarios[0].matchSSIDs = ["home"]
        let scene = library.scenarios[0]
        var incoming = source().profile
        incoming.lines.append(Line(id: "new", name: "New", type: "trojan"))
        incoming.lines[3].groupMembers = ["b", "new"]
        incoming.scenarios[0].name = "changed upstream"; incoming.scenarios[0].bindings = []
        incoming.ruleSets[0].conditions[0].domains.append("updated.example")
        let result = try library.refreshing(profileID: "source-a", incoming: incoming)
        XCTAssertEqual(result.scenarios[0], scene)
        XCTAssertEqual(result.groups[0].groupMembers, ["b", "new", "manual"])
        XCTAssertEqual(result.groups[0].groupDefault, "b")
        XCTAssertEqual(result.groups[0].name, "My group")
        XCTAssertEqual(result.groups[0].groupURL, library.groups[0].groupURL)
        XCTAssertEqual(result.groups[0].groupInterval, "9m")
        XCTAssertEqual(result.profiles[0].profile.ruleSets[0].conditions[0].domains.count, 2)
    }

    func testRemovedFixedMemberAndMatchingScopeRejectWholeRefresh() throws {
        let library = try legacy([source()]).validated()
        var incoming = source().profile
        incoming.lines[3].groupMembers = ["b"]
        XCTAssertThrowsError(try library.refreshing(profileID: "source-a", incoming: incoming))
        incoming = source().profile
        incoming.ruleSets[0].conditions = []
        XCTAssertThrowsError(try library.refreshing(profileID: "source-a", incoming: incoming))
        XCTAssertEqual(library.groups[0].groupMembers, ["a", "b"])
        XCTAssertNil(library.profiles[0].source?.updatedAt)
    }

    func testNewTemplatesAreExplicitAndRegenerationDoesNotTouchManualScene() throws {
        var library = try legacy([source()]).validated()
        let manual = Scenario(id: "manual", name: "Manual", defaultLineID: "direct")
        library.scenarios.append(manual)
        library.scenarios[0].name = "Edited"
        var incoming = source().profile
        var newGroup = incoming.lines[3]; newGroup.id = "new-group"
        incoming.lines.append(newGroup)
        incoming.scenarios.append(Scenario(id: "new-scene", name: "New", defaultLineID: "new-group"))
        library = try library.refreshing(profileID: "source-a", incoming: incoming)
        XCTAssertEqual(library.availableTemplateCount(profileID: "source-a"), 2)
        XCTAssertEqual(library.groups.count, 1)
        try library.importTemplates(profileID: "source-a")
        XCTAssertEqual(library.scenarios[0].name, "Edited")
        XCTAssertEqual(library.groups.count, 2)
        try library.importTemplates(profileID: "source-a", replacing: true)
        XCTAssertEqual(library.scenarios[0].name, "source-a · Source scene")
        XCTAssertEqual(library.scenarios.first { $0.id == "manual" }, manual)
        XCTAssertEqual(library.availableTemplateCount(profileID: "source-a"), 0)
    }

    func testDetachedGroupKeepsMembersAndExplicitReattachmentMerges() throws {
        var library = try legacy([source()]).validated()
        try library.setGroupFollowsSource("pool", enabled: false)
        var incoming = source().profile
        incoming.lines.append(Line(id: "c", name: "C", type: "trojan"))
        incoming.lines[3].groupMembers = ["a", "c"]
        library = try library.refreshing(profileID: "source-a", incoming: incoming)
        XCTAssertEqual(library.groups[0].groupMembers, ["a", "b"])
        try library.setGroupFollowsSource("pool", enabled: true)
        XCTAssertEqual(library.groups[0].groupMembers, ["a", "c"])
    }

    func testNewSourceObjectCannotReplaceAnIndependentLocalResource() throws {
        var library = try legacy([source()]).validated()
        library.profiles[0].profile.lines.append(Line(id: "new", name: "Local", type: "trojan"))
        var incoming = source().profile
        incoming.lines.append(Line(id: "new", name: "Remote", type: "trojan"))
        incoming.lines[3].groupMembers.append("new")
        library = try library.refreshing(profileID: "source-a", incoming: incoming)
        XCTAssertEqual(library.owner(ofLine: "new")?.profile.lines.first { $0.id == "new" }?.name, "Local")
        XCTAssertNotEqual(library.groups[0].groupMembers.last, "new")
        let again = try library.refreshing(profileID: "source-a", incoming: incoming)
        XCTAssertEqual(library.snapshot(), again.snapshot())
    }

    func testLocalCopiesKeepContentAndSurviveRefreshWithoutChangingSourceOrRouting() throws {
        var record = source()
        record.profile.lines[1].trojanPassword = "test-secret"
        record.profile.lines[1].nativeOptions = .object(["tls": .object(["enabled": .bool(true)])])
        record.profile.ruleSets[0].conditions.append(RuleSet(id: "nested", name: "Nested", type: "group", conditions: [
            RuleSet(id: "leaf", name: "Leaf", type: "url", url: "https://example.test/rules", fetchLineID: "a")
        ]))
        record.baseline = record.profile
        var library = try legacy([record]).validated()
        let original = library
        var draft = library.snapshot()
        let lineID = try XCTUnwrap(draft.copyLine("a", suffix: " 副本"))
        let ruleID = try XCTUnwrap(draft.copyRule("rule", suffix: " 副本"))
        let secondID = try XCTUnwrap(draft.copyLine("a", suffix: " 副本"))
        XCTAssertNil(draft.copyLine("direct", suffix: " 副本"))
        XCTAssertNil(draft.copyLine("pool", suffix: " 副本"))
        library.applyDraft(draft, editingProfileID: record.id)
        let copiedLine = try XCTUnwrap(library.owner(ofLine: lineID)?.profile.lines.first { $0.id == lineID })
        XCTAssertEqual(copiedLine.trojanPassword, "test-secret")
        XCTAssertEqual(copiedLine.nativeOptions, record.profile.lines[1].nativeOptions)
        XCTAssertTrue(copiedLine.identityProfileID.isEmpty)
        XCTAssertFalse(copiedLine.verified)
        XCTAssertEqual(library.snapshot().lines.first { $0.id == secondID }?.name, "Same name 副本 2")
        let copiedRule = try XCTUnwrap(library.owner(ofRule: ruleID)?.profile.ruleSets.first { $0.id == ruleID })
        func IDs(_ rule: RuleSet) -> Set<String> { Set([rule.id]).union(rule.conditions.flatMap { IDs($0) }) }
        XCTAssertTrue(IDs(copiedRule).isDisjoint(with: IDs(record.profile.ruleSets[0])))
        XCTAssertEqual(copiedRule.conditions[1].conditions[0].fetchLineID, "a")
        XCTAssertEqual(library.profiles[0].baseline, original.profiles[0].baseline)
        XCTAssertEqual(library.scenarios, original.scenarios)
        XCTAssertEqual(library.groups, original.groups)
        var incoming = record.profile
        incoming.lines[1].trojanPassword = "upstream-changed"
        incoming.ruleSets[0].conditions[0].domains = ["updated.test"]
        library = try library.refreshing(profileID: record.id, incoming: incoming)
        XCTAssertEqual(library.owner(ofLine: lineID)?.profile.lines.first { $0.id == lineID }, copiedLine)
        XCTAssertEqual(library.owner(ofRule: ruleID)?.profile.ruleSets.first { $0.id == ruleID }, copiedRule)
        XCTAssertEqual(try library.validated(), library)
    }

    func testImplicitFixedSelectionSurvivesSourceReorderAndRejectsRemoval() throws {
        var library = try legacy([source()]).validated()
        library.groups[0].groupDefault = ""
        var incoming = source().profile
        incoming.lines[3].groupMembers = ["b", "a"]
        let result = try library.refreshing(profileID: "source-a", incoming: incoming)
        XCTAssertEqual(result.groups[0].groupDefault, "a")
        incoming.lines[3].groupMembers = ["b"]
        XCTAssertThrowsError(try library.refreshing(profileID: "source-a", incoming: incoming))
    }

    func testSourceRefreshCannotInvalidateLocallySelectedAutomaticMode() throws {
        var library = try legacy([source()]).validated()
        library.groups[0].type = "urltest"; library.groups[0].groupDefault = ""
        var incoming = source().profile
        incoming.lines[3].groupMembers.append("direct")
        XCTAssertThrowsError(try library.refreshing(profileID: "source-a", incoming: incoming))
    }

    func testCycleAndStaleSelectionAreRejected() throws {
        var library = try legacy([source()]).validated()
        library.groups[0].groupMembers.append("pool")
        XCTAssertThrowsError(try library.validated())
        library.groups[0].groupMembers.removeLast()
        library.activeScenarioID = "missing"
        XCTAssertThrowsError(try library.validated())
    }

    func testEncryptedMigrationKeepsRecoverableOriginalExactlyOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let old = legacy([source(), source("source-b")])
        let encrypted = try XCTUnwrap(AES.GCM.seal(JSONEncoder().encode(old), using: key,
            authenticating: Data("XDial Profile Library v1".utf8)).combined)
        try encrypted.write(to: directory.appendingPathComponent("profiles.enc"))
        let store = ProfileLibraryStore(directory: directory, keyProvider: { _ in key })
        let migrated = try XCTUnwrap(store.load())
        XCTAssertEqual(migrated.schemaVersion, 3)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("profiles.enc")), encrypted)
        try store.save(migrated); try store.save(migrated)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("profiles-before-global-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), encrypted)
        XCTAssertEqual(try store.load(), migrated)
    }
}
