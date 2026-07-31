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
