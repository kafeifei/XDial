import SwiftUI

/// Reused in the catalog, group members, add sheet, and Scenario exit pickers.
struct LineLatencyView: View {
    @ObservedObject var store: LineLatencyStore
    let line: Line
    let profileID: String
    var group: Line? = nil
    var allowsTesting = true
    var body: some View {
        let value = LineLatencyPresentation(store: store, line: line, profileID: profileID, group: group, allowsTesting: allowsTesting)
        HStack(spacing: 5) {
            Text(value.label)
                .monospacedDigit().font(.system(size: 11))
                .foregroundStyle(value.failed ? XDialPalette.danger : .secondary)
                .frame(minWidth: 42, alignment: .trailing)
                .help(value.detail)
            if allowsTesting {
                Button {
                    let control = LineLatencyStore.TestControl.line(line.id, groupID: group?.id)
                    if let job = store.activeJob(for: control, profileID: profileID) { store.cancel(job.id) }
                    else { store.test([line], profileID: profileID, group: group, scope: .currentExit, control: control) }
                } label: {
                    Image(systemName: value.buttonIcon).font(.system(size: 11))
                        .frame(width: 20, height: 22).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!value.buttonEnabled)
                    .help(value.buttonHelp)
                    .accessibilityLabel(value.buttonLabel)
            }
        }
        .fixedSize()
    }
}

/// Resolve display-only state once per update, rather than re-querying it for
/// the label, color, tooltip, enabled flag, and accessibility label separately.
struct LineLatencyPresentation: Equatable {
    let label: String
    let detail: String
    let failed: Bool
    let buttonIcon: String
    let buttonEnabled: Bool
    let buttonHelp: String
    let buttonLabel: String

    @MainActor
    init(store: LineLatencyStore, line: Line, profileID: String, group: Line? = nil, allowsTesting: Bool = true) {
        let control = LineLatencyStore.TestControl.line(line.id, groupID: group?.id)
        let ownsJob = store.activeJob(for: control, profileID: profileID) != nil
        let available = store.targetCount([line], profileID: profileID, scope: .currentExit) > 0
        let fact = store.measurement(line, profileID: profileID)
        let failure = store.failure(line, profileID: profileID)
        let busy = store.isTesting(line, profileID: profileID)
        let requirement = store.testRequirement(line, profileID: profileID)
        if store.isQueued(line, profileID: profileID) { label = "排队中" }
        else if busy { label = "测速中" }
        else if let failure { label = failure.contains("超时") ? "超时" : "失败" }
        else if let ms = fact?.milliseconds { label = "\(ms) ms" }
        else {
            switch requirement {
            case .ready: label = "未测速"
            case .connection: label = "需连接"
            case .members: label = "无成员"
            case .unavailable: label = "不可测"
            }
        }
        if let failure { detail = failure }
        else if let at = fact?.observedAt {
            detail = "请求延迟 · " + Date(timeIntervalSince1970: Double(at) / 1000).formatted(date: .omitted, time: .standard)
        } else {
            switch requirement {
            case .ready: detail = allowsTesting ? "点击右侧按钮测量请求延迟" : "尚无测速结果，可展开线路选择器手动测速"
            case .connection: detail = "需先在 Next 中连接使用此线路的场景，才能测量这条线路；不会自动建立 VPN / Tailscale 连接"
            case .members: detail = "添加成员后可测速"
            case .unavailable: detail = "当前没有可测速的线路"
            }
        }
        failed = failure != nil
        buttonIcon = ownsJob ? "stop.circle" : "arrow.clockwise"
        buttonEnabled = ownsJob || (available && !busy)
        buttonHelp = ownsJob ? "停止本次测速" : available ? "只测此项当前出口；整组测试请用“整组测速”" : line.isGroup ? "尚无当前出口，请先在组内执行整组测速" : detail
        buttonLabel = (ownsJob ? "停止测速 " : "测速 ") + line.name
    }
}

struct LineLatencyBatchButton: View {
    @ObservedObject var store: LineLatencyStore
    let lines: [Line]
    let profileID: String
    var title = "测当前列表"
    let control: LineLatencyStore.TestControl
    private var job: LineLatencyStore.ActiveJob? { store.activeJob(for: control, profileID: profileID) }
    private var busy: Bool { job != nil }
    private var count: Int { store.targetCount(lines, profileID: profileID) }
    var body: some View {
        Button {
            if let job { store.cancel(job.id) }
            else { store.test(lines, profileID: profileID, scope: .allMembers, control: control) }
        } label: {
            Label(busy ? "停止本次（\(job?.count ?? 0)）" : "\(title)（\(count)）", systemImage: busy ? "stop.circle" : "arrow.clockwise")
        }.buttonStyle(.borderless).font(.caption)
            .disabled(!busy && count == 0)
            .help(busy ? "只停止此按钮启动的任务，其他测速继续" : "测量范围内 \(count) 条可测线路，组内成员去重；固定选线保持不变")
    }
}
