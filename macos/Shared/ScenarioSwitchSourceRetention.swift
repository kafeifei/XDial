import Foundation

/// Facts the Provider holds at a committed Switch, before it decides how the
/// source generation's already-attached relays end.
struct ScenarioSwitchSourceDrainFacts: Equatable {
    /// The request carried a host network epoch (an automatic Underlay
    /// refresh), not a user-initiated Scenario change or reconnect.
    let networkEpochSwitch: Bool
    let sourceScenarioID: String
    let targetScenarioID: String
    let sourceConfigurationFingerprint: String
    let targetConfigurationFingerprint: String
    /// `HostUnderlayIdentity.pathIdentity` of each generation's snapshot;
    /// `nil` when the host did not provide one.
    let sourcePathIdentity: String?
    let targetPathIdentity: String?
}

enum ScenarioSwitchSourceDrainDecision: Equatable {
    /// Grace `ScenarioSwitchSourceDrainPolicy.handoffGrace`, then cancel every
    /// source relay and retire the source generation.
    case boundedDrain
    /// Keep flow-owning relays on the still-running source Box until they
    /// finish, at most `limit` seconds. Association-owning (UDP) relays still
    /// take the bounded drain and re-associate with the committed generation.
    case retainFlows(limit: TimeInterval)
}

/// A committed Switch replaces the source Box. Cancelling a TCP relay ends
/// the application's connection, which is only necessary when the source
/// generation's sockets may no longer be valid or its routing is no longer
/// what the user wants. The one case that provably needs neither is an
/// automatic network-epoch Switch that recompiles the identical Scenario and
/// configuration over the identical default path (same default interface,
/// IPv4 addresses and default routers — for example a DNS-only change).
enum ScenarioSwitchSourceDrainPolicy {
    static let handoffGrace: TimeInterval = 1
    /// Long enough for interactive sessions and finite transfers that were in
    /// progress across a DNS-only refresh to finish or reach a natural pause;
    /// short enough that a second complete Box (memory, background probes,
    /// borrowed Line leases) never outlives the event that created it by more
    /// than minutes. Any later Switch, stop or path change retires it sooner.
    static let retainedFlowLimit: TimeInterval = 10 * 60

    static func decide(
        _ facts: ScenarioSwitchSourceDrainFacts
    ) -> ScenarioSwitchSourceDrainDecision {
        guard
            facts.networkEpochSwitch,
            !facts.sourceScenarioID.isEmpty,
            facts.sourceScenarioID == facts.targetScenarioID,
            !facts.sourceConfigurationFingerprint.isEmpty,
            facts.sourceConfigurationFingerprint
                == facts.targetConfigurationFingerprint,
            let sourcePath = facts.sourcePathIdentity,
            let targetPath = facts.targetPathIdentity,
            HostUnderlayIdentity.isValidPathIdentity(sourcePath),
            sourcePath == targetPath
        else {
            return .boundedDrain
        }
        return .retainFlows(limit: retainedFlowLimit)
    }
}

/// Provider engine-queue state for the single retained source generation.
///
/// Invariant: Line leases are held by the committed generation plus at most
/// one other generation — either the one candidate being prepared or this
/// retained source, never both. A retained source must end before any
/// candidate is admitted (latest-wins), and a second source cannot be retained
/// while one is held.
struct ScenarioSwitchSourceRetention {
    enum EndReason: String, Equatable {
        case flowsFinished = "flows-finished"
        case limitReached = "limit-reached"
        case successorCandidate = "successor-candidate"
        case stopped = "stopped"
    }

    struct Retained: Equatable {
        let token: UUID
        let sourceGeneration: String
        let committedGeneration: String
        let flowCount: Int
        let deadline: Date
    }

    private(set) var retained: Retained?

    var holdsSource: Bool {
        retained != nil
    }

    /// A new candidate may borrow Line leases only when no source is retained.
    var admitsCandidate: Bool {
        retained == nil
    }

    /// Returns `nil` (and changes nothing) when there is nothing to retain or
    /// a source is already held; the caller then drains and retires.
    mutating func begin(
        sourceGeneration: String,
        committedGeneration: String,
        flowCount: Int,
        limit: TimeInterval,
        now: Date = Date()
    ) -> Retained? {
        guard
            retained == nil,
            flowCount > 0,
            limit > 0,
            !sourceGeneration.isEmpty,
            sourceGeneration != committedGeneration
        else {
            return nil
        }
        let value = Retained(
            token: UUID(),
            sourceGeneration: sourceGeneration,
            committedGeneration: committedGeneration,
            flowCount: flowCount,
            deadline: now.addingTimeInterval(limit)
        )
        retained = value
        return value
    }

    /// Timer and natural-completion callbacks: only the retention that
    /// scheduled them can end it, so a late callback is a no-op.
    mutating func end(token: UUID) -> Retained? {
        guard let value = retained, value.token == token else {
            return nil
        }
        retained = nil
        return value
    }

    /// A successor candidate, stop or fatal teardown ends whatever is held.
    mutating func endCurrent() -> Retained? {
        let value = retained
        retained = nil
        return value
    }
}
