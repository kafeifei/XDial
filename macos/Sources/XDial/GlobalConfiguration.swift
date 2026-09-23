import CryptoKit
import Foundation

struct GlobalGroupSource: Codable, Hashable {
    var profileID: String
    var groupID: String
    var followsMembers: Bool
    var sourceMembers: [String]
}

extension Profile {
    @discardableResult
    mutating func copyLine(_ id: String, suffix: String) -> String? {
        guard let index = lines.firstIndex(where: { $0.id == id }),
              lines[index].type != "direct", !lines[index].isGroup else { return nil }
        var copy = lines[index]
        copy.id = UUID().uuidString
        copy.name = Self.copyName(copy.name, suffix: suffix, existing: lines.map(\.name))
        copy.verified = false
        copy.identityProfileID = ""
        copy.identityHostname = ""
        lines.insert(copy, at: index + 1)
        return copy.id
    }

    @discardableResult
    mutating func copyRule(_ id: String, suffix: String) -> String? {
        guard let index = ruleSets.firstIndex(where: { $0.id == id }) else { return nil }
        func independent(_ rule: RuleSet) -> RuleSet {
            var copy = rule
            copy.id = UUID().uuidString
            copy.conditions = rule.conditions.map(independent)
            return copy
        }
        var copy = independent(ruleSets[index])
        copy.name = Self.copyName(copy.name, suffix: suffix, existing: ruleSets.map(\.name))
        ruleSets.insert(copy, at: index + 1)
        return copy.id
    }

    private static func copyName(_ name: String, suffix: String, existing: [String]) -> String {
        let names = Set(existing)
        let base = name + suffix
        var result = base
        var number = 2
        while names.contains(result) { result = "\(base) \(number)"; number += 1 }
        return result
    }
}

extension ProfileLibrary {
    /// An editor/runtime value, never a second persisted copy of source resources.
    func snapshot() -> Profile {
        var result = Profile()
        result.profileID = Self.configurationID
        result.lines = [Line(id: "direct", name: "直连", type: "direct", verified: true)]
        for record in profiles {
            result.lines += record.profile.lines.filter { $0.id != "direct" }.map { source in
                var line = source
                line.identityProfileID = record.id
                line.identityHostname = record.profile.tailscale.hostname
                return line
            }
            result.ruleSets += record.profile.ruleSets
            result.importWarnings += record.profile.importWarnings
            result.importAdjustments += record.profile.importAdjustments
        }
        result.lines += groups
        result.scenarios = scenarios
        result.activeScenarioID = activeScenarioID
        return result
    }

    var runtimeRecord: ProfileRecord {
        ProfileRecord(id: Self.configurationID, name: "全部场景", profile: snapshot())
    }

    func owner(ofLine id: String) -> ProfileRecord? {
        guard id != "direct" else { return nil }
        return profiles.first { $0.profile.lines.contains { $0.id == id } }
    }

    func owner(ofRule id: String) -> ProfileRecord? {
        profiles.first { $0.profile.ruleSets.contains { $0.id == id } }
    }

    /// Whole-catalog bindings preserve references while resource lists filter by owner.
    mutating func applyDraft(_ draft: Profile, editingProfileID: String) {
        let previousLineIDs = Set(profiles.flatMap { $0.profile.lines.map(\.id) })
        let previousRuleIDs = Set(profiles.flatMap { $0.profile.ruleSets.map(\.id) })
        for index in profiles.indices {
            let lineIDs = Set(profiles[index].profile.lines.map(\.id))
            let ruleIDs = Set(profiles[index].profile.ruleSets.map(\.id))
            let selected = profiles[index].id == editingProfileID
            profiles[index].profile.lines = draft.lines.filter {
                !$0.isGroup && (lineIDs.contains($0.id) || (selected && !previousLineIDs.contains($0.id)))
            }.map { source in
                var line = source
                line.identityProfileID = ""; line.identityHostname = ""
                return line
            }
            profiles[index].profile.ruleSets = draft.ruleSets.filter {
                ruleIDs.contains($0.id) || (selected && !previousRuleIDs.contains($0.id))
            }
            if selected && !draft.tailscale.hostname.isEmpty {
                profiles[index].profile.tailscale = draft.tailscale
            }
        }
        groups = draft.lines.filter(\.isGroup)
        scenarios = draft.scenarios
        activeScenarioID = draft.activeScenarioID
        let retainedGroups = Set(groups.map(\.id))
        groupSources = groupSources.filter { retainedGroups.contains($0.key) }
        let retainedScenes = Set(scenarios.map(\.id))
        scenarioSources = scenarioSources.filter { retainedScenes.contains($0.key) }
    }

