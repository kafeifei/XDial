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

    /// Non-blocking completion observation for long-lived retained relays.
    fileprivate func notifyWhenFinished(
        queue: DispatchQueue,
        execute work: @escaping () -> Void
    ) {
        completionGroup.notify(queue: queue, execute: work)
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

/// What one registry entry owns; see `ProviderRelayRegistry.handoff`.
enum ProviderRelayOwnership: Equatable, Sendable {
    /// The entry owns the application's connection (system TCP flow or a
    /// local SOCKS5 client). Cancelling it ends that connection.
    case flow
    /// The entry owns one SOCKS association of a longer-lived UDP flow.
    /// Cancelling it re-associates the flow with the active generation.
    case association
}

struct ProviderRelayDrain: @unchecked Sendable {
    fileprivate struct Member {
        let handle: ProviderRelayHandle
        let ownership: ProviderRelayOwnership
    }

    fileprivate let members: [Member]
    let generation: String?

    static let empty = ProviderRelayDrain(
        members: [],
        generation: nil
    )

    var count: Int {
        members.count
    }

    /// Members that have not completed yet; for bounded evidence only.
    var unfinishedCount: Int {
        members.filter { !$0.handle.wait(until: .now()) }.count
    }

    static func merged(
        _ drains: [ProviderRelayDrain]
    ) -> ProviderRelayDrain {
        let generations = Set(drains.compactMap(\.generation))
        return ProviderRelayDrain(
            members: drains.flatMap(\.members),
            generation: generations.count == 1
                ? generations.first
                : nil
        )
    }

    /// The subset owning `ownership`, for the same generation.
    func subset(
        owning ownership: ProviderRelayOwnership
    ) -> ProviderRelayDrain {
        ProviderRelayDrain(
            members: members.filter { $0.ownership == ownership },
            generation: generation
        )
    }

    func wait(timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + timeout
        for member in members {
            guard member.handle.wait(until: deadline) else {
                return false
            }
        }
        return true
    }

    /// Calls `work` once on `queue` after every member has finished, without
    /// blocking a thread for the retained relays' lifetime. An empty drain
    /// completes immediately.
    func notifyWhenFinished(
        queue: DispatchQueue,
        execute work: @escaping () -> Void
    ) {
        let group = DispatchGroup()
        for member in members {
            group.enter()
            member.handle.notifyWhenFinished(
                queue: .global(qos: .utility)
            ) {
                group.leave()
            }
        }
        group.notify(queue: queue, execute: work)
    }

    /// Ends relays which did not finish inside the handoff grace period.
    /// Cancellation is idempotent, so a concurrent natural finish or Provider
    /// stop cannot turn this into a double-close.
    func cancel(
        with error: Error = AppProxyFlowCloseError.aborted
    ) {
        members.forEach { $0.handle.cancel(with: error) }
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
            handle: ProviderRelayHandle,
            ownership: ProviderRelayOwnership
        )

        var generation: String {
            switch self {
            case let .reserved(generation):
                return generation
            case let .attached(generation, _, _):
                return generation
            }
        }

        var drainMember: ProviderRelayDrain.Member? {
            guard case let .attached(_, handle, ownership) = self else {
                return nil
            }
            return ProviderRelayDrain.Member(
                handle: handle,
                ownership: ownership
            )
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
        let staleMembers = entries.values.compactMap(\.drainMember)
        entries.removeAll()
        state = .active(generation: generation, endpoint: endpoint)
        lock.unlock()

        let drain = ProviderRelayDrain(
            members: staleMembers,
            generation: replacedGeneration
        )
        drain.cancel()
        return drain
    }

    /// Atomically publishes a new endpoint for future flows while allowing
    /// already-attached relays from the previous generation to finish on their
    /// original endpoint. This is the Switch commit primitive: no flow can be
    /// claimed between the old and new generations, and an established relay
    /// never changes its SOCKS destination midway through its lifetime.
    ///
    /// What a registry entry owns differs by flow kind. A TCP entry owns the
    /// flow, so cancelling it ends the application's connection and the
    /// application reconnects. A UDP entry owns only one SOCKS association:
    /// cancelling it retires that association while its flow stays open and
    /// re-associates against the generation active at that point, because
    /// macOS never hands the same application socket back as a second flow.
    ///
    /// Reservations which have not attached yet lose the race and are removed;
    /// their caller observes `attach == false` and closes that claimed flow
    /// fail-closed. Attached handles stay registered until they finish, or until
    /// the caller cancels the returned drain. Each member keeps the ownership
    /// it attached with, so the caller can bound associations and flows
    /// separately; the registry itself never decides how long either lives.
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

        var drainingMembers: [ProviderRelayDrain.Member] = []
        var unattachedReservationIDs: [UUID] = []
        for (id, entry) in entries {
            guard entry.generation == replacedGeneration else {
                continue
            }
            if let member = entry.drainMember {
                drainingMembers.append(member)
            } else {
                unattachedReservationIDs.append(id)
            }
        }
        for id in unattachedReservationIDs {
            entries.removeValue(forKey: id)
        }
        state = .active(generation: generation, endpoint: endpoint)
        lock.unlock()

        return ProviderRelayDrain(
            members: drainingMembers,
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
        to reservation: Reservation,
        owning ownership: ProviderRelayOwnership = .flow
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
            handle: handle,
            ownership: ownership
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
                members: [],
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
        let members = entries.values.compactMap(\.drainMember)
        entries.removeAll()
        lock.unlock()

        let drain = ProviderRelayDrain(
            members: members,
            generation: generation
        )
        drain.cancel(with: error)
        return drain
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
