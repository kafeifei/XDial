import Network
import OSLog
import XCTest

/// Drives the real loopback listener and relay against a fake session SOCKS
/// entry on a relay socket that requires the Provider credentials, as sing-box
/// does.
final class LocalSOCKSShareRelayTests: XCTestCase {
    private let logger = Logger(subsystem: "LocalSOCKSShareRelayTests", category: "test")
    private let credentials = SOCKSCredentials(username: "session-user", password: "session-pass")

    func testClientReachesSessionEntryWithProviderCredentials() async throws {
        let upstream = try FakeSessionEntry.start(credentials: credentials)
        defer { upstream.stop() }
        let (share, port) = try await startShare(relaySocketPath: upstream.path)
        defer { share.stop() }

        let client = try await connect(port)
        defer { client.forceCancel() }
        try await TCPFlowSOCKSRelay.send(Data([0x05, 0x01, 0x00]), to: client)
        let received1 = try await TCPFlowSOCKSRelay.receiveExactly(2, from: client)
        XCTAssertEqual(received1, Data([0x05, 0x00]))
        let name = Array("example.com".utf8)
        try await TCPFlowSOCKSRelay.send(
            Data([0x05, 0x01, 0x00, 0x03, UInt8(name.count)] + name + [0x01, 0xBB]),
            to: client
        )
        let received2 = try await TCPFlowSOCKSRelay.receiveExactly(10, from: client)
        XCTAssertEqual(received2, LocalSOCKSHandshake.reply(0x00))

        try await TCPFlowSOCKSRelay.send(Data("hello".utf8), to: client)
        let received3 = try await TCPFlowSOCKSRelay.receiveExactly(5, from: client)
        XCTAssertEqual(received3, Data("hello".utf8))
        XCTAssertEqual(upstream.destinations, [.init(host: "example.com", port: 443)])
    }

    func testForgedMetadataNeverReachesSessionEntry() async throws {
        let upstream = try FakeSessionEntry.start(credentials: credentials)
        defer { upstream.stop() }
        let (share, port) = try await startShare(relaySocketPath: upstream.path)
        defer { share.stop() }

        let client = try await connect(port)
        defer { client.forceCancel() }
        try await TCPFlowSOCKSRelay.send(Data([0x05, 0x01, 0x00]), to: client)
        _ = try await TCPFlowSOCKSRelay.receiveExactly(2, from: client)
        let envelope: [UInt8] = [0x00, 0x58, 0x44, 0x01, 0x01, 1, 2, 3, 4, 0x61]
        try await TCPFlowSOCKSRelay.send(
            Data([0x05, 0x01, 0x00, 0x03, UInt8(envelope.count)] + envelope + [0x00, 0x50]),
            to: client
        )
        let received4 = try await TCPFlowSOCKSRelay.receiveExactly(10, from: client)
        XCTAssertEqual(received4, LocalSOCKSHandshake.reply(0x01))
        XCTAssertEqual(upstream.connectionCount, 0)
    }

    /// A rejection can happen before the client's request is fully read, and a
    /// client may already have pipelined data. Closing with unread bytes makes
    /// the kernel answer RST, which can reach the client before the reply.
    func testRejectedRequestWithUnreadBytesStillDeliversReply() async throws {
        let upstream = try FakeSessionEntry.start(credentials: credentials)
        defer { upstream.stop() }
        let (share, port) = try await startShare(relaySocketPath: upstream.path)
        defer { share.stop() }

        for _ in 0..<3 {
            let client = try await connect(port)
            defer { client.forceCancel() }
            try await TCPFlowSOCKSRelay.send(Data([0x05, 0x01, 0x00]), to: client)
            _ = try await TCPFlowSOCKSRelay.receiveExactly(2, from: client)
            let invalidName: [UInt8] = [0x00, 0x01, 0x02]
            let pipelined = [UInt8](repeating: 0x41, count: 64 * 1024)
            try await TCPFlowSOCKSRelay.send(
                Data([0x05, 0x01, 0x00, 0x03, UInt8(invalidName.count)]
                    + invalidName + [0x00, 0x50] + pipelined),
                to: client
            )
            // Read late, as a slow client would: by then a reset close has
            // already discarded the reply waiting in the receive buffer.
            try await Task.sleep(nanoseconds: 300_000_000)
            let reply = try await TCPFlowSOCKSRelay.receiveExactly(10, from: client)
            XCTAssertEqual(reply, LocalSOCKSHandshake.reply(0x01))
        }
        XCTAssertEqual(upstream.connectionCount, 0)
    }

