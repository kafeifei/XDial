import Foundation

/// The identity one full automatic-recovery budget belongs to.
///
/// `underlayFingerprint` is the host's opaque in-process Underlay identity;
/// like `HostUnderlaySnapshot.epochFingerprint` it is never logged,
/// persisted, sent to the Provider or exposed by Debug.
/// `connectivityGeneration` advances only when a settled host epoch reports
/// an unsatisfied -> satisfied path edge on an otherwise identical Underlay.
struct AutomaticRecoveryEpoch: Equatable {
    let scenarioID: String
    let underlayFingerprint: String
    let connectivityGeneration: UInt64
}

/// Why a parked or starting recovery received a fresh five-attempt budget.
/// The raw values are recorded in incident events and Debug state.
enum AutomaticRecoveryGrantReason: String, Codable, Equatable {
    /// A launch auto-connect failed or a committed session was lost in an
    /// epoch that had no budget yet.
    case recoveryStarted = "recovery-started"
    case underlayChanged = "underlay-changed"
    case scenarioChanged = "scenario-changed"
    case connectivityRestored = "connectivity-restored"
    case userRetry = "user-retry"
    case userConnect = "user-connect"

    /// Only grants caused by host network facts are rate limited. A user
    /// action is a new intent and never waits behind automatic grants.
    var isRateLimited: Bool {
        switch self {
        case .underlayChanged, .scenarioChanged, .connectivityRestored:
            true
        case .recoveryStarted, .userRetry, .userConnect:
            false
        }
    }
}

/// One connection transaction started by full automatic recovery.
enum AutomaticRecoveryAttemptKind: Equatable {
    /// Attempt `n` of the current epoch's 2 / 5 / 10 / 20 / 30 s budget.
    case budget(Int)
    /// The one attempt a full wake keeps for an unchanged parked epoch.
    case wake
    /// Slow-tail attempt `n` while parked in the same epoch.
    case tail(Int)

    var name: String {
        switch self {
        case .budget: "budget"
        case .wake: "wake"
        case .tail: "tail"
        }
    }

    var isSingleParkedAttempt: Bool {
        switch self {
        case .budget: false
        case .wake, .tail: true
        }
    }
}

/// What asked a parked recovery to continue.
enum AutomaticRecoveryResumeTrigger: Equatable {
    /// A host-observed network epoch settled by AppState's quiet window.
    case networkEpoch(connectivityRestored: Bool)
    /// A full wake (or screen/session wake) re-sampled the network.
    case wake
    /// The slow-tail timer for the parked epoch fired.
    case slowTail
}

/// Settled facts a resume request was decided on.
struct AutomaticRecoveryObservation: Equatable {
    let scenarioID: String
    let underlayFingerprint: String
}

enum AutomaticRecoveryRejection: String, Equatable {
    case notParked = "not-parked"
    case asleep = "asleep"
    case duplicateEpoch = "duplicate-epoch"
    case tailExhausted = "tail-exhausted"
    case incompleteObservation = "incomplete-observation"
}

enum AutomaticRecoveryDecision: Equatable {
    case grant(AutomaticRecoveryGrantReason)
    case deferred(AutomaticRecoveryGrantReason, until: Date)
    case singleAttempt(AutomaticRecoveryAttemptKind)
    case rejected(AutomaticRecoveryRejection)
}

/// Owns the full-recovery budget and what may replenish it.
///
/// A budget belongs to one recovery epoch `(desired Scenario, Underlay
/// fingerprint, connectivity generation)`. Once it is exhausted with a
/// network-related failure the recovery parks: the runtime stays reported as
/// disconnected and only host-observed, settled network facts or a user
/// action can grant another budget. XDial's own attempts never produce such
/// facts, and every automatic grant is bounded by a same-fingerprint spacing
/// and an hourly cap. The value type owns no timer; the host schedules the
/// returned dates and calls back.
struct AutomaticRecoveryLedger {
    struct Policy: Equatable {
        var maxAttempts = 5
        var sameFingerprintGrantInterval: TimeInterval = 5 * 60
        var rateLimitedGrantLimit = 6
        var rateLimitWindow: TimeInterval = 60 * 60
        /// Delays before each slow-tail attempt, measured from the failure
        /// that (re)parked the same epoch.
        var tailDelays: [TimeInterval] = [
            2 * 60, 5 * 60, 10 * 60, 20 * 60, 30 * 60,
        ]
    }

