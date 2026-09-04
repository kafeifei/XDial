import XCTest

final class LineAddressFamilyCapabilityTests: XCTestCase {
    func testDecodesAuthenticatedTLSFactsAndChoosesIPv4Only() throws {
        let raw = """
        {
          "ipv4": {
            "available": true,
            "attempts": 2,
            "tcp_connected": 2,
            "tls_authenticated": 1,
            "failure_codes": {"tls-peer-closed": 1}
          },
          "ipv6": {
            "available": false,
            "attempts": 2,
            "tcp_connected": 2,
            "tls_authenticated": 0,
            "failure_codes": {"tls-peer-closed": 2}
          }
        }
        """

        let result = try LineAddressFamilyCapabilityCodec.decodeProbe(raw)
        let capability = LineAddressFamilyCapabilityCodec.capability(
            from: result
        )

        XCTAssertEqual(capability.strategy, "ipv4_only")
        XCTAssertTrue(capability.isDegraded)
        XCTAssertEqual(
            capability.reportCode,
            "line-ipv6-egress-unavailable"
        )
        XCTAssertEqual(
            capability.reportFacts,
            [
                "ipv4_available": true,
                "ipv6_available": false,
                "degraded": true,
            ]
        )
    }

    func testSupportsDualStackAndIPv6Only() {
        XCTAssertNil(LineAddressFamilyCapability.dualStack.strategy)
        XCTAssertFalse(LineAddressFamilyCapability.dualStack.isDegraded)

        let ipv6Only = LineAddressFamilyCapability(
            ipv4Available: false,
            ipv6Available: true
        )
        XCTAssertEqual(ipv6Only.strategy, "ipv6_only")
        XCTAssertEqual(
            ipv6Only.reportCode,
            "line-ipv4-egress-unavailable"
        )
    }

    func testRejectsProbeWhoseAvailabilityDoesNotMatchTLSFacts() {
        let raw = """
        {
          "ipv4": {
            "available": true,
            "attempts": 2,
            "tcp_connected": 2,
            "tls_authenticated": 0,
            "failure_codes": {}
          },
          "ipv6": {
            "available": false,
            "attempts": 2,
            "tcp_connected": 0,
            "tls_authenticated": 0,
            "failure_codes": {"timeout": 2}
          }
        }
        """

        XCTAssertThrowsError(
            try LineAddressFamilyCapabilityCodec.decodeProbe(raw)
        )
    }

    func testSnapshotEncodingIsStableAndRejectsUnusableLine() throws {
        let encoded = try LineAddressFamilyCapabilityCodec.encodeSnapshot([
            "tail": LineAddressFamilyCapability(
                ipv4Available: true,
                ipv6Available: false
            ),
            "direct": .dualStack,
        ])
        XCTAssertEqual(
            encoded,
            "{\"direct\":{\"ipv4_available\":true,\"ipv6_available\":true},\"tail\":{\"ipv4_available\":true,\"ipv6_available\":false}}"
        )

        XCTAssertThrowsError(
            try LineAddressFamilyCapabilityCodec.encodeSnapshot([
                "tail": LineAddressFamilyCapability(
                    ipv4Available: false,
                    ipv6Available: false
                ),
            ])
        )
    }

    func testConvergenceRegeneratesOnlyForDegradedNonDirectLine() {
        let capabilities = [
            "direct": LineAddressFamilyCapability(
                ipv4Available: true,
                ipv6Available: false
            ),
            "tail": LineAddressFamilyCapability(
                ipv4Available: true,
                ipv6Available: false
            ),
        ]

        XCTAssertTrue(
            LineAddressFamilyCapabilityConvergence.requiresRegeneration(
                capabilities: capabilities,
                nonDirectLineIDs: ["tail"]
            )
        )
        XCTAssertFalse(
            LineAddressFamilyCapabilityConvergence.requiresRegeneration(
                capabilities: capabilities,
                nonDirectLineIDs: []
            )
        )
    }

    func testConvergenceRequiresExactSecondProbeMatch() {
        let baseline = [
            "tail": LineAddressFamilyCapability(
                ipv4Available: true,
                ipv6Available: false
            ),
        ]
        XCTAssertTrue(
            LineAddressFamilyCapabilityConvergence.isStable(
                baseline: baseline,
                constrained: baseline
            )
        )
        XCTAssertFalse(
            LineAddressFamilyCapabilityConvergence.isStable(
                baseline: baseline,
                constrained: ["tail": .dualStack]
            )
        )
    }
}
