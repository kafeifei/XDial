import XCTest

final class ScenarioSSIDMatchingTests: XCTestCase {
    func testSSIDPermissionIsOnlyRequiredByConfiguredMatchingRules() {
        var profile = Profile()
        profile.scenarios = [
            Scenario(
                id: "blank",
                name: "空白",
                matchSSIDs: ["  "]
            )
        ]
        XCTAssertFalse(profile.usesSSIDScenarioMatching)

        profile.scenarios.append(
            Scenario(
                id: "hotel",
                name: "酒店",
                matchSSIDs: ["Hotel Wi-Fi"]
            )
        )
        XCTAssertTrue(profile.usesSSIDScenarioMatching)
    }

    func testBlankScenarioRoundTripsWithoutImplicitConfiguration() throws {
        var profile = Profile()
        profile.scenarios = [Scenario(id: "blank", name: "空白")]
        profile.activeScenarioID = "blank"

        let data = try JSONEncoder().encode(profile)
        let restored = try JSONDecoder().decode(Profile.self, from: data)
        let scenario = try XCTUnwrap(restored.scenarios.first)

        XCTAssertEqual(scenario.id, "blank")
        XCTAssertTrue(scenario.matchSSIDs.isEmpty)
        XCTAssertTrue(scenario.bindings.isEmpty)
        XCTAssertTrue(scenario.defaultLineID.isEmpty)
        XCTAssertTrue(scenario.defaultSubscriptionID.isEmpty)
    }

    func testMultipleSSIDsRemainDistinctAndOrderedAfterRoundTrip() throws {
        let expected = ["Test Network Alpha", "Demo Phone Hotspot"]
        let original = Scenario(
            id: "mobile",
            name: "CorpVPN",
            matchSSIDs: expected
        )

        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(Scenario.self, from: data)

        XCTAssertEqual(restored.matchSSIDs, expected)
        XCTAssertEqual(restored.matchSSIDs.count, 2)
    }

    func testExactSSIDSelectsConfiguredScenario() {
        var profile = Profile()
        profile.scenarios = [
            Scenario(id: "home", name: "家庭", matchSSIDs: ["Home Wi-Fi"]),
            Scenario(id: "work", name: "公司", matchSSIDs: ["Office"]),
        ]

        XCTAssertEqual(
            profile.scenario(matchingSSID: "Office")?.id,
            "work"
        )
        XCTAssertNil(profile.scenario(matchingSSID: "office"))
        XCTAssertNil(profile.scenario(matchingSSID: "Unknown"))
    }

    func testFirstScenarioWinsIfInvalidProfileContainsDuplicateSSID() {
        var profile = Profile()
        profile.scenarios = [
            Scenario(id: "first", name: "一", matchSSIDs: ["Shared"]),
            Scenario(id: "second", name: "二", matchSSIDs: ["Shared"]),
        ]

        XCTAssertEqual(
            profile.scenario(matchingSSID: "Shared")?.id,
            "first"
        )
    }
}
