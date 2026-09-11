import Network
import XCTest

final class UDPRelayDatagramCodecTests: XCTestCase {
    private let destination = Network.NWEndpoint.hostPort(
        host: .ipv4(IPv4Address("93.184.216.34")!),
        port: 443
    )

    func testConnectByNameFlowSendsTheHostnameToSOCKS() throws {
        let codec = UDPRelayDatagramCodec()

        let packet = try codec.encode(
            payload: Data([0xaa]),
            destination: destination,
            remoteHostname: "example.com"
        )

        XCTAssertEqual(packet[3], 0x03)
        XCTAssertEqual(Int(packet[4]), Array("example.com".utf8).count)
        XCTAssertEqual(
            packet.subdata(in: 5 ..< 5 + Int(packet[4])),
            Data("example.com".utf8)
        )
    }

    func testDomainReplyIsHandedBackAsTheConcreteEndpoint() throws {
        let codec = UDPRelayDatagramCodec()
        _ = try codec.encode(
            payload: Data([0xaa]),
            destination: destination,
            remoteHostname: "example.com"
        )

        let decoded = try XCTUnwrap(
            codec.decode(
                packet: Self.domainReply(
                    name: "example.com",
                    port: 443,
                    payload: Data([0xbb, 0xcc])
                )
            )
        )

        XCTAssertEqual(decoded.payload, Data([0xbb, 0xcc]))
        XCTAssertEqual(decoded.endpoint, destination)
        guard case let .hostPort(host, _) = decoded.endpoint else {
            return XCTFail("reply must stay an addressable endpoint")
        }
        if case .name = host {
            XCTFail("NEAppProxyUDPFlow rejects a name host")
        }
    }

    func testDomainReplyMatchesTheSentNameCaseInsensitively() throws {
        let codec = UDPRelayDatagramCodec()
        _ = try codec.encode(
            payload: Data([0xaa]),
            destination: destination,
            remoteHostname: "Example.COM"
        )

        let decoded = try XCTUnwrap(
            codec.decode(
                packet: Self.domainReply(
                    name: "example.com",
                    port: 443,
                    payload: Data([0xbb])
                )
            )
        )

        XCTAssertEqual(decoded.endpoint, destination)
    }

    func testUnknownDomainReplyFallsBackToTheFlowDestination() throws {
        let codec = UDPRelayDatagramCodec()
        _ = try codec.encode(
            payload: Data([0xaa]),
            destination: destination,
            remoteHostname: "example.com"
        )

        let decoded = try XCTUnwrap(
            codec.decode(
                packet: Self.domainReply(
                    name: "cdn.example.net",
                    port: 443,
                    payload: Data([0xbb])
                )
            )
        )

        XCTAssertEqual(decoded.endpoint, destination)
    }

    func testDomainReplyWithoutAnyKnownDestinationIsDropped() throws {
        let codec = UDPRelayDatagramCodec()

        XCTAssertNil(
            try codec.decode(
                packet: Self.domainReply(
                    name: "example.com",
                    port: 443,
                    payload: Data([0xbb])
                )
            )
        )
    }

    func testAddressRepliesKeepTheirOwnEndpoint() throws {
        let codec = UDPRelayDatagramCodec()

        var ipv4 = Data([0x00, 0x00, 0x00, 0x01])
        ipv4.append(IPv4Address("1.2.3.4")!.rawValue)
        ipv4.append(contentsOf: [0x00, 0x35])
        ipv4.append(Data([0xde]))
        let decodedIPv4 = try XCTUnwrap(codec.decode(packet: ipv4))
        XCTAssertEqual(
            decodedIPv4.endpoint,
            .hostPort(host: .ipv4(IPv4Address("1.2.3.4")!), port: 53)
        )

        var ipv6 = Data([0x00, 0x00, 0x00, 0x04])
        ipv6.append(IPv6Address("2606:4700::1111")!.rawValue)
        ipv6.append(contentsOf: [0x00, 0x35])
        ipv6.append(Data([0xde]))
        let decodedIPv6 = try XCTUnwrap(codec.decode(packet: ipv6))
        XCTAssertEqual(
            decodedIPv6.endpoint,
            .hostPort(host: .ipv6(IPv6Address("2606:4700::1111")!), port: 53)
        )
    }

    func testDNSFlowPreservesResolverEndpointAndQueryAcrossTheCodec() throws {
        // A DNS flow's remoteHostname describes the queried name. Even after
        // extracting the UDP codec from the relay, the SOCKS header must keep
        // the original resolver and the DNS query must remain byte-for-byte.
        let query = Data([
            0x12, 0x34, 0x01, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x07, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65,
            0x03, 0x63, 0x6f, 0x6d, 0x00, 0x00, 0x01, 0x00, 0x01,
        ])
        let resolvers: [(Network.NWEndpoint.Host, UInt8, Data)] = [
            (.ipv4(IPv4Address("192.0.2.53")!), 0x01,
             IPv4Address("192.0.2.53")!.rawValue),
            (.ipv6(IPv6Address("2001:db8::53")!), 0x04,
             IPv6Address("2001:db8::53")!.rawValue),
        ]

        for (host, addressType, addressBytes) in resolvers {
            let codec = UDPRelayDatagramCodec()
            let resolver = Network.NWEndpoint.hostPort(host: host, port: 53)
            let packet = try codec.encode(
                payload: query,
                destination: resolver,
                remoteHostname: "example.com"
            )
            var expected = Data([0x00, 0x00, 0x00, addressType])
            expected.append(addressBytes)
            expected.append(contentsOf: [0x00, 0x35])
            expected.append(query)
            XCTAssertEqual(packet, expected)

            let decoded = try XCTUnwrap(codec.decode(packet: packet))
            XCTAssertEqual(decoded.endpoint, resolver)
            XCTAssertEqual(decoded.payload, query)
        }
    }

    func testFragmentedAndMalformedPacketsAreRejected() {
        let codec = UDPRelayDatagramCodec()

        XCTAssertThrowsError(
            try codec.decode(
                packet: Data([0x00, 0x00, 0x01, 0x01, 1, 2, 3, 4, 0x00, 0x35])
            )
        ) { error in
            XCTAssertEqual(
                error as? UDPRelayDatagramError,
                .fragmentedDatagram
            )
        }
        XCTAssertThrowsError(
            try codec.decode(packet: Data([0x00, 0x00, 0x00]))
        )
    }

    private static func domainReply(
        name: String,
        port: UInt16,
        payload: Data
    ) -> Data {
        var packet = Data([0x00, 0x00, 0x00, 0x03])
        let raw = Array(name.utf8)
        packet.append(UInt8(raw.count))
        packet.append(contentsOf: raw)
        packet.append(UInt8(port >> 8))
        packet.append(UInt8(port & 0xff))
        packet.append(payload)
        return packet
    }
}
