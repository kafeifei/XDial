import SwiftUI

/// Reused in the catalog, group members, add sheet, and Scenario exit pickers.
struct LineLatencyView: View {
    @ObservedObject var store: LineLatencyStore
    let line: Line
    let profileID: String
    var group: Line? = nil
    var allowsTesting = true
    private var control: LineLatencyStore.TestControl { .line(line.id, groupID: group?.id) }
    private var job: LineLatencyStore.ActiveJob? { store.activeJob(for: control, profileID: profileID) }
    private var ownsJob: Bool { job != nil }
    private var available: Bool { store.targetCount([line], profileID: profileID, scope: .currentExit) > 0 }
    private var fact: ProviderLineLatency? { store.measurement(line, profileID: profileID) }
    private var failure: String? { store.failure(line, profileID: profileID) }
    private var busy: Bool { store.isTesting(line, profileID: profileID) }
    private var requirement: LineLatencyStore.TestRequirement { store.testRequirement(line, profileID: profileID) }
    private var label: String {
        if store.isQueued(line, profileID: profileID) { return "排队中" }
        if busy { return "测速中" }
        if let failure { return failure.contains("超时") ? "超时" : "失败" }
        if let milliseconds = fact?.milliseconds { return "\(milliseconds) ms" }
        switch requirement {
        case .ready: return "未测速"
        case .connection: return "需连接"
        case .members: return "无成员"
        case .unavailable: return "不可测"
        }
    }
    private var detail: String {
        if let failure { return failure }
        if let observedAt = fact?.observedAt {
            return "请求延迟 · " + Date(timeIntervalSince1970: Double(observedAt) / 1000).formatted(date: .omitted, time: .standard)
        }
        switch requirement {
        case .ready: return allowsTesting ? "点击右侧按钮测量请求延迟" : "尚无测速结果，可展开线路选择器手动测速"
        case .connection: return "需先在 Next 中连接使用此线路的场景，才能测量这条线路；不会自动建立 VPN / Tailscale 连接"
        case .members: return "添加成员后可测速"
        case .unavailable: return "当前没有可测速的线路"
        }
    }
    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .monospacedDigit().font(.system(size: 11))
                .foregroundStyle(failure != nil ? XDialPalette.danger : .secondary)
                .frame(minWidth: 42, alignment: .trailing)
                .help(detail)
            if allowsTesting {
                Button {
                    if let job { store.cancel(job.id) }
                    else { store.test([line], profileID: profileID, group: group, scope: .currentExit, control: control) }
                } label: {
                    Image(systemName: ownsJob ? "stop.circle" : "arrow.clockwise").font(.system(size: 11))
                        .frame(width: 20, height: 22).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!ownsJob && (!available || busy))
                    .help(ownsJob ? "停止本次测速" : available ? "只测此项当前出口；整组测试请用“整组测速”" : line.isGroup ? "尚无当前出口，请先在组内执行整组测速" : detail)
                    .accessibilityLabel((ownsJob ? "停止测速 " : "测速 ") + line.name)
            }
        }
        .fixedSize()
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
