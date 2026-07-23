import XCTest
@testable import XDial

final class DataPathProbeTests: XCTestCase {
    func testStandaloneAcceptancePlanUsesVisibleCurrentRouteBinding() throws {
        var profile = Profile.bootstrap()
        profile.lines.append(Line(
            id: "proxy-one",
            name: "Proxy One",
            type: "trojan",
            trojanServer: "proxy.example.com",
            trojanPassword: "secret"
        ))
        profile.modes = [Mode(id: "proxy", name: "Proxy", defaultLineID: "proxy-one")]
        profile.activeModeID = "proxy"
        profile.ensureConnectivityTestConfiguration()
        let data = try JSONEncoder().encode(profile)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        let plan = try TunnelAcceptancePlan.make(
            profile: profile,
            profileJSON: json,
            anyConnect: nil
        )

        XCTAssertFalse(plan.requiresAnyConnect)
        XCTAssertEqual(plan.currentRouteTag, "proxy-proxy-one")
        XCTAssertEqual(Set(plan.targets.map(\.tag)), Set(["direct", "proxy-proxy-one"]))
    }

    func testAnyConnectAcceptancePlanPreservesTwoLineContract() throws {
        var profile = Profile.bootstrap()
        profile.lines[1].vpnServer = "gateway.example.com"
        profile.lines[1].vpnUsername = "user"
        profile.lines[1].vpnPassword = "secret"
        profile.modes = [Mode(id: "ac", name: "AC", defaultLineID: "vpn")]
        profile.activeModeID = "ac"
        profile.ensureConnectivityTestConfiguration()
        let data = try JSONEncoder().encode(profile)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        let plan = try TunnelAcceptancePlan.make(
            profile: profile,
            profileJSON: json,
            anyConnect: AnyConnectCredentials(
                server: "gateway.example.com",
                username: "user",
                password: "secret"
            )
        )

        XCTAssertTrue(plan.requiresAnyConnect)
        XCTAssertEqual(plan.currentRouteTag, "vpn")
        XCTAssertEqual(Set(plan.targets.map(\.tag)), Set(["direct", "vpn"]))

        let result = ConfiguredDataPathResult(
            targetAddresses: [
                "direct": "198.51.100.1",
                "vpn": "203.0.113.2",
            ],
            targets: plan.targets,
            unavailableTargets: [],
            routedDirectEgressIP: "198.51.100.1",
            routedCurrentEgressIP: "203.0.113.2",
            hostnameOK: true,
            routingEvidenceOK: true,
            currentRouteTag: plan.currentRouteTag
        )
        XCTAssertTrue(result.diagnosticSummary.contains("AnyConnect"))
        XCTAssertFalse(result.diagnosticSummary.lowercased().contains("vpn"))
        let report = MobileDiagnosticsService.report(
            version: "test",
            status: "Connected",
            systemProfileInstalled: true,
            profile: profile,
            lastError: nil,
            dataPathSummary: result.diagnosticSummary,
            isChinese: false
        )
        XCTAssertFalse(report.lowercased().contains("vpn"))
    }

    func testMixedAcceptancePlanChecksEveryReferencedOutletAndKeepsDefaultRoute() throws {
        var profile = Profile.bootstrap()
        profile.lines[1].vpnServer = "gateway.example.com"
        profile.lines[1].vpnUsername = "user"
        profile.lines[1].vpnPassword = "secret"
        profile.lines.append(Line(
            id: "proxy-one",
            name: "Proxy",
            type: "trojan",
            trojanServer: "proxy.example.com",
            trojanPassword: "secret"
        ))
        profile.ruleSets.append(RuleSet(
            id: "proxy-rule",
            name: "Proxy Rule",
            type: "manual",
            domains: ["example.com"]
        ))
        profile.modes = [Mode(
            id: "mixed",
            name: "Mixed",
            bindings: [
                RuleBinding(ruleSetID: "internal", lineID: "vpn"),
                RuleBinding(ruleSetID: "proxy-rule", lineID: "proxy-one"),
            ],
            defaultLineID: "direct"
        )]
        profile.activeModeID = "mixed"
        profile.ensureConnectivityTestConfiguration()
        let data = try JSONEncoder().encode(profile)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        let plan = try TunnelAcceptancePlan.make(
            profile: profile,
            profileJSON: json,
            anyConnect: AnyConnectCredentials(
                server: "gateway.example.com",
                username: "user",
                password: "secret"
            )
        )

        XCTAssertTrue(plan.requiresAnyConnect)
        XCTAssertEqual(plan.currentRouteTag, "vpn")
        XCTAssertEqual(
            Set(plan.targets.map(\.tag)),
            Set(["direct", "vpn", "proxy-proxy-one"])
        )
    }

