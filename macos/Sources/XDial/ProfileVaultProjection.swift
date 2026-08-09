import Foundation

enum ProfileVaultProjection {
    static func subscriptionGeoIPRuleSetURLTemplateKey(
        subscriptionID: String
    ) -> String {
        structuredKey([
            "subscription",
            subscriptionID,
            "geoip-rule-set-url-template",
        ])
    }

    static func splitSubscriptionGeoIPRuleSetURLTemplates(
        from profile: inout Profile,
        into vault: inout [String: String]
    ) {
        let currentKeys = Set(profile.subscriptions.map {
            subscriptionGeoIPRuleSetURLTemplateKey(
                subscriptionID: $0.id
            )
        })
        let obsoleteKeys = vault.keys.filter {
            isSubscriptionGeoIPRuleSetURLTemplateKey($0)
                && !currentKeys.contains($0)
        }
        for key in obsoleteKeys {
            vault.removeValue(forKey: key)
        }

        for index in profile.subscriptions.indices {
            let value = profile.subscriptions[index]
                .geoIPRuleSetURLTemplate
            let key = subscriptionGeoIPRuleSetURLTemplateKey(
                subscriptionID: profile.subscriptions[index].id
            )
            guard !value.isEmpty else {
                vault.removeValue(forKey: key)
                continue
            }
            vault[key] = value
            profile.subscriptions[index].geoIPRuleSetURLTemplate = ""
        }
    }

    static func restoreSubscriptionGeoIPRuleSetURLTemplates(
        from vault: [String: String],
        into profile: inout Profile
    ) {
        for index in profile.subscriptions.indices {
            let key = subscriptionGeoIPRuleSetURLTemplateKey(
                subscriptionID: profile.subscriptions[index].id
            )
            if let value = vault[key] {
                profile.subscriptions[index].geoIPRuleSetURLTemplate = value
            }
        }
    }

    private static func structuredKey(_ components: [String]) -> String {
        "v2" + components.map {
            "|\($0.utf8.count):\($0)"
        }.joined()
    }

    private static func isSubscriptionGeoIPRuleSetURLTemplateKey(
        _ key: String
    ) -> Bool {
        key.hasPrefix(structuredKey(["subscription"]) + "|")
            && key.hasSuffix(
                structuredKey(["geoip-rule-set-url-template"])
                    .dropFirst(2)
            )
    }
}