    struct DeferredGrant: Equatable {
        let reason: AutomaticRecoveryGrantReason
        let epoch: AutomaticRecoveryEpoch
        let notBefore: Date
    }

    struct Parking: Equatable {
        let epoch: AutomaticRecoveryEpoch
        let parkedAt: Date
        var failureCode: String
        var tailAttemptsUsed: Int
        var deferredGrant: DeferredGrant?
    }

    struct Grant: Equatable {
        let reason: AutomaticRecoveryGrantReason
        let at: Date
    }

    let policy: Policy
    private(set) var budget: AutomaticReconnectAttemptBudget
    private(set) var budgetEpoch: AutomaticRecoveryEpoch?
    private(set) var connectivityGeneration: UInt64 = 0
    private(set) var parking: Parking?
    private(set) var lastGrant: Grant?
    private var lastGrantAtByFingerprint: [String: Date] = [:]
    private var rateLimitedGrantTimes: [Date] = []

    init(policy: Policy = Policy()) {
        self.policy = policy
        budget = AutomaticReconnectAttemptBudget(
            maxAttempts: policy.maxAttempts
        )
    }

    var isParked: Bool { parking != nil }
    var attemptsUsed: Int { budget.attemptsUsed }
    var nextAttempt: Int? { budget.nextAttempt }
    var isExhausted: Bool { budget.nextAttempt == nil }

    @discardableResult
    mutating func recordStarted(_ attempt: Int) -> Bool {
        budget.recordStarted(attempt)
    }

    /// Delay before the next slow-tail attempt of the parked epoch, if any.
    var nextTailDelay: TimeInterval? {
        guard let parking,
              policy.tailDelays.indices.contains(
                  parking.tailAttemptsUsed
              ) else {
            return nil
        }
        return policy.tailDelays[parking.tailAttemptsUsed]
    }

    /// A launch auto-connect failure or a lost committed session starts a
    /// recovery episode. A new epoch receives a fresh budget; the same epoch
    /// continues whatever its budget has left, so short-lived successes do
    /// not reset it.
    @discardableResult
    mutating func beginEpisode(
        in epoch: AutomaticRecoveryEpoch,
        at now: Date
    ) -> Bool {
        parking = nil
        guard budgetEpoch != epoch else { return false }
        budgetEpoch = epoch
        budget.reset()
        lastGrant = Grant(reason: .recoveryStarted, at: now)
        noteGrant(for: epoch, reason: .recoveryStarted, at: now)
        return true
    }

    /// Five stable minutes in one committed transaction end the episode.
    mutating func stableReset() {
        budget.reset()
        budgetEpoch = nil
    }

    /// A user connection is a new intent: parking ends and any later
    /// automatic recovery starts from a fresh budget.
    mutating func noteUserConnection(at now: Date) {
        parking = nil
        budget.reset()
        budgetEpoch = nil
        lastGrant = Grant(reason: .userConnect, at: now)
    }

    /// Records the end of a full recovery. Only network-related failures
    /// park; identity, configuration and unclassified failures stop with
    /// their own error and are never granted another budget automatically.
    @discardableResult
    mutating func park(
        epoch: AutomaticRecoveryEpoch,
        failure: ConnectionReportError?,
        at now: Date
    ) -> Bool {
        guard AutomaticReconnectFailurePolicy.permitsNetworkEpochGrant(
            failure
        ) else {
            parking = nil
            return false
        }
        let code = ReconnectIncidentFailureCode.recordable(failure?.code)
        if var existing = parking, existing.epoch == epoch {
            existing.failureCode = code
            parking = existing
        } else {
            var deferred = parking?.deferredGrant
            if deferred?.epoch == epoch {
                deferred = nil
            }
            parking = Parking(
                epoch: epoch,
                parkedAt: now,
                failureCode: code,
                tailAttemptsUsed: 0,
                deferredGrant: deferred
            )
        }
        budgetEpoch = epoch
        return true
    }

