import XCTest

final class MenuBarTrackingRepairTests: XCTestCase {
    private let target = "com.kafeifei.xdial.debug"
    private func location(_ id: String) -> [String: Any] { ["bundle": ["_0": id]] }
    private func entry(_ id: String, allowed: Bool, items: [String]) -> [Any] {
        [location(id), ["location": location(id), "isAllowed": allowed,
                        "menuItemLocations": items.map(location), "futureMetadata": "preserve"]]
    }
    private func data(_ records: [Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "trackedApplications": PropertyListSerialization.data(fromPropertyList: records, format: .binary, options: 0),
            "showSpotlight": false,
        ], format: .binary, options: 0)
    }
    private func records(_ data: Data) throws -> [Any] {
        try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [Any])
    }

    func testRemovesOnlyDebugReferencesFromEveryForeignOwner() throws {
        let original = entry(target, allowed: true, items: [target])
            + entry("com.openai.codex", allowed: false,
                    items: ["com.openai.codex", target, "com.kafeifei.xdial.app", "com.openai.sky.CUAService"])
            + entry("terminal", allowed: true, items: [target, "terminal"])
        let plan = try MenuBarTrackingRepair.plan(data(original), target: target)
        let actual = try records(XCTUnwrap(plan.repairedTracking))
        let expected = entry(target, allowed: true, items: [target])
            + entry("com.openai.codex", allowed: false,
                    items: ["com.openai.codex", "com.kafeifei.xdial.app", "com.openai.sky.CUAService"])
            + entry("terminal", allowed: true, items: ["terminal"])
        XCTAssertTrue(NSArray(array: actual).isEqual(to: expected))
        XCTAssertEqual(plan.outer["showSpotlight"] as? Bool, false)
        XCTAssertEqual(plan.owners, ["com.openai.codex", "terminal"])
        XCTAssertNil(try MenuBarTrackingRepair.plan(data(actual), target: target).repairedTracking)
    }

    func testDoesNotOverrideExplicitlyDisabledOwnEntry() throws {
        let original = entry(target, allowed: false, items: [target])
            + entry("com.openai.codex", allowed: false, items: [target])
        let plan = try MenuBarTrackingRepair.plan(data(original), target: target)
        XCTAssertTrue(plan.ownEntryDisabled)
        XCTAssertNil(plan.repairedTracking)
    }

    func testUnknownSchemaOrMissingOwnIdentityCannotProduceWritePlan() throws {
        XCTAssertThrowsError(try MenuBarTrackingRepair.plan(data([location(target)]), target: target))
        XCTAssertThrowsError(try MenuBarTrackingRepair.plan(
            data(entry("com.openai.codex", allowed: false, items: [target])), target: target
        ))
        let own = entry(target, allowed: true, items: [target])
        XCTAssertThrowsError(try MenuBarTrackingRepair.plan(data(own + own), target: target))
        var mismatched = own
        mismatched[0] = location("other")
        XCTAssertThrowsError(try MenuBarTrackingRepair.plan(data(mismatched), target: target))
    }
}
