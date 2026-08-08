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

    func testApplicationCredentialDecisionUsesFirstMatchingScenarioBinding() {
        let app = try! XCTUnwrap(TransparentProxyProcessSelector(
            kind: .bundlePath,
            value: "/Applications/Claude.app"
        ))
        let helper = try! XCTUnwrap(TransparentProxyProcessSelector(
            kind: .bundlePath,
            value: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app"
        ))
        XCTAssertEqual(
            TransparentProxyApplicationCredentialDecision.select(
                sourceAppSigningIdentifier: "",
                auditTokenPresent: true,
                auditExecutablePath: "/Applications/Claude.app/Contents/"
                    + "Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper",
                activeSelectors: [app, helper]
            ),
            .application(selector: app)
        )
    }

    func testApplicationCredentialDecisionUsesBaseWithoutAuditToken() {
        let selector = try! XCTUnwrap(TransparentProxyProcessSelector(
            kind: .bundlePath,
            value: "/Applications/Claude.app"
        ))
        XCTAssertEqual(
            TransparentProxyApplicationCredentialDecision.select(
                sourceAppSigningIdentifier: "",
                auditTokenPresent: false,
                auditExecutablePath: nil,
                activeSelectors: [selector]
            ),
            .base
        )
    }

    func testApplicationCredentialDecisionRejectsUnresolvableAuditToken() {
        let selector = try! XCTUnwrap(TransparentProxyProcessSelector(
            kind: .bundlePath,
            value: "/Applications/Claude.app"
        ))
        XCTAssertEqual(
            TransparentProxyApplicationCredentialDecision.select(
                sourceAppSigningIdentifier: "",
                auditTokenPresent: true,
                auditExecutablePath: nil,
                activeSelectors: [selector]
            ),
            .reject
        )
    }

    func testApplicationCredentialDecisionUsesBaseForUnrelatedFlow() {
        let selector = try! XCTUnwrap(TransparentProxyProcessSelector(
            kind: .bundlePath,
            value: "/Applications/Claude.app"
        ))
        XCTAssertEqual(
            TransparentProxyApplicationCredentialDecision.select(
                sourceAppSigningIdentifier: "com.apple.Safari",
                auditTokenPresent: true,
                auditExecutablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
                activeSelectors: [selector]
            ),
            .base
        )
    }

    func testApplicationCredentialDecisionUsesExactBundleIdentifierWithoutAuditToken() throws {
        let selector = try XCTUnwrap(TransparentProxyProcessSelector(
            kind: .bundleIdentifier,
            value: "com.anthropic.claudefordesktop"
        ))
        XCTAssertEqual(
            TransparentProxyApplicationCredentialDecision.select(
                sourceAppSigningIdentifier:
                    "com.anthropic.claudefordesktop",
                auditTokenPresent: false,
                auditExecutablePath: nil,
                activeSelectors: [selector]
            ),
            .application(selector: selector)
        )
        XCTAssertEqual(
            TransparentProxyApplicationCredentialDecision.select(
                sourceAppSigningIdentifier:
                    "com.anthropic.claudefordesktop.helper",
                auditTokenPresent: false,
                auditExecutablePath: nil,
                activeSelectors: [selector]
            ),
            .base
        )
    }

    func testProcessNameSelectorMatchesFilenameAndWildcards() throws {
        let exact = try XCTUnwrap(TransparentProxyProcessSelector(
            kind: .name,
            value: "claude"
        ))
        let wildcard = try XCTUnwrap(TransparentProxyProcessSelector(
            kind: .name,
            value: "Claude Helper*"
        ))

        XCTAssertTrue(exact.matches(
            executablePath: "/Users/test/Library/Application Support/Claude/"
                + "claude-code/2.1.219/claude.app/Contents/MacOS/claude"
        ))
        XCTAssertTrue(wildcard.matches(
            executablePath: "/Applications/Claude.app/Contents/Frameworks/"
                + "Claude Helper.app/Contents/MacOS/Claude Helper (Renderer)"
        ))
        XCTAssertFalse(exact.matches(executablePath: "/usr/bin/other"))
    }

    func testExactAndPrefixPathSelectorsFollowSurgeSemantics() throws {
        let exact = try XCTUnwrap(TransparentProxyProcessSelector(
            kind: .exactPath,
            value: "/usr/local/bin/claude"
        ))
        let prefix = try XCTUnwrap(TransparentProxyProcessSelector(
            kind: .pathPrefix,
            value: "/Applications/Claude.app"
        ))

        XCTAssertTrue(exact.matches(executablePath: "/usr/local/bin/claude"))
        XCTAssertFalse(exact.matches(executablePath: "/opt/bin/claude"))
        XCTAssertTrue(prefix.matches(
            executablePath: "/Applications/Claude.app/Contents/MacOS/Claude"
        ))
        XCTAssertFalse(prefix.matches(
            executablePath: "/Applications/Claude.app2/Contents/MacOS/Claude"
        ))
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
