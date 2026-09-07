import Foundation

/// The profile and host Underlay identity selected together by a settled
/// network epoch. The manager retains ownership of the actual snapshot.
struct AutomaticReconnectPreparation {
    let profileJSON: String
    let underlayFingerprint: String
}

/// Owns one asynchronous recovery preparation. Cancellation and successful
/// consumption invalidate late callbacks without spending a retry attempt.
/// The host serializes access on its main queue.
struct AutomaticReconnectPreparationGate {
    private(set) var token: UUID?

    mutating func begin() -> UUID? {
        guard token == nil else { return nil }
        let created = UUID()
        token = created
        return created
    }

    func isCurrent(_ candidate: UUID) -> Bool {
        token == candidate
    }

    mutating func finish(_ candidate: UUID) -> Bool {
        guard isCurrent(candidate) else { return false }
        token = nil
        return true
    }

    mutating func cancel() {
        token = nil
    }
}
