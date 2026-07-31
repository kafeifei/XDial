import Foundation

/// Bridges callback I/O into Swift concurrency without depending on the
/// framework to invoke its callback after the underlying flow is closed.
final class RelayPendingOperation<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var terminalResult: Result<Value, Error>?

    /// Returns false when cancellation/completion won before installation.
    @discardableResult
    func install(
        _ continuation: CheckedContinuation<Value, Error>
    ) -> Bool {
        lock.lock()
        if let terminalResult {
            lock.unlock()
            continuation.resume(with: terminalResult)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    /// Returns true only for the result that won the completion race.
    @discardableResult
    func finish(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard terminalResult == nil else {
            lock.unlock()
            return false
        }
        terminalResult = result
        let currentContinuation = continuation
        continuation = nil
        lock.unlock()
        currentContinuation?.resume(with: result)
        return true
    }

    @discardableResult
    func cancel() -> Bool {
        finish(.failure(CancellationError()))
    }
}

func awaitRelayCallback<Value>(
    _ install: @escaping (
        @escaping (Result<Value, Error>) -> Void
    ) -> Void
) async throws -> Value {
    let pending = RelayPendingOperation<Value>()
    return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            guard pending.install(continuation) else {
                return
            }
            install { result in
                pending.finish(result)
            }
        }
    } onCancel: {
        pending.cancel()
    }
}
