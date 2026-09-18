import Foundation

struct ProfileSource: Codable, Hashable {
    var url: String
    var nodesOnly: Bool = false
    var format: String = "auto"
    var refreshInterval: TimeInterval = 86400
    var updatedAt: Date?
}

struct ProfileRecord: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString.lowercased()
    var name: String
    var profile: Profile
    var source: ProfileSource?
    var baseline: Profile?

    static func empty(named name: String) -> ProfileRecord {
        var profile = Profile()
        profile.lines = [Line(id: "direct", name: "直连", type: "direct", verified: true)]
        let scenario = Scenario(id: UUID().uuidString, name: "默认场景", defaultLineID: "direct")
        profile.scenarios = [scenario]
        profile.activeScenarioID = scenario.id
        var record = ProfileRecord(name: name, profile: profile)
        record.profile.profileID = record.id
        return record
    }

    /// Source-owned objects are replaced together; locally created scenarios and
    /// resources survive refresh. A removed dependency rejects the whole update.
    func refreshed(with incoming: Profile, at date: Date = Date()) throws -> ProfileRecord {
        var result = self
        let old = baseline ?? profile
        guard Set(incoming.importWarnings).isSubset(of: Set(old.importWarnings)) else {
            throw ProfileLibraryError.invalid("订阅新增了无法执行的规则，已保留原配置；请重新导入并查看兼容提示")
        }
        var merged = incoming
        merged.lines += profile.lines.filter { item in !old.lines.contains { $0.id == item.id } }
        // Membership belongs to the subscription; selection and probe preferences belong to the user.
        for item in incoming.lines where item.isGroup {
            guard let current = profile.lines.first(where: { $0.id == item.id && $0.isGroup }),
                  let previous = old.lines.first(where: { $0.id == item.id }),
                  let index = merged.lines.firstIndex(where: { $0.id == item.id }) else { continue }
            if current.groupURL != previous.groupURL { merged.lines[index].groupURL = current.groupURL }
            if current.groupInterval != previous.groupInterval { merged.lines[index].groupInterval = current.groupInterval }
            guard current.type != previous.type || current.groupDefault != previous.groupDefault else { continue }
            let member = current.type == "urltest" ? nil : (current.groupDefault.isEmpty ? current.groupMembers.first : current.groupDefault)
            if current.type == "selector" && member == nil {
                throw ProfileLibraryError.invalid("订阅更新无法保留空组的选线，已保留原配置")
            }
            do { try merged.selectLineGroupMember(member, in: item.id) }
            catch { throw ProfileLibraryError.invalid("订阅更新无法保留所选线路：" + error.localizedDescription) }
        }
        merged.ruleSets += profile.ruleSets.filter { item in !old.ruleSets.contains { $0.id == item.id } }
        merged.scenarios += profile.scenarios.filter { item in !old.scenarios.contains { $0.id == item.id } }
        // Business selector choices now live in Scenario bindings. Refresh the
        // source's matching content while retaining each local exit override.
        for index in merged.scenarios.indices {
            guard let current = profile.scenarios.first(where: { $0.id == merged.scenarios[index].id }),
                  let previous = old.scenarios.first(where: { $0.id == current.id }) else { continue }
            if current.defaultLineID != previous.defaultLineID || current.defaultSubscriptionID != previous.defaultSubscriptionID {
                merged.scenarios[index].defaultLineID = current.defaultLineID
                merged.scenarios[index].defaultSubscriptionID = current.defaultSubscriptionID
            }
            for binding in current.bindings {
                guard let original = previous.bindings.first(where: { $0.ruleSetID == binding.ruleSetID }),
                      binding.lineID != original.lineID || binding.subscriptionID != original.subscriptionID else { continue }
                guard let target = merged.scenarios[index].bindings.firstIndex(where: { $0.ruleSetID == binding.ruleSetID }) else {
                    throw ProfileLibraryError.invalid("订阅更新移除了已单独设置出口的规则，已保留原配置")
                }
                merged.scenarios[index].bindings[target].lineID = binding.lineID
                merged.scenarios[index].bindings[target].subscriptionID = binding.subscriptionID
            }
        }
        if merged.scenarios.contains(where: { $0.id == profile.activeScenarioID }) {
            merged.activeScenarioID = profile.activeScenarioID
        }
        merged.tailscale = profile.tailscale
        merged.lines = preservingProfileOrder(merged.lines, previous: profile.lines)
        merged.ruleSets = preservingProfileOrder(merged.ruleSets, previous: profile.ruleSets)
        merged.scenarios = preservingProfileOrder(merged.scenarios, previous: profile.scenarios)
        let lines = Set(merged.lines.map(\.id))
        let rules = Set(merged.ruleSets.map(\.id))
        for scenario in merged.scenarios {
            guard lines.contains(scenario.defaultLineID), scenario.defaultSubscriptionID.isEmpty,
                  scenario.bindings.allSatisfy({
                      rules.contains($0.ruleSetID) && lines.contains($0.lineID) && $0.subscriptionID.isEmpty
                  }) else {
                throw ProfileLibraryError.invalid("订阅更新使场景引用失效，已保留原配置")
            }
            var selected = Set<String>()
            for binding in scenario.bindings {
                guard let rule = merged.ruleSets.first(where: { $0.id == binding.ruleSetID }) else { continue }
                let members = Set(rule.matchingResources.map(\.id))
                let scoped = Set(binding.conditionIDs)
                guard scoped.isSubset(of: members) else {
                    throw ProfileLibraryError.invalid("订阅更新移除了场景使用的部分匹配内容，已保留原配置")
                }
                selected.formUnion(scoped.isEmpty ? members : scoped)
            }
            guard Set(scenario.matchOrder).isSubset(of: selected), Set(scenario.matchOrder).count == scenario.matchOrder.count else {
                throw ProfileLibraryError.invalid("订阅更新使原匹配顺序失效，已保留原配置")
            }
        }
        result.profile = merged
        result.baseline = incoming
        result.source?.updatedAt = date
        return result
    }
}

