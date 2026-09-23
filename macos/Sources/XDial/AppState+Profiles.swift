import Foundation
import SwiftUI

extension AppState {
    var editingRecord: ProfileRecord {
        profileLibrary.profiles.first { $0.id == profileLibrary.editingProfileID }!
    }

    var editingProfile: Profile {
        get {
            configurationCatalog.profile
        }
        set {
            profileLibrary.applyDraft(newValue, editingProfileID: profileLibrary.editingProfileID)
        }
    }

    var browsingRecord: ProfileRecord {
        profileLibrary.runtimeRecord
    }

    var configurationCatalog: ConfigurationCatalog {
        if let cached = configurationCatalogCache { return cached }
        let catalog = ConfigurationCatalog(profileLibrary)
        configurationCatalogCache = catalog
        return catalog
    }

    // Resolve IDs again on write: filtering, reordering, or a subscription refresh
    // can change array offsets while SwiftUI still holds a row's binding.
    func editingLineBinding(_ line: Line) -> Binding<Line> {
        Binding(get: { self.configurationCatalog.line(line.id) ?? line }, set: { value in
            guard let index = self.configurationCatalog.lineIndices[line.id] else { return }
            self.editingProfile.lines[index] = value
        })
    }

    func editingRuleBinding(_ rule: RuleSet) -> Binding<RuleSet> {
        Binding(get: { self.configurationCatalog.rule(rule.id) ?? rule }, set: { value in
            guard let index = self.configurationCatalog.ruleIndices[rule.id] else { return }
            self.editingProfile.ruleSets[index] = value
        })
    }

    var editingActiveProfile: Bool { true }

    func selectEditingProfile(_ id: String) {
        guard profileLibrary.profiles.contains(where: { $0.id == id }) else { return }
        profileLibrary.editingProfileID = id
        persistProfileLibrary()
    }

    func saveEditingProfile() {
        profileOperationError = nil
        editingProfile.reconcileMatchingReferences()
        profile = profileLibrary.snapshot()
        save()
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
            profile = loaded.snapshot()
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
        do { try profileLibrary.insert(record) }
        catch { profileOperationError = error.localizedDescription; return false }
        guard persistProfileLibrary() else { profileLibrary = original; return false }
        profile = profileLibrary.snapshot()
        save()
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
        !hasPendingScenarioSwitch && (try? profileLibrary.removingProfile(id)) != nil
    }

    @discardableResult
    func deleteProfile(_ id: String) -> Bool {
        guard !hasPendingScenarioSwitch else { return false }
        let original = profileLibrary
        do { profileLibrary = try profileLibrary.removingProfile(id) }
        catch { profileOperationError = error.localizedDescription; return false }
        guard persistProfileLibrary() else { profileLibrary = original; return false }
        profile = profileLibrary.snapshot()
        save()
        return true
    }

    func importSourceTemplates(_ id: String, replacing: Bool = false) {
        let original = profileLibrary
        do {
            try profileLibrary.importTemplates(profileID: id, replacing: replacing)
            guard persistProfileLibrary() else { profileLibrary = original; return }
            profile = profileLibrary.snapshot()
            save()
        } catch { profileOperationError = error.localizedDescription }
    }

    func setGroupFollowsSource(_ id: String, enabled: Bool) {
        let original = profileLibrary
        do {
            try profileLibrary.setGroupFollowsSource(id, enabled: enabled)
            guard persistProfileLibrary() else { profileLibrary = original; return }
            profile = profileLibrary.snapshot()
            save()
        } catch { profileOperationError = error.localizedDescription }
    }

    func lineSourceName(_ id: String) -> String {
        configurationCatalog.lineSources[id] ?? tr("全局", "Global")
    }

    func ruleSourceName(_ id: String) -> String {
        configurationCatalog.ruleSources[id] ?? ""
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

    func copyEditingLine(_ id: String) {
        guard editingRecord.profile.lines.contains(where: { $0.id == id }) else { return }
        var draft = editingProfile
        guard let copyID = draft.copyLine(id, suffix: tr(" 副本", " Copy")) else { return }
        editingProfile = draft
        editorPosition.expandedLineIDs.insert(copyID)
        saveEditingProfile()
    }

    func copyEditingRule(_ id: String) {
        guard editingRecord.profile.ruleSets.contains(where: { $0.id == id }) else { return }
        var draft = editingProfile
        guard let copyID = draft.copyRule(id, suffix: tr(" 副本", " Copy")) else { return }
        editingProfile = draft
        editorPosition.expandedRuleIDs.insert(copyID)
        saveEditingProfile()
    }

    func buildEditingProfileJSON() -> String {
        var snapshot = editingRecord.profile
        snapshot.profileID = editingRecord.id
        guard let data = try? JSONEncoder().encode(snapshot) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
