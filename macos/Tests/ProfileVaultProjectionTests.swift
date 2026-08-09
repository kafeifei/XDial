import XCTest

final class ProfileVaultProjectionTests: XCTestCase {
    func testGeoIPRuleSetURLTemplateIsSplitFromProfileAndRestored() throws {
        let template =
            "https://rules.example.invalid/geoip/{code}.srs?token=private"
        var profile = Profile()
        profile.subscriptions = [Subscription(
            id: "enterprise",
            name: "Enterprise",
            url: "",
            geoIPRuleSetURLTemplate: template
        )]
        var vault: [String: String] = [:]

        ProfileVaultProjection.splitSubscriptionGeoIPRuleSetURLTemplates(
            from: &profile,
            into: &vault
        )

        XCTAssertEqual(
            profile.subscriptions[0].geoIPRuleSetURLTemplate,
            ""
        )
        XCTAssertEqual(
            vault[ProfileVaultProjection
                .subscriptionGeoIPRuleSetURLTemplateKey(
                    subscriptionID: "enterprise"
                )],
            template
        )
        let encodedProfile = try JSONEncoder().encode(profile)
        XCTAssertFalse(
            try XCTUnwrap(String(data: encodedProfile, encoding: .utf8))
                .contains("token=private")
        )

        var restored = try JSONDecoder().decode(
            Profile.self,
            from: encodedProfile
        )
        ProfileVaultProjection.restoreSubscriptionGeoIPRuleSetURLTemplates(
            from: vault,
            into: &restored
        )

        XCTAssertEqual(
            restored.subscriptions[0].geoIPRuleSetURLTemplate,
            template
        )
    }

    func testClearingGeoIPRuleSetURLTemplateRemovesVaultValue() {
        var profile = Profile()
        profile.subscriptions = [Subscription(
            id: "enterprise",
            name: "Enterprise",
            url: ""
        )]
        let key = ProfileVaultProjection
            .subscriptionGeoIPRuleSetURLTemplateKey(
                subscriptionID: "enterprise"
            )
        var vault = [key: "https://old.example.invalid/{code}.srs"]

        ProfileVaultProjection.splitSubscriptionGeoIPRuleSetURLTemplates(
            from: &profile,
            into: &vault
        )

        XCTAssertNil(vault[key])
    }

    func testDeletingSubscriptionRemovesOrphanedGeoIPTemplate() {
        var profile = Profile()
        let key = ProfileVaultProjection
            .subscriptionGeoIPRuleSetURLTemplateKey(
                subscriptionID: "deleted"
            )
        var vault = [key: "https://old.example.invalid/{code}.srs"]

        ProfileVaultProjection.splitSubscriptionGeoIPRuleSetURLTemplates(
            from: &profile,
            into: &vault
        )

        XCTAssertNil(vault[key])
    }
}