    mutating func promoteEmbeddedObjects() throws {
        guard profiles.allSatisfy({ $0.profile.subscriptions.isEmpty }) else {
            throw ProfileLibraryError.invalid("旧配置包含嵌套订阅，请先转换为独立 Profile；原配置未修改")
        }
        let oldActiveProfileID = activeProfileID
        var desired = activeScenarioID
        // Legacy libraries can contain the same local IDs in different Profiles.
        // Persist the translation so later subscription refreshes use the same IDs.
        var occupied = Set(groups.map(\.id) + scenarios.map(\.id))
        for index in profiles.indices {
            var record = profiles[index]
            let original = record.profile
            var mapping = record.resourceIDs ?? [:]
            for id in Self.objectIDs(original) where id != "direct" && occupied.contains(mapping[id] ?? id) {
                if mapping[id] == nil {
                    mapping[id] = Self.scopedID(profileID: record.id, objectID: id)
                }
            }
            record.resourceIDs = mapping.isEmpty ? nil : mapping
            record.profile = Self.remap(original, using: mapping)
            if let baseline = record.baseline { record.baseline = Self.remap(baseline, using: mapping) }
            if record.id == oldActiveProfileID { desired = record.profile.activeScenarioID }
            occupied.formUnion(Self.objectIDs(record.profile))
            appendTemplates(from: record, rename: false)
            record.profile = Self.resourcesOnly(record.profile)
            profiles[index] = record
        }
        activeScenarioID = desired.isEmpty ? (scenarios.first?.id ?? "") : desired
        activeProfileID = Self.configurationID
        schemaVersion = 3
        try validateReferences(allowEmptyGroups: true)
    }

    mutating func insert(_ incoming: ProfileRecord) throws {
        guard incoming.profile.subscriptions.isEmpty else {
            throw ProfileLibraryError.invalid("不能将嵌套订阅导入资源 Profile")
        }
        guard !profiles.contains(where: { $0.id == incoming.id }), incoming.id != Self.configurationID else {
            throw ProfileLibraryError.invalid("配置身份重复")
        }
        var candidate = self
        var record = incoming
        let occupied = Set(Self.objectIDs(snapshot()))
        var mapping = record.resourceIDs ?? [:]
        for id in Self.objectIDs(record.profile) where id != "direct" && occupied.contains(id) {
            mapping[id] = Self.scopedID(profileID: record.id, objectID: id)
        }
        record.resourceIDs = mapping.isEmpty ? nil : mapping
        record.profile = Self.remap(record.profile, using: mapping)
        if let baseline = record.baseline { record.baseline = Self.remap(baseline, using: mapping) }
        candidate.appendTemplates(from: record, rename: true)
        record.profile = Self.resourcesOnly(record.profile)
        candidate.profiles.append(record)
        candidate.editingProfileID = record.id
        if candidate.activeScenarioID.isEmpty { candidate.activeScenarioID = candidate.scenarios.first?.id ?? "" }
        try candidate.validateReferences(allowEmptyGroups: true)
        self = candidate
    }

