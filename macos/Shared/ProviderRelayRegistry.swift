import Foundation

/// A dormant relay is registered before its unstructured task is launched.
/// This closes the stop-vs-start race without ever holding a registry lock
/// while calling NetworkExtension or Network APIs.
final class ProviderRelayHandle: @unchecked Sendable {
    private enum State {
        case dormant
        case running(Task<Void, Never>)
        case finished
    }

    let id = UUID()

    private let lock = NSLock()
    private let completionGroup = DispatchGroup()
    private let shutdown: RelayTaskShutdown
    private let operation: () async -> Void
    private var state: State = .dormant
    private var cancellationIssued = false

    init(
        shutdown: RelayTaskShutdown,
        operation: @escaping () async -> Void
    ) {
        self.shutdown = shutdown
        self.operation = operation
        completionGroup.enter()
    }

    @discardableResult
    func start(onFinish: @escaping () -> Void) -> Bool {
        lock.lock()
        guard case .dormant = state, !cancellationIssued else {
            lock.unlock()
            return false
        }
        let task = Task { [self] in
            await operation()
            markFinished()
            onFinish()
        }
        state = .running(task)
        lock.unlock()
        return true
    }

    func cancel(with error: Error) {
        lock.lock()
        guard !cancellationIssued else {
            lock.unlock()
            return
        }
        cancellationIssued = true
        let task: Task<Void, Never>?
        let finishDormant: Bool
        switch state {
        case .dormant:
            state = .finished
            task = nil
            finishDormant = true
        case let .running(currentTask):
            task = currentTask
            finishDormant = false
        case .finished:
            task = nil
            finishDormant = false
        }
        lock.unlock()

        // Closing the underlying I/O first makes child continuations
        // observable; task cancellation then releases their async callers.
        shutdown.finish(with: error)
        task?.cancel()
        if finishDormant {
            completionGroup.leave()
        }
    }

    func wait(until deadline: DispatchTime) -> Bool {
        completionGroup.wait(timeout: deadline) == .success
    }

    private func markFinished() {
        lock.lock()
        guard case .running = state else {
            lock.unlock()
            return
        }
        state = .finished
        lock.unlock()
        completionGroup.leave()
    }
}

struct ProviderRelayDrain: @unchecked Sendable {
    fileprivate let handles: [ProviderRelayHandle]
    let generation: String?

    static let empty = ProviderRelayDrain(
        handles: [],
        generation: nil
    )

    var count: Int {
        handles.count
    }

    static func merged(
        _ drains: [ProviderRelayDrain]
    ) -> ProviderRelayDrain {
        let generations = Set(drains.compactMap(\.generation))
        return ProviderRelayDrain(
            handles: drains.flatMap(\.handles),
            generation: generations.count == 1
                ? generations.first
                : nil
        )
    }

    func wait(timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + timeout
        for handle in handles {
            guard handle.wait(until: deadline) else {
                return false
            }
        }
        return true
    }

    /// Ends relays which did not finish inside the handoff grace period.
    /// Cancellation is idempotent, so a concurrent natural finish or Provider
    /// stop cannot turn this into a double-close.
    func cancel(
        with error: Error = AppProxyFlowCloseError.aborted
    ) {
        handles.forEach { $0.cancel(with: error) }
    }
}

final class ProviderRelayRegistry<Endpoint>: @unchecked Sendable {
    struct Reservation: @unchecked Sendable {
        fileprivate let id: UUID
        let generation: String
        let endpoint: Endpoint
    }

    enum Claim {
        case relay(Reservation)
        case reject
        case passThrough
    }

    private enum State {
        case inactive
        case active(generation: String, endpoint: Endpoint)
        case rejecting(generation: String)
    }

    private enum Entry {
        case reserved(generation: String)
        case attached(
            generation: String,
            handle: ProviderRelayHandle
        )

        var generation: String {
            switch self {
            case let .reserved(generation):
                return generation
            case let .attached(generation, _):
                return generation
            }
        }
    }

    private let lock = NSLock()
    private var state: State = .inactive
    private var entries: [UUID: Entry] = [:]

    /// Publishes the endpoint before system network settings are committed.
    /// Any unexpectedly surviving old generation is failed closed.
    @discardableResult
    func activate(
        generation: String,
        endpoint: Endpoint
    ) -> ProviderRelayDrain {
        lock.lock()
        let replacedGeneration: String?
        switch state {
        case .inactive:
            replacedGeneration = nil
        case let .active(generation, _),
             let .rejecting(generation):
            replacedGeneration = generation
        }
        let staleHandles: [ProviderRelayHandle] =
            entries.values.compactMap { entry in
            guard case let .attached(_, handle) = entry else {
                return nil
            }
            return handle
        }
        entries.removeAll()
        state = .active(generation: generation, endpoint: endpoint)
        lock.unlock()

        let error = AppProxyFlowCloseError.aborted
        staleHandles.forEach { $0.cancel(with: error) }
        return ProviderRelayDrain(
            handles: staleHandles,
            generation: replacedGeneration
        )
    }

