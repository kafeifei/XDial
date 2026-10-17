import Foundation

/// Keeps a manual Scenario selection authoritative on the same Wi-Fi. An
/// Underlay refresh can re-sample that Wi-Fi without becoming a new SSID
/// activation. Missing SSID reads are not proof that the network changed.
struct SSIDScenarioSelectionState {
    private enum Network {
        case unknown
        case connected(String)
        case disconnected
    }

    private var network: Network = .unknown
    private var hasManualSelection = false

    mutating func noteManualSelection() {
        hasManualSelection = true
    }

    /// Call only for a confirmed Wi-Fi disconnect/power-off, never for a nil
    /// SSID, lost permission, or an unavailable Internet path. Rejoining the
    /// same SSID after this boundary is a new activation.
    mutating func noteWiFiDisconnected() {
        network = .disconnected
        hasManualSelection = false
    }

    /// Returns the allowed automatic match, or nil to retain the caller's
    /// desired Scenario. `forceMatching` is reserved for an explicit edit of
    /// the currently observed SSID's matching rule.
    mutating func resolve(
        ssid: String?,
        matchedScenarioID: String?,
        forceMatching: Bool = false
    ) -> String? {
        guard let ssid, !ssid.isEmpty else { return nil }
        switch network {
        case let .connected(previousSSID):
            if previousSSID != ssid {
                hasManualSelection = false
            }
        case .disconnected:
            hasManualSelection = false
        case .unknown:
            // A first sample arriving after a manual click establishes that
            // click's network baseline; it must not undo the click.
            break
        }
        network = .connected(ssid)
        if forceMatching {
            hasManualSelection = false
        }
        return hasManualSelection ? nil : matchedScenarioID
    }
}

/// Coalesces the host-side signals emitted by one physical network change.
///
/// NWPath/default-route/DNS and SSID notifications arrive independently and
/// in either order. This value type owns no timer; AppState schedules a quiet
/// window using the returned token and asks `settle` for the one final intent.
/// A stale timer can never consume a newer epoch revision.
struct NetworkEpochSwitchCoordinator {
    enum CompletionOutcome: Equatable {
        case succeeded
        case retryableFailure
        case terminalFailure
        case invalidated
    }

    struct QuietToken: Equatable {
        let epoch: UInt64
        let revision: UInt64
    }

    struct Intent: Equatable {
        let epoch: UInt64
        let desiredScenarioID: String
        let underlayFingerprint: String
        let underlayChanged: Bool
        /// The host observed an unsatisfied -> satisfied path edge inside
        /// this epoch. A parked recovery treats it as a connectivity
        /// generation, not as a new Underlay fingerprint.
        var connectivityRestored = false
    }

    private struct Pending {
        let epoch: UInt64
        var desiredScenarioID: String
        var underlayFingerprint: String?
        var underlayChanged: Bool
        var permitsRepeatedTuple: Bool
        var connectivityRestored = false
        var revision: UInt64
    }

    private struct SettledTuple: Equatable {
        let desiredScenarioID: String
        let underlayFingerprint: String
    }

    private var nextEpoch: UInt64 = 0
    private var nextRevision: UInt64 = 0
    private var pending: Pending?
    private var activeIntent: Intent?
    private var lastSettledTuple: SettledTuple?

    var hasPendingIntent: Bool { pending != nil }
    var hasActiveIntent: Bool { activeIntent != nil }
    var pendingDesiredScenarioID: String? { pending?.desiredScenarioID }

    func hasUnderlayFingerprint(_ fingerprint: String) -> Bool {
        pending?.underlayFingerprint == fingerprint
    }

