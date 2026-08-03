import Network
import XCTest

final class TransparentProxyFlowMetadataTests: XCTestCase {
    func testApplicationBundlePathAcceptsCanonicalAppBundle() throws {
        let bundlePath = try XCTUnwrap(
            TransparentProxyApplicationBundlePath("/Applications/Claude.app")
        )

        XCTAssertEqual(bundlePath.value, "/Applications/Claude.app")
    }

    func testApplicationBundlePathRejectsAmbiguousPaths() {
        XCTAssertNil(TransparentProxyApplicationBundlePath("Claude.app"))
        XCTAssertNil(
            TransparentProxyApplicationBundlePath("/Applications/Claude")
        )
        XCTAssertNil(
            TransparentProxyApplicationBundlePath(
                "/Applications/Other/../Claude.app"
            )
        )
        XCTAssertNil(
            TransparentProxyApplicationBundlePath("/Applications/Claude.app/")
        )
    }

    func testApplicationBundlePathContainsEveryNestedExecutable() throws {
        let bundlePath = try XCTUnwrap(
            TransparentProxyApplicationBundlePath("/Applications/Claude.app")
        )

        XCTAssertTrue(
            bundlePath.contains(
                executablePath: "/Applications/Claude.app/Contents/MacOS/Claude"
            )
        )
        XCTAssertTrue(
            bundlePath.contains(
                executablePath: "/Applications/Claude.app/Contents/Frameworks/"
                    + "Claude Helper.app/Contents/MacOS/computer_use"
            )
        )
    }

    func testApplicationBundlePathUsesDirectoryBoundary() throws {
        let bundlePath = try XCTUnwrap(
            TransparentProxyApplicationBundlePath("/Applications/Claude.app")
        )

        XCTAssertFalse(
            bundlePath.contains(
                executablePath: "/Applications/Claude.app2/Contents/MacOS/Claude"
            )
        )
        XCTAssertFalse(
            bundlePath.contains(
                executablePath: "/Applications/Other.app/Contents/MacOS/Claude"
            )
        )
    }

    func testApplicationCredentialDecisionUsesFirstMatchingModeBinding() {
        XCTAssertEqual(
            TransparentProxyApplicationCredentialDecision.select(
                auditTokenPresent: true,
                auditExecutablePath: "/Applications/Claude.app/Contents/"
                    + "Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper",
                activeBundlePaths: [
                    "/Applications/Claude.app",
                    "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app",
                ]
            ),
            .application(bundlePath: "/Applications/Claude.app")
        )
    }

    func testApplicationCredentialDecisionUsesBaseWithoutAuditToken() {
        XCTAssertEqual(
            TransparentProxyApplicationCredentialDecision.select(
                auditTokenPresent: false,
                auditExecutablePath: nil,
                activeBundlePaths: ["/Applications/Claude.app"]
            ),
            .base
        )
    }

    func testApplicationCredentialDecisionRejectsUnresolvableAuditToken() {
        XCTAssertEqual(
            TransparentProxyApplicationCredentialDecision.select(
                auditTokenPresent: true,
                auditExecutablePath: nil,
                activeBundlePaths: ["/Applications/Claude.app"]
            ),
            .reject
        )
    }

    func testApplicationCredentialDecisionUsesBaseForUnrelatedFlow() {
        XCTAssertEqual(
            TransparentProxyApplicationCredentialDecision.select(
                auditTokenPresent: true,
                auditExecutablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
                activeBundlePaths: ["/Applications/Claude.app"]
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
