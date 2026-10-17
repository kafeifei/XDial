import Observation

/// Each row observes its own flag. Expanding a card must not invalidate its
/// siblings, the resource catalog, or the window's navigation.
@Observable final class EditorExpansion {
    var isExpanded = false
}

final class EditorExpansionSet {
    private var rows: [String: EditorExpansion] = [:]

    private func row(_ id: String) -> EditorExpansion {
        if let row = rows[id] { return row }
        let row = EditorExpansion()
        rows[id] = row
        return row
    }

    func contains(_ id: String) -> Bool { row(id).isExpanded }
    func insert(_ id: String) { row(id).isExpanded = true }
    func remove(_ id: String) { row(id).isExpanded = false }
    func sorted() -> [String] { rows.filter { $0.value.isExpanded }.keys.sorted() }
}

/// “通用”页左侧的分类。
enum GeneralSettingsSection: CaseIterable, Hashable {
    case startup, appearance, system, feedback, about
}

@Observable final class ProfileEditorPosition {
    static let generalTab = 4

    var tab = 0
    var generalSection = GeneralSettingsSection.startup

    /// 从 Popover 等入口直接定位到“通用”里的某个分类。
    func showGeneral(_ section: GeneralSettingsSection) {
        tab = Self.generalTab
        generalSection = section
    }
    let expandedLineIDs = EditorExpansionSet()
    let expandedRuleIDs = EditorExpansionSet()
    var expandedScenarioID: String?
    /// 一次性的“滚动到这条线路”请求；序号让同一条线路可以被再次定位。
    private(set) var lineRevealRequest: LineRevealRequest?

    struct LineRevealRequest: Equatable {
        let lineID: String
        let serial: Int
    }

    @ObservationIgnored private var revealSerial = 0

    func revealLine(_ lineID: String) {
        revealSerial += 1
        lineRevealRequest = LineRevealRequest(lineID: lineID, serial: revealSerial)
    }

    /// 定位完成后撤销请求，重新打开窗口时不再跳回这条线路。
    func finishLineReveal(_ request: LineRevealRequest) {
        if lineRevealRequest == request { lineRevealRequest = nil }
    }

    func showProfileSection() {
        switch tab {
        case 0, 1: return // Lines and Rules are the Profile section.
        default: tab = 0
        }
    }
}

/// Disposable indexes for the current library revision. No persisted copy and
/// no runtime decision making: resource identities still belong to the library.
struct ConfigurationCatalog {
    let profile: Profile
    let lineIndices: [String: Int]
    let ruleIndices: [String: Int]
    let lineSources: [String: String]
    let ruleSources: [String: String]

    init(_ library: ProfileLibrary) {
        var profile = library.snapshot()
        profile.tailscale = library.profiles.first { $0.id == library.editingProfileID }?.profile.tailscale ?? profile.tailscale
        self.profile = profile
        lineIndices = Dictionary(profile.lines.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        ruleIndices = Dictionary(profile.ruleSets.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var lines: [String: String] = [:]
        var rules: [String: String] = [:]
        for record in library.profiles {
            for line in record.profile.lines where line.id != "direct" { lines[line.id] = record.name }
            for rule in record.profile.ruleSets { rules[rule.id] = record.name }
        }
        lineSources = lines
        ruleSources = rules
    }

    func line(_ id: String) -> Line? { lineIndices[id].map { profile.lines[$0] } }
    func rule(_ id: String) -> RuleSet? { ruleIndices[id].map { profile.ruleSets[$0] } }
}
