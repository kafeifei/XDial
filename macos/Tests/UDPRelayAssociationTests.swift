import Network
import XCTest

/// A SOCKS UDP association used to cost a loopback TCP control connection and
/// a UDP port on each side. On the relay socket it costs neither: the
/// datagrams follow the handshake on the same connection.
final class UDPRelayAssociationTests: XCTestCase {
    private let credentials = SOCKSCredentials(
        username: "session-user", password: "session-pass"
    )

    func testDatagramsFollowTheHandshakeOnTheSameConnection() async throws {
        let requests = RequestLog()
        let entry = try RelaySocketTestEntry { [credentials] peer in
            guard Self.authenticate(peer, credentials: credentials),
                  let request = peer.readStream(10)
            else { return }
            requests.set(request)
            // No relay endpoint: 0.0.0.0:0.
            peer.writeData(Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
            while case let .data(datagram)? = peer.readFrame() {
                peer.writeData(datagram)
            }
        }
        defer { entry.stop() }

        let control = RelayStreamConnection(socketPath: entry.path)
        defer { control.cancel(with: CancellationError()) }
        try await control.start()
        try await UDPFlowSOCKSRelay.associateUDP(
            control, credentials: credentials, boundInterface: nil
        )
        XCTAssertEqual(
            requests.get(),
            Data([0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        )

        let codec = UDPRelayDatagramCodec()
        let destination = NWEndpoint.hostPort(host: "192.0.2.53", port: 53)
        for payload in [Data("first".utf8), Data("second".utf8)] {
            let packet = try codec.encode(
                payload: payload, destination: destination, remoteHostname: nil
            )
            try await control.sendDatagram(packet)
            let reply = try await control.receiveFrame()
            let decoded = try codec.decode(packet: try XCTUnwrap(reply))
            XCTAssertEqual(decoded?.payload, payload)
            XCTAssertEqual(decoded?.endpoint, destination)
        }
    }

    func testBoundFlowKeepsItsInterfaceEnvelope() async throws {
        let requests = RequestLog()
        let entry = try RelaySocketTestEntry { [credentials] peer in
            guard Self.authenticate(peer, credentials: credentials),
                  let head = peer.readStream(5),
                  let rest = peer.readStream(Int(head[4]) + 2)
            else { return }
            requests.set(head + rest)
            peer.writeData(Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
            _ = peer.readFrame()
        }
        defer { entry.stop() }

        let control = RelayStreamConnection(socketPath: entry.path)
        defer { control.cancel(with: CancellationError()) }
        try await control.start()
        try await UDPFlowSOCKSRelay.associateUDP(
            control, credentials: credentials, boundInterface: "en0"
        )
        let envelope = try XCTUnwrap(
            TransparentProxyFlowMetadata.encodeBoundAssociation(
                boundInterface: "en0"
            )
        )
        XCTAssertEqual(
            requests.get(),
            Data([0x05, 0x03, 0x00, 0x03, UInt8(envelope.count)])
                + envelope + Data([0x00, 0x00])
        )
    }

    /// An entry that names a UDP port expects datagrams on a socket this side
    /// must not open. Refusing keeps the two ends from silently disagreeing.
    func testAnEntryThatAnnouncesARelayPortIsRefused() async throws {
        let entry = try RelaySocketTestEntry { [credentials] peer in
            guard Self.authenticate(peer, credentials: credentials),
                  peer.readStream(10) != nil
            else { return }
            peer.writeData(
                Data([0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0xC0, 0x01])
            )
            _ = peer.readFrame()
        }
        defer { entry.stop() }

        let control = RelayStreamConnection(socketPath: entry.path)
        defer { control.cancel(with: CancellationError()) }
        try await control.start()
        do {
            try await UDPFlowSOCKSRelay.associateUDP(
                control, credentials: credentials, boundInterface: nil
            )
            XCTFail("accepted an association with a UDP relay endpoint")
        } catch UDPFlowSOCKSRelay.RelayError.socksProtocol {
        }
    }

    func testAssociationEndsWhenItsConnectionIsCut() async throws {
        let entry = try RelaySocketTestEntry { [credentials] peer in
            guard Self.authenticate(peer, credentials: credentials),
                  peer.readStream(10) != nil
            else { return }
            peer.writeData(Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
            peer.close()
        }
        defer { entry.stop() }

        let control = RelayStreamConnection(socketPath: entry.path)
        defer { control.cancel(with: CancellationError()) }
        try await control.start()
        try await UDPFlowSOCKSRelay.associateUDP(
            control, credentials: credentials, boundInterface: nil
        )
        do {
            _ = try await control.receiveFrame()
            XCTFail("a dead association still delivered a datagram")
        } catch let error as NWError {
            XCTAssertEqual(error, .posix(.ECONNRESET))
        }
    }

    private static func authenticate(
        _ peer: RelaySocketTestEntry.Peer,
        credentials: SOCKSCredentials
    ) -> Bool {
        guard peer.readStream(3) == Data([0x05, 0x01, 0x02]) else {
            return false
        }
        peer.writeData(Data([0x05, 0x02]))
        guard let userHeader = peer.readStream(2),
              let user = peer.readStream(Int(userHeader[1])),
              let passLength = peer.readStream(1),
              let pass = peer.readStream(Int(passLength[0])),
              String(decoding: user, as: UTF8.self) == credentials.username,
              String(decoding: pass, as: UTF8.self) == credentials.password
        else {
            return false
        }
        peer.writeData(Data([0x01, 0x00]))
        return true
    }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?

    func set(_ data: Data) {
        lock.lock()
        value = data
        lock.unlock()
    }

    func get() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
