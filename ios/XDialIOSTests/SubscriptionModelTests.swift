import XCTest
@testable import XDial

final class SubscriptionModelTests: XCTestCase {
    func testLegacySubscriptionDefaultsGeoIPRuleSetURLTemplateToEmpty() throws {
        let data = Data(#"{"id":"legacy","name":"Legacy","url":""}"#.utf8)

        let subscription = try JSONDecoder().decode(Subscription.self, from: data)

        XCTAssertEqual(subscription.geoIPRuleSetURLTemplate, "")
    }

    func testGeoIPRuleSetURLTemplateRoundTrips() throws {
        let template = "https://rules.example.invalid/geoip/{code}.srs"
        let original = Subscription(
            id: "enterprise",
            name: "Enterprise",
            url: "",
            geoIPRuleSetURLTemplate: template
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Subscription.self, from: data)

        XCTAssertEqual(decoded.geoIPRuleSetURLTemplate, template)
    }

    func testBootstrapContainsNoRemoteRuleSetSource() {
        let profile = Profile.bootstrap()

        XCTAssertFalse(profile.ruleSets.contains { $0.type == "url" })
        XCTAssertTrue(profile.ruleSets.contains {
            $0.id == "internal" && $0.type == "manual"
        })
        XCTAssertTrue(profile.ruleSets.contains { $0.isConnectivityTestRule })
    }
}
