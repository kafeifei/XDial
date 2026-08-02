import Foundation
import XCTest

final class ApplicationRuleSetModelTests: XCTestCase {
    func testApplicationIdentityCanonicalizesAndDeduplicates() {
        let identities = ApplicationRuleApplication.normalizedIdentities([
            "q6l2sf6ydw/com.anthropic.claude",
            "Q6L2SF6YDW/com.anthropic.claude",
            "Q6L2SF6YDW/com.anthropic.claude.helper",
            "invalid",
            "Q6L2SF6YDW/contains space",
        ])

        XCTAssertEqual(identities, [
            "Q6L2SF6YDW/com.anthropic.claude",
            "Q6L2SF6YDW/com.anthropic.claude.helper",
        ])
    }

    func testApplicationRuleRoundTripsWithStableJSONKey() throws {
        let source = RuleSet(
            id: "claude",
            name: "Claude",
            type: "application",
            applications: [
                ApplicationRuleApplication(
                    name: "Claude",
                    path: "/Applications/Claude.app",
                    identities: [
                        "Q6L2SF6YDW/com.anthropic.claudefordesktop",
                        "Q6L2SF6YDW/com.anthropic.claudefordesktop.helper",
                    ]
                ),
            ]
        )

        let data = try JSONEncoder().encode(source)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let applications = try XCTUnwrap(
            object["applications"] as? [[String: Any]]
        )
        XCTAssertEqual(applications.count, 1)
        XCTAssertEqual(
            applications[0]["identities"] as? [String],
            [
                "Q6L2SF6YDW/com.anthropic.claudefordesktop",
                "Q6L2SF6YDW/com.anthropic.claudefordesktop.helper",
            ]
        )

        let decoded = try JSONDecoder().decode(RuleSet.self, from: data)
        XCTAssertEqual(decoded, source)
    }

    func testSanitizeApplicationsRemovesInvalidAndMergesSamePath() {
        let cleaned = RuleSet.sanitizeApplications([
            ApplicationRuleApplication(
                name: "Claude",
                path: "/Applications/Claude.app",
                identities: ["Q6L2SF6YDW/com.anthropic.claude"]
            ),
            ApplicationRuleApplication(
                name: "Claude duplicate",
                path: "/Applications/Claude.app",
                identities: ["Q6L2SF6YDW/com.anthropic.claude.helper"]
            ),
            ApplicationRuleApplication(
                name: "No identity",
                path: "/Applications/Bad.app",
                identities: []
            ),
        ])

        XCTAssertEqual(cleaned.count, 1)
        XCTAssertEqual(cleaned[0].name, "Claude")
        XCTAssertEqual(cleaned[0].identities, [
            "Q6L2SF6YDW/com.anthropic.claude",
            "Q6L2SF6YDW/com.anthropic.claude.helper",
        ])
    }
}