    private mutating func appendTemplates(from record: ProfileRecord, rename: Bool, replace: Bool = false) {
        for group in record.profile.lines where group.isGroup {
            if let index = groups.firstIndex(where: { $0.id == group.id }) {
                guard replace else { continue }
                groups[index] = group
            } else { groups.append(group) }
            groupSources[group.id] = GlobalGroupSource(profileID: record.id, groupID: group.id,
                followsMembers: record.source != nil, sourceMembers: group.groupMembers)
        }
        for source in record.profile.scenarios {
            var scene = source
            if rename { scene.name = record.profile.scenarios.count == 1 ? record.name : record.name + " · " + source.name }
            if let index = scenarios.firstIndex(where: { $0.id == scene.id }) {
                guard replace else { continue }
                // Reimporting routing must not duplicate or reassign activation triggers.
                scene.matchSSIDs = scenarios[index].matchSSIDs
                scenarios[index] = scene
            } else {
                scenarios.append(scene)
            }
            scenarioSources[scene.id] = record.id
        }
    }

    func availableTemplateCount(profileID: String) -> Int {
        guard let baseline = profiles.first(where: { $0.id == profileID })?.baseline else { return 0 }
        return baseline.lines.filter { source in source.isGroup && !groups.contains(where: { $0.id == source.id }) }.count
            + baseline.scenarios.filter { source in !scenarios.contains(where: { $0.id == source.id }) }.count
    }

    mutating func importTemplates(profileID: String, replacing: Bool = false) throws {
        guard var record = profiles.first(where: { $0.id == profileID }), let baseline = record.baseline else { return }
        var candidate = self
        record.profile = baseline
        candidate.appendTemplates(from: record, rename: true, replace: replacing)
        try candidate.validateReferences(allowEmptyGroups: true)
        self = candidate
    }

    mutating func setGroupFollowsSource(_ id: String, enabled: Bool) throws {
        guard var source = groupSources[id],
              let index = groups.firstIndex(where: { $0.id == id }),
              let record = profiles.first(where: { $0.id == source.profileID }), record.source != nil else {
            throw ProfileLibraryError.invalid("线路组的来源订阅不存在")
        }
        var candidate = self
        if enabled {
            guard let group = record.baseline?.lines.first(where: { $0.id == source.groupID && $0.isGroup }) else {
                throw ProfileLibraryError.invalid("订阅中已没有此线路组，无法跟随")
            }
            if candidate.groups[index].type == "selector", candidate.groups[index].groupDefault.isEmpty {
                candidate.groups[index].groupDefault = candidate.groups[index].groupMembers.first ?? ""
            }
            let manual = candidate.groups[index].groupMembers.filter { !source.sourceMembers.contains($0) }
            candidate.groups[index].groupMembers = Self.unique(group.groupMembers + manual)
            source.sourceMembers = group.groupMembers
        }
        source.followsMembers = enabled
        candidate.groupSources[id] = source
        try candidate.validateReferences(allowEmptyGroups: true)
        self = candidate
    }