    func testPureDirectPlanMarksSplitRoutingNotApplicable() throws {
        var profile = Profile.bootstrap()
        profile.modes = [Mode(id: "direct-only", name: "Direct", defaultLineID: "direct")]
        profile.activeModeID = "direct-only"
        profile.ensureConnectivityTestConfiguration()
        let data = try JSONEncoder().encode(profile)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        let plan = try TunnelAcceptancePlan.make(
            profile: profile,
            profileJSON: json,
            anyConnect: nil
        )

        XCTAssertNil(plan.currentRouteTag)
        XCTAssertEqual(plan.targets.map(\.tag), ["direct"])

        let result = ConfiguredDataPathResult(
            targetAddresses: ["direct": "198.51.100.1"],
            unavailableTargets: [],
            routedDirectEgressIP: "198.51.100.1",
            routedCurrentEgressIP: nil,
            hostnameOK: true,
            routingEvidenceOK: true,
            currentRouteTag: nil
        )
        XCTAssertTrue(result.isUsable)
        XCTAssertEqual(result.splitRoutingState, .notApplicable)
        XCTAssertTrue(result.diagnosticSummary.contains(
            "公网双出口不适用；线路与DNS通过，未执行双出口分流验收"
        ))
        XCTAssertFalse(result.diagnosticSummary.contains("分流通过"))
    }

    func testAcceptancePlanMatchesGlobalGeneratedTailscaleEndpointSemantics() throws {
        var profile = Profile.bootstrap()
        profile.lines.append(Line(
            id: "overlay",
            name: "Overlay",
            type: "tailscale",
            tailscaleAcceptRoutes: true
        ))
        profile.lines.append(Line(
            id: "exit",
            name: "Exit",
            type: "tailscale",
            tailscaleExitNode: "100.64.0.8"
        ))
        profile.ruleSets.append(RuleSet(
            id: "overlay-rule",
            name: "Overlay",
            type: "manual",
            cidrs: ["100.64.0.0/10"]
        ))
        profile.modes = [Mode(
            id: "direct-overlay",
            name: "Direct + Overlay",
            bindings: [RuleBinding(ruleSetID: "overlay-rule", lineID: "overlay")],
            defaultLineID: "direct"
        )]
        profile.activeModeID = "direct-overlay"
        profile.ensureConnectivityTestConfiguration()
        let data = try JSONEncoder().encode(profile)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        let plan = try TunnelAcceptancePlan.make(
            profile: profile,
            profileJSON: json,
            anyConnect: nil
        )

        XCTAssertNil(plan.currentRouteTag)
        XCTAssertEqual(plan.targets.map(\.tag), ["direct"])
        XCTAssertEqual(
            Set(plan.generatedTailscaleTargets.map(\.tag)),
            Set(["tailscale-overlay", "tailscale-exit"])
        )
        XCTAssertFalse(profile.modes[0].bindings.contains {
            $0.ruleSetID == RuleSet.connectivityOutboundID
        })
    }

    func testRequiresBothLinesBeforeTestingRouting() {
        XCTAssertFalse(DataPathProbe.Result(
            directLineEgressIP: nil,
            anyConnectLineEgressIP: "203.0.113.2",
            routedDirectEgressIP: "198.51.100.1",
            routedAnyConnectEgressIP: "203.0.113.2",
            hostnameOK: true,
            routingEvidenceOK: true
        ).isUsable)
        XCTAssertFalse(DataPathProbe.Result(
            directLineEgressIP: "198.51.100.1",
            anyConnectLineEgressIP: nil,
            routedDirectEgressIP: "198.51.100.1",
            routedAnyConnectEgressIP: "203.0.113.2",
            hostnameOK: true,
            routingEvidenceOK: true
        ).isUsable)
    }

    func testRequiresRouterHitEvidenceInsteadOfInferringFromPublicAddresses() {
        XCTAssertFalse(DataPathProbe.Result(
            directLineEgressIP: "198.51.100.1",
            anyConnectLineEgressIP: "203.0.113.2",
            routedDirectEgressIP: "203.0.113.2",
            routedAnyConnectEgressIP: "203.0.113.2",
            hostnameOK: true,
            routingEvidenceOK: false
        ).isUsable)
        XCTAssertTrue(DataPathProbe.Result(
            directLineEgressIP: "198.51.100.1",
            anyConnectLineEgressIP: "203.0.113.2",
            routedDirectEgressIP: "192.0.2.90",
            routedAnyConnectEgressIP: "192.0.2.91",
            hostnameOK: true,
            routingEvidenceOK: true
        ).isUsable)
    }

    func testAcceptsSamePublicEgressWhenRouterEvidenceIsCorrectAndRejectsDNSFailure() {
        XCTAssertTrue(DataPathProbe.Result(
            directLineEgressIP: "198.51.100.1",
            anyConnectLineEgressIP: "198.51.100.1",
            routedDirectEgressIP: "198.51.100.1",
            routedAnyConnectEgressIP: "198.51.100.1",
            hostnameOK: true,
            routingEvidenceOK: true
        ).isUsable)
        XCTAssertFalse(DataPathProbe.Result(
            directLineEgressIP: "198.51.100.1",
            anyConnectLineEgressIP: "203.0.113.2",
            routedDirectEgressIP: "198.51.100.1",
            routedAnyConnectEgressIP: "203.0.113.2",
            hostnameOK: false,
            routingEvidenceOK: true
        ).isUsable)
    }

