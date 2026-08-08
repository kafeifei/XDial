import XCTest

final class ScenarioIconCatalogTests: XCTestCase {
    func testCatalogHasUniqueSemanticKeysAndSymbols() {
        let presets = ScenarioIconCatalog.presets
        XCTAssertGreaterThanOrEqual(presets.count, 20)
        XCTAssertEqual(Set(presets.map(\.id)).count, presets.count)
        XCTAssertEqual(Set(presets.map(\.symbol)).count, presets.count)
    }

    func testAutomaticMatchingPrefersNameThenSavedSSID() {
        XCTAssertEqual(
            ScenarioIconCatalog.automaticPreset(
                name: "酒店",
                ssids: ["Office"]
            ).id,
            "hotel"
        )
        XCTAssertEqual(
            ScenarioIconCatalog.automaticPreset(
                name: "全局 VPN",
                ssids: []
            ).id,
            "global"
        )
        XCTAssertEqual(
            ScenarioIconCatalog.automaticPreset(
                name: "临时",
                ssids: ["Airport_Free_WiFi"]
            ).id,
            "travel"
        )
        XCTAssertEqual(
            ScenarioIconCatalog.automaticPreset(
                name: "临时",
                ssids: ["Hotel_Guest"]
            ).id,
            "hotel"
        )
        XCTAssertEqual(
            ScenarioIconCatalog.automaticPreset(
                name: "临时",
                ssids: ["Campus_Guest"]
            ).id,
            "campus"
        )
    }

    func testSSIDDoesNotInferAbstractSecurityMeaning() {
        XCTAssertEqual(
            ScenarioIconCatalog.automaticPreset(
                name: "临时",
                ssids: ["XDial-VPN"]
            ).id,
            "general"
        )
    }

    func testManualOverrideAlwaysWinsAndUnknownKeyIsStableFallback() {
        let manual = Scenario(
            id: "manual",
            name: "酒店",
            iconOverride: "office"
        )
        XCTAssertEqual(
            ScenarioIconCatalog.resolvedPreset(for: manual).id,
            "office"
        )

        let future = Scenario(
            id: "future",
            name: "酒店",
            iconOverride: "future-icon"
        )
        XCTAssertEqual(
            ScenarioIconCatalog.resolvedPreset(for: future).id,
            "general"
        )
        XCTAssertEqual(future.iconOverride, "future-icon")
    }

    func testIconSemanticKeyRoundTripsAndOldProfileDefaultsToAutomatic() throws {
        let original = Scenario(
            id: "hotel",
            name: "酒店",
            iconOverride: "hotel"
        )
        let data = try JSONEncoder().encode(original)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["icon"] as? String, "hotel")
        XCTAssertEqual(
            try JSONDecoder().decode(Scenario.self, from: data).iconOverride,
            "hotel"
        )

        let oldData = try XCTUnwrap(
            "{\"id\":\"old\",\"name\":\"公司\"}".data(using: .utf8)
        )
        let old = try JSONDecoder().decode(Scenario.self, from: oldData)
        XCTAssertNil(old.iconOverride)
        XCTAssertEqual(
            ScenarioIconCatalog.resolvedPreset(for: old).id,
            "office"
        )
    }
}

final class ScenarioGridLayoutTests: XCTestCase {
    func testColumnsBalanceWithinTheMinimumNumberOfRows() {
        let expected = [
            0: 1,
            1: 1,
            2: 2,
            3: 3,
            4: 4,
            5: 3,
            6: 3,
            7: 4,
            8: 4,
            9: 3,
            10: 4,
            11: 4,
            12: 4,
        ]
        for (count, columns) in expected {
            XCTAssertEqual(
                ScenarioGridLayout.columnCount(itemCount: count),
                columns,
                "unexpected columns for \(count) scenarios"
            )
        }
    }
}
