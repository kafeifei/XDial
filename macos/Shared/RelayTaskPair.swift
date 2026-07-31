import Foundation

/// Owns the one-shot shutdown of a duplex relay.
///
/// NetworkExtension and Network callbacks do not necessarily observe Swift task
/// cancellation. The underlying flow and connection must therefore be closed
/// before a task group waits for the sibling relay direction to finish.
final class RelayTaskShutdown: @unchecked Sendable {
    private let lock = NSLock()
    private var action: ((Error?) -> Void)?

    init(_ action: @escaping (Error?) -> Void) {
        self.action = action
    }

    func finish(with error: Error?) {
        lock.lock()
        let currentAction = action
        action = nil
        lock.unlock()
        currentAction?(error)
    }
}

enum RelayTaskPair {
    /// Runs both halves of a stream until both finish normally.
    ///
    /// Each operation owns its directional half-close. A normal EOF in one
    /// direction must not cancel the other direction: TCP permits a peer to
    /// finish sending while it continues receiving. Errors and parent
    /// cancellation still tear down the complete relay before waiting for the
    /// sibling task.
    static func run(
        first: @escaping @Sendable () async throws -> Void,
        second: @escaping @Sendable () async throws -> Void,
        shutdown: RelayTaskShutdown
    ) async throws {
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask(operation: first)
                    group.addTask(operation: second)

                    do {
                        while try await group.next() != nil {
                            try Task.checkCancellation()
                        }
                    } catch {
                        shutdown.finish(with: error)
                        group.cancelAll()
                        await drain(&group)
                        throw error
                    }

                    try Task.checkCancellation()
                    shutdown.finish(with: nil)
                }
            } onCancel: {
                shutdown.finish(with: CancellationError())
            }
        } catch {
            // Also covers cancellation observed before the task group is made.
            shutdown.finish(with: error)
            throw error
        }
    }

    private static func drain(
        _ group: inout ThrowingTaskGroup<Void, Error>
    ) async {
        while !group.isEmpty {
            do {
                _ = try await group.next()
            } catch {
                // The first terminal error is authoritative. Errors caused by
                // closing the sibling's underlying I/O are cleanup outcomes.
            }
        }
    }
}

enum RelayTaskGroup {
    typealias Operation = @Sendable () async throws -> Void

    static func run(
        operations: [Operation],
        shutdown: RelayTaskShutdown
    ) async throws {
        guard !operations.isEmpty else {
            shutdown.finish(with: nil)
            return
        }
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for operation in operations {
                        group.addTask(operation: operation)
                    }

                    do {
                        _ = try await group.next()
                        try Task.checkCancellation()
                    } catch {
                        shutdown.finish(with: error)
                        group.cancelAll()
                        await drain(&group)
                        throw error
                    }

                    shutdown.finish(with: nil)
                    group.cancelAll()
                    await drain(&group)
                    try Task.checkCancellation()
                }
            } onCancel: {
                shutdown.finish(with: CancellationError())
            }
        } catch {
            // Also covers cancellation observed before the task group is made.
            shutdown.finish(with: error)
            throw error
        }
    }

    private static func drain(
        _ group: inout ThrowingTaskGroup<Void, Error>
    ) async {
        while !group.isEmpty {
            do {
                _ = try await group.next()
            } catch {
                // The first terminal result is authoritative. Errors caused by
                // closing the sibling's underlying I/O are cleanup outcomes.
            }
        }
    }
}