    func refreshing(profileID: String, incoming original: Profile, at date: Date = Date()) throws -> ProfileLibrary {
        guard original.subscriptions.isEmpty else {
            throw ProfileLibraryError.invalid("订阅包含旧式嵌套订阅，原配置已保留")
        }
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            throw ProfileLibraryError.invalid("订阅已不存在")
        }
        var candidate = self
        let record = profiles[index]
        let previous = record.baseline ?? record.profile
        var mapping = record.resourceIDs ?? [:]
        let previousIDs = Set(Self.objectIDs(previous))
        let occupied = Set(Self.objectIDs(snapshot()))
        for id in Self.objectIDs(original) where id != "direct" && mapping[id] == nil &&
            !previousIDs.contains(id) && occupied.contains(id) {
            mapping[id] = Self.scopedID(profileID: record.id, objectID: id)
        }
        let incoming = Self.remap(original, using: mapping)
        candidate.profiles[index].resourceIDs = mapping.isEmpty ? nil : mapping
        guard Set(incoming.importWarnings).isSubset(of: Set(previous.importWarnings)) else {
            throw ProfileLibraryError.invalid("订阅新增了无法执行的规则，已保留原配置")
        }
        var resources = Self.resourcesOnly(incoming)
        resources.tailscale = record.profile.tailscale
        resources.lines += record.profile.lines.filter { local in !previous.lines.contains { $0.id == local.id } }
        resources.ruleSets += record.profile.ruleSets.filter { local in !previous.ruleSets.contains { $0.id == local.id } }
        resources.lines = Self.ordered(resources.lines, like: record.profile.lines)
        resources.ruleSets = Self.ordered(resources.ruleSets, like: record.profile.ruleSets)
        candidate.profiles[index].profile = resources
        candidate.profiles[index].baseline = incoming
        candidate.profiles[index].source?.updatedAt = date
        for groupIndex in candidate.groups.indices {
            let id = candidate.groups[groupIndex].id
            guard var source = candidate.groupSources[id], source.profileID == profileID, source.followsMembers else { continue }
            guard let updated = incoming.lines.first(where: { $0.id == source.groupID && $0.isGroup }) else {
                throw ProfileLibraryError.invalid("订阅移除了正在跟随的线路组「\(candidate.groups[groupIndex].name)」，已保留原配置")
            }
            // A selector without an explicit default still fixes its first member.
            // Source reordering must not silently select another exit.
            if candidate.groups[groupIndex].type == "selector", candidate.groups[groupIndex].groupDefault.isEmpty {
                candidate.groups[groupIndex].groupDefault = candidate.groups[groupIndex].groupMembers.first ?? ""
            }
            let manual = candidate.groups[groupIndex].groupMembers.filter { !source.sourceMembers.contains($0) }
            candidate.groups[groupIndex].groupMembers = Self.unique(updated.groupMembers + manual)
            source.sourceMembers = updated.groupMembers
            candidate.groupSources[id] = source
        }
        try candidate.validateReferences(allowEmptyGroups: true)
        return candidate
    }

    func removingProfile(_ id: String) throws -> ProfileLibrary {
        guard profiles.count > 1 else { throw ProfileLibraryError.invalid("至少保留一份资源配置") }
        var result = self
        result.profiles.removeAll { $0.id == id }
        guard !result.groupSources.values.contains(where: { $0.profileID == id && $0.followsMembers }) else {
            throw ProfileLibraryError.invalid("线路组仍在跟随此订阅，请先关闭跟随或删除对应线路组")
        }
        result.groupSources = result.groupSources.filter { $0.value.profileID != id }
        result.scenarioSources = result.scenarioSources.filter { $0.value != id }
        if result.editingProfileID == id { result.editingProfileID = result.profiles[0].id }
        try result.validateReferences(allowEmptyGroups: true)
        return result
    }

    /// Storage permits empty group drafts; references and fixed selections never silently fall back.
    func validateReferences(allowEmptyGroups: Bool = false) throws {
        let draft = snapshot()
        let lineIDs = draft.lines.map(\.id), ruleIDs = draft.ruleSets.map(\.id)
        let matchingIDs = draft.matchingResources.map(\.id)
        guard Set(matchingIDs).count == matchingIDs.count,
              !lineIDs.contains(""), !ruleIDs.contains(""), !matchingIDs.contains(""), Set(lineIDs).count == lineIDs.count, Set(ruleIDs).count == ruleIDs.count,
              Set(scenarios.map(\.id)).count == scenarios.count else {
            throw ProfileLibraryError.invalid("不同来源的资源身份冲突")
        }
        let lines = Set(lineIDs), rules = Set(ruleIDs)
        for group in groups {
            guard allowEmptyGroups || !group.groupMembers.isEmpty else { throw ProfileLibraryError.invalid("线路组为空") }
            guard group.groupDefault.isEmpty || group.groupMembers.contains(group.groupDefault) else {
                throw ProfileLibraryError.invalid("线路组「\(group.name)」固定的成员已不存在，已保留原配置")
            }
            guard Set(group.groupMembers).count == group.groupMembers.count else {
                throw ProfileLibraryError.invalid("线路组中有重复成员")
            }
            if let member = group.groupMembers.first {
                var probe = draft
                let index = probe.lines.firstIndex { $0.id == group.id }!
                probe.lines[index].groupMembers.removeFirst()
                if let issue = probe.lineGroupMemberIssue(member, addingTo: group.id) {
                    throw ProfileLibraryError.invalid("线路组「\(group.name)」：" + issue)
                }
            }
        }
        for rule in draft.matchingResources where rule.type == "url" {
            guard lines.contains(rule.fetchLineID.isEmpty ? "direct" : rule.fetchLineID) else {
                throw ProfileLibraryError.invalid("规则「\(rule.name)」的下载线路已不存在")
            }
        }
        guard activeScenarioID.isEmpty ? scenarios.isEmpty : scenarios.contains(where: { $0.id == activeScenarioID }) else {
            throw ProfileLibraryError.invalid("活动场景不存在")
        }
        var ssids = Set<String>()
        for scene in scenarios {
            guard lines.contains(scene.defaultLineID), scene.defaultSubscriptionID.isEmpty else {
                throw ProfileLibraryError.invalid("场景「\(scene.name)」的默认出口已不存在")
            }
            var selected = Set<String>()
            for binding in scene.bindings {
                guard rules.contains(binding.ruleSetID), lines.contains(binding.lineID), binding.subscriptionID.isEmpty,
                      let rule = draft.ruleSets.first(where: { $0.id == binding.ruleSetID }) else {
                    throw ProfileLibraryError.invalid("场景「\(scene.name)」引用的线路或规则已不存在")
                }
                let members = Set(rule.matchingResources.map(\.id))
                guard Set(binding.conditionIDs).isSubset(of: members) else {
                    throw ProfileLibraryError.invalid("场景「\(scene.name)」引用的部分规则内容已被删除")
                }
                selected.formUnion(binding.conditionIDs.isEmpty ? members : Set(binding.conditionIDs))
            }
            guard Set(scene.matchOrder).isSubset(of: selected), Set(scene.matchOrder).count == scene.matchOrder.count else {
                throw ProfileLibraryError.invalid("场景「\(scene.name)」的规则顺序引用失效")
            }
            for ssid in scene.matchSSIDs {
                guard ssids.insert(ssid).inserted else { throw ProfileLibraryError.invalid("多个场景使用了同一个 SSID，请先解除冲突") }
            }
        }
    }

    static func resourcesOnly(_ profile: Profile) -> Profile {
        var result = profile
        result.lines.removeAll(where: \.isGroup)
        result.scenarios = []; result.activeScenarioID = ""; result.subscriptions = []
        return result
    }
    private static func objectIDs(_ p: Profile) -> [String] {
        p.lines.map(\.id) + p.ruleSets.map(\.id) + p.matchingResources.map(\.id) + p.scenarios.map(\.id)
    }
    private static func scopedID(profileID: String, objectID: String) -> String {
        "resource-" + SHA256.hash(data: Data((profileID + "/" + objectID).utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
    private static func remap(_ original: Profile, using map: [String: String]) -> Profile {
        func id(_ value: String) -> String { map[value] ?? value }
        func rule(_ source: RuleSet) -> RuleSet {
            var value = source
            value.id = id(value.id); value.fetchLineID = id(value.fetchLineID)
            value.conditions = value.conditions.map(rule)
            return value
        }
        var p = original
        p.lines = p.lines.map { source in
            var line = source
            line.id = id(line.id); line.groupMembers = line.groupMembers.map(id); line.groupDefault = id(line.groupDefault)
            return line
        }
        p.ruleSets = p.ruleSets.map(rule)
        p.scenarios = p.scenarios.map { source in
            var scene = source
            scene.id = id(scene.id); scene.defaultLineID = id(scene.defaultLineID); scene.matchOrder = scene.matchOrder.map(id)
            scene.bindings = scene.bindings.map { source in
                var binding = source
                binding.ruleSetID = id(binding.ruleSetID); binding.lineID = id(binding.lineID)
                binding.conditionIDs = binding.conditionIDs.map(id)
                return binding
            }
            return scene
        }
        p.activeScenarioID = id(p.activeScenarioID)
        return p
    }
    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
    private static func ordered<T: Identifiable>(_ values: [T], like old: [T]) -> [T] where T.ID: Hashable {
        let ranks = Dictionary(old.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return values.enumerated().sorted {
            (ranks[$0.element.id] ?? (old.count + $0.offset)) < (ranks[$1.element.id] ?? (old.count + $1.offset))
        }.map(\.element)
    }
}
