import Foundation
import Network

enum RelayStreamConnectionError: Error, Equatable {
    /// The entry is not there, or it stopped answering mid-handshake.
    case unavailable
}

/// The Provider's end of one relay socket connection to the sing-box entry.
///
/// It speaks `RelayStreamFrame` in both directions. One task may receive while
/// another sends; each direction has a single user at a time.
final class RelayStreamConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var decoder = RelayStreamFrameDecoder()
    /// Stream bytes a handshake read took out of a frame and did not need yet.
    private var backlog = Data()
    /// Why the socket will deliver nothing more.
    private var inputEnd: Error?
    private var started = false
    private var finishSent = false

    init(socketPath: String) {
        connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
    }

    func start() async throws {
        markStarted()
        let connection = self.connection
        let _: Void = try await awaitRelayCallback { completion in
            let gate = RelayStreamOneShot()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.take() {
                        completion(.success(()))
                    }
                // The entry lives in this process. If its socket cannot be
                // reached now, no network change will bring it back, so
                // waiting would only leave the flow hanging without an error.
                case let .failed(error), let .waiting(error):
                    if gate.take() {
                        completion(.failure(error))
                    }
                case .cancelled:
                    if gate.take() {
                        completion(
                            .failure(RelayStreamConnectionError.unavailable)
                        )
                    }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    /// Sends a piece of a byte stream.
    func send(_ bytes: Data) async throws {
        guard !bytes.isEmpty else {
            return
        }
        try await sendEncoded(RelayStreamFrame.encodeStream(bytes))
    }

    /// Sends one datagram as one frame.
    func sendDatagram(_ datagram: Data) async throws {
        guard let frame = RelayStreamFrame.encodeDatagram(datagram) else {
            throw NWError.posix(.EMSGSIZE)
        }
        try await sendEncoded(frame)
    }

    /// Tells the entry that this direction finished cleanly. The socket stays
    /// open both ways; only the frame carries the meaning.
    func finishSending() async throws {
        guard claimFinish() else {
            return
        }
        try await sendEncoded(RelayStreamFrame.encodedFinish)
    }

    /// Returns the next bytes of the stream, or `nil` once the entry finished
    /// cleanly. A stream cut short throws a connection reset.
    func receive() async throws -> Data? {
        if let pending = takeBacklog(upTo: Int.max) {
            return pending
        }
        return try await receiveFrame()
    }

    func receiveExactly(_ length: Int) async throws -> Data {
        var result = takeBacklog(upTo: length) ?? Data()
        while result.count < length {
            guard let payload = try await receiveFrame() else {
                throw RelayStreamConnectionError.unavailable
            }
            let needed = length - result.count
            if payload.count <= needed {
                result.append(payload)
            } else {
                result.append(payload.prefix(needed))
                keepBacklog(payload.dropFirst(needed))
            }
        }
        return result
    }

    /// Returns the payload of the next frame — one datagram on a UDP
    /// association — or `nil` once the entry finished cleanly.
    func receiveFrame() async throws -> Data? {
        while true {
            let buffered = try nextBuffered()
            switch buffered.frame {
            case let .data(payload):
                return payload
            case .finish:
                return nil
            case nil:
                break
            }
            // Bytes that arrived with the end of the stream were handed out
            // above before the end itself is reported.
            if buffered.finished {
                return nil
            }
            if let end = buffered.inputEnd {
                throw end
            }
            note(try await readChunk())
        }
    }

    /// Ends the connection. Without an error this is a clean end and says so;
    /// with one the stream is cut, and the entry sees it as cut.
    func cancel(with error: Error?) {
        guard RelayConnectionCancellation.mode(for: error) == .graceful else {
            connection.forceCancel()
            return
        }
        lock.lock()
        let canAnnounce = started && !finishSent
        if canAnnounce {
            finishSent = true
        }
        lock.unlock()
        guard canAnnounce else {
            connection.cancel()
            return
        }
        let connection = self.connection
        connection.send(
            content: RelayStreamFrame.encodedFinish,
            completion: .contentProcessed { _ in
                connection.cancel()
            }
        )
    }

    private func readChunk() async throws -> RelayStreamChunk {
        let connection = self.connection
        return try await awaitRelayCallback { completion in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: 64 * 1024
            ) { data, _, isComplete, error in
                completion(
                    .success(
                        RelayStreamChunk(
                            data: data ?? Data(),
                            isComplete: isComplete,
                            error: error
                        )
                    )
                )
            }
        }
    }

    private func nextBuffered() throws -> (
        frame: RelayStreamFrame?,
        finished: Bool,
        inputEnd: Error?
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (try decoder.next(), decoder.finished, inputEnd)
    }

    private func note(_ chunk: RelayStreamChunk) {
        lock.lock()
        defer { lock.unlock() }
        if !chunk.data.isEmpty {
            decoder.append(chunk.data)
        }
        if let error = chunk.error {
            inputEnd = error
        } else if chunk.isComplete {
            // The socket ended. Unless a FIN frame is among the bytes read so
            // far, the stream was cut.
            inputEnd = NWError.posix(.ECONNRESET)
        } else if chunk.data.isEmpty {
            inputEnd = RelayStreamConnectionError.unavailable
        }
    }

    private func sendEncoded(_ frames: Data) async throws {
        let connection = self.connection
        let _: Void = try await awaitRelayCallback { completion in
            connection.send(
                content: frames,
                completion: .contentProcessed { error in
                    if let error {
                        completion(.failure(error))
                    } else {
                        completion(.success(()))
                    }
                }
            )
        }
    }

    private func markStarted() {
        lock.lock()
        started = true
        lock.unlock()
    }

    private func keepBacklog(_ bytes: Data) {
        lock.lock()
        backlog.append(bytes)
        lock.unlock()
    }

    private func claimFinish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finishSent else {
            return false
        }
        finishSent = true
        return true
    }

    private func takeBacklog(upTo length: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !backlog.isEmpty, length > 0 else {
            return nil
        }
        if backlog.count <= length {
            let taken = backlog
            backlog = Data()
            return taken
        }
        let taken = Data(backlog.prefix(length))
        backlog = Data(backlog.dropFirst(length))
        return taken
    }
}

private struct RelayStreamChunk {
    let data: Data
    let isComplete: Bool
    let error: Error?
}

private final class RelayStreamOneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var available = true

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard available else {
            return false
        }
        available = false
        return true
    }
}
