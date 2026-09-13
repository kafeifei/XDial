import Foundation

extension AppState {
    var editingRecord: ProfileRecord {
        profileLibrary.profiles.first { $0.id == profileLibrary.editingProfileID }!
    }

    var editingProfile: Profile {
        get { editingRecord.profile }
        set {
            guard let index = profileLibrary.profiles.firstIndex(where: { $0.id == profileLibrary.editingProfileID }) else { return }
            profileLibrary.profiles[index].profile = newValue
        }
    }

    var browsingRecord: ProfileRecord {
        profileLibrary.profiles.first { $0.id == browsedProfileID } ?? editingRecord
    }

    var editorPosition: ProfileEditorPosition {
        get { editorPositions[profileLibrary.editingProfileID] ?? ProfileEditorPosition() }
        set { editorPositions[profileLibrary.editingProfileID] = newValue }
    }

    var editingActiveProfile: Bool { profileLibrary.editingProfileID == profileLibrary.activeProfileID }

    func selectEditingProfile(_ id: String) {
        guard profileLibrary.profiles.contains(where: { $0.id == id }) else { return }
        profileLibrary.editingProfileID = id
        settingsArea = .configuration
        persistProfileLibrary()
    }

    func saveEditingProfile() {
        profileOperationError = nil
        if editingActiveProfile {
            profile = editingProfile
            save()
        } else {
            persistProfileLibrary()
        }
    }

    func saveEditingVisualOrder() { saveEditingProfile() }

    @discardableResult
    func persistProfileLibrary() -> Bool {
        guard profileLibraryLoaded else { return false }
        do {
            try profileLibraryStore.save(profileLibrary)
            profilePersistenceError = nil
            return true
        } catch {
            profilePersistenceError = error.localizedDescription
            return false
        }
    }

    func loadProfileLibrary() {
        do {
            let existing = try profileLibraryStore.load()
            let loaded = existing ?? ProfileLibrary()
            if existing == nil { try profileLibraryStore.save(loaded) }
            profileLibrary = loaded
            profile = loaded.profiles.first { $0.id == loaded.activeProfileID }!.profile
            browsedProfileID = loaded.activeProfileID
            profileLibraryLoaded = true
            profilePersistenceError = nil
        } catch {
            profilePersistenceError = "无法读取配置库：\(error.localizedDescription)"
            profileLibraryLoaded = false
        }
    }

    @discardableResult
    func insertProfile(_ record: ProfileRecord) -> Bool {
        let original = profileLibrary
        profileLibrary.profiles.append(record)
        profileLibrary.editingProfileID = record.id
        guard persistProfileLibrary() else { profileLibrary = original; return false }
        settingsArea = .configuration
        return true
    }

    func renameEditingProfile(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = profileLibrary.profiles.firstIndex(where: { $0.id == editingRecord.id }) else { return }
        profileLibrary.profiles[index].name = trimmed
        persistProfileLibrary()
    }

    var canDeleteEditingProfile: Bool {
        profileLibrary.profiles.count > 1 &&
        !(editingActiveProfile && engine.status != "disconnected") &&
        !hasPendingScenarioSwitch
    }

    func deleteEditingProfile() {
        guard canDeleteEditingProfile else { return }
        let original = profileLibrary
        let id = editingRecord.id
        profileLibrary.profiles.removeAll { $0.id == id }
        let fallback = profileLibrary.profiles[0]
        profileLibrary.editingProfileID = fallback.id
        if profileLibrary.activeProfileID == id { profileLibrary.activeProfileID = fallback.id }
        guard persistProfileLibrary() else { profileLibrary = original; return }
        if original.activeProfileID == id { profile = fallback.profile }
        if browsedProfileID == id { browsedProfileID = fallback.id }
        editorPositions.removeValue(forKey: id)
    }

    func copyEditingScenario(_ id: String) {
        guard var scenario = editingProfile.scenarios.first(where: { $0.id == id }) else { return }
        scenario.id = UUID().uuidString
        scenario.name += tr(" 副本", " Copy")
        scenario.matchSSIDs = []
        editingProfile.scenarios.append(scenario)
        editorPosition.expandedScenarioID = scenario.id
        saveEditingProfile()
    }

    func buildEditingProfileJSON() -> String {
        var snapshot = editingProfile
        snapshot.profileID = editingRecord.id
        guard let data = try? JSONEncoder().encode(snapshot) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
