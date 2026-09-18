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
        persistProfileLibrary()
    }

    func saveEditingProfile() {
        profileOperationError = nil
        editingProfile.reconcileMatchingReferences()
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
            let loaded = try profileLibraryStore.loadOrCreate {
                try ProfileLibraryMigration.initialLibrary {
                    try ProfileDocumentService.convertLegacyProfile($0, id: $1)
                }
            }
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
        return true
    }

    @discardableResult
    func updateProfileMetadata(_ id: String, name: String, source: ProfileSource?) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = profileLibrary.profiles.firstIndex(where: { $0.id == id }) else { return false }
        let original = profileLibrary
        profileLibrary.profiles[index].name = trimmed
        profileLibrary.profiles[index].source = source
        guard persistProfileLibrary() else { profileLibrary = original; return false }
        return true
    }

    func canDeleteProfile(_ id: String) -> Bool {
        profileLibrary.profiles.contains(where: { $0.id == id }) &&
        profileLibrary.profiles.count > 1 &&
        !(id == profileLibrary.activeProfileID && engine.status != "disconnected") &&
        !hasPendingScenarioSwitch
    }

    @discardableResult
    func deleteProfile(_ id: String) -> Bool {
        guard canDeleteProfile(id) else { return false }
        let original = profileLibrary
        profileLibrary.profiles.removeAll { $0.id == id }
        let fallback = profileLibrary.profiles[0]
        if profileLibrary.editingProfileID == id { profileLibrary.editingProfileID = fallback.id }
        if profileLibrary.activeProfileID == id { profileLibrary.activeProfileID = fallback.id }
        guard persistProfileLibrary() else { profileLibrary = original; return false }
        if original.activeProfileID == id { profile = fallback.profile }
        if browsedProfileID == id { browsedProfileID = fallback.id }
        editorPositions.removeValue(forKey: id)
        return true
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