    mutating func endParking() {
        parking = nil
    }

    /// Re-anchors the parked epoch on the Underlay captured after XDial's own
    /// attempt rolled back. Whatever changed while that attempt ran is not a
    /// host-observed settled epoch and must not earn a grant; tail progress
    /// and any deferred grant are kept so re-anchoring cannot reset bounds.
    mutating func absorbParkedUnderlay(fingerprint: String) {
        guard let current = parking,
              !fingerprint.isEmpty,
              current.epoch.underlayFingerprint != fingerprint else {
            return
        }
        let epoch = AutomaticRecoveryEpoch(
            scenarioID: current.epoch.scenarioID,
            underlayFingerprint: fingerprint,
            connectivityGeneration: current.epoch.connectivityGeneration
        )
        parking = Parking(
            epoch: epoch,
            parkedAt: current.parkedAt,
            failureCode: current.failureCode,
            tailAttemptsUsed: current.tailAttemptsUsed,
            // A grant deferred for exactly this Underlay was earned by a
            // host-observed change before the attempt ran; re-anchoring on
            // the same facts is not a budget and must not cancel it.
            deferredGrant: current.deferredGrant
        )
        budgetEpoch = epoch
    }

    mutating func recordTailAttemptStarted() {
        parking?.tailAttemptsUsed += 1
    }

    /// Decides whether a parked recovery may continue. Settled new facts
    /// grant a fresh budget subject to the rate limits; the parked epoch
    /// itself only ever earns single wake or slow-tail attempts.
    mutating func resume(
        _ trigger: AutomaticRecoveryResumeTrigger,
        observed: AutomaticRecoveryObservation,
        systemAsleep: Bool,
        at now: Date
    ) -> AutomaticRecoveryDecision {
        guard let parking else { return .rejected(.notParked) }
        guard !systemAsleep else { return .rejected(.asleep) }
        guard !observed.scenarioID.isEmpty,
              !observed.underlayFingerprint.isEmpty else {
            return .rejected(.incompleteObservation)
        }
        let connectivityRestored =
            trigger == .networkEpoch(connectivityRestored: true)
        if connectivityRestored {
            connectivityGeneration &+= 1
        }
        let epoch = AutomaticRecoveryEpoch(
            scenarioID: observed.scenarioID,
            underlayFingerprint: observed.underlayFingerprint,
            connectivityGeneration: connectivityRestored
                ? connectivityGeneration
                : parking.epoch.connectivityGeneration
        )
        let reason: AutomaticRecoveryGrantReason?
        if epoch.scenarioID != parking.epoch.scenarioID {
            reason = .scenarioChanged
        } else if epoch.underlayFingerprint
            != parking.epoch.underlayFingerprint {
            reason = .underlayChanged
        } else if connectivityRestored {
            reason = .connectivityRestored
        } else {
            reason = nil
        }

        let singleAttempt: AutomaticRecoveryAttemptKind?
        switch trigger {
        case .networkEpoch:
            singleAttempt = nil
        case .wake:
            singleAttempt = .wake
        case .slowTail:
            singleAttempt = nextTailDelay == nil
                ? nil
                : .tail(parking.tailAttemptsUsed + 1)
        }

        guard let reason else {
            if let singleAttempt {
                return .singleAttempt(singleAttempt)
            }
            return trigger == .slowTail
                ? .rejected(.tailExhausted)
                : .rejected(.duplicateEpoch)
        }
        let decision = grantOrDefer(reason, epoch: epoch, at: now)
        if case .deferred = decision, let singleAttempt {
            // The deferral is kept; the wake / tail attempt it would have
            // replaced still runs within its own bound.
            return .singleAttempt(singleAttempt)
        }
        return decision
    }

