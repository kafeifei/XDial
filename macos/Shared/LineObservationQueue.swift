import Foundation

/// Serializes transaction-owned Line observation work across replacement.
///
/// Cancellation is cooperative, so a replacement must wait for the previous
/// operation to actually return before it may acquire the Provider's one probe
/// lease. `cancel()` deliberately retains the task handle for the same reason.
@MainActor
final class LineObservationQueue {
    private var task: Task<Void, Never>?

    func replace(
        operation: @escaping @MainActor () async -> Void
    ) {
        let previous = task
        previous?.cancel()
        task = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    func cancel() {
        task?.cancel()
    }

    deinit {
        task?.cancel()
    }
}
