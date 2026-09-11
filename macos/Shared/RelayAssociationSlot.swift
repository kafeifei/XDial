import Foundation

/// Publishes the currently ready relay association to an I/O loop.
///
/// A waiter retains only the bounded batch which its caller has already read.
/// Closing the slot releases every waiter, while task cancellation removes only
/// that task's continuation.
final class RelayAssociationSlot<Value: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var closed = false
    private var waiters: [UUID: CheckedContinuation<Value?, Error>] = [:]

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func waitForCurrent() async throws -> Value? {
        try Task.checkCancellation()
        lock.lock()
        if closed {
            lock.unlock()
            return nil
        }
        if let value {
            lock.unlock()
            return value
        }
        lock.unlock()

        // Keep the healthy data path allocation-free. A waiter identity is
        // needed only across a genuine readiness gap.
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if closed {
                    lock.unlock()
                    continuation.resume(returning: nil)
                } else if let value {
                    lock.unlock()
                    continuation.resume(returning: value)
                } else {
                    waiters[waiterID] = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            self.cancel(waiterID: waiterID)
        }
    }

    /// Publishes a ready value and returns the value it replaced. A closed slot
    /// rejects the candidate by returning `accepted == false`.
    func adopt(_ candidate: Value) -> (accepted: Bool, replaced: Value?) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return (false, nil)
        }
        let replaced = value
        value = candidate
        let pending = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()

        for waiter in pending {
            waiter.resume(returning: candidate)
        }
        return (true, replaced)
    }

    /// Clears the candidate only when it is still the published value.
    func release(_ candidate: Value) {
        lock.lock()
        if let value, value === candidate {
            self.value = nil
        }
        lock.unlock()
    }

    /// Closes the slot exactly once and returns the value it held.
    func close() -> (didClose: Bool, current: Value?) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return (false, nil)
        }
        closed = true
        let current = value
        value = nil
        let pending = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()

        for waiter in pending {
            waiter.resume(returning: nil)
        }
        return (true, current)
    }

    private func cancel(waiterID: UUID) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: waiterID)
        lock.unlock()
        waiter?.resume(throwing: CancellationError())
    }
}
