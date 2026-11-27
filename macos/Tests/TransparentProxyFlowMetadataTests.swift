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

    func testEncodesBoundFlowEndpointHostnameAndInterface() throws {
        let address = try XCTUnwrap(IPv4Address("192.168.69.26"))
        let encoded = try XCTUnwrap(
            TransparentProxyFlowMetadata.encodeBoundFlow(
                hostname: "Kafeifeis-iPhone.local.",
                endpointHost: .ipv4(address),
                boundInterface: "en0"
            )
        )

        XCTAssertEqual(
            Array(encoded.prefix(6)),
            [0x00, 0x58, 0x44, 0x02, 0x07, 0x01]
        )
        XCTAssertEqual(encoded.subdata(in: 6 ..< 10), address.rawValue)
        let hostnameLength = Int(encoded[10])
        XCTAssertEqual(
            String(
                data: encoded.subdata(in: 11 ..< 11 + hostnameLength),
                encoding: .utf8
            ),
            "Kafeifeis-iPhone.local."
        )
        let interfaceLengthOffset = 11 + hostnameLength
        XCTAssertEqual(encoded[interfaceLengthOffset], 3)
        XCTAssertEqual(
            String(
                data: encoded.dropFirst(interfaceLengthOffset + 1),
                encoding: .utf8
            ),
            "en0"
        )
    }

    func testEncodesUDPAssociationSocketFacts() throws {
        let bound = try XCTUnwrap(
            TransparentProxyFlowMetadata.encodeUDPAssociation(
                boundInterface: "en0",
                sourcePort: 5901
            )
        )
        XCTAssertEqual(
            Array(bound),
            [0x00, 0x58, 0x44, 0x03, 0x0c, 0x03, 0x65, 0x6e, 0x30, 0x17, 0x0d]
        )

        let unbound = try XCTUnwrap(
            TransparentProxyFlowMetadata.encodeUDPAssociation(
                boundInterface: nil,
                sourcePort: 5900
            )
        )
        XCTAssertEqual(
            Array(unbound),
            [0x00, 0x58, 0x44, 0x03, 0x08, 0x17, 0x0c]
        )

        let specific = try XCTUnwrap(
            TransparentProxyFlowMetadata.encodeUDPAssociation(
                boundInterface: nil,
                sourcePort: 5900,
                sourceAddress: .ipv6(IPv6Address("fd7a:115c:a1e0::1")!)
            )
        )
        XCTAssertEqual(
            Array(specific),
            [0x00, 0x58, 0x44, 0x03, 0x18, 0x17, 0x0c, 0x04]
                + Array(IPv6Address("fd7a:115c:a1e0::1")!.rawValue)
        )

        // The wildcard is the default bind, and a link-local address cannot
        // be bound without its scope: neither is stated.
        for host: Network.NWEndpoint.Host in [
            .ipv4(.any), .ipv6(.any), .ipv6(IPv6Address("fe80::1")!),
            .name("localhost", nil),
        ] {
            XCTAssertEqual(
                TransparentProxyFlowMetadata.encodeUDPAssociation(
                    boundInterface: nil,
                    sourcePort: 5900,
                    sourceAddress: host
                ),
                unbound
            )
        }
    }

    func testRejectsInvalidUDPAssociationMetadata() {
        XCTAssertNil(
            TransparentProxyFlowMetadata.encodeUDPAssociation(
                boundInterface: nil,
                sourcePort: nil
            )
        )
        XCTAssertNil(
            TransparentProxyFlowMetadata.encodeUDPAssociation(
                boundInterface: nil,
                sourcePort: 0
            )
        )
        for boundInterface in ["", String(repeating: "a", count: 16), "无线"] {
            XCTAssertNil(
                TransparentProxyFlowMetadata.encodeUDPAssociation(
                    boundInterface: boundInterface,
                    sourcePort: 5901
                )
            )
        }
    }

    func testDatagramSOCKSHostUsesTrustedConnectByNameHostname() throws {
        let address = try XCTUnwrap(IPv6Address("2001:db8::10"))
        let port = try XCTUnwrap(Network.NWEndpoint.Port(rawValue: 443))
        let selected = TransparentProxyFlowMetadata.datagramSOCKSHost(
            hostname: "connect-by-name.example",
            endpointHost: .ipv6(address),
            endpointPort: port
        )

        guard case let .name(hostname, _) = selected else {
            return XCTFail("expected SOCKS domain destination")
        }
        XCTAssertEqual(hostname, "connect-by-name.example")
    }

    func testDatagramSOCKSHostKeepsLiteralWithoutHostname() throws {
        let address = try XCTUnwrap(IPv6Address("2001:db8::10"))
        let port = try XCTUnwrap(Network.NWEndpoint.Port(rawValue: 443))
        let selected = TransparentProxyFlowMetadata.datagramSOCKSHost(
            hostname: nil,
            endpointHost: .ipv6(address),
            endpointPort: port
        )

        guard case let .ipv6(selectedAddress) = selected else {
            return XCTFail("expected literal IPv6 destination")
        }
        XCTAssertEqual(selectedAddress, address)
    }

    func testDatagramSOCKSHostRejectsInvalidHostname() throws {
        let address = try XCTUnwrap(IPv4Address("192.0.2.10"))
        let port = try XCTUnwrap(Network.NWEndpoint.Port(rawValue: 443))
        let selected = TransparentProxyFlowMetadata.datagramSOCKSHost(
            hostname: " bad.example",
            endpointHost: .ipv4(address),
            endpointPort: port
        )

        guard case let .ipv4(selectedAddress) = selected else {
            return XCTFail("expected literal IPv4 destination")
        }
        XCTAssertEqual(selectedAddress, address)
    }

    func testDatagramSOCKSHostKeepsIPv4DNSResolverEndpoint() throws {
        let resolver = try XCTUnwrap(IPv4Address("172.20.10.1"))
        let dnsPort = try XCTUnwrap(Network.NWEndpoint.Port(rawValue: 53))
        let selected = TransparentProxyFlowMetadata.datagramSOCKSHost(
            hostname: "chatgpt.com",
            endpointHost: .ipv4(resolver),
            endpointPort: dnsPort
        )

        guard case let .ipv4(selectedAddress) = selected else {
            return XCTFail("expected literal IPv4 resolver destination")
        }
        XCTAssertEqual(selectedAddress, resolver)
    }

    func testDatagramSOCKSHostKeepsIPv6DNSResolverEndpoint() throws {
        let resolver = try XCTUnwrap(IPv6Address("2001:db8::53"))
        let dnsPort = try XCTUnwrap(Network.NWEndpoint.Port(rawValue: 53))
        let selected = TransparentProxyFlowMetadata.datagramSOCKSHost(
            hostname: "chatgpt.com",
            endpointHost: .ipv6(resolver),
            endpointPort: dnsPort
        )

        guard case let .ipv6(selectedAddress) = selected else {
            return XCTFail("expected literal IPv6 resolver destination")
        }
        XCTAssertEqual(selectedAddress, resolver)
    }
}

