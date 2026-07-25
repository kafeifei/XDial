import NetworkExtension
import XCTest
@testable import XDial

@MainActor
final class OnDemandReconnectTests: XCTestCase {
    func testStartEnvelopeIsVersionedAndRoundTripsStandaloneParameters() throws {
        let envelope = OnDemandStartEnvelope(
            transport: "standalone",
            parameters: ["acceptance_plan": "{\"kind\":\"standalone\"}"],
            configJSON: "{\"route\":{}}"
        )

        let decoded = try JSONDecoder().decode(
            OnDemandStartEnvelope.self,
            from: JSONEncoder().encode(envelope)
        )

        XCTAssertEqual(decoded, envelope)
        XCTAssertTrue(decoded.isValid)
        XCTAssertEqual(decoded.format, OnDemandStartEnvelope.currentFormat)
        XCTAssertEqual(decoded.schemaVersion, OnDemandStartEnvelope.currentSchemaVersion)
    }

    func testStartEnvelopeRejectsUnknownSchemaAndEmptyConfig() throws {
        let unknownSchema = Data("""
        {
          "format": "xdial-on-demand-start",
          "schema_version": 999,
          "transport": "anyconnect",
          "parameters": {},
          "config_json": "{}"
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(OnDemandStartEnvelope.self, from: unknownSchema)

        XCTAssertFalse(decoded.isValid)
        XCTAssertFalse(OnDemandStartEnvelope(
            transport: "anyconnect",
            parameters: [:],
            configJSON: ""
        ).isValid)
    }

    func testOnDemandArmsOnlyAfterAcceptanceAndSecureEnvelope() {
        XCTAssertTrue(SystemOnDemandReconnectPolicy.shouldArm(
            userEnabled: true,
            dataPathVerified: true,
            hasStartEnvelope: true
        ))
        XCTAssertFalse(SystemOnDemandReconnectPolicy.shouldArm(
            userEnabled: false,
            dataPathVerified: true,
            hasStartEnvelope: true
        ))
        XCTAssertFalse(SystemOnDemandReconnectPolicy.shouldArm(
            userEnabled: true,
            dataPathVerified: false,
            hasStartEnvelope: true
        ))
        XCTAssertFalse(SystemOnDemandReconnectPolicy.shouldArm(
            userEnabled: true,
            dataPathVerified: true,
            hasStartEnvelope: false
        ))
        XCTAssertTrue(SystemOnDemandReconnectPolicy.shouldSuspendActiveProfile(
            systemOnDemandActive: true,
            userEnabled: true,
            hasStartEnvelope: false
        ))
        XCTAssertFalse(SystemOnDemandReconnectPolicy.shouldSuspendActiveProfile(
            systemOnDemandActive: true,
            userEnabled: true,
            hasStartEnvelope: true
        ))
    }

    func testFreshTunnelManagerRestoresAcceptancePlanFromSystemProfileMetadata() throws {
        let expected = TunnelAcceptancePlan(
            requiresAnyConnect: false,
            currentRouteTag: "tailscale-home",
            targets: [
                TunnelAcceptanceTarget(tag: "tailscale-home", label: "Home"),
            ],
            generatedTailscaleTargets: [
                TunnelAcceptanceTarget(tag: "tailscale-home", label: "Home"),
            ]
        )
        let persistedConfiguration = TunnelManager.systemProviderConfiguration(
            acceptancePlan: expected
        )
        let restoredProtocol = NETunnelProviderProtocol()
        restoredProtocol.providerConfiguration = persistedConfiguration

        let freshManager = TunnelManager()
        XCTAssertNil(freshManager.activeAcceptancePlan)
        XCTAssertTrue(
            freshManager.restoreAcceptancePlanFromSystemProfileIfNeeded(restoredProtocol)
        )
        XCTAssertEqual(freshManager.activeAcceptancePlan, expected)
        XCTAssertNil(persistedConfiguration["configJSON"])
        XCTAssertNil(persistedConfiguration["password"])
    }

    func testSecureEnvelopeIsClearedOnlyWhenItsStartOrRuntimeFails() {
        XCTAssertTrue(OnDemandStartEnvelopeFailurePolicy.shouldClear(
            startedFromSecureEnvelope: true,
            startOrRuntimeFailed: true
        ))
        XCTAssertFalse(OnDemandStartEnvelopeFailurePolicy.shouldClear(
            startedFromSecureEnvelope: false,
            startOrRuntimeFailed: true
        ))
        XCTAssertFalse(OnDemandStartEnvelopeFailurePolicy.shouldClear(
            startedFromSecureEnvelope: true,
            startOrRuntimeFailed: false
        ))
    }

    func testNonemptySystemOptionsDoNotMasqueradeAsManualStart() {
        XCTAssertFalse(OnDemandManualStartContract.isComplete(
            configJSON: nil,
            usesAnyConnect: nil,
            server: nil,
            username: nil,
            password: nil
        ))
        XCTAssertFalse(OnDemandManualStartContract.isComplete(
            configJSON: "{}",
            usesAnyConnect: nil,
            server: "system-metadata",
            username: nil,
            password: nil
        ))
        XCTAssertTrue(OnDemandManualStartContract.isComplete(
            configJSON: "{}",
            usesAnyConnect: false,
            server: nil,
            username: nil,
            password: nil
        ))
        XCTAssertTrue(OnDemandManualStartContract.isComplete(
            configJSON: "{}",
            usesAnyConnect: true,
            server: "gateway.example.com",
            username: "user",
            password: "secret"
        ))
    }

    func testNetworkSettingsTimeoutRejectsLateCallbackAndNextJobCanFinish() {
        let first = OneShotNetworkSettingsResult()
        let timeout = NSError(
            domain: "XDialTests",
            code: 31,
            userInfo: [NSLocalizedDescriptionKey: "timeout"]
        )

        XCTAssertTrue(first.finish(timeout))
        XCTAssertFalse(first.finish(nil))
        XCTAssertEqual((first.snapshot().error as NSError?)?.code, 31)

        // stop barrier 之后的新启动使用全新的 gate，不受迟到的旧 callback 影响。
        let restarted = OneShotNetworkSettingsResult()
        XCTAssertTrue(restarted.finish(nil))
        XCTAssertTrue(restarted.snapshot().completed)
        XCTAssertNil(restarted.snapshot().error)
    }

    func testNetworkSettingsCallbackIsOneShotWhenSystemCallsTwice() {
        let result = OneShotNetworkSettingsResult()

        XCTAssertTrue(result.finish(nil))
        XCTAssertFalse(result.finish(NSError(domain: "late", code: 1)))
        XCTAssertTrue(result.snapshot().completed)
        XCTAssertNil(result.snapshot().error)
    }

    func testSystemOnDemandUsesOneConnectRuleForAnyInterface() throws {
        let rules = TunnelManager.makeSystemOnDemandRules()
        let connect = try XCTUnwrap(rules.first as? NEOnDemandRuleConnect)

        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(connect.interfaceTypeMatch, .any)
    }
}