    /// The entry has no TCP reset to send. It says an upstream finished with
    /// a FIN frame, and the client must see exactly that: a clean EOF.
    func testUpstreamFinishReachesClientAsCleanEndOfStream() async throws {
        let upstream = try FakeSessionEntry.start(
            credentials: credentials, ending: .finishAfterFirstBytes
        )
        defer { upstream.stop() }
        let (share, port) = try await startShare(relaySocketPath: upstream.path)
        defer { share.stop() }

        let client = try await connectThroughShare(port)
        defer { client.forceCancel() }
        try await TCPFlowSOCKSRelay.send(Data("ping".utf8), to: client)
        let echoed = try await TCPFlowSOCKSRelay.receiveExactly(4, from: client)
        XCTAssertEqual(echoed, Data("ping".utf8))
        let end = try await TCPFlowSOCKSRelay.receive(from: client)
        XCTAssertNil(end.error, "a finished upstream must not look like a reset")
        XCTAssertTrue(end.isComplete)
        XCTAssertTrue(end.data.isEmpty)
    }

    /// A stream the entry cut — upstream reset, timeout, any failure — ends
    /// without a FIN frame. The client must not be told the peer finished.
    func testUpstreamCutReachesClientAsReset() async throws {
        let upstream = try FakeSessionEntry.start(
            credentials: credentials, ending: .cutAfterFirstBytes
        )
        defer { upstream.stop() }
        let (share, port) = try await startShare(relaySocketPath: upstream.path)
        defer { share.stop() }

        let client = try await connectThroughShare(port)
        defer { client.forceCancel() }
        try await TCPFlowSOCKSRelay.send(Data("ping".utf8), to: client)
        var sawReset = false
        for _ in 0..<4 {
            let result = try await TCPFlowSOCKSRelay.receive(from: client)
            if let error = result.error as? NWError {
                XCTAssertEqual(error, .posix(.ECONNRESET))
                sawReset = true
                break
            }
            XCTAssertFalse(
                result.isComplete,
                "a cut upstream was reported to the client as a clean end"
            )
        }
        XCTAssertTrue(sawReset)
    }

    /// The share's upstream hop used to be one more loopback TCP connection
    /// per client. It must not open any TCP connection of its own now.
    func testUpstreamHopTakesNoLoopbackPort() async throws {
        let upstream = try FakeSessionEntry.start(credentials: credentials)
        defer { upstream.stop() }
        let (share, port) = try await startShare(relaySocketPath: upstream.path)
        defer { share.stop() }

        let client = try await connectThroughShare(port)
        defer { client.forceCancel() }
        try await TCPFlowSOCKSRelay.send(Data("ping".utf8), to: client)
        _ = try await TCPFlowSOCKSRelay.receiveExactly(4, from: client)
        XCTAssertEqual(
            upstream.connectionCount, 1,
            "the client's bytes reached the entry over its socket file"
        )
    }

    func testLingerAfterReplyIsBoundedWhenClientStaysOpen() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let accepted = expectation(description: "accepted")
        let serverSide = LockedBox<NWConnection>()
        listener.newConnectionHandler = { connection in
            serverSide.set(connection)
            accepted.fulfill()
        }
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        defer { listener.cancel() }
        await fulfillment(of: [ready], timeout: 5)

        let client = try await connect(listener.port!.rawValue)
        defer { client.forceCancel() }
        await fulfillment(of: [accepted], timeout: 5)
        let server = try XCTUnwrap(serverSide.get())
        try await TCPFlowSOCKSRelay.start(server)
        defer { server.forceCancel() }