final class FlowSystemInterfaceTests: XCTestCase {
    func testBoundFlowKeepsItsBinding() {
        XCTAssertEqual(
            FlowSystemInterface(isBound: true, interfaceName: "utun4"),
            .bound("utun4")
        )
    }

    func testBoundFlowWithoutInterfaceIsInvalid() {
        XCTAssertEqual(
            FlowSystemInterface(isBound: true, interfaceName: nil),
            .invalid
        )
        XCTAssertEqual(
            FlowSystemInterface(isBound: true, interfaceName: ""),
            .invalid
        )
    }

    /// An unbound socket to a Tailnet or MagicDNS address was routed to the
    /// VPN's utun by the system table; Direct must not send it out en0.
    func testUnboundFlowCarriesTheRoutedInterface() {
        let choice = FlowSystemInterface(isBound: false, interfaceName: "utun4")
        XCTAssertEqual(choice, .routed("utun4"))
        XCTAssertEqual(choice.name, "utun4")
    }

    func testUnboundFlowWithoutUsableInterfaceKeepsTheDefault() {
        XCTAssertEqual(
            FlowSystemInterface(isBound: false, interfaceName: nil),
            .none
        )
        XCTAssertEqual(
            FlowSystemInterface(
                isBound: false,
                interfaceName: "an-interface-name-too-long"
            ),
            .none
        )
        XCTAssertNil(FlowSystemInterface.none.name)
    }

    func testRoutedInterfaceTravelsInTheSameEnvelopeAsABinding() throws {
        let tailnet = try XCTUnwrap(IPv4Address("100.103.86.57"))
        let choice = FlowSystemInterface(isBound: false, interfaceName: "utun4")
        let routed = TransparentProxyFlowMetadata.encodeBoundFlow(
            hostname: nil,
            endpointHost: .ipv4(tailnet),
            boundInterface: try XCTUnwrap(choice.name)
        )
        let bound = TransparentProxyFlowMetadata.encodeBoundFlow(
            hostname: nil,
            endpointHost: .ipv4(tailnet),
            boundInterface: "utun4"
        )
        XCTAssertNotNil(routed)
        XCTAssertEqual(routed, bound)
        XCTAssertNotNil(
            TransparentProxyFlowMetadata.encodeUDPAssociation(
                boundInterface: try XCTUnwrap(choice.name),
                sourcePort: nil
            )
        )
    }
}
