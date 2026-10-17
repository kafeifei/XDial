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

/// 完整自动恢复只为“同一份意图无需用户操作就可能成功”的失败消耗预算：
/// 本机网络或 Line 路径暂时不可用，或已提交会话在 XDial 之下丢失。
/// 判定只读结构化 code 与结构化证据，展示文字从不参与。
///
/// 凭据、证书、配置等终止错误和未知 code 一律保留原错误立即结束。
/// 未知 code 与 Scenario Switch 一致不重试：没有结构化证据证明是瞬态时，
/// 重复同一事务只会把同一结论推迟约一分钟，期间还要反复接管、撤销系统网络。
enum AutomaticReconnectFailurePolicy {
    /// Committed sessions lost below XDial, and transactions whose Provider
    /// disappeared mid-start, carry no terminal evidence; the architecture
    /// escalates exactly these losses to a full recovery.
    private static let sessionLossCodes: Set<String> = [
        ConnectionFailureCode.providerSessionLost,
        "interrupted-transaction-recovered",
        "data-plane-failed",
    ]

    /// Probes proved the Line's path unusable on this network, or the network
    /// changed while the attempt was being prepared.
    private static let linePathCodes: Set<String> = [
        "line-address-family-unavailable",
        "line-address-family-capability-changed",
        ProxyResourceReadiness.lineFailureCode,
        ProxyResourceReadiness.subscriptionFailureCode,
        "network-superseded",
    ]

    /// AnyConnect transport channel closes (`AnyConnectCloseEvidence`).
    /// Server-initiated `peer-terminate` is not among them.
    private static let anyConnectTransportCodes: Set<String> = [
        "anyconnect-tls-dpd-timeout",
        "anyconnect-tls-read-timeout",
        "anyconnect-tls-read-eof",
        "anyconnect-tls-read-reset",
        "anyconnect-tls-read-closed",
        "anyconnect-tls-write-timeout",
        "anyconnect-tls-write-reset",
        "anyconnect-tls-write-eof",
        "anyconnect-tls-write-closed",
    ]

    /// A server-requested disconnect qualifies only when its structured
    /// category says the session aged out or the server failed. Credential,
    /// policy, duplicate-session and unclassified reasons stay terminal.
    private static let anyConnectPeerDisconnectCode =
        "anyconnect-peer-disconnect"
    private static let transientPeerDisconnectCategories: Set<String> = [
        "idle-timeout",
        "session-timeout",
        "rekey",
        "server-error",
    ]

    static func isTransient(_ error: ConnectionReportError?) -> Bool {
        guard let error else { return false }
        let code = error.code
        if AutomaticLineReadinessFailurePolicy.switchCode(for: code)
            == ScenarioSwitchFailureCode.lineReadinessTransient {
            return true
        }
        if HostUnderlayCaptureFailureReason(rawValue: code) != nil {
            return true
        }
        if sessionLossCodes.contains(code)
            || linePathCodes.contains(code)
            || anyConnectTransportCodes.contains(code) {
            return true
        }
        guard code == anyConnectPeerDisconnectCode,
              let category = error.evidence?.anyConnect?.close?
                .peerReasonCategory else {
            return false
        }
        return transientPeerDisconnectCategories.contains(category)
    }
}

/// 自动重连是同一份用户连接意图的有界恢复，不是静默无限拉起。
///
/// Underlay 改变后的自动重建仍只重试结构化的 Underlay 瞬态故障；
/// 启动自动连接与已提交会话意外断线按 `AutomaticReconnectFailurePolicy`
/// 分类，终止与未知错误立即结束。无论哪种来源，预算都是五次，
/// 且必须连续稳定五分钟才会清零。
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
        guard qualifies(report, trigger: trigger) else {
            return nil
        }
        return delayForNextAttempt(attemptsUsed: attemptsUsed)
    }

    /// Whether this settled failure may consume retry budget at all. A
    /// qualifying failure with no budget left is exhausted; any other is a
    /// terminal stop that keeps the original error.
    func qualifies(
        _ report: ConnectionReport,
        trigger: AutomaticReconnectTrigger
    ) -> Bool {
        guard
            report.state == .failed,
            report.rollbackComplete,
            report.systemTakeoverRemoved
        else {
            return false
        }
        switch trigger {
        case .underlayChange:
            return report.error?.code ==
                ConnectionFailureCode.underlayEgressUnavailable
        case .automaticConnection, .unexpectedDisconnect:
            return AutomaticReconnectFailurePolicy.isTransient(report.error)
        }
    }

    func delayForNextAttempt(attemptsUsed: Int) -> TimeInterval? {
        guard delays.indices.contains(attemptsUsed) else {
            return nil
        }
        return delays[attemptsUsed]
    }
}
