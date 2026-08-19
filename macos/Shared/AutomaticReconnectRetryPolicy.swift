import Foundation

enum ConnectionFailureCode {
    static let underlayEgressUnavailable =
        "underlay-egress-unavailable"
    static let providerSessionLost = "provider-session-lost"
}

enum AutomaticReconnectTrigger: String, Codable {
    case automaticConnection = "automatic-connection"
    case underlayChange = "underlay-change"
    case unexpectedDisconnect = "unexpected-disconnect"
}

struct AutomaticReconnectRuntimeState: Codable, Equatable {
    let inProgress: Bool
    let trigger: AutomaticReconnectTrigger?
    let attemptsUsed: Int
    let maxAttempts: Int
    let stableResetAt: Date?
    let retryAt: Date?
    let retryAttempt: Int?
    let underlayWaitEvidence: HostUnderlayCaptureEvidence?

    enum CodingKeys: String, CodingKey {
        case inProgress = "in_progress"
        case trigger
        case attemptsUsed = "attempts_used"
        case maxAttempts = "max_attempts"
        case stableResetAt = "stable_reset_at"
        case retryAt = "retry_at"
        case retryAttempt = "retry_attempt"
        case underlayWaitEvidence = "underlay_wait_evidence"
    }

    init(
        inProgress: Bool,
        trigger: AutomaticReconnectTrigger?,
        attemptsUsed: Int,
        maxAttempts: Int,
        stableResetAt: Date?,
        retryAt: Date?,
        retryAttempt: Int?,
        underlayWaitEvidence: HostUnderlayCaptureEvidence? = nil
    ) {
        self.inProgress = inProgress
        self.trigger = trigger
        self.attemptsUsed = attemptsUsed
        self.maxAttempts = maxAttempts
        self.stableResetAt = stableResetAt
        self.retryAt = retryAt
        self.retryAttempt = retryAttempt
        self.underlayWaitEvidence = underlayWaitEvidence
    }

    func retryCountdownSeconds(at date: Date) -> Int? {
        guard let retryAt else { return nil }
        return max(0, Int(ceil(retryAt.timeIntervalSince(date))))
    }
}

/// Counts only retries which actually reached a new connection transaction.
/// Waiting for macOS to expose a usable Underlay snapshot is preparation for
/// an attempt, not an attempt itself, and therefore must not exhaust recovery.
struct AutomaticReconnectAttemptBudget {
    let maxAttempts: Int
    private(set) var attemptsUsed = 0

    var nextAttempt: Int? {
        guard attemptsUsed < maxAttempts else { return nil }
        return attemptsUsed + 1
    }

    @discardableResult
    mutating func recordStarted(_ attempt: Int) -> Bool {
        guard attempt == nextAttempt else { return false }
        attemptsUsed = attempt
        return true
    }

    mutating func reset() {
        attemptsUsed = 0
    }
}

/// 自动重连是同一份用户连接意图的有界恢复，不是静默无限拉起。
///
/// Underlay 改变后的自动重建仍只重试结构化的 Underlay 瞬态故障；
/// 已稳定提交的会话意外断线则允许对本次恢复事务做有界重试。无论哪种来源，
/// 预算都是五次，且必须连续稳定五分钟才会清零。
struct AutomaticReconnectRetryPolicy {
    private let delays: [TimeInterval]
    let stableResetInterval: TimeInterval

    init(
        delays: [TimeInterval] = [2, 5, 10, 20, 30],
        stableResetInterval: TimeInterval = 5 * 60
    ) {
        self.delays = delays
        self.stableResetInterval = stableResetInterval
    }

    var maxAttempts: Int {
        delays.count
    }

    /// A failed host snapshot has not started another data-plane attempt.
    /// Poll it at the shortest retry cadence until the Underlay is usable.
    var underlayWaitRetryDelay: TimeInterval {
        delays.first ?? 2
    }

    func delay(
        after report: ConnectionReport,
        attemptsUsed: Int,
        trigger: AutomaticReconnectTrigger
    ) -> TimeInterval? {
        guard
            report.state == .failed,
            report.rollbackComplete,
            report.systemTakeoverRemoved
        else {
            return nil
        }
        switch trigger {
        case .automaticConnection:
            break
        case .underlayChange:
            guard report.error?.code ==
                ConnectionFailureCode.underlayEgressUnavailable else {
                return nil
            }
        case .unexpectedDisconnect:
            break
        }
        return delayForNextAttempt(attemptsUsed: attemptsUsed)
    }

    func delayForNextAttempt(attemptsUsed: Int) -> TimeInterval? {
        guard delays.indices.contains(attemptsUsed) else {
            return nil
        }
        return delays[attemptsUsed]
    }
}
