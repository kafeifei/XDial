import Foundation
import XCTest

final class ApplicationRuleSetModelTests: XCTestCase {
    func testApplicationRulePersistsOnlyBundlePath() throws {
        let source = RuleSet(
            id: "claude",
            name: "Claude",
            type: "application",
            applications: [
                ApplicationRuleApplication(
                    name: "Claude",
                    path: "/Applications/Claude.app"
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
            applications[0]["path"] as? String,
            "/Applications/Claude.app"
        )
        XCTAssertNil(applications[0]["identities"])

        let decoded = try JSONDecoder().decode(RuleSet.self, from: data)
        XCTAssertEqual(decoded, source)
    }

    func testLegacyIdentitiesAreDroppedDuringSanitization() throws {
        let data = try XCTUnwrap("""
        {
          "name": "Claude",
          "path": "/Applications/Claude.app",
          "identities": [
            "Q6L2SF6YDW/com.anthropic.claudefordesktop",
            "Q6L2SF6YDW/computer_use"
          ]
        }
        """.data(using: .utf8))
        let legacy = try JSONDecoder().decode(
            ApplicationRuleApplication.self,
            from: data
        )
        let cleaned = RuleSet.sanitizeApplications([legacy])

        XCTAssertEqual(cleaned, [
            ApplicationRuleApplication(
                name: "Claude",
                path: "/Applications/Claude.app"
            ),
        ])
        let encoded = try JSONEncoder().encode(cleaned[0])
        let encodedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertNil(encodedObject["identities"])
    }

    func testSanitizeApplicationsNormalizesAndDeduplicatesBundlePaths() {
        let cleaned = RuleSet.sanitizeApplications([
            ApplicationRuleApplication(
                name: "Claude",
                path: "/Applications/Claude.app"
            ),
            ApplicationRuleApplication(
                name: "Claude duplicate",
                path: "/Applications/Claude.app"
            ),
            ApplicationRuleApplication(
                name: "Relative",
                path: "Applications/Bad.app"
            ),
            ApplicationRuleApplication(
                name: "Not app",
                path: "/Applications/Bad.bundle"
            ),
        ])

        XCTAssertEqual(cleaned, [
            ApplicationRuleApplication(
                name: "Claude",
                path: "/Applications/Claude.app"
            ),
        ])
    }
}
