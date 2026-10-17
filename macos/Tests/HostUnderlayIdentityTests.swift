import XCTest

final class HostUnderlayIdentityTests: XCTestCase {
    private let wifi = HostUnderlayIdentity.Interface(
        name: "en0",
        index: 7,
        type: "wifi"
    )
    private let ethernet = HostUnderlayIdentity.Interface(
        name: "en7",
        index: 19,
        type: "ethernet"
    )
    private let homeDNS = "[\"192.168.1.1\"]"

    private func identity(
        defaultInterface: HostUnderlayIdentity.Interface? = nil,
        interfaces: [HostUnderlayIdentity.Interface]? = nil,
        dns: String? = nil,
        addresses: [HostInterfaceAddressFact]? = nil,
        routers: HostDefaultRouterFacts = HostDefaultRouterFacts(
            ipv4: "192.168.1.1",
            ipv6: "fe80::1"
        )
    ) -> HostUnderlayIdentity {
        HostUnderlayIdentity(
            defaultInterface: defaultInterface ?? wifi,
            interfaces: interfaces ?? [wifi],
            systemDNSJSON: dns ?? homeDNS,
            interfaceAddresses: addresses ?? [
                ipv4("en0", "192.168.1.23"),
                ipv6("en0", "fe80::1c80:ff0d:a123:291d"),
            ],
            routers: routers
        )
    }

    private func ipv4(
        _ name: String,
        _ address: String
    ) -> HostInterfaceAddressFact {
        HostInterfaceAddressFact(
            interfaceName: name,
            family: .ipv4,
            address: address
        )
    }

    private func ipv6(
        _ name: String,
        _ address: String
    ) -> HostInterfaceAddressFact {
        HostInterfaceAddressFact(
            interfaceName: name,
            family: .ipv6,
            address: address
        )
    }

    /// Two networks can share en0, the same DNS address and the same
    /// default-route gateway address only by coincidence; a different
    /// gateway is a different attachment even with nothing else changed.
    func testGatewayChangeIsNewEpochAndNewPath() {
        let home = identity()
        let office = identity(routers: HostDefaultRouterFacts(
            ipv4: "192.168.1.254",
            ipv6: "fe80::1"
        ))

        XCTAssertNotEqual(home, office)
        XCTAssertNotEqual(home.epochFingerprint, office.epochFingerprint)
        XCTAssertNotEqual(home.pathIdentity, office.pathIdentity)
        XCTAssertEqual(home.differenceKinds(comparedTo: office), ["gateway"])
    }

    func testIPv6RouterChangeIsGateway() {
        let before = identity()
        let after = identity(routers: HostDefaultRouterFacts(
            ipv4: "192.168.1.1",
            ipv6: "fe80::2"
        ))

        XCTAssertEqual(before.differenceKinds(comparedTo: after), ["gateway"])
        XCTAssertNotEqual(before.pathIdentity, after.pathIdentity)
    }

    func testDefaultInterfaceAddressChangeIsNewEpochAndNewPath() {
        let before = identity()
        let after = identity(addresses: [
            ipv4("en0", "192.168.1.42"),
            ipv6("en0", "fe80::1c80:ff0d:a123:291d"),
        ])

        XCTAssertNotEqual(before.epochFingerprint, after.epochFingerprint)
        XCTAssertNotEqual(before.pathIdentity, after.pathIdentity)
        XCTAssertEqual(before.differenceKinds(comparedTo: after), ["address"])
    }

    /// The DNS-only epoch is the case in which established sockets on the
    /// unchanged default path remain valid.
    func testDNSOnlyChangeIsNewEpochOnTheSamePath() {
        let before = identity()
        let after = identity(dns: "[\"192.168.1.1\",\"1.1.1.1\"]")

        XCTAssertNotEqual(before.epochFingerprint, after.epochFingerprint)
        XCTAssertEqual(before.pathIdentity, after.pathIdentity)
        XCTAssertEqual(
            before.differenceKinds(comparedTo: after),
            ["system-dns"]
        )
    }

    /// RFC 4941 temporary addresses rotate on a stable link and after wake;
    /// they must never make an unchanged network look like a new epoch.
    func testIPv6TemporaryAddressRotationDoesNotChangeIdentity() {
        let before = identity(addresses: [
            ipv4("en0", "192.168.1.23"),
            ipv6("en0", "fe80::1c80:ff0d:a123:291d"),
            ipv6("en0", "2001:db8:1:2:1c80:ff0d:a123:291d"),
            ipv6("en0", "2001:db8:1:2:9d3a:4c1e:77b0:12aa"),
        ])
        let rotated = identity(addresses: [
            ipv4("en0", "192.168.1.23"),
            ipv6("en0", "fe80::1c80:ff0d:a123:291d"),
            ipv6("en0", "2001:db8:1:2:1c80:ff0d:a123:291d"),
            ipv6("en0", "2001:db8:1:2:5e21:8f03:c4d9:e710"),
        ])

        XCTAssertEqual(before, rotated)
        XCTAssertEqual(before.epochFingerprint, rotated.epochFingerprint)
        XCTAssertEqual(before.pathIdentity, rotated.pathIdentity)
        XCTAssertEqual(before.differenceKinds(comparedTo: rotated), [])
    }

