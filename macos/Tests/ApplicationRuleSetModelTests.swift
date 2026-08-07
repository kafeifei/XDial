import Foundation
import XCTest

final class ApplicationRuleSetModelTests: XCTestCase {
    func testLegacyURLRuleDefaultsFetchLineToDirect() throws {
        let data = try XCTUnwrap("""
        {
          "id": "remote",
          "name": "Remote",
          "type": "url",
          "enabled": true,
          "url": "https://rules.example.com/list.srs",
          "format": "srs"
        }
        """.data(using: .utf8))

        let decoded = try JSONDecoder().decode(RuleSet.self, from: data)

        XCTAssertEqual(decoded.fetchLineID, "direct")
    }

    func testApplicationRulePersistsRootBundleIdentityAndPath() throws {
        let source = RuleSet(
            id: "claude",
            name: "Claude",
            type: "application",
            applications: [
                ApplicationRuleApplication(
                    name: "Claude",
                    path: "/Applications/Claude.app",
                    bundleIdentifier: "com.anthropic.claudefordesktop"
                ),
            ],
            processes: ["claude", "Claude Helper*"]
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
        XCTAssertEqual(
            applications[0]["bundle_identifier"] as? String,
            "com.anthropic.claudefordesktop"
        )
        XCTAssertNil(applications[0]["identities"])
        XCTAssertEqual(
            object["processes"] as? [String],
            ["claude", "Claude Helper*"]
        )

        let decoded = try JSONDecoder().decode(RuleSet.self, from: data)
        XCTAssertEqual(decoded, source)
    }

    func testLegacyIdentitiesAreDroppedDuringSanitization() throws {
        let data = try XCTUnwrap("""
        {
          "name": "Claude",
          "path": "/Applications/LegacyClaudeForTest.app",
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
                path: "/Applications/LegacyClaudeForTest.app"
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
                path: "/Applications/XDialSanitizeFixture.app",
                bundleIdentifier: "com.anthropic.claudefordesktop"
            ),
            ApplicationRuleApplication(
                name: "Claude duplicate",
                path: "/Applications/XDialSanitizeFixture.app"
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
                path: "/Applications/XDialSanitizeFixture.app",
                bundleIdentifier: "com.anthropic.claudefordesktop"
            ),
        ])
    }

    func testSanitizeProcessesUsesSurgeProcessNameModes() {
        let cleaned = RuleSet.sanitizeProcesses([
            "claude",
            "claude",
            "Claude Helper*",
            "/usr/local/bin/claude",
            "/Applications/Claude.app/",
            " bin/claude ",
            "/Applications/Other/../Claude.app/",
        ])

        XCTAssertEqual(cleaned, [
            "claude",
            "Claude Helper*",
            "/usr/local/bin/claude",
            "/Applications/Claude.app/",
        ])
    }
}
