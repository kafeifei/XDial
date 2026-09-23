import Observation
import XCTest

final class ConfigurationEditorStateTests: XCTestCase {
    func testExpandingOneRowDoesNotInvalidateSiblingOrNavigation() {
        let position = ProfileEditorPosition()
        let selectedChanges = ChangeCounter()
        let siblingChanges = ChangeCounter()
        let navigationChanges = ChangeCounter()
        withObservationTracking { _ = position.expandedRuleIDs.contains("selected") }
            onChange: { selectedChanges.increment() }
        withObservationTracking { _ = position.expandedRuleIDs.contains("sibling") }
            onChange: { siblingChanges.increment() }
        withObservationTracking { _ = position.tab }
            onChange: { navigationChanges.increment() }
        position.expandedRuleIDs.insert("selected")
        XCTAssertEqual(selectedChanges.value, 1)
        XCTAssertEqual(siblingChanges.value, 0)
        XCTAssertEqual(navigationChanges.value, 0)
        position.tab = 3
        XCTAssertEqual(navigationChanges.value, 1)
        XCTAssertTrue(position.expandedRuleIDs.contains("selected"))
        position.expandedRuleIDs.remove("selected")
        XCTAssertFalse(position.expandedRuleIDs.contains("selected"))
    }

    func testCatalogPreservesSourceIdentityAndGlobalReferences() throws {
        var library = ProfileLibrary()
        var first = Profile()
        first.tailscale.hostname = "source-host"
        first.lines = [Line(id: "one", name: "Same", type: "trojan")]
        first.ruleSets = [RuleSet(id: "rule-one", name: "Same", type: "manual")]
        var second = first
        second.lines[0].id = "two"
        second.ruleSets[0].id = "rule-two"
        library.profiles = [ProfileRecord(id: "a", name: "Source A", profile: first), ProfileRecord(id: "b", name: "Source B", profile: second)]
        library.editingProfileID = "b"
        var group = Line(id: "group", name: "Global", type: "selector")
        group.groupMembers = ["one", "two"]
        library.groups = [group]
        let catalog = ConfigurationCatalog(library)
        XCTAssertEqual(catalog.line("one")?.identityProfileID, "a")
        XCTAssertEqual(catalog.line("one")?.identityHostname, "source-host")
        XCTAssertEqual(catalog.lineSources["one"], "Source A")
        XCTAssertEqual(catalog.ruleSources["rule-two"], "Source B")
        XCTAssertNil(catalog.lineSources["direct"])
        XCTAssertNil(catalog.lineSources["group"])
        XCTAssertEqual(catalog.line("group")?.groupMembers, ["one", "two"])
        XCTAssertEqual(catalog.rule("rule-one")?.name, "Same")
        XCTAssertNil(catalog.rule("missing"))

        library.profiles[0].name = "Renamed source"
        library.profiles[0].profile.lines[0].name = "Renamed line"
        library.profiles[1].profile.ruleSets = []
        let updated = ConfigurationCatalog(library)
        XCTAssertEqual(updated.line("one")?.name, "Renamed line")
        XCTAssertEqual(updated.lineSources["one"], "Renamed source")
        XCTAssertNil(updated.rule("rule-two"))
        XCTAssertEqual(catalog.line("one")?.name, "Same", "An old projection must remain a value snapshot")
    }
}

private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
}
