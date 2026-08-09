import XCTest

final class SubscriptionModelTests: XCTestCase {
    func testLegacySubscriptionDefaultsGeoIPRuleSetURLTemplateToEmpty() throws {
        let data = Data(#"{"id":"legacy","name":"Legacy","url":""}"#.utf8)

        let subscription = try JSONDecoder().decode(Subscription.self, from: data)

        XCTAssertEqual(subscription.geoIPRuleSetURLTemplate, "")
    }

    func testGeoIPRuleSetURLTemplateUsesVersionedJSONKey() throws {
        let template = "file:///Library/Application%20Support/XDial/rules/{code}.srs"
        let subscription = Subscription(
            id: "enterprise",
            name: "Enterprise",
            url: "",
            geoIPRuleSetURLTemplate: template
        )

        let data = try JSONEncoder().encode(subscription)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(
            object["geoip_rule_set_url_template"] as? String,
            template
        )

        let decoded = try JSONDecoder().decode(Subscription.self, from: data)
        XCTAssertEqual(decoded.geoIPRuleSetURLTemplate, template)
    }

    func testBootstrapContainsNoRemoteRuleSetSource() {
        let profile = Profile.bootstrap()

        XCTAssertFalse(profile.ruleSets.contains { $0.type == "url" })
        XCTAssertTrue(profile.ruleSets.contains {
            $0.id == "internal" && $0.type == "manual"
        })
    }
}