    /// Atomically publishes a new endpoint for future flows while allowing
    /// already-attached relays from the previous generation to finish on their
    /// original endpoint. This is the Switch commit primitive: no flow can be
    /// claimed between the old and new generations, and an old flow never
    /// changes its SOCKS destination midway through its lifetime.
    ///
    /// Reservations which have not attached yet lose the race and are removed;
    /// their caller observes `attach == false` and closes that claimed flow
    /// fail-closed. Attached handles stay registered until they finish, or until
    /// the caller cancels the returned bounded drain.
    @discardableResult
    func handoff(
        generation: String,
        endpoint: Endpoint
    ) -> ProviderRelayDrain {
        lock.lock()
        let replacedGeneration: String?
        switch state {
        case .inactive:
            replacedGeneration = nil
        case let .active(currentGeneration, _),
             let .rejecting(currentGeneration):
            replacedGeneration = currentGeneration
        }

        var drainingHandles: [ProviderRelayHandle] = []
        var unattachedReservationIDs: [UUID] = []
        for (id, entry) in entries {
            guard entry.generation == replacedGeneration else {
                continue
            }
            switch entry {
            case .reserved:
                unattachedReservationIDs.append(id)
            case let .attached(_, handle):
                drainingHandles.append(handle)
            }
        }
        for id in unattachedReservationIDs {
            entries.removeValue(forKey: id)
        }
        state = .active(generation: generation, endpoint: endpoint)
        lock.unlock()

        return ProviderRelayDrain(
            handles: drainingHandles,
            generation: replacedGeneration
        )
    }

    func claim() -> Claim {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .inactive:
            return .passThrough
        case .rejecting:
            return .reject
        case let .active(generation, endpoint):
            let id = UUID()
            entries[id] = .reserved(generation: generation)
            return .relay(
                Reservation(
                    id: id,
                    generation: generation,
                    endpoint: endpoint
                )
            )
        }
    }

    func reserve() -> Reservation? {
        guard case let .relay(reservation) = claim() else {
            return nil
        }
        return reservation
    }

    func attach(
        _ handle: ProviderRelayHandle,
        to reservation: Reservation
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard
            case let .active(activeGeneration, _) = state,
            activeGeneration == reservation.generation,
            case let .reserved(entryGeneration)? = entries[reservation.id],
            entryGeneration == reservation.generation
        else {
            return false
        }
        entries[reservation.id] = .attached(
            generation: reservation.generation,
            handle: handle
        )
        return true
    }

    func finish(_ reservation: Reservation) {
        lock.lock()
        defer { lock.unlock() }
        guard
            let entry = entries[reservation.id],
            entry.generation == reservation.generation
        else {
            return
        }
        entries.removeValue(forKey: reservation.id)
    }

    @discardableResult
    func deactivateCurrent(
        error: Error = AppProxyFlowCloseError.aborted
    ) -> ProviderRelayDrain {
        lock.lock()
        let generation: String
        switch state {
        case let .active(activeGeneration, _):
            generation = activeGeneration
        case let .rejecting(activeGeneration):
            let drain = ProviderRelayDrain(
                handles: [],
                generation: activeGeneration
            )
            lock.unlock()
            return drain
        case .inactive:
            lock.unlock()
            return .empty
        }
        // Keep a tombstone until system takeover is confirmed absent. During
        // that interval new flows are claimed and aborted, never passed to the
        // Underlay.
        state = .rejecting(generation: generation)
        // A stop during Switch drain owns every relay still registered, not
        // only the newest generation. Leaving an older generation alive after
        // the system takeover is removed would leak both its Box and its flow.
        let matchingEntries = entries
        entries.removeAll()
        let handles: [ProviderRelayHandle] =
            matchingEntries.values.compactMap { entry in
            guard case let .attached(_, handle) = entry else {
                return nil
            }
            return handle
        }
        lock.unlock()

        handles.forEach { $0.cancel(with: error) }
        return ProviderRelayDrain(
            handles: handles,
            generation: generation
        )
    }

    func markInactive(generation: String) {
        lock.lock()
        if case let .rejecting(currentGeneration) = state,
           currentGeneration == generation {
            state = .inactive
        }
        lock.unlock()
    }

    var isRejecting: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .rejecting = state else {
            return false
        }
        return true
    }

    var registeredCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
}
