import Foundation

/// Bounds how long a UDP flow keeps looking for a live SOCKS association.
///
/// macOS never creates a second `NEAppProxyUDPFlow` for the same application
/// socket: once the Provider closes a flow, every later datagram that socket
/// sends is silently dropped. Long-lived queriers — mDNSResponder keeps one
/// socket per DNS question and retries on it forever — therefore black-hole
/// permanently. An engine generation switch must re-associate the flow instead
/// of closing it, while a data plane which is genuinely gone still has to fail
/// the flow closed rather than retry forever.
struct RelayReassociationPolicy: Equatable {
    /// Delay before each re-association attempt. The first retry is immediate
    /// so a generation switch is invisible to the application; later ones back
    /// off so a missing listener cannot turn into a busy loop.
    let delays: [TimeInterval]
    /// Wall-clock budget measured from the first association failure.
    let budget: TimeInterval
    /// An association which served at least this long before failing counts as
    /// healthy. Its next failure starts a fresh budget, while an association
    /// that fails immediately keeps consuming the current one.
    let healthyDuration: TimeInterval

    static let `default` = RelayReassociationPolicy(
        delays: [0, 0.1, 0.3, 1, 2, 2, 2, 2],
        budget: 12,
        healthyDuration: 1
    )

    /// - Parameters:
    ///   - attempt: 1 for the first re-association after a failure.
    ///   - elapsed: seconds since the first failure of the current budget.
    /// - Returns: how long to wait before the attempt, or `nil` when the flow
    ///   must be closed instead.
    func delay(
        forAttempt attempt: Int,
        elapsed: TimeInterval
    ) -> TimeInterval? {
        guard attempt >= 1, attempt <= delays.count else {
            return nil
        }
        guard elapsed >= 0, elapsed < budget else {
            return nil
        }
        let delay = delays[attempt - 1]
        guard elapsed + delay <= budget else {
            return nil
        }
        return delay
    }

    func resetsBudget(afterAssociationLasting duration: TimeInterval) -> Bool {
        duration >= healthyDuration
    }
}

/// Tracks one flow's remaining re-association budget.
///
/// Kept separate from the I/O so the back-off schedule, the healthy-association
/// reset and the give-up point are exercised without a live data plane.
struct RelayReassociationBudget {
    let policy: RelayReassociationPolicy

    private(set) var attempt = 0
    private var startedAt: Date?

    init(policy: RelayReassociationPolicy = .default) {
        self.policy = policy
    }

    /// - Parameters:
    ///   - duration: how long the association which just ended stayed up.
    ///   - now: the moment it ended.
    /// - Returns: the delay before the next attempt, or `nil` when the flow has
    ///   run out of budget and must be closed.
    mutating func nextDelay(
        afterAssociationLasting duration: TimeInterval,
        now: Date = Date()
    ) -> TimeInterval? {
        if policy.resetsBudget(afterAssociationLasting: duration) {
            attempt = 0
            startedAt = nil
        }
        let start = startedAt ?? now
        startedAt = start
        attempt += 1
        return policy.delay(
            forAttempt: attempt,
            elapsed: now.timeIntervalSince(start)
        )
    }
}

/// Measures only the interval during which an association was ready to carry
/// datagrams. Connection and SOCKS handshake time must not make a failed
/// association appear healthy and reset the retry budget.
struct RelayAssociationHealthClock {
    private var readyAt: Date?

    mutating func markReady(at now: Date = Date()) {
        readyAt = now
    }

    func duration(endingAt now: Date = Date()) -> TimeInterval {
        guard let readyAt else {
            return 0
        }
        return max(0, now.timeIntervalSince(readyAt))
    }
}
