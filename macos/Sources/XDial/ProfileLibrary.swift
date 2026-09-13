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
        var merged = incoming
        // Selector choice belongs to the user even when membership comes from a source.
        for index in merged.lines.indices where merged.lines[index].type == "selector" {
            guard let current = profile.lines.first(where: { $0.id == merged.lines[index].id }),
                  let previous = old.lines.first(where: { $0.id == current.id }),
                  current.groupDefault != previous.groupDefault else { continue }
            guard current.groupDefault.isEmpty || merged.lines[index].groupMembers.contains(current.groupDefault) else {
                throw ProfileLibraryError.invalid("订阅更新移除了所选线路，已保留原配置")
            }
            merged.lines[index].groupDefault = current.groupDefault
        }
        merged.lines += profile.lines.filter { item in !old.lines.contains { $0.id == item.id } }
        merged.ruleSets += profile.ruleSets.filter { item in !old.ruleSets.contains { $0.id == item.id } }
        merged.scenarios += profile.scenarios.filter { item in !old.scenarios.contains { $0.id == item.id } }
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
        }
        result.profile = merged
        result.baseline = incoming
        result.source?.updatedAt = date
        return result
    }
}

struct ProfileLibrary: Codable, Hashable {
    var schemaVersion = 1
    var profiles: [ProfileRecord]
    var activeProfileID: String
    var editingProfileID: String

    init() {
        let record = ProfileRecord.empty(named: "我的配置")
        profiles = [record]
        activeProfileID = record.id
        editingProfileID = record.id
    }

    func validated() throws -> ProfileLibrary {
        guard schemaVersion == 1, !profiles.isEmpty,
              Set(profiles.map(\.id)).count == profiles.count,
              profiles.contains(where: { $0.id == activeProfileID }),
              profiles.contains(where: { $0.id == editingProfileID }) else {
            throw ProfileLibraryError.invalid("配置库格式或配置引用无效")
        }
        return self
    }
}

enum ProfileLibraryError: LocalizedError {
    case invalid(String)
    case keychain(Int32)

    var errorDescription: String? {
        switch self {
        case let .invalid(message): return message
        case let .keychain(status): return "无法访问 XDial Next 钥匙串（\(status)），配置尚未保存"
        }
    }
}

enum ProfileSettingsArea: String { case configuration, general }

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
