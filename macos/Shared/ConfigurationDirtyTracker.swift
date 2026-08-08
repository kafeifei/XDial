enum RuntimeConfigurationSignature: Equatable {
    case valid(String)
    case invalid
}

struct ConfigurationDirtyTracker<Snapshot: Equatable> {
    private(set) var isDirty = false
    private var lastSaved: Snapshot?
    private var applied: Snapshot?

    mutating func load(_ snapshot: Snapshot) {
        lastSaved = snapshot
        applied = nil
        isDirty = false
    }

    mutating func markApplied(_ snapshot: Snapshot) {
        lastSaved = snapshot
        applied = snapshot
        isDirty = false
    }

    /// Adopt the fingerprint recorded by the running transaction without
    /// discarding edits that may already have happened after it started.
    mutating func adoptApplied(_ snapshot: Snapshot) {
        applied = snapshot
        isDirty = lastSaved.map { $0 != snapshot } ?? false
    }

    mutating func recordSave(
        _ snapshot: Snapshot,
        markDirty: Bool,
        engineHoldsSnapshot: Bool
    ) {
        let changed = lastSaved != snapshot
        lastSaved = snapshot
        guard markDirty, engineHoldsSnapshot, changed else {
            return
        }
        isDirty = applied.map { $0 != snapshot } ?? true
    }

    mutating func clear() {
        applied = nil
        isDirty = false
    }
}