    func testParsesIPv4AndIPv6FromCloudflareTrace() {
        let ipv4 = Data("fl=1\nip=203.0.113.9\nts=1\n".utf8)
        let ipv6 = Data("ip=2001:db8::9\nloc=US\n".utf8)

        XCTAssertEqual(DataPathProbe.parseTraceIPAddress(ipv4), "203.0.113.9")
        XCTAssertEqual(DataPathProbe.parseTraceIPAddress(ipv6), "2001:db8::9")
    }

    func testRejectsMissingOrUnsafeTraceAddress() {
        XCTAssertNil(DataPathProbe.parseTraceIPAddress(Data("loc=US\n".utf8)))
        XCTAssertNil(DataPathProbe.parseTraceIPAddress(Data("ip=<script>\n".utf8)))
        XCTAssertNil(DataPathProbe.parseTraceIPAddress(Data("ip=not-an-address\n".utf8)))
        XCTAssertNil(DataPathProbe.parseTraceIPAddress(Data("ip=999.999.999.999\n".utf8)))
    }

    func testRoutingSnapshotRequiresOnlyExpectedOutboundDeltas() {
        let before = RoutingProbeSnapshot(
            directTargetDirect: 4,
            directTargetVPN: 1,
            directTargetOther: 0,
            anyConnectTargetDirect: 2,
            anyConnectTargetVPN: 7,
            anyConnectTargetOther: 0
        )
        let valid = RoutingProbeSnapshot(
            directTargetDirect: 5,
            directTargetVPN: 1,
            directTargetOther: 0,
            anyConnectTargetDirect: 2,
            anyConnectTargetVPN: 8,
            anyConnectTargetOther: 0
        )
        let wrongRoute = RoutingProbeSnapshot(
            directTargetDirect: 5,
            directTargetVPN: 1,
            directTargetOther: 0,
            anyConnectTargetDirect: 3,
            anyConnectTargetVPN: 7,
            anyConnectTargetOther: 0
        )

        XCTAssertTrue(before.provesConfiguredRouting(after: valid))
        XCTAssertFalse(before.provesConfiguredRouting(after: wrongRoute))
        XCTAssertFalse(valid.provesConfiguredRouting(after: before))
    }

    func testStandaloneRoutingSnapshotRequiresExactConfiguredTag() {
        let before = RoutingProbeSnapshot(
            directTargetDirect: 0,
            directTargetVPN: 0,
            directTargetOther: 0,
            anyConnectTargetDirect: 0,
            anyConnectTargetVPN: 0,
            anyConnectTargetOther: 0,
            directTargetTags: ["direct": 4],
            anyConnectTargetTags: ["proxy-main": 2]
        )
        let valid = RoutingProbeSnapshot(
            directTargetDirect: 1,
            directTargetVPN: 0,
            directTargetOther: 0,
            anyConnectTargetDirect: 0,
            anyConnectTargetVPN: 0,
            anyConnectTargetOther: 1,
            directTargetTags: ["direct": 5],
            anyConnectTargetTags: ["proxy-main": 3]
        )
        let wrongProxy = RoutingProbeSnapshot(
            directTargetDirect: 1,
            directTargetVPN: 0,
            directTargetOther: 0,
            anyConnectTargetDirect: 0,
            anyConnectTargetVPN: 0,
            anyConnectTargetOther: 1,
            directTargetTags: ["direct": 5],
            anyConnectTargetTags: ["proxy-main": 2, "proxy-other": 1]
        )

        XCTAssertTrue(before.provesConfiguredRouting(
            after: valid,
            directTag: "direct",
            currentRouteTag: "proxy-main"
        ))
        XCTAssertFalse(before.provesConfiguredRouting(
            after: wrongProxy,
            directTag: "direct",
            currentRouteTag: "proxy-main"
        ))
    }

    func testReconnectSuppressionRequiresAnActualActiveTunnelStop() {
        XCTAssertFalse(ProbeFailureReconnectPolicy.shouldSuppressAutomaticReconnect(
            shouldStop: false,
            tunnelIsActive: true
        ))
        XCTAssertFalse(ProbeFailureReconnectPolicy.shouldSuppressAutomaticReconnect(
            shouldStop: true,
            tunnelIsActive: false
        ))
        XCTAssertTrue(ProbeFailureReconnectPolicy.shouldSuppressAutomaticReconnect(
            shouldStop: true,
            tunnelIsActive: true
        ))
    }

    func testOneShotTimeoutCompletesWhenProviderNeverCallsBack() async {
        let result: String = await withCheckedContinuation { continuation in
            let oneShot = OneShotContinuation<String>(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
                oneShot.finish("timed-out")
            }
            // Intentionally never invoke a simulated provider callback.
        }
        XCTAssertEqual(result, "timed-out")
    }

    func testOneShotCancellationCanFinishBeforeContinuationIsInstalled() async {
        let oneShot = OneShotContinuation<String>()
        oneShot.finish("cancelled")
        let result: String = await withCheckedContinuation { continuation in
            oneShot.install(continuation)
        }
        XCTAssertEqual(result, "cancelled")
    }
}
