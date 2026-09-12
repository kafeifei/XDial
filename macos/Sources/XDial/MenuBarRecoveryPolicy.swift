import Foundation

/// Recreating a status item is not proof that Control Center accepted it. Require
/// stable, visible geometry before resetting the retry budget.
struct MenuBarRecoveryPolicy {
    enum Observation: String {
        case visible
        case missing
        case deferred
    }

    enum Action: Equatable {
        case none
        case rebuild
        case recovered
        case blocked
    }

    static let missingGrace: TimeInterval = 3
    static let stableVisibility: TimeInterval = 10
    static let retryInterval: TimeInterval = 5
    static let maximumAttempts = 3

    private(set) var attempts = 0
    private(set) var isBlocked = false
    private var missingSince: TimeInterval?
    private var visibleSince: TimeInterval?
    private var lastAttempt: TimeInterval?

    mutating func observe(_ observation: Observation, at now: TimeInterval) -> Action {
        switch observation {
        case .deferred:
            missingSince = nil
            visibleSince = nil
            return .none
        case .visible:
            missingSince = nil
            if visibleSince == nil { visibleSince = now }
            guard attempts > 0,
                  now - (visibleSince ?? now) >= Self.stableVisibility else {
                return .none
            }
            self = Self()
            visibleSince = now
            return .recovered
        case .missing:
            visibleSince = nil
            if missingSince == nil { missingSince = now }
            guard !isBlocked,
                  now - (missingSince ?? now) >= Self.missingGrace,
                  lastAttempt.map({ now - $0 >= Self.retryInterval }) ?? true else {
                return .none
            }
            guard attempts < Self.maximumAttempts else {
                isBlocked = true
                return .blocked
            }
            attempts += 1
            lastAttempt = now
            return .rebuild
        }
    }

    static func isAtMenuBar(frame: CGRect, screen: CGRect, thickness: CGFloat) -> Bool {
        guard frame.width > 0, frame.height > 0, thickness > 0 else { return false }
        let band = CGRect(
            x: screen.minX, y: screen.maxY - thickness - 2,
            width: screen.width, height: thickness + 4
        )
        return band.intersects(frame) && frame.midY >= band.minY
    }
}