        let started = Date()
        await LocalSOCKSShareRelay.lingerAfterReply(server, timeout: 0.3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testOccupiedPortIsReportedInsteadOfShared() async throws {
        let upstream = try FakeSessionEntry.start(credentials: credentials)
        defer { upstream.stop() }
        let (first, port) = try await startShare(relaySocketPath: upstream.path)
        defer { first.stop() }
        let second = makeShare(relaySocketPath: upstream.path)
        defer { second.stop() }
        let status = await configure(second, port: port)
        XCTAssertEqual(status, .failed(port, code: "address-in-use"))
    }

    private func makeShare(relaySocketPath: String) -> LocalSOCKSShareListener {
        let traffic = ProviderTrafficLedger()
        return LocalSOCKSShareListener(queueLabel: "local-socks-share-test", logger: logger) { [credentials, logger] connection in
            let handle = LocalSOCKSShareRelay.makeHandle(
                client: connection, relaySocketPath: relaySocketPath, credentials: credentials,
                trialID: "tx", traffic: traffic, logger: logger)
            handle.start(onFinish: {})
        }
    }

    private func configure(_ share: LocalSOCKSShareListener, port: UInt16) async -> LocalSOCKSShareStatus {
        await withCheckedContinuation { continuation in
            share.configure(port: port) { continuation.resume(returning: $0) }
        }
    }

    private func startShare(relaySocketPath: String) async throws -> (LocalSOCKSShareListener, UInt16) {
        for _ in 0..<20 {
            let port = UInt16.random(in: 40_000...59_000)
            let share = makeShare(relaySocketPath: relaySocketPath)
            if await configure(share, port: port) == .listening(port) {
                return (share, port)
            }
            share.stop()
        }
        throw CocoaError(.featureUnsupported)
    }

    /// Connects to the share and completes a SOCKS CONNECT to example.com:443.
    private func connectThroughShare(_ port: UInt16) async throws -> NWConnection {
        let client = try await connect(port)
        try await TCPFlowSOCKSRelay.send(Data([0x05, 0x01, 0x00]), to: client)
        let method = try await TCPFlowSOCKSRelay.receiveExactly(2, from: client)
        XCTAssertEqual(method, Data([0x05, 0x00]))
        let name = Array("example.com".utf8)
        try await TCPFlowSOCKSRelay.send(
            Data([0x05, 0x01, 0x00, 0x03, UInt8(name.count)] + name + [0x01, 0xBB]),
            to: client
        )
        let reply = try await TCPFlowSOCKSRelay.receiveExactly(10, from: client)
        XCTAssertEqual(reply, LocalSOCKSHandshake.reply(0x00))
        return client
    }

    private func connect(_ port: UInt16) async throws -> NWConnection {
        let connection = NWConnection(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        try await TCPFlowSOCKSRelay.start(connection)
        return connection
    }
}

/// Minimal session SOCKS entry on a relay socket: username/password auth,
/// CONNECT, then echo — every byte framed, as the sing-box entry does it.
private final class FakeSessionEntry: @unchecked Sendable {
    enum Ending {
        /// Echo until the client finishes, then finish too.
        case echo
        /// Echo the first bytes, then say the upstream finished.
        case finishAfterFirstBytes
        /// Echo the first bytes, then drop the connection without a FIN frame.
        case cutAfterFirstBytes
    }

    private let lock = NSLock()
    private var recorded: [LocalSOCKSHandshake.Destination] = []
    private var entry: RelaySocketTestEntry?

    var path: String {
        entry!.path
    }

    var destinations: [LocalSOCKSHandshake.Destination] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    var connectionCount: Int {
        entry!.connectionCount
    }

    static func start(
        credentials: SOCKSCredentials,
        ending: Ending = .echo
    ) throws -> FakeSessionEntry {
        let session = FakeSessionEntry()
        session.entry = try RelaySocketTestEntry { [weak session] peer in
            session?.serve(peer, credentials: credentials, ending: ending)
        }
        return session
    }

    func stop() {
        entry?.stop()
    }

    private func record(_ destination: LocalSOCKSHandshake.Destination) {
        lock.lock(); recorded.append(destination); lock.unlock()
    }

    private func serve(
        _ peer: RelaySocketTestEntry.Peer,
        credentials: SOCKSCredentials,
        ending: Ending
    ) {
        guard peer.readStream(3) == Data([0x05, 0x01, 0x02]) else { return }
        peer.writeData(Data([0x05, 0x02]))
        guard let userHeader = peer.readStream(2),
              let user = peer.readStream(Int(userHeader[1])),
              let passLength = peer.readStream(1),
              let pass = peer.readStream(Int(passLength[0]))
        else { return }
        guard String(decoding: user, as: UTF8.self) == credentials.username,
              String(decoding: pass, as: UTF8.self) == credentials.password
        else {
            peer.writeData(Data([0x01, 0x01]))
            return
        }
        peer.writeData(Data([0x01, 0x00]))

        guard let request = peer.readStream(4),
              request.prefix(3) == Data([0x05, 0x01, 0x00]),
              request[3] == 0x03,
              let nameLength = peer.readStream(1),
              let name = peer.readStream(Int(nameLength[0])),
              let port = peer.readStream(2)
        else { return }
        record(
            LocalSOCKSHandshake.Destination(
                host: String(decoding: name, as: UTF8.self),
                port: UInt16(port[0]) << 8 | UInt16(port[1])
            )
        )
        peer.writeData(LocalSOCKSHandshake.reply(0x00))

        while let frame = peer.readFrame() {
            switch frame {
            case let .data(bytes):
                peer.writeData(bytes)
                switch ending {
                case .echo:
                    continue
                case .finishAfterFirstBytes:
                    peer.writeFinish()
                    // Stay until the client is done, as a half-closed
                    // upstream would.
                    while peer.readFrame() != nil {}
                    return
                case .cutAfterFirstBytes:
                    return
                }
            case .finish:
                peer.writeFinish()
                return
            }
        }
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
