import Network
import XCTest

/// Drives `RelayStreamConnection` over a real Unix stream socket against an
/// entry that speaks the wire format independently.
final class RelayStreamConnectionTests: XCTestCase {
    func testSendsFramedBytesAndAnExplicitFinish() async throws {
        let seen = FrameLog()
        let entry = try RelaySocketTestEntry { peer in
            while let frame = peer.readFrame() {
                seen.append(frame)
                if frame == .finish {
                    break
                }
            }
            seen.close()
        }
        defer { entry.stop() }

        let connection = RelayStreamConnection(socketPath: entry.path)
        defer { connection.cancel(with: CancellationError()) }
        try await connection.start()
        try await connection.send(Data("hello".utf8))
        try await connection.send(Data())
        try await connection.sendDatagram(Data("datagram".utf8))
        try await connection.finishSending()
        try await connection.finishSending()

        let frames = await seen.all()
        XCTAssertEqual(
            frames,
            [.data(Data("hello".utf8)), .data(Data("datagram".utf8)), .finish],
            "an empty send writes nothing and a second finish is a no-op"
        )
    }

    func testReceivesStreamUntilTheEntryFinishes() async throws {
        let entry = try RelaySocketTestEntry { peer in
            // One frame in two writes, then two frames in one write.
            let wire = Data([0x01, 0x00, 0x00, 0x05]) + Data("hello".utf8)
            peer.writeRaw(wire.prefix(6))
            Thread.sleep(forTimeInterval: 0.05)
            peer.writeRaw(wire.dropFirst(6))
            peer.writeRaw(
                Data([0x01, 0x00, 0x00, 0x01, 0x21, 0x02, 0x00, 0x00, 0x00])
            )
            _ = peer.readFrame()
        }
        defer { entry.stop() }

        let connection = RelayStreamConnection(socketPath: entry.path)
        defer { connection.cancel(with: CancellationError()) }
        try await connection.start()
        var received = Data()
        while let bytes = try await connection.receive() {
            received.append(bytes)
        }
        XCTAssertEqual(received, Data("hello!".utf8))
        let again = try await connection.receive()
        XCTAssertNil(again, "a finished stream stays finished")
    }

    /// What a TCP reset used to report: the stream stopped, and nobody said it
    /// was done.
    func testAStreamThatEndsWithoutFinishIsAReset() async throws {
        let cuts: [(String, Data)] = [
            ("at a frame boundary", Data()),
            ("inside a header", Data([0x01, 0x00])),
            ("inside a payload", Data([0x01, 0x00, 0x00, 0x09, 0x61])),
        ]
        for (name, tail) in cuts {
            let entry = try RelaySocketTestEntry { peer in
                peer.writeData(Data("partial".utf8))
                peer.writeRaw(tail)
                peer.close()
            }
            defer { entry.stop() }

            let connection = RelayStreamConnection(socketPath: entry.path)
            defer { connection.cancel(with: CancellationError()) }
            try await connection.start()
            let first = try await connection.receive()
            XCTAssertEqual(
                first, Data("partial".utf8),
                "bytes sent before the cut still arrive: \(name)"
            )
            do {
                _ = try await connection.receive()
                XCTFail("a cut stream was reported as a clean end: \(name)")
            } catch let error as NWError {
                XCTAssertEqual(error, .posix(.ECONNRESET), name)
                XCTAssertEqual(
                    AppProxyFlowCloseError.normalize(error)?.code,
                    AppProxyFlowCloseError.normalize(
                        NWError.posix(.ECONNRESET)
                    )?.code
                )
            }
        }
    }

    func testMalformedStreamIsAnErrorNotAnEnd() async throws {
        let entry = try RelaySocketTestEntry { peer in
            peer.writeRaw(Data([0x05, 0x00, 0x00, 0x00]))
            _ = peer.readFrame()
        }
        defer { entry.stop() }

        let connection = RelayStreamConnection(socketPath: entry.path)
        defer { connection.cancel(with: CancellationError()) }
        try await connection.start()
        do {
            _ = try await connection.receive()
            XCTFail("an unframed stream was accepted")
        } catch {
            XCTAssertEqual(error as? RelayStreamFrameError, .malformed)
        }
    }

