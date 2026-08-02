import Network
import XCTest

final class TransparentProxyFlowMetadataTests: XCTestCase {
    func testCanonicalApplicationIdentityUsesTeamAndSigningIdentifier() throws {
        let identity = try XCTUnwrap(
            TransparentProxyApplicationIdentity(
                teamIdentifier: "Q6L2SF6YDW",
                signingIdentifier: "com.anthropic.claudefordesktop"
            )
        )

        XCTAssertEqual(
            identity.canonical,
            "Q6L2SF6YDW/com.anthropic.claudefordesktop"
        )
    }

    func testRejectsAmbiguousApplicationIdentityComponents() {
        XCTAssertNil(
            TransparentProxyApplicationIdentity(
                teamIdentifier: "TEAM/OTHER",
                signingIdentifier: "com.example.app"
            )
        )
        XCTAssertNil(
            TransparentProxyApplicationIdentity(
                teamIdentifier: "TEAM",
                signingIdentifier: "com.example/app"
            )
        )
        XCTAssertNil(
            TransparentProxyApplicationIdentity(
                teamIdentifier: "q6l2sf6ydw",
                signingIdentifier: "com.example.app"
            )
        )
        XCTAssertNil(
            TransparentProxyApplicationIdentity(
                teamIdentifier: "Q6L2SF6YDW",
                signingIdentifier: "com.example."
            )
        )
    }

    func testApplicationCredentialDecisionUsesExactAuditIdentity() throws {
        let auditIdentity = try XCTUnwrap(
            TransparentProxyApplicationIdentity(
                teamIdentifier: "Q6L2SF6YDW",
                signingIdentifier: "com.anthropic.claudefordesktop"
            )
        )

        XCTAssertEqual(
            TransparentProxyApplicationCredentialDecision.select(
                metadataSigningIdentifier: "com.anthropic.claudefordesktop",
                auditIdentity: auditIdentity,
                activeCanonicalIdentities: [auditIdentity.canonical]
            ),
            .application(canonicalIdentity: auditIdentity.canonical)
        )
    }

    func testApplicationCredentialDecisionRejectsConfiguredMetadataWithoutAudit() {
        XCTAssertEqual(
            TransparentProxyApplicationCredentialDecision.select(
                metadataSigningIdentifier: "com.anthropic.claudefordesktop",
                auditIdentity: nil,
                activeCanonicalIdentities: [
                    "Q6L2SF6YDW/com.anthropic.claudefordesktop",
                ]
            ),
            .reject
        )
    }

    func testApplicationCredentialDecisionRejectsTeamSpoofForSameBundle() throws {
        let auditIdentity = try XCTUnwrap(
            TransparentProxyApplicationIdentity(
                teamIdentifier: "ABCDE12345",
                signingIdentifier: "com.anthropic.claudefordesktop"
            )
        )

        XCTAssertEqual(
            TransparentProxyApplicationCredentialDecision.select(
                metadataSigningIdentifier: auditIdentity.signingIdentifier,
                auditIdentity: auditIdentity,
                activeCanonicalIdentities: [
                    "Q6L2SF6YDW/com.anthropic.claudefordesktop",
                ]
            ),
            .reject
        )
    }

    func testApplicationCredentialDecisionRejectsConflictingMetadataAndAudit() throws {
        let auditIdentity = try XCTUnwrap(
            TransparentProxyApplicationIdentity(
                teamIdentifier: "Q6L2SF6YDW",
                signingIdentifier: "com.anthropic.claudefordesktop"
            )
        )

        XCTAssertEqual(
            TransparentProxyApplicationCredentialDecision.select(
                metadataSigningIdentifier: "com.example.other",
                auditIdentity: auditIdentity,
                activeCanonicalIdentities: [auditIdentity.canonical]
            ),
            .reject
        )
    }

    func testApplicationCredentialDecisionUsesBaseForUnrelatedFlow() throws {
        let auditIdentity = try XCTUnwrap(
            TransparentProxyApplicationIdentity(
                teamIdentifier: "ABCDE12345",
                signingIdentifier: "com.example.unrelated"
            )
        )

        XCTAssertEqual(
            TransparentProxyApplicationCredentialDecision.select(
                metadataSigningIdentifier: auditIdentity.signingIdentifier,
                auditIdentity: auditIdentity,
                activeCanonicalIdentities: [
                    "Q6L2SF6YDW/com.anthropic.claudefordesktop",
                ]
            ),
            .base
        )
    }

    func testEncodesIPv4EndpointWithoutReplacingHostname() throws {
        let address = try XCTUnwrap(IPv4Address("100.117.141.16"))

        let encoded = try XCTUnwrap(
            TransparentProxyFlowMetadata.encode(
                hostname: "mbp128k",
                endpointHost: .ipv4(address)
            )
        )

        XCTAssertEqual(
            Array(encoded.prefix(5)),
            [0x00, 0x58, 0x44, 0x01, 0x01]
        )
        XCTAssertEqual(
            encoded.subdata(in: 5 ..< 9),
            address.rawValue
        )
        XCTAssertEqual(
            String(data: encoded.dropFirst(9), encoding: .utf8),
            "mbp128k"
        )
    }

    func testEncodesIPv6Endpoint() throws {
        let address = try XCTUnwrap(IPv6Address("fd7a:115c:a1e0::1"))

        let encoded = try XCTUnwrap(
            TransparentProxyFlowMetadata.encode(
                hostname: "node.example.ts.net",
                endpointHost: .ipv6(address)
            )
        )

        XCTAssertEqual(encoded[4], 0x04)
        XCTAssertEqual(
            encoded.subdata(in: 5 ..< 21),
            address.rawValue
        )
        XCTAssertEqual(
            String(data: encoded.dropFirst(21), encoding: .utf8),
            "node.example.ts.net"
        )
    }

    func testDoesNotWrapUnresolvedOrInvalidEndpoint() {
        XCTAssertNil(
            TransparentProxyFlowMetadata.encode(
                hostname: "node.example",
                endpointHost: .name("node.example", nil)
            )
        )
        XCTAssertNil(
            TransparentProxyFlowMetadata.encode(
                hostname: "",
                endpointHost: .ipv4(IPv4Address.loopback)
            )
        )
    }

    func testRejectsMetadataLargerThanSOCKSDomainField() {
        XCTAssertNil(
            TransparentProxyFlowMetadata.encode(
                hostname: String(repeating: "a", count: 247),
                endpointHost: .ipv4(IPv4Address.loopback)
            )
        )
    }
}