    /// `connectivityRestored` marks a host-observed path restoration edge.
    /// Recovery preparation re-samples with `forceNewEpoch` but is not such
    /// an edge, so the two facts stay separate.
    mutating func observeUnderlayChange(
        currentDesiredScenarioID: String,
        underlayFingerprint: String,
        forceNewEpoch: Bool = false,
        connectivityRestored: Bool = false
    ) -> QuietToken? {
        guard !currentDesiredScenarioID.isEmpty,
              !underlayFingerprint.isEmpty else {
            return nil
        }
        if pending == nil {
            let observedTuple = SettledTuple(
                desiredScenarioID: currentDesiredScenarioID,
                underlayFingerprint: underlayFingerprint
            )
            if !forceNewEpoch,
               lastSettledTuple == observedTuple
                || activeIntent.map({ tuple(for: $0) }) == observedTuple {
                return nil
            }
            var created = makePending(
                desiredScenarioID: currentDesiredScenarioID,
                underlayFingerprint: underlayFingerprint,
                underlayChanged: true,
                permitsRepeatedTuple: forceNewEpoch
            )
            created.connectivityRestored = connectivityRestored
            pending = created
        } else {
            pending?.underlayFingerprint = underlayFingerprint
            pending?.underlayChanged = true
            if forceNewEpoch {
                pending?.permitsRepeatedTuple = true
            }
            if connectivityRestored {
                pending?.connectivityRestored = true
            }
            bumpRevision()
        }
        return currentToken
    }

    /// Records the latest Scenario decision made from an SSID sample. The
    /// caller also feeds the existing desired Scenario when the latest sample
    /// has no match, so a transient earlier match cannot survive the quiet
    /// window after Wi-Fi has already moved again.
    mutating func observeSSIDResolution(
        desiredScenarioID: String
    ) -> QuietToken? {
        guard !desiredScenarioID.isEmpty else { return nil }
        if pending == nil {
            let created = makePending(
                desiredScenarioID: desiredScenarioID,
                underlayFingerprint: nil,
                underlayChanged: false,
                permitsRepeatedTuple: false
            )
            pending = created
        } else {
            pending?.desiredScenarioID = desiredScenarioID
            bumpRevision()
        }
        return currentToken
    }

    /// CoreWLAN announces that its SSID value is changing before the stable
    /// value is readable. Treat that announcement as part of the current
    /// physical epoch so an Underlay-only timer cannot settle just before the
    /// delayed SSID sample arrives.
    mutating func observeSSIDSettling(
        currentDesiredScenarioID: String,
        forceNewEpoch: Bool = false
    ) -> QuietToken? {
        guard !currentDesiredScenarioID.isEmpty else { return nil }
        if pending == nil {
            pending = makePending(
                desiredScenarioID: currentDesiredScenarioID,
                underlayFingerprint: nil,
                underlayChanged: false,
                permitsRepeatedTuple: forceNewEpoch
            )
        } else {
            if forceNewEpoch {
                pending?.permitsRepeatedTuple = true
            }
            bumpRevision()
        }
        return currentToken
    }

    /// The quiet-window owner re-samples Underlay immediately before settle.
    /// This fills SSID-only epochs and replaces a notification-time snapshot
    /// when route/DNS facts continued converging during the debounce window.
    mutating func refreshUnderlayFingerprint(
        _ underlayFingerprint: String
    ) -> QuietToken? {
        guard !underlayFingerprint.isEmpty,
              pending != nil else {
            return nil
        }
        if pending?.underlayFingerprint != underlayFingerprint {
            pending?.underlayFingerprint = underlayFingerprint
            bumpRevision()
        }
        return currentToken
    }

    mutating func noteUnmatchedSSID() {
        // A real, non-empty SSID with no match is still an SSID transition.
        // It preserves the current Scenario but separates a later return to a
        // previously seen (Scenario, Underlay) tuple from a delayed duplicate.
        lastSettledTuple = nil
        activeIntent = nil
    }

    func isCurrent(_ token: QuietToken) -> Bool {
        currentToken == token
    }

    mutating func settle(_ token: QuietToken) -> Intent? {
        guard let pending,
              pending.epoch == token.epoch,
              pending.revision == token.revision,
              let underlayFingerprint = pending.underlayFingerprint,
              !underlayFingerprint.isEmpty else {
            return nil
        }
        self.pending = nil
        let tuple = SettledTuple(
            desiredScenarioID: pending.desiredScenarioID,
            underlayFingerprint: underlayFingerprint
        )
        guard pending.permitsRepeatedTuple || tuple != lastSettledTuple else {
            return nil
        }
        guard pending.permitsRepeatedTuple
                || activeIntent.map({ self.tuple(for: $0) }) != tuple else {
            return nil
        }
        let intent = Intent(
            epoch: pending.epoch,
            desiredScenarioID: pending.desiredScenarioID,
            underlayFingerprint: underlayFingerprint,
            underlayChanged: pending.underlayChanged,
            connectivityRestored: pending.connectivityRestored
        )
        activeIntent = intent
        return intent
    }