    func testHandshakeReadsCrossFrameBoundariesAndKeepTheRest() async throws {
        let entry = try RelaySocketTestEntry { peer in
            peer.writeData(Data([0x01, 0x02, 0x03]))
            peer.writeData(Data([0x04, 0x05]))
            peer.writeData(Data([0x06]))
            peer.writeFinish()
            _ = peer.readFrame()
        }
        defer { entry.stop() }

        let connection = RelayStreamConnection(socketPath: entry.path)
        defer { connection.cancel(with: CancellationError()) }
        try await connection.start()
        let head = try await connection.receiveExactly(2)
        XCTAssertEqual(head, Data([0x01, 0x02]))
        let middle = try await connection.receiveExactly(2)
        XCTAssertEqual(middle, Data([0x03, 0x04]))
        let rest = try await connection.receive()
        XCTAssertEqual(rest, Data([0x05]), "bytes left in a frame are not lost")
        let next = try await connection.receive()
        XCTAssertEqual(next, Data([0x06]))
        do {
            _ = try await connection.receiveExactly(1)
            XCTFail("a handshake read past the end of the stream succeeded")
        } catch {
            XCTAssertEqual(
                error as? RelayStreamConnectionError, .unavailable
            )
        }
    }

    func testDatagramsKeepTheirBoundaries() async throws {
        let largest = Data(
            (0..<65_769).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        )
        let entry = try RelaySocketTestEntry { peer in
            // Echo datagram for datagram.
            while case let .data(datagram)? = peer.readFrame() {
                peer.writeData(datagram)
            }
        }
        defer { entry.stop() }

        let connection = RelayStreamConnection(socketPath: entry.path)
        defer { connection.cancel(with: CancellationError()) }
        try await connection.start()
        for datagram in [Data("a".utf8), Data("bc".utf8), largest] {
            try await connection.sendDatagram(datagram)
        }
        for expected in [Data("a".utf8), Data("bc".utf8), largest] {
            let datagram = try await connection.receiveFrame()
            XCTAssertEqual(datagram, expected)
        }
        do {
            try await connection.sendDatagram(
                Data(count: RelayStreamFrame.maximumPayloadLength + 1)
            )
            XCTFail("an oversized datagram was sent")
        } catch let error as NWError {
            XCTAssertEqual(error, .posix(.EMSGSIZE))
        }
    }

    func testCleanCancelFinishesAndFailedCancelCuts() async throws {
        for (failure, expectsFinish) in [
            (nil as Error?, true),
            (CancellationError() as Error?, false),
        ] {
            let seen = FrameLog()
            let entry = try RelaySocketTestEntry { peer in
                while let frame = peer.readFrame() {
                    seen.append(frame)
                }
                seen.close()
            }
            defer { entry.stop() }

            let connection = RelayStreamConnection(socketPath: entry.path)
            try await connection.start()
            try await connection.send(Data("bye".utf8))
            connection.cancel(with: failure)

            let frames = await seen.all()
            XCTAssertEqual(
                frames,
                expectsFinish
                    ? [.data(Data("bye".utf8)), .finish]
                    : [.data(Data("bye".utf8))],
                "the entry must be able to tell a finished flow from a cut one"
            )
        }
    }

    /// The entry lives in this process. If its socket is gone, the flow must
    /// fail now rather than wait for a network change that cannot help.
    func testMissingEntryFailsInsteadOfWaiting() async throws {
        let connection = RelayStreamConnection(
            socketPath: "/tmp/xdial-no-such-relay-\(UUID().uuidString.prefix(8))"
        )
        defer { connection.cancel(with: CancellationError()) }
        let started = Date()
        do {
            try await connection.start()
            XCTFail("connected to a socket that does not exist")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        }
        // Cancelling a connection that never came up must not hang or crash.
        connection.cancel(with: nil)
    }
}

/// Frames an entry saw, readable from the test once the entry is done.
final class FrameLog: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [RelaySocketTestEntry.Frame] = []
    private var closed = false
    private var waiter: CheckedContinuation<[RelaySocketTestEntry.Frame], Never>?

    func append(_ frame: RelaySocketTestEntry.Frame) {
        lock.lock()
        frames.append(frame)
        lock.unlock()
    }

    func close() {
        lock.lock()
        closed = true
        let pending = waiter
        waiter = nil
        let snapshot = frames
        lock.unlock()
        pending?.resume(returning: snapshot)
    }

    func all() async -> [RelaySocketTestEntry.Frame] {
        await withCheckedContinuation { continuation in
            lock.lock()
            if closed {
                let snapshot = frames
                lock.unlock()
                continuation.resume(returning: snapshot)
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }
}
