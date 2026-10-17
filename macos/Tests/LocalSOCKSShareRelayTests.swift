import Network
import OSLog
import XCTest

/// Drives the real loopback listener and relay against a fake session SOCKS
/// entry that requires the Provider credentials, as sing-box does.
final class LocalSOCKSShareRelayTests: XCTestCase {
    private let logger = Logger(subsystem: "LocalSOCKSShareRelayTests", category: "test")
    private let credentials = SOCKSCredentials(username: "session-user", password: "session-pass")

    func testClientReachesSessionEntryWithProviderCredentials() async throws {
        let upstream = try await FakeSessionEntry.start(credentials: credentials)
        defer { upstream.stop() }
        let (share, port) = try await startShare(upstreamPort: upstream.port)
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
        let upstream = try await FakeSessionEntry.start(credentials: credentials)
        defer { upstream.stop() }
        let (share, port) = try await startShare(upstreamPort: upstream.port)
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
        let upstream = try await FakeSessionEntry.start(credentials: credentials)
        defer { upstream.stop() }
        let (share, port) = try await startShare(upstreamPort: upstream.port)
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
        let upstream = try await FakeSessionEntry.start(credentials: credentials)
        defer { upstream.stop() }
        let (first, port) = try await startShare(upstreamPort: upstream.port)
        defer { first.stop() }
        let second = makeShare(upstreamPort: upstream.port)
        defer { second.stop() }
        let status = await configure(second, port: port)
        XCTAssertEqual(status, .failed(port, code: "address-in-use"))
    }

    private func makeShare(upstreamPort: UInt16) -> LocalSOCKSShareListener {
        let traffic = ProviderTrafficLedger()
        return LocalSOCKSShareListener(queueLabel: "local-socks-share-test", logger: logger) { [credentials, logger] connection in
            let handle = LocalSOCKSShareRelay.makeHandle(
                client: connection, socksPort: upstreamPort, credentials: credentials,
                trialID: "tx", traffic: traffic, logger: logger)
            handle.start(onFinish: {})
        }
    }

    private func configure(_ share: LocalSOCKSShareListener, port: UInt16) async -> LocalSOCKSShareStatus {
        await withCheckedContinuation { continuation in
            share.configure(port: port) { continuation.resume(returning: $0) }
        }
    }

    private func startShare(upstreamPort: UInt16) async throws -> (LocalSOCKSShareListener, UInt16) {
        for _ in 0..<20 {
            let port = UInt16.random(in: 40_000...59_000)
            let share = makeShare(upstreamPort: upstreamPort)
            if await configure(share, port: port) == .listening(port) {
                return (share, port)
            }
            share.stop()
        }
        throw CocoaError(.featureUnsupported)
    }

    private func connect(_ port: UInt16) async throws -> NWConnection {
        let connection = NWConnection(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        try await TCPFlowSOCKSRelay.start(connection)
        return connection
    }
}

/// Minimal session SOCKS entry: username/password auth, CONNECT, then echo.
private final class FakeSessionEntry: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var recorded: [LocalSOCKSHandshake.Destination] = []
    private var accepted = 0
    let port: UInt16

    var destinations: [LocalSOCKSHandshake.Destination] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    var connectionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return accepted
    }

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start(credentials: SOCKSCredentials) async throws -> FakeSessionEntry {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.take() { continuation.resume(returning: listener.port!.rawValue) }
                case let .failed(error):
                    if once.take() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { _ in }
            listener.start(queue: .global())
        }
        let entry = FakeSessionEntry(listener: listener, port: port)
        listener.newConnectionHandler = { connection in
            Task { await entry.serve(connection, credentials: credentials) }
        }
        return entry
    }

    func stop() {
        listener.cancel()
    }

    private func noteAccepted() {
        lock.lock(); accepted += 1; lock.unlock()
    }

    private func record(_ destination: LocalSOCKSHandshake.Destination) {
        lock.lock(); recorded.append(destination); lock.unlock()
    }

    private func serve(_ connection: NWConnection, credentials: SOCKSCredentials) async {
        noteAccepted()
        do {
            try await TCPFlowSOCKSRelay.start(connection)
            let read: LocalSOCKSHandshake.Read = { try await TCPFlowSOCKSRelay.receiveExactly($0, from: connection) }
            guard try await read(3) == Data([0x05, 0x01, 0x02]) else { throw CocoaError(.coderInvalidValue) }
            try await TCPFlowSOCKSRelay.send(Data([0x05, 0x02]), to: connection)
            let user = try await read(Int(try await read(2).last!))
            let pass = try await read(Int(try await read(1).first!))
            guard String(decoding: user, as: UTF8.self) == credentials.username,
                  String(decoding: pass, as: UTF8.self) == credentials.password else {
                try await TCPFlowSOCKSRelay.send(Data([0x01, 0x01]), to: connection)
                throw CocoaError(.coderInvalidValue)
            }
            try await TCPFlowSOCKSRelay.send(Data([0x01, 0x00]), to: connection)
            let destination = try await LocalSOCKSHandshake.readRequest(read)
            record(destination)
            try await TCPFlowSOCKSRelay.send(LocalSOCKSHandshake.reply(0x00), to: connection)
            while true {
                let result = try await TCPFlowSOCKSRelay.receive(from: connection)
                if !result.data.isEmpty {
                    try await TCPFlowSOCKSRelay.send(result.data, to: connection)
                }
                if result.isComplete || result.error != nil || result.data.isEmpty { break }
            }
        } catch {}
        connection.forceCancel()
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !taken else { return false }
        taken = true
        return true
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