    /// Completes only the currently active settled intent. Retryable failures
    /// keep that identity active so repeated notifications cannot create a
    /// second budget. Terminal outcomes are remembered for tuple de-duplication;
    /// explicit invalidation leaves the tuple eligible for a future epoch.
    @discardableResult
    mutating func complete(
        _ intent: Intent,
        outcome: CompletionOutcome
    ) -> Bool {
        guard activeIntent == intent else { return false }
        switch outcome {
        case .retryableFailure:
            return true
        case .succeeded, .terminalFailure:
            lastSettledTuple = tuple(for: intent)
            activeIntent = nil
        case .invalidated:
            activeIntent = nil
        }
        return true
    }

    mutating func cancel() {
        pending = nil
        activeIntent = nil
        nextRevision &+= 1
    }

    private var currentToken: QuietToken? {
        pending.map {
            QuietToken(epoch: $0.epoch, revision: $0.revision)
        }
    }

    private mutating func makePending(
        desiredScenarioID: String,
        underlayFingerprint: String?,
        underlayChanged: Bool,
        permitsRepeatedTuple: Bool
    ) -> Pending {
        nextEpoch &+= 1
        nextRevision &+= 1
        return Pending(
            epoch: nextEpoch,
            desiredScenarioID: desiredScenarioID,
            underlayFingerprint: underlayFingerprint,
            underlayChanged: underlayChanged,
            permitsRepeatedTuple: permitsRepeatedTuple,
            revision: nextRevision
        )
    }

    private mutating func bumpRevision() {
        nextRevision &+= 1
        pending?.revision = nextRevision
    }

    private func tuple(for intent: Intent) -> SettledTuple {
        SettledTuple(
            desiredScenarioID: intent.desiredScenarioID,
            underlayFingerprint: intent.underlayFingerprint
        )
    }
}

enum UnderlayPathTransitionAction: Equatable {
    case none
    case cancelPending
    case scheduleRefresh(allowEquivalentSnapshot: Bool)
}

/// Separates a connectivity epoch from an interface snapshot change. A Wi-Fi
/// network can lose and regain Internet while its interface, route and DNS
/// snapshot remain byte-for-byte identical.
struct UnderlayPathTransitionState {
    private enum Availability {
        case initial
        case available
        case unavailable
        case restoring
    }

    private var availability: Availability = .initial

    mutating func observe(
        isSatisfied: Bool,
        hasCompleteSnapshot: Bool,
        snapshotMatchesBaseline: Bool
    ) -> UnderlayPathTransitionAction {
        guard isSatisfied else {
            availability = .unavailable
            return .cancelPending
        }
        if availability == .unavailable {
            availability = .restoring
        }
        guard hasCompleteSnapshot else { return .none }
        if availability == .restoring {
            availability = .available
            return .scheduleRefresh(allowEquivalentSnapshot: true)
        }
        availability = .available
        return snapshotMatchesBaseline
            ? .cancelPending
            : .scheduleRefresh(allowEquivalentSnapshot: false)
    }
}

/// macOS reports an NWPath unavailable -> satisfied cycle while the machine
/// wakes even when the committed Underlay is byte-for-byte unchanged. That is
/// a power lifecycle boundary, not a network epoch: the existing Provider and
/// its Line-local recovery remain authoritative. A materially changed snapshot
/// still proceeds, and a later real connectivity restoration is outside this
/// bounded coalescing window.
///
/// `snapshotMatchesBaseline` must compare with the Underlay the committed
/// generation actually runs on (or a parked recovery was decided on), never
/// with a newer snapshot whose epoch failed to commit: only the former proves
/// the running state is still current after the wake.
struct SystemWakeUnderlayPolicy {
    static let equivalentRestorationWindow: TimeInterval = 30

    static func suppressesEquivalentRestoration(
        connectivityRestored: Bool,
        snapshotMatchesBaseline: Bool,
        secondsSinceSystemWake: TimeInterval?
    ) -> Bool {
        guard connectivityRestored,
              snapshotMatchesBaseline,
              let secondsSinceSystemWake else {
            return false
        }
        return secondsSinceSystemWake >= 0
            && secondsSinceSystemWake <= equivalentRestorationWindow
    }
}