    /// Re-evaluates a deferred grant when its date arrives. It is never
    /// dropped: a still-limited grant is deferred again.
    mutating func reevaluateDeferredGrant(
        systemAsleep: Bool,
        at now: Date
    ) -> AutomaticRecoveryDecision {
        guard var parking,
              let deferred = parking.deferredGrant else {
            return .rejected(.notParked)
        }
        guard !systemAsleep else { return .rejected(.asleep) }
        guard now >= deferred.notBefore else {
            return .deferred(deferred.reason, until: deferred.notBefore)
        }
        parking.deferredGrant = nil
        self.parking = parking
        return grantOrDefer(
            deferred.reason,
            epoch: deferred.epoch,
            at: now
        )
    }

    /// "Retry now" while parked is a user intent: it always grants.
    mutating func userRetry(at now: Date) -> AutomaticRecoveryDecision {
        guard let parking else { return .rejected(.notParked) }
        applyGrant(.userRetry, epoch: parking.epoch, at: now)
        return .grant(.userRetry)
    }

    func rateLimitedGrantCount(at now: Date) -> Int {
        rateLimitedGrantTimes.filter {
            now.timeIntervalSince($0) < policy.rateLimitWindow
        }.count
    }

    func projection(at now: Date) -> AutomaticRecoveryLedgerProjection {
        AutomaticRecoveryLedgerProjection(
            parked: parking != nil,
            parkedAt: parking?.parkedAt,
            parkedScenarioID: parking?.epoch.scenarioID,
            parkedFailureCode: parking?.failureCode,
            lastGrantReason: lastGrant?.reason.rawValue,
            lastGrantAt: lastGrant?.at,
            deferredGrantReason: parking?.deferredGrant?.reason.rawValue,
            deferredGrantUntil: parking?.deferredGrant?.notBefore,
            rateLimitedGrantsInWindow: rateLimitedGrantCount(at: now),
            rateLimitedGrantLimit: policy.rateLimitedGrantLimit,
            tailAttemptsUsed: parking?.tailAttemptsUsed ?? 0,
            tailMaxAttempts: policy.tailDelays.count,
            connectivityGeneration: connectivityGeneration
        )
    }

    private mutating func grantOrDefer(
        _ reason: AutomaticRecoveryGrantReason,
        epoch: AutomaticRecoveryEpoch,
        at now: Date
    ) -> AutomaticRecoveryDecision {
        pruneGrantHistory(at: now)
        var notBefore = now
        if reason.isRateLimited,
           rateLimitedGrantTimes.count >= policy.rateLimitedGrantLimit,
           let oldest = rateLimitedGrantTimes.first {
            notBefore = max(
                notBefore,
                oldest.addingTimeInterval(policy.rateLimitWindow)
            )
        }
        if reason == .connectivityRestored,
           let last = lastGrantAtByFingerprint[epoch.underlayFingerprint] {
            notBefore = max(
                notBefore,
                last.addingTimeInterval(policy.sameFingerprintGrantInterval)
            )
        }
        guard notBefore <= now else {
            parking?.deferredGrant = DeferredGrant(
                reason: reason,
                epoch: epoch,
                notBefore: notBefore
            )
            return .deferred(reason, until: notBefore)
        }
        applyGrant(reason, epoch: epoch, at: now)
        return .grant(reason)
    }

    private mutating func applyGrant(
        _ reason: AutomaticRecoveryGrantReason,
        epoch: AutomaticRecoveryEpoch,
        at now: Date
    ) {
        budget.reset()
        budgetEpoch = epoch
        parking = nil
        lastGrant = Grant(reason: reason, at: now)
        noteGrant(for: epoch, reason: reason, at: now)
    }

