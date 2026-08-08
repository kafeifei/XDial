import XCTest
@testable import XDial

final class MobileConfigurationSupportTests: XCTestCase {
    func testExportMarksAndRemovesSensitiveConfiguration() throws {
        var profile = Profile.bootstrap()
        let privateGroup = try JSONDecoder().decode(
            SubProxyGroup.self,
            from: Data(#"{"name":"Auto","type":"urltest","proxies":["Imported line"],"url":"https://probe.example.com/check?token=probe-secret"}"#.utf8)
        )
        let privateRule = try JSONDecoder().decode(
            SubRule.self,
            from: Data(#"{"type":"rule-set","value":"https://rules.example.com/list?token=rule-secret","group":"Auto"}"#.utf8)
        )
        profile.lines[1].vpnServer = "gateway.example.com"
        profile.lines[1].vpnUsername = "sensitive-user"
        profile.lines[1].vpnPassword = "sensitive-password"
        profile.lines[2].trojanPassword = "sensitive-node-key"
        profile.lines[2].vmessUUID = "sensitive-uuid"
        profile.ruleSets[1].url = "https://rule-user:rule-password@rules.example.com/rule-path-secret/list.srs?token=rule-query"
        profile.subscriptions = [
            Subscription(
                id: "sub-1",
                name: "Private subscription",
                url: "https://subscription.example.com/list?token=sensitive-token",
                lines: [
                    Line(
                        id: "sub-line",
                        name: "Imported line",
                        type: "shadowsocks",
                        ssPassword: "nested-password"
                    ),
                ],
                proxyGroups: [privateGroup],
                rules: [privateRule]
            ),
        ]
        profile.subscriptions[0].testURL = "https://health.example.com/ping?token=health-secret"

        let data = try MobileConfigurationService.exportData(for: profile)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(root["contains_credentials"] as? Bool, false)
        XCTAssertEqual(root["contains_subscription_urls"] as? Bool, false)
        XCTAssertFalse(text.contains("sensitive-user"))
        XCTAssertFalse(text.contains("sensitive-password"))
        XCTAssertFalse(text.contains("sensitive-node-key"))
        XCTAssertFalse(text.contains("sensitive-uuid"))
        XCTAssertFalse(text.contains("sensitive-token"))
        XCTAssertFalse(text.contains("nested-password"))
        XCTAssertFalse(text.contains("rule-user"))
        XCTAssertFalse(text.contains("rule-password"))
        XCTAssertFalse(text.contains("rule-path-secret"))
        XCTAssertFalse(text.contains("rule-query"))
        XCTAssertFalse(text.contains("probe-secret"))
        XCTAssertFalse(text.contains("rule-secret"))
        XCTAssertFalse(text.contains("health-secret"))

        let imported = try MobileConfigurationService.importProfile(from: data)
        XCTAssertEqual(imported.lines[1].vpnServer, "gateway.example.com")
        XCTAssertEqual(imported.lines[1].vpnUsername, "")
        XCTAssertEqual(imported.lines[1].vpnPassword, "")
        XCTAssertEqual(imported.subscriptions[0].url, "")
        XCTAssertEqual(imported.subscriptions[0].lines[0].ssPassword, "")
        XCTAssertEqual(imported.subscriptions[0].testURL, "")
        XCTAssertEqual(imported.subscriptions[0].proxyGroups[0].url, "")
        XCTAssertTrue(imported.subscriptions[0].rules.isEmpty)
        XCTAssertEqual(imported.ruleSets[1].url, "")
        XCTAssertFalse(imported.ruleSets[1].enabled)
    }

    func testImportAcceptsRawProfileAndKeepsStructure() throws {
        var profile = Profile.bootstrap()
        profile.scenarios = [Scenario(id: "scenario-1", name: "Scenario", defaultLineID: "direct")]
        profile.activeScenarioID = "scenario-1"
        let data = try JSONEncoder().encode(profile)

        let imported = try MobileConfigurationService.importProfile(from: data)

        XCTAssertEqual(imported.lines.count, profile.lines.count)
        XCTAssertEqual(imported.ruleSets.count, profile.ruleSets.count)
        XCTAssertEqual(imported.scenarios.first?.id, "scenario-1")
        XCTAssertEqual(imported.activeScenarioID, "scenario-1")
    }

    func testImportRejectsMissingStructure() throws {
        let data = try JSONSerialization.data(withJSONObject: [:])

        XCTAssertThrowsError(try MobileConfigurationService.importProfile(from: data)) { error in
            XCTAssertEqual(error as? MobileConfigurationError, .missingField("lines"))
        }
    }

    func testImportRejectsDuplicateIdentifiers() throws {
        var profile = Profile.bootstrap()
        profile.lines.append(profile.lines[0])
        let data = try JSONEncoder().encode(profile)

        XCTAssertThrowsError(try MobileConfigurationService.importProfile(from: data)) { error in
            XCTAssertEqual(error as? MobileConfigurationError, .duplicateIdentifier("line"))
        }
    }

    func testImportRejectsDanglingActiveScenario() throws {
        var profile = Profile.bootstrap()
        profile.activeScenarioID = "missing-scenario"
        let data = try JSONEncoder().encode(profile)

        XCTAssertThrowsError(try MobileConfigurationService.importProfile(from: data)) { error in
            XCTAssertEqual(error as? MobileConfigurationError, .invalidActiveScenario)
        }
    }

    func testImportRejectsAmbiguousBindingTarget() throws {
        var profile = Profile.bootstrap()
        profile.scenarios = [
            Scenario(
                id: "scenario-1",
                name: "Scenario",
                bindings: [
                    RuleBinding(ruleSetID: "internal", lineID: "direct", subscriptionID: "sub-1")
                ],
                defaultLineID: "direct"
            ),
        ]
        profile.subscriptions = [
            Subscription(id: "sub-1", name: "Subscription", url: "https://example.com/sub")
        ]
        profile.activeScenarioID = "scenario-1"
        let data = try JSONEncoder().encode(profile)

        XCTAssertThrowsError(try MobileConfigurationService.importProfile(from: data)) { error in
            XCTAssertEqual(error as? MobileConfigurationError, .invalidReference("binding.target"))
        }
    }

    func testImportRejectsOversizedFile() {
        let data = Data(repeating: 0x20, count: MobileConfigurationService.maxImportBytes + 1)

        XCTAssertThrowsError(try MobileConfigurationService.importProfile(from: data)) { error in
            XCTAssertEqual(error as? MobileConfigurationError, .fileTooLarge)
        }
    }

    func testImportKeepsValidSubscriptionSelections() throws {
        var profile = Profile.bootstrap()
        profile.subscriptions = [Subscription(
            id: "sub-1",
            name: "Subscription",
            url: "",
            strategy: "selector",
            lines: [
                Line(
                    id: "node-1",
                    name: "Node One",
                    type: "shadowsocks",
                    ssServer: "node.example.com",
                    ssPassword: "secret"
                ),
            ],
            proxyGroups: [SubProxyGroup(
                name: "Manual",
                type: "select",
                proxies: ["Node One"],
                selected: "Node One"
            )],
            selected: "Node One"
        )]

        let imported = try MobileConfigurationService.importProfile(from: JSONEncoder().encode(profile))

        XCTAssertEqual(imported.subscriptions[0].selected, "Node One")
        XCTAssertEqual(imported.subscriptions[0].proxyGroups[0].selected, "Node One")
    }

    func testImportRejectsDanglingSubscriptionSelections() throws {
        var profile = Profile.bootstrap()
        profile.subscriptions = [Subscription(
            id: "sub-1",
            name: "Subscription",
            url: "",
            strategy: "selector",
            lines: [Line(id: "node-1", name: "Node One", type: "shadowsocks")],
            selected: "Missing Node"
        )]

        XCTAssertThrowsError(
            try MobileConfigurationService.importProfile(from: JSONEncoder().encode(profile))
        ) { error in
            XCTAssertEqual(error as? MobileConfigurationError, .invalidReference("subscription.selected"))
        }
    }

    func testDiagnosticsContainsRequiredFieldsAndRedactsSensitiveValues() {
        var profile = Profile.bootstrap()
        profile.lines[1].vpnServer = "private.gateway.example.com"
        profile.lines[1].vpnUsername = "private-user"
        profile.lines[1].vpnPassword = "private-password"
        profile.subscriptions = [
            Subscription(
                id: "sub-1",
                name: "Subscription",
                url: "https://subscription.example.com/list?token=private-token"
            ),
        ]
        let lastError = "private-user private-password private.gateway.example.com "
            + "https://subscription.example.com/list?token=private-token "
            + "https://unrelated.example.com/path VPN disconnected"

        let report = MobileDiagnosticsService.report(
            version: "1.2.3 (45)",
            status: "Not connected",
            systemProfileInstalled: true,
            profile: profile,
            lastError: lastError,
            dataPathSummary: "Direct: 203.0.113.1; AnyConnect: 198.51.100.2",
            isChinese: false
        )

        XCTAssertTrue(report.contains("Version: 1.2.3 (45)"))
        XCTAssertTrue(report.contains("Status: Not connected"))
        XCTAssertTrue(report.contains("System profile: Installed"))
        XCTAssertTrue(report.contains("Object counts: lines 3, rules 5, scenarios 0, subscriptions 1"))
        XCTAssertTrue(report.contains("Egress probe: Direct: 203.0.113.1; AnyConnect: 198.51.100.2"))
        XCTAssertTrue(report.contains("Last error:"))
        XCTAssertFalse(report.contains("private-user"))
        XCTAssertFalse(report.contains("private-password"))
        XCTAssertFalse(report.contains("private.gateway.example.com"))
        XCTAssertFalse(report.contains("private-token"))
        XCTAssertFalse(report.contains("unrelated.example.com"))
        XCTAssertFalse(report.lowercased().contains("vpn"))
    }
}