enum SystemSleepNetworkEpochAction: Equatable {
    case evaluateCurrentPath
    case deferUntilWake
}

/// Prevents Dark Wake path churn from becoming a sequence of data-plane
/// generations. The host records the power boundary before Network.framework
/// callbacks are consumed; the first full wake always performs one fresh
/// Underlay capture, which either proves the committed snapshot is still
/// equivalent or emits one material network epoch.
struct SystemSleepNetworkEpochGate {
    private var isSleeping = false

    var defersNetworkWork: Bool { isSleeping }

    mutating func noteSystemWillSleep() {
        isSleeping = true
    }

    mutating func noteSystemDidWake() {
        isSleeping = false
    }

    mutating func observeNetworkSignal() -> SystemSleepNetworkEpochAction {
        isSleeping ? .deferUntilWake : .evaluateCurrentPath
    }
}

enum NetworkEpochTransitionAction: Equatable {
    case none
    case switchScenario(requiresUnderlayRefresh: Bool)
    case persistScenario
    /// Full recovery is parked after exhausting its budget. The settled epoch
    /// goes to the recovery ledger, which decides whether it earns a new
    /// budget; it never becomes a manual connection.
    case resumeParkedRecovery
}

/// A network epoch can carry two independent facts: the host Underlay changed,
/// and the SSID selected a Scenario. An unchanged Scenario still enters the
/// staged Switch transaction when its Underlay epoch changes, so the committed
/// generation keeps serving traffic until the replacement is fully ready.
struct NetworkEpochTransitionPolicy {
    static func decide(
        desiredScenarioID: String,
        currentDesiredScenarioID: String,
        committedScenarioID: String,
        underlayChanged: Bool,
        keepsConnection: Bool,
        runtimeStatus: String,
        hasPendingScenarioSwitch: Bool,
        automaticRecoveryParked: Bool = false
    ) -> NetworkEpochTransitionAction {
        if automaticRecoveryParked {
            // Explicit disconnect withdraws the intent and ends parking; an
            // SSID-only repeat of the current choice carries no new fact.
            guard keepsConnection,
                  runtimeStatus == "disconnected",
                  !hasPendingScenarioSwitch,
                  underlayChanged
                    || desiredScenarioID != currentDesiredScenarioID else {
                return .none
            }
            return .resumeParkedRecovery
        }

        let unchangedCommittedScenario =
            !desiredScenarioID.isEmpty
            && desiredScenarioID == currentDesiredScenarioID
            && desiredScenarioID == committedScenarioID
            && !hasPendingScenarioSwitch

        if unchangedCommittedScenario {
            guard underlayChanged,
                  keepsConnection,
                  runtimeStatus == "connected" else {
                return .none
            }
            return .switchScenario(requiresUnderlayRefresh: true)
        }

        if !underlayChanged,
           desiredScenarioID == currentDesiredScenarioID {
            return .none
        }
        return keepsConnection
            ? .switchScenario(
                requiresUnderlayRefresh: underlayChanged
            )
            : .persistScenario
    }
}

/// A committed generation whose network epoch could not be switched keeps
/// running on the Underlay it was started with. When that Underlay's default
/// interface no longer exists the generation cannot be proven healthy, so an
/// automatic epoch whose Switch has finally failed escalates to a full
/// rollback and automatic recovery. While the old default interface still
/// exists the old generation remains authoritative.
enum StaleCommittedGenerationPolicy {
    struct Interface: Equatable {
        let name: String
        let index: Int
    }

    static func shouldEscalate(
        switchFinallyFailed: Bool,
        automaticEpoch: Bool,
        committedDefaultInterface: Interface?,
        currentInterfaces: [Interface]
    ) -> Bool {
        guard switchFinallyFailed,
              automaticEpoch,
              let committedDefaultInterface,
              !committedDefaultInterface.name.isEmpty,
              !currentInterfaces.isEmpty else {
            return false
        }
        // The generation was built with this exact interface identity; a
        // same-named interface with a new index is a different interface.
        return !currentInterfaces.contains(committedDefaultInterface)
    }
}