    /// A Transparent Proxy creates no interface, no IPv4 / IPv6 service state
    /// and no DNS settings; its only local endpoint is a loopback listener.
    /// Address facts outside the default interface therefore cannot let the
    /// Provider's own start or stop look like a network change.
    func testProviderStartFactsDoNotChangeIdentity() {
        let beforeStart = identity(addresses: [
            ipv4("en0", "192.168.1.23"),
        ])
        let afterStart = identity(addresses: [
            ipv4("lo0", "127.0.0.1"),
            ipv6("lo0", "::1"),
            ipv4("en0", "192.168.1.23"),
            ipv4("bridge100", "192.168.64.1"),
            ipv6("utun4", "fe80::d576:3430:fe0a:5750"),
        ])

        XCTAssertEqual(beforeStart, afterStart)
        XCTAssertEqual(beforeStart.epochFingerprint, afterStart.epochFingerprint)
        XCTAssertEqual(beforeStart.pathIdentity, afterStart.pathIdentity)
    }

    func testEnumerationOrderAndDuplicatesAreNotIdentity() {
        let first = identity(
            interfaces: [wifi, ethernet],
            addresses: [
                ipv4("en0", "10.0.0.2"),
                ipv4("en0", "10.0.0.9"),
            ]
        )
        let second = identity(
            interfaces: [ethernet, wifi],
            addresses: [
                ipv4("en0", "10.0.0.9"),
                ipv4("en0", "10.0.0.2"),
                ipv4("en0", "10.0.0.9"),
            ]
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.epochFingerprint, second.epochFingerprint)
        XCTAssertEqual(first.pathIdentity, second.pathIdentity)
    }

    func testInterfaceSetChangeKeepsDefaultPath() {
        let before = identity(interfaces: [wifi])
        let after = identity(interfaces: [wifi, ethernet])

        XCTAssertEqual(
            before.differenceKinds(comparedTo: after),
            ["interface-set"]
        )
        XCTAssertNotEqual(before.epochFingerprint, after.epochFingerprint)
        XCTAssertEqual(before.pathIdentity, after.pathIdentity)
    }

    func testDefaultInterfaceMoveReportsEveryChangedFact() {
        let wifiNetwork = identity(interfaces: [wifi, ethernet])
        let wiredNetwork = identity(
            defaultInterface: ethernet,
            interfaces: [wifi, ethernet],
            dns: "[\"10.1.0.53\"]",
            addresses: [
                ipv4("en0", "192.168.1.23"),
                ipv4("en7", "10.1.4.20"),
            ],
            routers: HostDefaultRouterFacts(ipv4: "10.1.0.1", ipv6: nil)
        )

        XCTAssertEqual(
            wifiNetwork.differenceKinds(comparedTo: wiredNetwork),
            ["default-interface", "system-dns", "gateway", "address"]
        )
        XCTAssertNotEqual(wifiNetwork.pathIdentity, wiredNetwork.pathIdentity)
    }

    func testRoutersAreCanonicalNumericFacts() {
        let zoned = identity(routers: HostDefaultRouterFacts(
            ipv4: " 192.168.1.1 ",
            ipv6: "FE80:0:0:0::1%en0"
        ))
        let plain = identity()

        XCTAssertEqual(zoned, plain)
        XCTAssertEqual(zoned.ipv6Router, "fe80::1")

        let malformed = identity(routers: HostDefaultRouterFacts(
            ipv4: "router.local",
            ipv6: "not-an-address"
        ))
        XCTAssertNil(malformed.ipv4Router)
        XCTAssertNil(malformed.ipv6Router)
    }

    func testFingerprintIsStableAcrossResamplingOfTheSameFacts() {
        XCTAssertEqual(identity(), identity())
        XCTAssertEqual(identity().epochFingerprint, identity().epochFingerprint)
        XCTAssertEqual(identity().pathIdentity, identity().pathIdentity)
    }

    func testPathIdentityIsOpaqueBoundedToken() {
        let token = identity().pathIdentity

        XCTAssertTrue(HostUnderlayIdentity.isValidPathIdentity(token))
        XCTAssertEqual(token.utf8.count, 81)
        XCTAssertFalse(token.contains("192.168"))
        XCTAssertFalse(token.contains("en0"))
        for invalid in [
            "",
            "underlay-path-v1:",
            "underlay-path-v1:" + String(repeating: "A", count: 64),
            "underlay-path-v2:" + String(repeating: "a", count: 64),
            token + "0",
        ] {
            XCTAssertFalse(
                HostUnderlayIdentity.isValidPathIdentity(invalid),
                invalid
            )
        }
    }
}