    private mutating func noteGrant(
        for epoch: AutomaticRecoveryEpoch,
        reason: AutomaticRecoveryGrantReason,
        at now: Date
    ) {
        if !epoch.underlayFingerprint.isEmpty {
            lastGrantAtByFingerprint[epoch.underlayFingerprint] = now
        }
        if reason.isRateLimited {
            rateLimitedGrantTimes.append(now)
        }
        pruneGrantHistory(at: now)
    }

    private mutating func pruneGrantHistory(at now: Date) {
        let window = policy.rateLimitWindow
        let spacing = policy.sameFingerprintGrantInterval
        rateLimitedGrantTimes.removeAll {
            now.timeIntervalSince($0) >= window
        }
        lastGrantAtByFingerprint = lastGrantAtByFingerprint.filter {
            now.timeIntervalSince($0.value) < spacing
        }
    }
}

/// Decides which settled report may end the current full-recovery step.
///
/// Network Extension status callbacks and journal reads arrive at any time,
/// e.g. a screen-wake `syncStatus` right after a full wake. While an attempt
/// is scheduled, preparing or capturing the Underlay, the journal still holds
/// the previous failed transaction; that report is history, not the
/// attempt's outcome. Only the transaction the step is waiting for — the
/// failure that opened the episode, or the attempt's own transaction once it
/// exists — can decide whether to retry, park or stop.
struct AutomaticRecoveryOutcomeGate {
    enum Decision: Equatable {
        /// No full recovery is in progress.
        case notRecovering
        /// Keep reporting "reconnecting"; this report decides nothing.
        case awaitOutcome
        /// The awaited transaction settled; retry, park or stop now.
        case attemptOutcome
    }

    private(set) var awaitedTransactionID: String?

    /// The step now waits for this transaction's settled report.
    mutating func await(_ transactionID: String?) {
        awaitedTransactionID = transactionID
    }

    /// A new attempt was scheduled: until it creates its own transaction no
    /// report belongs to it.
    mutating func attemptScheduled() {
        awaitedTransactionID = nil
    }

    mutating func reset() {
        awaitedTransactionID = nil
    }

    func decide(
        recoveryInProgress: Bool,
        attemptPending: Bool,
        report: ConnectionReport?,
        currentTransactionID: String?
    ) -> Decision {
        guard recoveryInProgress else { return .notRecovering }
        guard !attemptPending,
              let awaitedTransactionID,
              let report,
              report.transactionID == awaitedTransactionID,
              report.transactionID == currentTransactionID,
              [.failed, .cancelled].contains(report.state),
              report.rollbackComplete,
              report.systemTakeoverRemoved else {
            return .awaitOutcome
        }
        return .attemptOutcome
    }
}

/// Debug projection of the ledger. It deliberately carries no Underlay
/// fingerprint or interface facts.
struct AutomaticRecoveryLedgerProjection: Codable, Equatable {
    let parked: Bool
    let parkedAt: Date?
    let parkedScenarioID: String?
    let parkedFailureCode: String?
    let lastGrantReason: String?
    let lastGrantAt: Date?
    let deferredGrantReason: String?
    let deferredGrantUntil: Date?
    let rateLimitedGrantsInWindow: Int
    let rateLimitedGrantLimit: Int
    let tailAttemptsUsed: Int
    let tailMaxAttempts: Int
    let connectivityGeneration: UInt64

    enum CodingKeys: String, CodingKey {
        case parked
        case parkedAt = "parked_at"
        case parkedScenarioID = "parked_scenario_id"
        case parkedFailureCode = "parked_failure_code"
        case lastGrantReason = "last_grant_reason"
        case lastGrantAt = "last_grant_at"
        case deferredGrantReason = "deferred_grant_reason"
        case deferredGrantUntil = "deferred_grant_until"
        case rateLimitedGrantsInWindow = "automatic_grants_last_hour"
        case rateLimitedGrantLimit = "automatic_grant_hourly_limit"
        case tailAttemptsUsed = "tail_attempts_used"
        case tailMaxAttempts = "tail_max_attempts"
        case connectivityGeneration = "connectivity_generation"
    }
}
