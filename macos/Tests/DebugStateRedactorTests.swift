import XCTest

final class DebugServerRedactionTests: XCTestCase {
    func testGeoIPRuleSetURLTemplateIsRedactedWhenNonempty() throws {
        let source: [String: Any] = [
            "subscriptions": [[
                "geoip_rule_set_url_template":
                    "https://rules.example.invalid/{code}.srs?token=private",
            ]],
        ]

        let redacted = try XCTUnwrap(
            DebugStateRedactor.redactSecrets(source) as? [String: Any]
        )
        let subscriptions = try XCTUnwrap(
            redacted["subscriptions"] as? [[String: Any]]
        )

        XCTAssertEqual(
            subscriptions[0]["geoip_rule_set_url_template"] as? String,
            "***"
        )
    }

    func testEmptyGeoIPRuleSetURLTemplateStaysEmpty() throws {
        let source: [String: Any] = [
            "geoip_rule_set_url_template": "",
        ]

        let redacted = try XCTUnwrap(
            DebugStateRedactor.redactSecrets(source) as? [String: Any]
        )

        XCTAssertEqual(
            redacted["geoip_rule_set_url_template"] as? String,
            ""
        )
    }

    func testNativeOptionsNeverExposeTransportOrTLSCredentials() throws {
        let input: [String: Any] = ["native_options": ["transport": ["headers": ["Authorization": "private-example"]]]]
        let result = try XCTUnwrap(DebugStateRedactor.redactSecrets(input) as? [String: Any])
        XCTAssertEqual(result["native_options"] as? String, "***")
    }
}