struct ProfileLibrary: Codable, Hashable {
    // Older Next builds must refuse the library instead of ignoring Scenario
    // match order / partial scopes and changing its routing on a downgrade.
    var schemaVersion = 2
    var profiles: [ProfileRecord]
    var activeProfileID: String
    var editingProfileID: String

    init() {
        let record = ProfileRecord.empty(named: "默认配置")
        profiles = [record]
        activeProfileID = record.id
        editingProfileID = record.id
    }

    func validated() throws -> ProfileLibrary {
        guard (1...2).contains(schemaVersion), !profiles.isEmpty,
              Set(profiles.map(\.id)).count == profiles.count,
              profiles.contains(where: { $0.id == activeProfileID }),
              profiles.contains(where: { $0.id == editingProfileID }) else {
            throw ProfileLibraryError.invalid("配置库格式或配置引用无效")
        }
        var result = self
        result.schemaVersion = 2
        return result
    }
}

enum ProfileLibraryError: LocalizedError {
    case invalid(String)
    case keychain(Int32)

    var errorDescription: String? {
        switch self {
        case let .invalid(message): return message
        case let .keychain(status): return "无法访问配置钥匙串（\(status)），配置尚未保存"
        }
    }
}

struct ProfileEditorPosition {
    var tab = 0
    var expandedLineIDs: Set<String> = []
    var expandedRuleIDs: Set<String> = []
    var expandedScenarioID: String?
}

private func preservingProfileOrder<T: Identifiable>(_ incoming: [T], previous: [T]) -> [T] {
    var ranks: [T.ID: Int] = [:]
    for (index, item) in previous.enumerated() { ranks[item.id] = index }
    return incoming.enumerated().sorted {
        let lhs = ranks[$0.element.id] ?? (previous.count + $0.offset)
        let rhs = ranks[$1.element.id] ?? (previous.count + $1.offset)
        return lhs < rhs
    }.map(\.element)
}
