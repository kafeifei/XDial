import Foundation

/// Writes one UDP association's downlink to the application flow.
///
/// Receiving never waits for the flow, and no task hop sits on the
/// per-datagram path: a datagram arriving while no write is in flight is
/// written straight from the receive callback, and datagrams arriving during a
/// write are queued and handed to the next write as one batch, issued from the
/// previous write's completion. The queue never grows past its limits: UDP may
/// drop, and a backlog the application cannot drain would only turn into
/// latency, so a full queue drops the arriving datagram and reports the count
/// with the next batch.
///
/// The end of the stream is ordered behind the datagrams already accepted:
/// `wait()` resolves only once their writes complete.
final class UDPRelayDownlinkPipeline<Element>: @unchecked Sendable {
    struct Limits: Equatable {
        let maximumCount: Int
        let maximumBytes: Int

        /// About 300 KB of 1,200-byte media datagrams, a few frames of Screen
        /// Sharing at full rate; the byte limit caps larger datagrams.
        static var `default`: Limits {
            Limits(maximumCount: 256, maximumBytes: 1 << 20)
        }
    }

    enum PushResult: Equatable {
        /// Written now or queued for the next write.
        case accepted
        /// The queue was full; the datagram is gone.
        case dropped
        /// The pipeline has ended; the producer should stop receiving.
        case closed
    }

    enum Outcome {
        /// The receive side finished and every accepted datagram was written.
        case finished
        /// The receive side failed after every accepted datagram was written.
        case receiveFailed(Error)
        /// The application flow rejected a write.
        case writeFailed(Error)
        /// The consumer stopped the pipeline.
        case stopped
    }

    /// Hands a batch to the flow; the completion reports the flow's error.
    typealias Write = (
        _ batch: [Element],
        _ completion: @escaping (Error?) -> Void
    ) -> Void
    /// Observes a written batch and the datagrams dropped while it waited.
    typealias Written = (_ batch: [Element], _ dropped: Int) -> Void

    private let limits: Limits
    private let write: Write
    private let written: Written
    private let lock = NSLock()
    private var pending: [Element] = []
    private var pendingBytes = 0
    private var dropped = 0
    private var writing = false
    private var streamEnd: Result<Void, Error>?
    private var resolved: Outcome?
    private var waiter: CheckedContinuation<Outcome, Never>?

    init(
        limits: Limits = .default,
        write: @escaping Write,
        written: @escaping Written
    ) {
        precondition(limits.maximumCount > 0 && limits.maximumBytes > 0)
        self.limits = limits
        self.write = write
        self.written = written
    }

    func push(_ element: Element, byteCount: Int) -> PushResult {
        lock.lock()
        guard resolved == nil, streamEnd == nil else {
            lock.unlock()
            return .closed
        }
        guard writing else {
            // Nothing is queued while no write is in flight.
            writing = true
            lock.unlock()
            issue([element], dropped: 0)
            return .accepted
        }
        // A write is in flight. An empty queue always accepts one datagram,
        // so a datagram larger than the byte limit is still delivered.
        guard
            pending.isEmpty
                || (pending.count < limits.maximumCount
                    && pendingBytes + byteCount <= limits.maximumBytes)
        else {
            dropped += 1
            lock.unlock()
            return .dropped
        }
        pending.append(element)
        pendingBytes += byteCount
        lock.unlock()
        return .accepted
    }

    /// Ends the receive side. Only the first end counts.
    func finish(throwing error: Error? = nil) {
        lock.lock()
        guard resolved == nil, streamEnd == nil else {
            lock.unlock()
            return
        }
        let end: Result<Void, Error> = error.map { .failure($0) } ?? .success(())
        streamEnd = end
        let idle = !writing
        lock.unlock()
        if idle {
            resolve(Self.outcome(of: end))
        }
    }

    /// Stops writing. A write already in flight completes on its own.
    func stop() {
        resolve(.stopped)
    }

    /// Waits for the pipeline to end. Cancelling the waiter stops it.
    /// There is a single waiter.
    func wait() async -> Outcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let resolved {
                    lock.unlock()
                    continuation.resume(returning: resolved)
                    return
                }
                precondition(waiter == nil, "single waiter")
                waiter = continuation
                lock.unlock()
            }
        } onCancel: {
            stop()
        }
    }

    private func issue(_ batch: [Element], dropped: Int) {
        write(batch) { error in
            self.completed(batch, dropped: dropped, error: error)
        }
    }

    private func completed(_ batch: [Element], dropped: Int, error: Error?) {
        if let error {
            resolve(.writeFailed(error))
            return
        }
        written(batch, dropped)
        lock.lock()
        guard resolved == nil else {
            lock.unlock()
            return
        }
        guard pending.isEmpty else {
            let next = pending
            let nextDropped = self.dropped
            pending.removeAll(keepingCapacity: true)
            pendingBytes = 0
            self.dropped = 0
            lock.unlock()
            issue(next, dropped: nextDropped)
            return
        }
        writing = false
        let end = streamEnd
        lock.unlock()
        if let end {
            resolve(Self.outcome(of: end))
        }
    }

    private func resolve(_ outcome: Outcome) {
        lock.lock()
        guard resolved == nil else {
            lock.unlock()
            return
        }
        resolved = outcome
        pending.removeAll()
        pendingBytes = 0
        let consumer = waiter
        waiter = nil
        lock.unlock()
        consumer?.resume(returning: outcome)
    }

    private static func outcome(of end: Result<Void, Error>) -> Outcome {
        switch end {
        case .success:
            return .finished
        case let .failure(error):
            return .receiveFailed(error)
        }
    }
}
