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
        underlayFingerprint: String
    ) -> QuietToken? {
        guard !currentDesiredScenarioID.isEmpty,
              !underlayFingerprint.isEmpty else {
            return nil
        }
        if pending == nil {
            if lastSettledTuple == SettledTuple(
                desiredScenarioID: currentDesiredScenarioID,
                underlayFingerprint: underlayFingerprint
            ) {
                return nil
            }
            let created = makePending(
                desiredScenarioID: currentDesiredScenarioID,
                underlayFingerprint: underlayFingerprint,
                underlayChanged: true
            )
            pending = created
        } else {
            pending?.underlayFingerprint = underlayFingerprint
            pending?.underlayChanged = true
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
                underlayChanged: false
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
                underlayChanged: false
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
        guard tuple != lastSettledTuple else { return nil }
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
        underlayChanged: Bool
    ) -> Pending {
        nextEpoch &+= 1
        nextRevision &+= 1
        return Pending(
            epoch: nextEpoch,
            desiredScenarioID: desiredScenarioID,
            underlayFingerprint: underlayFingerprint,
            underlayChanged: underlayChanged,
            revision: nextRevision
        )
    }

    private mutating func bumpRevision() {
        nextRevision &+= 1
        pending?.revision = nextRevision
    }
}
