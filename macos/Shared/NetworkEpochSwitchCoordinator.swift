import Foundation

/// Coalesces the host-side signals emitted by one physical network change.
///
/// NWPath/default-route/DNS and SSID notifications arrive independently and
/// in either order. This value type owns no timer; AppState schedules a quiet
/// window using the returned token and asks `settle` for the one final intent.
/// A stale timer can never consume a newer epoch revision.
struct NetworkEpochSwitchCoordinator {
    struct QuietToken: Equatable {
        let epoch: UInt64
        let revision: UInt64
    }

    struct Intent: Equatable {
        let epoch: UInt64
        let desiredScenarioID: String
        let underlayFingerprint: String
        let underlayChanged: Bool
    }

    private struct Pending {
        let epoch: UInt64
        var desiredScenarioID: String
        var underlayFingerprint: String?
        var underlayChanged: Bool
        var permitsRepeatedTuple: Bool
        var revision: UInt64
    }

    private struct SettledTuple: Equatable {
        let desiredScenarioID: String
        let underlayFingerprint: String
    }

    private var nextEpoch: UInt64 = 0
    private var nextRevision: UInt64 = 0
    private var pending: Pending?
    private var lastSettledTuple: SettledTuple?

    var hasPendingIntent: Bool { pending != nil }

    mutating func observeUnderlayChange(
        currentDesiredScenarioID: String,
        underlayFingerprint: String,
        forceNewEpoch: Bool = false
    ) -> QuietToken? {
        guard !currentDesiredScenarioID.isEmpty,
              !underlayFingerprint.isEmpty else {
            return nil
        }
        if pending == nil {
            if !forceNewEpoch, lastSettledTuple == SettledTuple(
                desiredScenarioID: currentDesiredScenarioID,
                underlayFingerprint: underlayFingerprint
            ) {
                return nil
            }
            let created = makePending(
                desiredScenarioID: currentDesiredScenarioID,
                underlayFingerprint: underlayFingerprint,
                underlayChanged: true,
                permitsRepeatedTuple: forceNewEpoch
            )
            pending = created
        } else {
            pending?.underlayFingerprint = underlayFingerprint
            pending?.underlayChanged = true
            if forceNewEpoch {
                pending?.permitsRepeatedTuple = true
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
        currentDesiredScenarioID: String
    ) -> QuietToken? {
        guard !currentDesiredScenarioID.isEmpty else { return nil }
        if pending == nil {
            pending = makePending(
                desiredScenarioID: currentDesiredScenarioID,
                underlayFingerprint: nil,
                underlayChanged: false,
                permitsRepeatedTuple: false
            )
        } else {
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
        lastSettledTuple = tuple
        return Intent(
            epoch: pending.epoch,
            desiredScenarioID: pending.desiredScenarioID,
            underlayFingerprint: underlayFingerprint,
            underlayChanged: pending.underlayChanged
        )
    }

    mutating func cancel() {
        pending = nil
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
        hasPendingScenarioSwitch: Bool
    ) -> NetworkEpochTransitionAction {
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
