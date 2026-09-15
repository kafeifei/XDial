import AppKit
import SwiftUI
import UniformTypeIdentifiers

private extension UTType {
    static let xdialSettingsEntry = UTType(
        exportedAs: XDialBuildIdentity.settingsEntryTypeIdentifier,
        conformingTo: .data
    )
}

struct SettingsReorderItem: Codable, Equatable {
    let kind: String
    let id: String

    func itemProvider() -> NSItemProvider {
        guard let data = try? JSONEncoder().encode(self) else {
            return NSItemProvider()
        }
        return NSItemProvider(
            item: data as NSData,
            typeIdentifier: UTType.xdialSettingsEntry.identifier
        )
    }
}

private struct SettingsReorderDropDelegate: DropDelegate {
    let target: SettingsReorderItem
    let draggedItem: SwiftUI.Binding<SettingsReorderItem?>
    let move: (SettingsReorderItem, String) -> Bool
    let onDrop: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        guard let dragged = draggedItem.wrappedValue else { return false }
        return dragged.kind == target.kind
            && info.hasItemsConforming(
                to: [UTType.xdialSettingsEntry]
            )
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info),
              let dragged = draggedItem.wrappedValue,
              dragged.id != target.id else { return }
        _ = move(dragged, target.id)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else {
            return DropProposal(operation: .forbidden)
        }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard draggedItem.wrappedValue != nil else { return false }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            draggedItem.wrappedValue = nil
        }
        onDrop()
        return true
    }
}

private struct SettingsReorderModifier: ViewModifier {
    let item: SettingsReorderItem
    let draggedItem: SwiftUI.Binding<SettingsReorderItem?>
    let allowsDragging: Bool
    let move: (SettingsReorderItem, String) -> Bool
    let onDrop: () -> Void

    private var isPlaceholder: Bool {
        draggedItem.wrappedValue == item
    }

    func body(content: Content) -> some View {
        Group {
            if allowsDragging {
                content
                    .onDrag {
                        let provider = item.itemProvider()
                        DispatchQueue.main.async {
                            draggedItem.wrappedValue = item
                        }
                        return provider
                    }
            } else {
                content
            }
        }
            .onDrop(
                of: [UTType.xdialSettingsEntry],
                delegate: SettingsReorderDropDelegate(
                    target: item,
                    draggedItem: draggedItem,
                    move: move,
                    onDrop: onDrop
                )
            )
            .opacity(isPlaceholder ? 0 : 1)
    }
}

private struct SettingsReorderListDropDelegate: DropDelegate {
    let draggedItem: SwiftUI.Binding<SettingsReorderItem?>
    let onDrop: () -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard draggedItem.wrappedValue != nil else { return false }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            draggedItem.wrappedValue = nil
        }
        onDrop()
        return true
    }
}

extension View {
    func settingsReorderable(
        _ item: SettingsReorderItem,
        draggedItem: SwiftUI.Binding<SettingsReorderItem?>,
        allowsDragging: Bool = true,
        onDrop: @escaping () -> Void = {},
        move: @escaping (SettingsReorderItem, String) -> Bool
    ) -> some View {
        modifier(SettingsReorderModifier(
            item: item,
            draggedItem: draggedItem,
            allowsDragging: allowsDragging,
            move: move,
            onDrop: onDrop
        ))
    }

    func settingsReorderDropArea(
        draggedItem: SwiftUI.Binding<SettingsReorderItem?>,
        onDrop: @escaping () -> Void = {}
    ) -> some View {
        self.onDrop(
            of: [UTType.xdialSettingsEntry],
            delegate: SettingsReorderListDropDelegate(
                draggedItem: draggedItem,
                onDrop: onDrop
            )
        )
    }
}

@discardableResult
private func reorder<Item>(
    _ items: inout [Item],
    draggedID: String,
    targetID: String,
    id: (Item) -> String
) -> Bool {
    guard draggedID != targetID,
          let sourceIndex = items.firstIndex(where: { id($0) == draggedID }),
          let targetIndex = items.firstIndex(where: { id($0) == targetID }) else {
        return false
    }
    let item = items.remove(at: sourceIndex)
    items.insert(item, at: min(targetIndex, items.endIndex))
    return true
}

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    private var tab: Int { state.editorPosition.tab }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ProfileNavigation()
            }
            .padding(.horizontal, 16).frame(height: 48)
            .background(titleAccent.opacity(0.07))

            HStack(spacing: 4) {
                settingsTab(0, title: state.tr("线路", "Lines"), symbol: "point.3.connected.trianglepath.dotted")
                settingsTab(3, title: state.tr("线路组", "Line Groups"), symbol: "square.stack.3d.up")
                settingsTab(1, title: state.tr("规则", "Rules"), symbol: "list.bullet.rectangle")
                settingsTab(2, title: state.tr("场景", "Scenarios"), symbol: "square.grid.2x2")
                Spacer(minLength: 8)
                Text(state.editingRecord.source == nil ? state.tr("本地配置", "Local") : state.tr("订阅配置", "Subscription"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            if let error = state.profilePersistenceError ?? state.profileOperationError {
                Text(error).font(.caption).foregroundStyle(XDialPalette.danger)
                    .textSelection(.enabled).padding(12)
            }
            if state.editingActiveProfile && state.configDirty { dirtyBanner }
            Divider()
            ZStack {
                if tab == 0 { LinesTab().id(state.editingRecord.id) }
                else if tab == 3 { LinesTab(groupsOnly: true).id(state.editingRecord.id + "-groups") }
                else if tab == 1 { RulesTab().id(state.editingRecord.id) }
                else { ScenariosTab().id(state.editingRecord.id) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(XDialPalette.canvas)
        }
        .frame(width: 620, height: 580)
        .background(XDialPalette.canvas)
        .onReceive(NotificationCenter.default.publisher(for: .xdialSettingsSelectTab)) { notification in
            guard let index = notification.userInfo?["index"] as? Int, (0 ... 4).contains(index) else { return }
            if index == 4 {
                ApplicationWindowLifecycleController.shared.prepareToPresentSettingsWindow()
                openWindow(id: "general")
                NSApp.activate(ignoringOtherApps: true)
            } else {
                state.editorPosition.tab = index
            }
        }
    }

    private var titleAccent: Color {
        if state.isConnected { return XDialPalette.success }
        if state.isBusy { return XDialPalette.progress }
        if state.engine.lastError != nil { return XDialPalette.danger }
        return Color.secondary.opacity(0.82)
    }

    private func settingsTab(
        _ index: Int,
        title: String,
        symbol: String
    ) -> some View {
        let selected = tab == index
        return Button {
            state.editorPosition.tab = index
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(
                selected ? XDialPalette.selection : Color.secondary
            )
            .frame(width: 76, height: 28)
            .background(
                selected
                    ? XDialPalette.selection.opacity(0.18)
                    : Color.clear,
                in: Capsule()
            )
            .overlay {
                if selected {
                    Capsule().stroke(
                        XDialPalette.selection.opacity(0.52),
                        lineWidth: 0.75
                    )
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// 当前事务依赖的已保存配置发生变化时，三个配置 Tab 共用这一条状态轨。
    /// 它是“运行快照待应用”，不是错误，因此不使用危险色或独立警告卡片。
    private var dirtyBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(XDialPalette.warning)
            Text(
                state.tr(
                    "修改已保存，当前连接尚未应用",
                    "Changes saved; the current connection has not applied them"
                )
            )
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.primary.opacity(0.82))
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if state.isBusy {
                Text(state.tr("连接完成后可应用", "Apply after connecting"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else if state.canConnect {
                Button { state.reconnect() } label: {
                    Label(
                        state.tr("应用并重连", "Apply & Reconnect"),
                        systemImage: "arrow.clockwise"
                    )
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(XDialPalette.primaryAction)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(
                        XDialPalette.primaryAction.opacity(0.09),
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint(
                    state.tr(
                        "使用已保存配置重新建立当前连接",
                        "Reconnect using the saved configuration"
                    )
                )
            } else {
                Text(dirtyConfigurationBlocker)
                .font(.system(size: 10.5))
                .foregroundStyle(XDialPalette.warning)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 36)
        .background {
            LinearGradient(
                colors: [
                    XDialPalette.warning.opacity(0.085),
                    XDialPalette.warning.opacity(0.035),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .overlay(alignment: .top) {
            Divider().opacity(0.55)
        }
    }

    private var dirtyConfigurationBlocker: String {
        if !state.installation.isReady {
            return state.tr("请先完成安装", "Complete setup first")
        }
        if state.activeScenario == nil {
            return state.tr("请先选择场景", "Choose a scenario first")
        }
        return state.tr(
            "请先完善当前场景",
            "Complete the current scenario first"
        )
    }

    private var installationBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.caption)
                .foregroundStyle(XDialPalette.progress)
            Text(
                state.installation.report.error?.message
                    ?? state.tr(
                        "XDial 正在完成首次安装",
                        "XDial is completing first-run setup"
                    )
            )
            .font(.caption)
            .foregroundStyle(XDialPalette.progress)
            Spacer()
            Button(state.tr("查看进度", "View Progress")) {
                state.installation.present()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 34)
        .background(XDialPalette.progress.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(XDialPalette.progress.opacity(0.16), lineWidth: 0.5)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

// MARK: - 线路 Tab

struct LinesTab: View {
    var groupsOnly = false
    @EnvironmentObject var state: AppState
    @State private var showAddSub = false
    @State private var draggedItem: SettingsReorderItem?
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(groupsOnly ? state.tr("搜索线路组", "Search line groups") : state.tr("搜索线路", "Search lines"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Text("\(state.editingProfile.lines.filter { $0.isGroup == groupsOnly }.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 14).padding(.top, 10)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach($state.editingProfile.lines) { $line in
                        if line.isGroup == groupsOnly && (searchText.isEmpty || line.name.localizedCaseInsensitiveContains(searchText)) {
                        Group {
                            if line.isGroup { LineGroupRow(line: $line, onDelete: { delete(line) }) }
                            else { LineRow(line: $line, onDelete: { delete(line) }) }
                        }
                            .settingsReorderable(
                                SettingsReorderItem(
                                    kind: "line",
                                    id: line.id
                                ),
                                draggedItem: $draggedItem,
                                allowsDragging: searchText.isEmpty
                            ) { item, targetID in
                                moveLine(item, to: targetID)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .settingsReorderDropArea(draggedItem: $draggedItem)
            }
            Divider()
            AddBar {
                Menu {
                    if groupsOnly {
                    lineTypeButton("手动选择组", type: "selector", icon: "square.stack.3d.up")
                    lineTypeButton("自动测速组", type: "urltest", icon: "speedometer")
                    } else {
                    lineTypeButton("VPN", type: "vpn", icon: "lock.shield")
                    lineTypeButton(
                        "Trojan",
                        type: "trojan",
                        icon: "shield.lefthalf.filled"
                    )
                    lineTypeButton(
                        "Shadowsocks",
                        type: "shadowsocks",
                        icon: "eye.slash"
                    )
                    lineTypeButton(
                        "VMess",
                        type: "vmess",
                        icon: "point.3.connected.trianglepath.dotted"
                    )
                    lineTypeButton(
                        "AnyTLS",
                        type: "anytls",
                        icon: "lock.square"
                    )
                    lineTypeButton(
                        "Tailscale",
                        type: "tailscale",
                        icon: "circle.grid.3x3.fill"
                    )
                    }
                } label: {
                    Label(groupsOnly ? state.tr("添加线路组", "Add Line Group") : state.tr("添加线路", "Add Line"), systemImage: "plus")
                }
            }
        }
    }

    private func lineTypeButton(
        _ title: String,
        type: String,
        icon: String
    ) -> some View {
        Button {
            add(type: type)
        } label: {
            Label(title, systemImage: icon)
        }
    }

    private func add(type: String) {
        let id = type + "-" + String(UUID().uuidString.prefix(6))
        let name: String
        switch type {
        case "vpn": name = "VPN"
        case "trojan": name = "Trojan 节点"
        case "shadowsocks": name = "SS 节点"
        case "vmess": name = "VMess 节点"
        case "anytls": name = "AnyTLS 节点"
        case "tailscale": name = "Tailscale"
        default: name = "节点"
        }
        var line = Line(id: id, name: name, type: type)
        if line.isGroup {
            line.name = type == "selector" ? "手动选择组" : "自动测速组"
        }
        state.editingProfile.lines.append(line)
        state.editorPosition.expandedLineIDs.insert(line.id)
        state.saveEditingProfile()
    }

    private func delete(_ line: Line) {
        if line.type == "direct" { return }
        if state.editingProfile.scenarios.contains(where: { $0.defaultLineID == line.id || $0.bindings.contains(where: { $0.lineID == line.id }) }) || state.editingProfile.lines.contains(where: { $0.groupMembers.contains(line.id) }) {
            state.profileOperationError = "此线路仍被场景或线路组使用，请先修改引用"
            return
        }
        if line.type == "tailscale" {
            state.engine.stopTailscaleSetup(lineID: line.id)
        }
        state.editingProfile.lines.removeAll { $0.id == line.id }
        state.saveEditingProfile()
    }


    private func moveLine(
        _ item: SettingsReorderItem?,
        to targetID: String
    ) -> Bool {
        guard let item, item.kind == "line",
              reorder(
                &state.editingProfile.lines,
                draggedID: item.id,
                targetID: targetID,
                id: { $0.id }
              ) else { return false }
        state.saveEditingVisualOrder()
        return true
    }

    private func moveSubscription(
        _ item: SettingsReorderItem?,
        to targetID: String
    ) -> Bool {
        guard let item, item.kind == "subscription",
              reorder(
                &state.editingProfile.subscriptions,
                draggedID: item.id,
                targetID: targetID,
                id: { $0.id }
              ) else { return false }
        state.saveEditingVisualOrder()
        return true
    }
}

private struct RuntimeResourceBadge: View {
    let kind: String
    let resourceID: String
    let enabled: Bool
    @EnvironmentObject private var state: AppState

    private var report: ConnectionReport? {
        state.engine.presentedConnectionReport
    }

    private var runtimeState: ConnectionResourceRuntimeState {
        .resolve(
            enabled: enabled,
            report: report,
            kind: kind,
            resourceID: resourceID
        )
    }

    private var task: ConnectionTaskReport? {
        report?.task(kind: kind, resourceID: resourceID)
    }

    var body: some View {
        Label(label, systemImage: icon)
            .font(.caption2)
            .foregroundStyle(color)
            .lineLimit(1)
            .help(helpText)
            .accessibilityLabel(helpText)
    }

    private var label: String {
        switch runtimeState {
        case .disabled:
            return state.tr("已停用", "Disabled")
        case .notObserved:
            return state.tr("尚未运行", "Not run")
        case .notPlanned:
            return state.tr("未激活", "Inactive")
        case let .task(taskState):
            switch taskState {
            case .pending:
                return state.tr("等待", "Waiting")
            case .running:
                return state.tr("检查中", "Checking")
            case .ready:
                return report?.state == .committed
                    ? state.tr("运行中", "Running")
                    : state.tr("已就绪", "Ready")
            case .committing:
                return state.tr("提交中", "Committing")
            case .committed:
                return state.tr("已接管", "Committed")
            case .rollingBack:
                return state.tr("正在回滚", "Rolling back")
            case .rolledBack:
                return report?.state == .cancelled
                    ? state.tr("已断开", "Disconnected")
                    : state.tr("已回滚", "Rolled back")
            case .failed:
                return state.tr("失败", "Failed")
            case .skipped:
                return state.tr("已跳过", "Skipped")
            }
        }
    }

    private var icon: String {
        switch runtimeState {
        case .disabled, .notObserved, .notPlanned:
            return "circle"
        case let .task(taskState):
            switch taskState {
            case .pending:
                return "circle"
            case .running, .committing, .rollingBack:
                return "clock.fill"
            case .ready, .committed:
                return "checkmark.circle.fill"
            case .rolledBack:
                return "arrow.uturn.backward.circle.fill"
            case .failed:
                return "xmark.octagon.fill"
            case .skipped:
                return "minus.circle"
            }
        }
    }

    private var color: Color {
        switch runtimeState {
        case .disabled, .notObserved, .notPlanned:
            return .secondary
        case let .task(taskState):
            switch taskState {
            case .pending, .rolledBack, .skipped:
                return .secondary
            case .running, .committing:
                return XDialPalette.progress
            case .rollingBack:
                return XDialPalette.selection
            case .ready, .committed:
                return XDialPalette.success
            case .failed:
                return XDialPalette.danger
            }
        }
    }

    private var helpText: String {
        if let message = task?.error?.message, !message.isEmpty {
            return message
        }
        switch runtimeState {
        case .disabled:
            return state.tr(
                "这条线路在配置中已停用。",
                "This line is disabled in the profile."
            )
        case .notObserved:
            return state.tr(
                "还没有连接事务可以证明这条线路的运行状态。",
                "No connection transaction has observed this resource yet."
            )
        case .notPlanned:
            return state.tr(
                "这条线路没有被本次运行中的 Scenario 引用。",
                "This resource is not referenced by the runtime Scenario."
            )
        case .task:
            return label
        }
    }
}

struct LineRow: View {
    @SwiftUI.Binding var line: Line
    var onDelete: () -> Void
    private var expanded: Bool {
        get { state.editorPosition.expandedLineIDs.contains(line.id) }
        nonmutating set {
            if newValue { state.editorPosition.expandedLineIDs.insert(line.id) }
            else { state.editorPosition.expandedLineIDs.remove(line.id) }
        }
    }
    @State private var showAuthKey = false
    @State private var authKey = ""
    @State private var anyTLSALPNInput: String
    @EnvironmentObject var state: AppState
    @ObservedObject private var net = NetworkInfo.shared

    init(
        line: SwiftUI.Binding<Line>,
        onDelete: @escaping () -> Void
    ) {
        self._line = line
        self.onDelete = onDelete
        self._anyTLSALPNInput = State(
            initialValue: line.wrappedValue.anytlsALPN.joined(
                separator: "\n"
            )
        )
    }

    private var sourceOwned: Bool { state.editingRecord.baseline?.lines.contains(where: { $0.id == line.id }) == true }
    private var isLocked: Bool { line.type == "direct" }
    private var tailscaleStatus: TailscaleRuntimeStatus? {
        state.tailscaleConfigurationStatus(for: line.id)
    }
    private var tailscaleError: String? {
        state.tailscaleConfigurationError(for: line.id)
    }
    private var tailscaleBusy: Bool {
        state.isTailscaleConfigurationBusy(for: line.id)
    }
    private var tailscaleRuntimeConnected: Bool {
        ConnectionReportRuntimeFacts.committedLines(
            status: state.engine.status,
            report: state.engine.connectionReport
        )?.lineIDs.contains(line.id) == true
    }

    var body: some View {
        CollapsibleCard(
            isExpanded: expanded,
            locked: isLocked,
            onToggle: { expanded.toggle() },
            onDelete: (isLocked || sourceOwned) ? nil : onDelete,
            enabled: Binding(get: { line.enabled }, set: { if !isLocked && !sourceOwned { line.enabled = $0; state.saveEditingProfile() } }),
            header: {
                RuntimeResourceBadge(
                    kind: "line",
                    resourceID: line.id,
                    enabled: line.enabled
                )

                Text(line.name)
                    .font(.system(size: 13, weight: .medium))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction {
                        if !isLocked { expanded.toggle() }
                    }

                if !briefInfo.isEmpty {
                    Text(briefInfo).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(typeLabel).font(.caption).foregroundStyle(.secondary)
                Text(sourceOwned ? "订阅" : "自建").font(.caption).foregroundStyle(.secondary)
            },
            detail: {
                VStack(alignment: .leading, spacing: 4) {
                    runtimeFailure
                    HStack {
                        Text("名称").font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                        TextField("名称", text: $line.name)
                            .textFieldStyle(.roundedBorder).font(.caption)
                            .onChange(of: line.name) { _, _ in state.saveEditingProfile() }
                    }
                    detailFields
                    if ["trojan", "shadowsocks", "vmess", "anytls"].contains(line.type) {
                        DisclosureGroup("高级选项（sing-box）") {
                            NativeLineOptionsEditor(line: $line)
                        }
                    }
                }
                .disabled(sourceOwned)
            }
        )
        .opacity(line.enabled ? 1.0 : 0.65)
    }

    @ViewBuilder
    private var runtimeFailure: some View {
        if let task = state.engine.presentedConnectionReport?.task(
            kind: "line",
            resourceID: line.id
        ),
           task.state == .failed,
           let error = task.error {
            Label(
                error.message,
                systemImage: "exclamationmark.octagon.fill"
            )
            .font(.caption)
            .foregroundStyle(XDialPalette.danger)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 4)
        }
    }

    private var briefInfo: String {
        // 出口地址只是当前连接事务的 Provider 观察；运行状态只看上方 badge。
        if let info = net.observation(
            for: line.id,
            transactionID: state.engine.connectionReport?.transactionID
        ), !info.summary.isEmpty {
            return info.summary
        }
        // 没有本次事务的有效观察时，只显示静态配置。
        switch line.type {
        case "tailscale":
            if tailscaleRuntimeConnected {
                if let status = tailscaleStatus,
                   let node = status.exitNodes.first(where: {
                       $0.ip == line.tailscaleExitNode
                   }) {
                    return state.tr(
                        "已连接 · \(node.name)",
                        "Connected · \(node.name)"
                    )
                }
                return state.tr("已连接", "Connected")
            }
            if let status = tailscaleStatus {
                if status.isRunning {
                    if line.tailscaleExitNode.isEmpty {
                        return state.tr("已登录 · 未选择出口", "Signed in · No exit node")
                    }
                    if let node = status.exitNodes.first(where: { $0.ip == line.tailscaleExitNode }) {
                        return node.online
                            ? state.tr("已登录 · \(node.name)", "Signed in · \(node.name)")
                            : state.tr("出口节点离线", "Exit node offline")
                    }
                    return state.tr("出口节点不可用", "Exit node unavailable")
                }
                return state.tr("需要登录", "Sign-in required")
            }
            return state.tr("登录状态未检查", "Sign-in status not checked")
        case "vpn":
            return line.vpnServer
        case "trojan":
            guard !line.trojanServer.isEmpty else { return "" }
            return "\(line.trojanServer):\(line.trojanPort)"
        case "shadowsocks":
            guard !line.ssServer.isEmpty else { return "" }
            return "\(line.ssServer):\(line.ssPort)"
        case "vmess":
            guard !line.vmessServer.isEmpty else { return "" }
            return "\(line.vmessServer):\(line.vmessPort)"
        case "anytls":
            guard !line.anytlsServer.isEmpty else { return "" }
            return "\(line.anytlsServer):\(line.anytlsPort)"
        default:
            return ""
        }
    }

    private var typeLabel: String {
        switch line.type {
        case "direct": return "直连"
        case "vpn": return "VPN"
        case "trojan": return "Trojan"
        case "shadowsocks": return "SS"
        case "vmess": return "VMess"
        case "anytls": return "AnyTLS"
        case "tailscale": return "Tailscale"
        default: return line.type
        }
    }

    private var tailscaleStatusColor: Color {
        if tailscaleRuntimeConnected {
            return XDialPalette.success
        }
        if tailscaleStatus?.isRunning == true {
            if !line.tailscaleExitNode.isEmpty,
               tailscaleStatus?.exitNodes.first(where: { $0.ip == line.tailscaleExitNode })?.online != true {
                return XDialPalette.warning
            }
            return XDialPalette.success
        }
        if tailscaleStatus != nil || tailscaleError != nil {
            return XDialPalette.warning
        }
        return XDialPalette.disabled
    }

    private var tailscaleStatusLabel: String {
        if tailscaleRuntimeConnected {
            return state.tr("已连接", "Connected")
        }
        if tailscaleStatus?.isRunning == true {
            return state.tr("已登录", "Signed in")
        }
        if tailscaleStatus != nil {
            return state.tr("需要登录", "Sign-in required")
        }
        return state.tr("尚未检查", "Not checked")
    }

    @ViewBuilder
    private var detailFields: some View {
        switch line.type {
        case "vpn":
            field("服务器", $line.vpnServer, placeholder: "vpn.example.com:8443")
            field("用户名", $line.vpnUsername)
            secureField("密码", $line.vpnPassword)
            insecureToggle
        case "trojan":
            field("服务器", $line.trojanServer)
            intField("端口", $line.trojanPort)
            field("SNI", $line.trojanSNI)
            secureField("密码", $line.trojanPassword)
            insecureToggle
        case "shadowsocks":
            field("服务器", $line.ssServer)
            intField("端口", $line.ssPort)
            field("加密方法", $line.ssMethod)
            secureField("密码", $line.ssPassword)
        case "vmess":
            field("服务器", $line.vmessServer)
            intField("端口", $line.vmessPort)
            secureField("UUID", $line.vmessUUID)
            intField("Alter ID", $line.vmessAltID)
        case "anytls":
            field("服务器", $line.anytlsServer)
            boundedIntField("端口", $line.anytlsPort, range: 1...65535)
            field("SNI", $line.anytlsSNI)
            secureField("密码", $line.anytlsPassword)
            anyTLSFingerprintField
            anyTLSALPNField
            boundedIntField(
                "检查间隔",
                $line.anytlsIdleSessionCheckInterval,
                range: 0...3600,
                help: state.tr(
                    "6–3600 秒；0 表示使用协议默认值",
                    "6–3600 seconds; 0 uses the protocol default"
                )
            )
            boundedIntField(
                "空闲超时",
                $line.anytlsIdleSessionTimeout,
                range: 0...3600,
                help: state.tr(
                    "6–3600 秒；0 表示使用协议默认值",
                    "6–3600 seconds; 0 uses the protocol default"
                )
            )
            boundedIntField(
                "最少空闲",
                $line.anytlsMinIdleSession,
                range: Line.anyTLSMinIdleSessionRange,
                help: state.tr(
                    "至少保留的空闲会话数（0–64）",
                    "Minimum idle sessions to retain (0–64)"
                )
            )
            anyTLSUDPField
            anyTLSTFOField
            insecureToggle
            if let issue = anyTLSVisibleValidationIssue {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(XDialPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case "tailscale":
            tailscaleDetail
        default:
            EmptyView()
        }
    }

    private var tailscaleDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            HStack(spacing: 8) {
                Circle()
                    .fill(tailscaleStatusColor)
                    .frame(width: 8, height: 8)
                Text(tailscaleStatusLabel)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if tailscaleBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        refreshTailscaleStatus()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help(state.tr("刷新状态", "Refresh status"))
                    .disabled(state.engine.status != "disconnected")
                }
            }

            if let error = tailscaleError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(XDialPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(
                state.tr("启用 MagicDNS", "Enable MagicDNS"),
                isOn: Binding(
                    get: { line.tailscaleMagicDNS },
                    set: {
                        line.tailscaleMagicDNS = $0
                        state.saveEditingProfile()
                    }
                )
            )
            .toggleStyle(.switch)
            .font(.caption)
            .disabled(state.engine.status != "disconnected")
            .accessibilityIdentifier("tailscale-magic-dns-toggle")

            Text(state.tr(
                "解析并访问 Tailnet 节点；仅在当前 Scenario 使用这条线路时生效，Scenario 中已有的显式域名规则优先。",
                "Resolve and reach Tailnet peers only when the current Scenario uses this line. Explicit domain rules in the Scenario take priority."
            ))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if tailscaleRuntimeConnected {
                tailscaleConnectedFields
            } else if let status = tailscaleStatus, status.isRunning {
                tailscaleSignedInFields(status)
            } else {
                tailscaleSignInFields
            }
        }
        .padding(.top, 2)
    }

    private var tailscaleConnectedFields: some View {
        Text(state.tr(
            "本次连接事务已确认 Tailscale 线路就绪。断开 XDial 后可以刷新登录与出口节点配置。",
            "The current connection transaction confirmed this Tailscale line is ready. Disconnect XDial to refresh sign-in or exit-node configuration."
        ))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var tailscaleSignInFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.tr(
                "登录只用于在本机建立一份持久的 Tailscale 身份，不会启动系统 VPN。",
                "Sign-in creates one persistent local Tailscale identity and does not start a system VPN."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Button {
                beginTailscaleLogin()
            } label: {
                Label(
                    state.tr("在浏览器中登录", "Sign In in Browser"),
                    systemImage: "safari"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(tailscaleBusy || state.engine.status != "disconnected")
            .accessibilityIdentifier("tailscale-browser-login")

            DisclosureGroup(
                state.tr("使用 Auth Key", "Use Auth Key"),
                isExpanded: $showAuthKey
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    SecureField("tskey-auth-…", text: $authKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .accessibilityIdentifier("tailscale-auth-key")
                    Text(state.tr(
                        "只用于这一次注册；提交后立即清空，不写入配置、钥匙串或日志。",
                        "Used once for registration, then cleared. It is not saved to the profile, Keychain, or logs."
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    Button(state.tr("使用 Auth Key 注册", "Register with Auth Key")) {
                        registerTailscaleAuthKey()
                    }
                    .disabled(
                        authKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || tailscaleBusy
                            || state.engine.status != "disconnected"
                    )
                }
                .padding(.top, 5)
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private func tailscaleSignedInFields(_ status: TailscaleRuntimeStatus) -> some View {
        HStack {
            Text(state.tr("设备", "Device"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(state.editingProfile.tailscale.hostname)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Spacer()
        }

        HStack {
            Text(state.tr("出口节点", "Exit Node"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Picker("", selection: Binding(
                get: { line.tailscaleExitNode },
                set: {
                    line.tailscaleExitNode = $0
                    state.saveEditingProfile()
                }
            )) {
                Text(state.tr("不使用", "None")).tag("")
                if !line.tailscaleExitNode.isEmpty,
                   !status.exitNodes.contains(where: { $0.ip == line.tailscaleExitNode }) {
                    Text(state.tr(
                        "已保存但当前不可用",
                        "Saved but unavailable"
                    )).tag(line.tailscaleExitNode)
                }
                ForEach(status.exitNodes) { node in
                    Text(exitNodeLabel(node))
                        .tag(node.ip)
                        .disabled(!node.online)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityIdentifier("tailscale-exit-node-picker")
        }

        if !line.tailscaleExitNode.isEmpty,
           status.exitNodes.first(where: { $0.ip == line.tailscaleExitNode })?.online != true {
            Label(
                state.tr(
                    "所选出口节点当前不可用；连接会明确失败，不会回落到其他出口。",
                    "The selected exit node is unavailable. Connection will fail instead of falling back."
                ),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(XDialPalette.warning)
        }

        HStack {
            Spacer()
            Button(state.tr("退出登录", "Sign Out"), role: .destructive) {
                logoutTailscale()
            }
            .disabled(tailscaleBusy)
        }
    }

    private func exitNodeLabel(_ node: TailscaleRuntimeExitNode) -> String {
        var label = node.name.isEmpty ? node.ip : node.name
        if !node.online {
            label += state.tr("（离线）", " (Offline)")
        }
        return label
    }

    private func prepareTailscale(authKey: String = "") {
        guard line.type == "tailscale", !tailscaleBusy else { return }
        guard requireInstallation() else { return }
        guard state.engine.status == "disconnected" else {
            state.setTailscaleConfigurationError(state.tr(
                "请先断开 XDial，再配置 Tailscale 登录状态。",
                "Disconnect XDial before configuring Tailscale sign-in."
            ), for: line.id)
            return
        }
        state.setTailscaleConfigurationBusy(true, for: line.id)
        state.setTailscaleConfigurationError(nil, for: line.id)
        state.engine.prepareTailscale(
            profileJSON: state.buildEditingProfileJSON(),
            lineID: line.id,
            authKey: authKey
        ) { result in
            state.setTailscaleConfigurationBusy(false, for: line.id)
            applyTailscaleResult(result)
        }
    }

    private func refreshTailscaleStatus() {
        // setup session 会在连接数据面或 helper 重启时被关闭。刷新必须具备
        // 自愈能力：重建隔离会话并读取同一份持久身份，而不是查询旧会话。
        prepareTailscale()
    }

    private func beginTailscaleLogin() {
        guard !tailscaleBusy else { return }
        guard requireInstallation() else { return }
        state.setTailscaleConfigurationBusy(true, for: line.id)
        state.setTailscaleConfigurationError(nil, for: line.id)
        // 设置窗口或 helper 重启后，旧卡片可能还在但 setup session 已经结束。
        // 登录按钮先重建会话，不能假设 onAppear 曾成功执行。
        state.engine.prepareTailscale(
            profileJSON: state.buildEditingProfileJSON(),
            lineID: line.id
        ) { result in
            switch result {
            case let .failure(error):
                state.setTailscaleConfigurationBusy(false, for: line.id)
                state.setTailscaleConfigurationError(
                    error.localizedDescription,
                    for: line.id
                )
            case let .success(status):
                state.setTailscaleConfigurationStatus(
                    status,
                    for: line.id
                )
                if status.isRunning {
                    state.setTailscaleConfigurationBusy(
                        false,
                        for: line.id
                    )
                    return
                }
                if let url = validatedAuthURL(status.authURL) {
                    state.setTailscaleConfigurationBusy(
                        false,
                        for: line.id
                    )
                    NSWorkspace.shared.open(url)
                    startTailscalePolling()
                    return
                }
                requestTailscaleLoginURL()
            }
        }
    }

    private func requestTailscaleLoginURL() {
        state.engine.beginTailscaleLogin(lineID: line.id) { result in
            state.setTailscaleConfigurationBusy(false, for: line.id)
            switch result {
            case let .failure(error):
                state.setTailscaleConfigurationError(
                    error.localizedDescription,
                    for: line.id
                )
            case let .success(status):
                state.setTailscaleConfigurationStatus(
                    status,
                    for: line.id
                )
                if let url = validatedAuthURL(status.authURL) {
                    NSWorkspace.shared.open(url)
                    startTailscalePolling()
                } else if !status.isRunning {
                    state.setTailscaleConfigurationError(state.tr(
                        "没有取得有效的登录入口，请重试。",
                        "No valid sign-in URL was returned. Please try again."
                    ), for: line.id)
                }
            }
        }
    }

    private func registerTailscaleAuthKey() {
        let transientKey = authKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transientKey.isEmpty else { return }
        authKey = ""
        prepareTailscale(authKey: transientKey)
    }

    private func logoutTailscale() {
        guard !tailscaleBusy else { return }
        guard requireInstallation() else { return }
        state.setTailscaleConfigurationBusy(true, for: line.id)
        state.setTailscaleConfigurationError(nil, for: line.id)
        state.engine.logoutTailscale(lineID: line.id) { result in
            state.setTailscaleConfigurationBusy(false, for: line.id)
            applyTailscaleResult(result)
        }
    }

    private func applyTailscaleResult(_ result: Result<TailscaleRuntimeStatus, Error>) {
        switch result {
        case .success(let status):
            state.setTailscaleConfigurationStatus(
                status,
                for: line.id
            )
        case .failure(let error):
            state.setTailscaleConfigurationError(
                error.localizedDescription,
                for: line.id
            )
        }
    }

    private func requireInstallation() -> Bool {
        guard state.requireInstallationReady() else {
            state.setTailscaleConfigurationError(state.tr(
                "XDial 的首次安装尚未完成；安装窗口会自动继续。",
                "XDial first-run setup is not complete. The installation window will continue automatically."
            ), for: line.id)
            return false
        }
        return true
    }

    private func validatedAuthURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            return nil
        }
        return url
    }

    private func startTailscalePolling() {
        state.startTailscaleConfigurationPolling(lineID: line.id)
    }

    private var insecureToggle: some View {
        HStack(alignment: .top) {
            Text("跳过证书验证").font(.caption).foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Toggle("", isOn: $line.allowInsecure)
                    .labelsHidden()
                    .onChange(of: line.allowInsecure) { _, _ in
                        markLineChanged()
                    }
                Text("仅自签证书的服务器才需要开启；开启后无法防中间人窃取凭据")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var anyTLSFingerprintField: some View {
        HStack {
            Text(state.tr("TLS 指纹", "TLS Fingerprint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Picker("", selection: SwiftUI.Binding(
                get: { line.anytlsClientFingerprint },
                set: { value in
                    guard line.anytlsClientFingerprint != value else {
                        return
                    }
                    line.anytlsClientFingerprint = value
                    markLineChanged()
                }
            )) {
                ForEach(
                    Line.anyTLSSupportedClientFingerprints,
                    id: \.self
                ) { fingerprint in
                    Text(anyTLSFingerprintLabel(fingerprint))
                        .tag(fingerprint)
                }
                if !Line.anyTLSSupportedClientFingerprints.contains(
                    line.anytlsClientFingerprint
                ) {
                    Text(state.tr(
                        "不支持：\(line.anytlsClientFingerprint)",
                        "Unsupported: \(line.anytlsClientFingerprint)"
                    ))
                    .tag(line.anytlsClientFingerprint)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            Spacer()
        }
    }

    private var anyTLSALPNField: some View {
        HStack(alignment: .top) {
            Text("ALPN")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                TextEditor(text: $anyTLSALPNInput)
                    .font(.caption.monospaced())
                    .frame(minHeight: 42, maxHeight: 58)
                    .padding(3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.secondary.opacity(0.35))
                    )
                    .onChange(of: anyTLSALPNInput) { _, input in
                        let protocols = input.isEmpty
                            ? []
                            : input.components(separatedBy: .newlines)
                        guard line.anytlsALPN != protocols else {
                            return
                        }
                        line.anytlsALPN = protocols
                        markLineChanged()
                    }
                    .onChange(of: line.anytlsALPN) { _, protocols in
                        let input = protocols.joined(separator: "\n")
                        if anyTLSALPNInput != input {
                            anyTLSALPNInput = input
                        }
                    }
                Text(state.tr(
                    "每行一个协议，留空表示不指定，最多 8 项",
                    "One protocol per line; blank leaves ALPN unspecified; max 8"
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var anyTLSTFOField: some View {
        HStack(alignment: .top) {
            Text("TFO")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Toggle("", isOn: SwiftUI.Binding(
                    get: { line.tfo },
                    set: { value in
                        // AnyTLS 握手会读取已经建立连接的远端地址，与
                        // TCP Fast Open 不兼容。导入的 true 仍要保留并
                        // 可见地阻止连接，但 UI 只允许用户把它关掉。
                        guard !value, line.tfo else { return }
                        line.tfo = false
                        markLineChanged()
                    }
                ))
                .labelsHidden()
                .disabled(!line.tfo)
                Text(state.tr(
                    line.tfo
                        ? "订阅导入了 TFO；AnyTLS 不支持，请关闭后再连接"
                        : "AnyTLS 不支持 TCP Fast Open",
                    line.tfo
                        ? "The subscription enabled TFO. Turn it off before connecting."
                        : "AnyTLS does not support TCP Fast Open"
                ))
                .font(.caption2)
                .foregroundStyle(
                    line.tfo ? XDialPalette.danger : Color.secondary
                )
            }
            Spacer()
        }
    }

    private var anyTLSUDPField: some View {
        HStack(alignment: .top) {
            Text("UDP")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Label(
                    state.tr("原生 UoT", "Native UoT"),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(XDialPalette.success)
                Text(state.tr(
                    line.udp
                        ? "AnyTLS 数据面原生承载 UDP"
                        : "订阅声明了 udp=false；该值仅保留为导入事实，AnyTLS 数据面仍原生支持 UDP",
                    line.udp
                        ? "The AnyTLS data plane carries UDP natively"
                        : "The subscription declared udp=false. It is preserved as imported metadata; the AnyTLS data plane still supports UDP natively."
                ))
                .font(.caption2)
                .foregroundStyle(
                    line.udp ? Color.secondary : XDialPalette.warning
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private var anyTLSVisibleValidationIssue: String? {
        return line.anyTLSOptionsValidationIssue
    }

    private func anyTLSFingerprintLabel(_ value: String) -> String {
        switch value {
        case "":
            return state.tr("系统 TLS（不伪装）", "System TLS (no mimic)")
        case "chrome":
            return "Chrome"
        case "firefox":
            return "Firefox"
        case "edge":
            return "Edge"
        case "safari":
            return "Safari"
        case "ios":
            return "iOS"
        case "android":
            return "Android"
        case "random":
            return state.tr("随机浏览器", "Random browser")
        case "randomized":
            return state.tr("随机生成", "Randomized")
        case "chrome_psk", "chrome_psk_shuffle",
             "chrome_padding_psk_shuffle", "chrome_pq",
             "chrome_pq_psk":
            return "\(value) \(state.tr("（兼容）", "(legacy)"))"
        default:
            return value.uppercased()
        }
    }

    private func markLineChanged() {
        line.verified = false
        state.saveEditingProfile()
    }

    private func field(_ label: String, _ binding: SwiftUI.Binding<String>, placeholder: String = "") -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            ASCIITextField(placeholder: placeholder, text: binding)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onChange(of: binding.wrappedValue) { _, _ in
                    markLineChanged()
                }
        }
    }

    private func secureField(_ label: String, _ binding: SwiftUI.Binding<String>) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            ASCIISecureField(placeholder: "", text: binding)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onChange(of: binding.wrappedValue) { _, _ in
                    markLineChanged()
                }
        }
    }

    private func intField(_ label: String, _ binding: SwiftUI.Binding<Int>) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            TextField("", value: binding, format: .number)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onChange(of: binding.wrappedValue) { _, _ in
                    markLineChanged()
                }
        }
    }

    private func boundedIntField(
        _ label: String,
        _ binding: SwiftUI.Binding<Int>,
        range: ClosedRange<Int>,
        help: String = ""
    ) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                TextField("", value: binding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onChange(of: binding.wrappedValue) { _, _ in
                        // 保留用户输入的事实，让模型校验与连接计划 fail-closed。
                        // 边输边静默夹到边界会把 30 之类的正常输入改成 60，
                        // 也会掩盖订阅里真正的非法值。
                        markLineChanged()
                    }
                let effectiveHelp = help.isEmpty
                    ? "\(range.lowerBound)–\(range.upperBound)"
                    : help
                if !effectiveHelp.isEmpty {
                    Text(effectiveHelp)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func toggleField(_ label: String, _ binding: SwiftUI.Binding<Bool>) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            Toggle("", isOn: binding)
                .labelsHidden()
                .onChange(of: binding.wrappedValue) { _, _ in
                    markLineChanged()
                }
            Spacer()
        }
    }
}

// MARK: - 规则 Tab

struct RulesTab: View {
    @EnvironmentObject var state: AppState
    @State private var draggedItem: SettingsReorderItem?
    @State private var searchText = ""

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var visibleRuleIDs: Set<String> {
        Set(state.editingProfile.ruleSets.filter { $0.matchesSearch(query) }.map(\.id))
    }

    var body: some View {
        let visible = visibleRuleIDs
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField(state.tr("搜索名称、域名、IP 或应用", "Search name, domain, IP or app"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Text(state.tr("\(visible.count) / \(state.editingProfile.ruleSets.count) 个规则", "\(visible.count) / \(state.editingProfile.ruleSets.count) rules"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.top, 10)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach($state.editingProfile.ruleSets) { $rule in
                        if visible.contains(rule.id) {
                        RuleSetRow(rule: $rule, onDelete: { delete(rule) }, searchQuery: query)
                            .settingsReorderable(
                                SettingsReorderItem(
                                    kind: "rule",
                                    id: rule.id
                                ),
                                draggedItem: $draggedItem,
                                allowsDragging: query.isEmpty
                            ) { item, targetID in
                                moveRule(item, to: targetID)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .settingsReorderDropArea(draggedItem: $draggedItem)
            }
            Divider()
            AddBar {
                Button {
                    let rule = RuleSet(id: UUID().uuidString, name: state.tr("新规则", "New Rule"), type: "group")
                    state.editingProfile.ruleSets.append(rule)
                    state.editorPosition.expandedRuleIDs.insert(rule.id)
                    searchText = ""
                    state.saveEditingProfile()
                } label: {
                    Label(
                        state.tr("添加规则", "Add Rule"),
                        systemImage: "plus"
                    )
                }
            }
        }
    }

    private func delete(_ rule: RuleSet) {
        guard !state.editingProfile.scenarios.contains(where: { $0.bindings.contains(where: { $0.ruleSetID == rule.id }) }) else {
            state.profileOperationError = "此规则仍被场景使用，请先修改引用"
            return
        }
        state.editingProfile.ruleSets.removeAll { $0.id == rule.id }
        state.saveEditingProfile()
    }

    private func moveRule(
        _ item: SettingsReorderItem?,
        to targetID: String
    ) -> Bool {
        guard let item, item.kind == "rule",
              reorder(
                &state.editingProfile.ruleSets,
                draggedID: item.id,
                targetID: targetID,
                id: { $0.id }
              ) else { return false }
        state.saveEditingVisualOrder()
        return true
    }
}

struct RuleSetRow: View {
    @SwiftUI.Binding var rule: RuleSet
    var onDelete: (() -> Void)?
    var isCondition = false
    var searchQuery = ""
    private static let presetCatalog = RuleSetPresetCatalog.load()
    private var expanded: Bool {
        get { state.editorPosition.expandedRuleIDs.contains(rule.id) }
        nonmutating set {
            if newValue { state.editorPosition.expandedRuleIDs.insert(rule.id) }
            else { state.editorPosition.expandedRuleIDs.remove(rule.id) }
        }
    }
    @State private var domainsText = ""
    @State private var cidrsText = ""
    @State private var processesText = ""
    @State private var loaded = false
    @State private var processesLoaded = false
    @State private var applicationSelectionError: String?
    @EnvironmentObject var state: AppState

    private var sourceOwned: Bool {
        state.editingRecord.baseline?.ruleSets.contains(where: { $0.id == rule.id }) == true ||
        state.editingRecord.baseline?.matchingResources.contains(where: { $0.id == rule.id }) == true
    }

    private func saveDomainsAndCIDRs() {
        rule.domains = domainsText.split(whereSeparator: \.isNewline)
            .map { RuleSet.sanitizeEntry(String($0)) }
            .filter { !$0.isEmpty }
        rule.cidrs = cidrsText.split(whereSeparator: \.isNewline)
            .map { RuleSet.sanitizeEntry(String($0)) }
            .filter { !$0.isEmpty }
        state.saveEditingProfile()
    }

    private func saveProcesses() {
        rule.processes = RuleSet.sanitizeProcesses(
            processesText.split(whereSeparator: \.isNewline).map(String.init)
        )
        state.saveEditingProfile()
    }

    var body: some View {
        CollapsibleCard(
            isExpanded: expanded,
            onToggle: { expanded.toggle() },
            onDelete: sourceOwned ? nil : onDelete,
            enabled: Binding(get: { rule.enabled }, set: { guard !sourceOwned else { return }; rule.enabled = $0; state.saveEditingProfile() }),
            header: {
                Text(rule.name).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(ruleTypeLabel)
                    .font(.caption).foregroundStyle(.secondary)
                if rule.type != "group" {
                    Button {
                        guard !sourceOwned else { return }
                        rule.invert.toggle()
                        state.saveEditingProfile()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: rule.invert
                                ? "checkmark"
                                : "arrow.left.arrow.right")
                                .font(.system(
                                    size: 9,
                                    weight: rule.invert ? .bold : .semibold
                                ))
                                .frame(width: 12)
                            Text(state.tr("反向", "Invert"))
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(
                            rule.invert
                                ? XDialPalette.selection
                                : XDialPalette.textSecondary
                        )
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(
                            rule.invert
                                ? XDialPalette.selection.opacity(0.20)
                                : XDialPalette.surface,
                            in: Capsule()
                        )
                        .overlay {
                            Capsule().stroke(
                                rule.invert
                                    ? XDialPalette.selection.opacity(0.72)
                                    : XDialPalette.divider,
                                lineWidth: 0.8
                            )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(state.tr("反向", "Invert"))
                    .help(state.tr(
                        "反向匹配：匹配该规则之外的流量",
                        "Invert: match traffic outside this rule"
                    ))
                    .accessibilityValue(rule.invert
                        ? state.tr("已开启", "On")
                        : state.tr("已关闭", "Off"))
                }
            },
            detail: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(state.tr("名称", "Name")).font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                        TextField("", text: $rule.name)
                            .textFieldStyle(.roundedBorder).font(.caption)
                            .disabled(sourceOwned)
                            .onChange(of: rule.name) { _, _ in state.saveEditingProfile() }
                    }
                    if rule.type == "group" {
                        Text(state.tr("以下内容任一匹配即命中", "Match any of the following"))
                            .font(.caption).foregroundStyle(.secondary).padding(.vertical, 5)
                        LazyVStack(spacing: 6) {
                            ForEach($rule.conditions) { $condition in
                                if searchQuery.isEmpty || rule.name.localizedCaseInsensitiveContains(searchQuery) || condition.matchesSearch(searchQuery) {
                                AnyView(RuleSetRow(rule: $condition, onDelete: {
                                    rule.conditions.removeAll { $0.id == condition.id }
                                    state.saveEditingProfile()
                                }, isCondition: true))
                                }
                            }
                        }
                    } else if rule.type == "native" {
                        NativeRuleEditor(rule: $rule)
                    } else if rule.type == "url" {
                        urlFields
                    } else if rule.type == "application" {
                        applicationFields
                    } else {
                        manualFields
                    }
                    if !isCondition && !sourceOwned { addContentMenu.padding(.top, 8) }
                }
                .disabled(sourceOwned && rule.type != "group")
            }
        )
        .alert(
            state.tr("无法读取应用程序", "Could not read application"),
            isPresented: Binding(
                get: { applicationSelectionError != nil },
                set: { if !$0 { applicationSelectionError = nil } }
            )
        ) {
            Button(state.tr("好", "OK"), role: .cancel) {}
        } message: {
            Text(applicationSelectionError ?? "")
        }
    }

    private var ruleTypeLabel: String {
        if !isCondition { return rule.contentSummary(chinese: state.language == .zh) }
        switch rule.type {
        case "group":
            return state.tr("\(rule.conditions.count) 组条件", "\(rule.conditions.count) condition groups")
        case "url":
            return "URL"
        case "application":
            return state.tr("应用 · \(rule.matchItemCount ?? 0) 项", "App · \(rule.matchItemCount ?? 0) items")
        case "native":
            return state.tr("sing-box · \(rule.matchItemCount ?? 0) 项", "sing-box · \(rule.matchItemCount ?? 0) items")
        default:
            return state.tr("域名 / IP · \(rule.matchItemCount ?? 0) 项", "Domain / IP · \(rule.matchItemCount ?? 0) items")
        }
    }

    private var addContentMenu: some View {
        Menu {
            Button(state.tr("域名", "Domain")) { addContent(name: "域名", type: "native", field: "domain_suffix") }
            Button(state.tr("IP / 网段", "IP / CIDR")) { addContent(name: "IP / 网段", type: "native", field: "ip_cidr") }
            Button(state.tr("应用 / 进程", "App / Process")) { addContent(name: "应用 / 进程", type: "application") }
            Menu(state.tr("远程规则集", "Remote Rule Set")) {
                Button(state.tr("填写 URL…", "Enter URL…")) { addContent(name: "远程规则集", type: "url") }
                Divider()
                ForEach(Self.presetCatalog.presets) { preset in
                    Button(state.language == .zh ? preset.nameZH : preset.nameEN) {
                        appendContent(RuleSet(id: UUID().uuidString, name: state.language == .zh ? preset.nameZH : preset.nameEN,
                                              type: "url", url: preset.url, format: preset.format, invert: preset.invert))
                    }
                }
            }
            Divider()
            Button(state.tr("高级组合条件", "Advanced Match")) { addContent(name: "组合条件", type: "native") }
        } label: {
            Label(state.tr("添加匹配内容", "Add Matching Content"), systemImage: "plus")
        }.menuStyle(.borderlessButton).fixedSize()
    }

    private func addContent(name: String, type: String, field: String? = nil) {
        var content = RuleSet(id: UUID().uuidString, name: name, type: type)
        if type == "native" { content.nativeRule = .object(field.map { [$0: .array([])] } ?? [:]) }
        appendContent(content)
    }

    private func appendContent(_ content: RuleSet) {
        state.editingProfile.appendMatchingContent(content, to: rule.id)
        state.editorPosition.expandedRuleIDs.insert(content.id)
        state.saveEditingProfile()
    }

    private var urlFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("URL").font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                ASCIITextField(placeholder: "https://...", text: $rule.url)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onChange(of: rule.url) { _, _ in state.saveEditingProfile() }
                Picker("", selection: $rule.fetchLineID) {
                    Text(state.tr("直连", "Direct")).tag("direct")
                    ForEach(state.editingProfile.lines.filter {
                        $0.enabled && $0.id != "direct"
                    }) { line in
                        Text(line.name).tag(line.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 120)
                .help(state.tr("选择获取线路", "Select fetch line"))
                .onChange(of: rule.fetchLineID) { _, _ in state.saveEditingProfile() }
            }
            HStack {
                Text("格式").font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                Picker("", selection: $rule.format) {
                    Text("自动").tag("auto")
                    Text("sing-box .srs").tag("srs")
                    Text("sing-box .json").tag("json")
                    Text("纯文本列表").tag("text")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: rule.format) { _, _ in state.saveEditingProfile() }
            }
        }
        .padding(.leading, 18)
    }

    private var manualFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                Text("域名（每行一个）").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $domainsText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 60)
                    .border(Color.gray.opacity(0.3))
                    .onChange(of: domainsText) { _, _ in
                        if loaded { saveDomainsAndCIDRs() }
                    }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("IP CIDR（每行一个）").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $cidrsText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 50)
                    .border(Color.gray.opacity(0.3))
                    .onChange(of: cidrsText) { _, _ in
                        if loaded { saveDomainsAndCIDRs() }
                    }
            }
        }
        .padding(.leading, 18)
        .onAppear {
            domainsText = rule.domains.joined(separator: "\n")
            cidrsText = rule.cidrs.joined(separator: "\n")
            loaded = true
        }
    }

    private var applicationFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            if rule.applications.isEmpty {
                Text(state.tr(
                    "尚未选择应用程序。",
                    "No application selected."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                ForEach(rule.applications) { application in
                    HStack(alignment: .top, spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(
                            forFile: application.path
                        ))
                        .resizable()
                        .frame(width: 18, height: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(application.name)
                                .font(.caption)
                            HStack(spacing: 4) {
                                Text(state.tr("自动匹配", "Automatic"))
                                Text(application.path + "/")
                                    .font(.system(size: 10, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button(role: .destructive) {
                            rule.applications.removeAll {
                                $0.path == application.path
                            }
                            state.saveEditingProfile()
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .help(state.tr(
                            "移除应用程序",
                            "Remove application"
                        ))
                    }
                }
            }
            HStack(spacing: 8) {
                Button(state.tr("添加应用程序…", "Add Application…")) {
                    chooseApplications(replacing: false)
                }
                if !rule.applications.isEmpty {
                    Button(state.tr("替换…", "Replace…")) {
                        chooseApplications(replacing: true)
                    }
                }
            }
            .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.tr(
                    "附加程序规则（可选，每行一个）",
                    "Additional process rules (optional, one per line)"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                TextEditor(text: $processesText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 54)
                    .border(Color.gray.opacity(0.3))
                    .onChange(of: processesText) { _, _ in
                        if processesLoaded { saveProcesses() }
                    }
            }
            Text(state.tr(
                "所选应用程序会自动覆盖程序包内的主程序和所有辅助程序。包外程序可填写文件名（支持 * 和 ?）、完整绝对路径，或以 / 结尾的目录路径。",
                "Selected applications automatically include every executable in their bundles. For programs outside a bundle, enter a filename (with * or ?), an absolute path, or a directory path ending in /."
            ))
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 18)
        .onAppear {
            processesText = rule.processes.joined(separator: "\n")
            processesLoaded = true
        }
    }

    private func chooseApplications(replacing: Bool) {
        do {
            let selected = try ApplicationRulePicker.chooseApplications()
            guard !selected.isEmpty else { return }
            rule.applications = RuleSet.sanitizeApplications(
                replacing ? selected : rule.applications + selected
            )
            state.saveEditingProfile()
        } catch {
            applicationSelectionError = error.localizedDescription
        }
    }
}

private enum ApplicationRulePicker {
    static func chooseApplications() throws -> [ApplicationRuleApplication] {
        let panel = NSOpenPanel()
        panel.title = "选择应用程序"
        panel.prompt = "选择"
        panel.message = "选中后会自动匹配应用程序包内的主程序和所有辅助程序。"
        panel.allowsMultipleSelection = true
        // 把 .app 作为 file package 选择；若只允许目录同时又禁止进入 package，
        // NSOpenPanel 会把目标显示出来却无法选中。
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK else { return [] }
        return try panel.urls.map {
            try ApplicationRuleBundleCollector.collect(at: $0)
        }
    }
}

// MARK: - 场景 Tab

struct ScenariosTab: View {
    @EnvironmentObject var state: AppState
    @State private var showTemplate = false
    @State private var newName = ""
    private var expandedID: String? {
        get { state.editorPosition.expandedScenarioID }
        nonmutating set { state.editorPosition.expandedScenarioID = newValue }
    }
    @State private var draggedItem: SettingsReorderItem?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach($state.editingProfile.scenarios) { $scenario in
                        let scenarioID = scenario.id
                        ScenarioRow(
                            scenario: $scenario,
                            isActive: state.editingActiveProfile && scenarioID == state.engine.connectionReport?.scenario.id && state.isConnected,
                            isExpanded: expandedID == scenarioID,
                            onToggle: {
                                expandedID = expandedID == scenarioID
                                    ? nil
                                    : scenarioID
                            },
                            // 和主 popover 的 Picker、DebugServer 的 select-scenario
                            // 走同一个 intent，门禁与 dirty 置位只有一处实现
                            onActivate: { state.copyEditingScenario(scenarioID) },
                            onDelete: {
                                if expandedID == scenarioID {
                                    expandedID = nil
                                }
                                state.deleteScenario(id: scenarioID)
                            }
                        )
                        .settingsReorderable(
                            SettingsReorderItem(
                                kind: "scenario",
                                id: scenarioID
                            ),
                            draggedItem: $draggedItem,
                            allowsDragging: expandedID != scenarioID
                        ) { item, targetID in
                            moveScenario(item, to: targetID)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .settingsReorderDropArea(draggedItem: $draggedItem)
            }
            Divider()
            AddBar {
                Menu {
                    ForEach(ScenarioTemplate.allCases, id: \.self) { t in
                        Button(t.displayName) {
                            state.createScenario(from: t, named: t.displayName)
                        }
                    }
                } label: {
                    Label(state.tr("添加场景", "Add Scenario"), systemImage: "plus")
                }
            }
        }
    }

    private func moveScenario(
        _ item: SettingsReorderItem?,
        to targetID: String
    ) -> Bool {
        guard let item, item.kind == "scenario",
              reorder(
                &state.editingProfile.scenarios,
                draggedID: item.id,
                targetID: targetID,
                id: { $0.id }
              ) else { return false }
        state.saveEditingVisualOrder()
        return true
    }

}

struct ScenarioRow: View {
    @SwiftUI.Binding var scenario: Scenario
    let isActive: Bool
    let isExpanded: Bool
    let onToggle: () -> Void
    let onActivate: () -> Void
    let onDelete: () -> Void
    @EnvironmentObject var state: AppState
    @State private var newSSID = ""
    @State private var ssidError: String?
    @State private var showsIconPicker = false

    private var sourceOwned: Bool { state.editingRecord.baseline?.scenarios.contains(where: { $0.id == scenario.id }) == true }

    private var bindingSummary: String {
        let n = scenario.bindings.count
        return n == 0 ? state.tr("无规则", "No rules") : "\(n) \(state.tr("条规则", "rules"))"
    }

    var body: some View {
        CollapsibleCard(
            isExpanded: isExpanded,
            onToggle: onToggle,
            onDelete: sourceOwned ? nil : onDelete,
            accentBar: isActive,
            header: {
                Button(action: onActivate) {
                    Image(systemName: "doc.on.doc").font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help(state.tr("复制场景", "Copy Scenario"))
                Image(systemName: iconPreset.symbol)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                HStack(spacing: 7) {
                    Text(scenario.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(
                            minWidth: 72,
                            idealWidth: 108,
                            maxWidth: 148,
                            alignment: .leading
                        )
                        .layoutPriority(2)
                    Text(bindingSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .layoutPriority(2)

                    if !scenario.matchSSIDs.isEmpty {
                        ScenarioSSIDCapsuleLayout(
                            horizontalSpacing: 4,
                            minimumItemWidth: 48,
                            maximumItemWidth: 148
                        ) {
                            ForEach(scenario.matchSSIDs, id: \.self) { ssid in
                                scenarioSSIDCapsule(ssid)
                            }
                        }
                        .frame(
                            minWidth: 0,
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                        .clipped()
                        .layoutPriority(-1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            },
            detail: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(state.tr("名称", "Name")).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                        TextField("", text: $scenario.name)
                            .textFieldStyle(.roundedBorder).font(.caption)
                            .onChange(of: scenario.name) { _, _ in state.saveEditingProfile() }
                        Button {
                            showsIconPicker.toggle()
                        } label: {
                            ZStack(alignment: .bottomTrailing) {
                                Image(systemName: iconPreset.symbol)
                                    .font(.system(size: 15, weight: .regular))
                                if scenario.iconOverride == nil {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 7, weight: .semibold))
                                        .offset(x: 3, y: 2)
                                }
                            }
                            .foregroundStyle(XDialPalette.selection)
                            .frame(width: 30, height: 26)
                            .background(
                                XDialPalette.selection.opacity(0.09),
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(
                                        XDialPalette.selection.opacity(0.16),
                                        lineWidth: 0.5
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .help(state.tr("选择场景图标", "Choose scenario icon"))
                        .accessibilityLabel(
                            state.tr("场景图标", "Scenario icon")
                        )
                        .accessibilityValue(iconAccessibilityValue)
                        .popover(isPresented: $showsIconPicker) {
                            ScenarioIconPicker(scenario: $scenario)
                                .environmentObject(state)
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Label(
                                state.tr("Wi-Fi 自动切换", "Automatic Wi-Fi switch"),
                                systemImage: "wifi"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Spacer()
                            if let currentSSID = state.currentSSID {
                                Button(state.tr(
                                    "使用当前：\(currentSSID)",
                                    "Use current: \(currentSSID)"
                                )) {
                                    addSSID(currentSSID)
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                            } else {
                                Button(
                                    state.wifiSSIDAccessState == .denied
                                        ? state.tr(
                                            "打开位置设置",
                                            "Open Location Settings"
                                        )
                                        : state.tr(
                                            "读取当前 Wi-Fi",
                                            "Read current Wi-Fi"
                                        )
                                ) {
                                    state.requestSSIDAccess()
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                                .foregroundStyle(XDialPalette.primaryAction)
                            }
                        }

                        ForEach(scenario.matchSSIDs, id: \.self) { ssid in
                            HStack(spacing: 7) {
                                Image(systemName: "wifi")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(ssid)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    state.removeSSID(ssid, from: scenario.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 27)
                            .background(.quaternary.opacity(0.55))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        }

                        HStack(spacing: 6) {
                            TextField(
                                state.tr("添加 SSID", "Add SSID"),
                                text: $newSSID
                            )
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .onSubmit { addSSID(newSSID) }
                            Button {
                                addSSID(newSSID)
                            } label: {
                                Image(systemName: "plus.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .disabled(newSSID.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty)
                        }

                        if let ssidError {
                            Text(ssidError)
                                .font(.caption2)
                                .foregroundStyle(XDialPalette.danger)
                        } else if state.wifiSSIDAccessState == .denied {
                            Text(state.tr(
                                "需要在系统设置中允许 XDial 访问位置，macOS 才会提供 SSID。",
                                "Allow XDial location access in System Settings so macOS can provide the SSID."
                            ))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    HStack {
                        HStack(spacing: 6) {
                            Color.clear
                                .frame(width: 28, height: 1)
                                .accessibilityHidden(true)
                            Text(state.tr("匹配条件", "Match"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 166, alignment: .leading)
                        }
                        .frame(width: 200, alignment: .leading)
                        Text(state.tr("线路或组", "Line or group")).font(.caption).foregroundStyle(.secondary)
                    }

                    if !scenario.matchOrder.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(state.tr("沿用原配置的匹配顺序", "Preserve Source Match Order"))
                                    .font(.caption)
                                Spacer()
                                Button(state.tr("改用下方规则顺序", "Use Rule Order Below")) {
                                    scenario.matchOrder = []
                                    state.saveEditingProfile()
                                }.controlSize(.small)
                            }
                            Text(state.tr("同名规则已归类，交错的匹配顺序仍保留。改用下方顺序后可拖动排序，重叠流量的出口可能改变。", "Conditions are grouped by name while their original priority is retained. Using the order below enables reordering and may change overlapping matches."))
                                .font(.caption2).foregroundStyle(.secondary)
                        }.padding(.vertical, 5)
                    }

                    ScenarioBindingList(
                        bindings: $scenario.bindings,
                        scenarioID: scenario.id,
                        state: state,
                        onSave: { state.saveEditingProfile() }
                    )

                    Divider()

                    HStack {
                        Text(state.tr("其他流量", "Other"))
                            .font(.caption)
                            .frame(width: 200, alignment: .leading)
                        exitPicker(selectedID: SwiftUI.Binding(
                            get: { scenario.defaultTargetID },
                            set: { scenario.defaultTargetID = $0; state.saveEditingProfile() }
                        ))
                    }

                    // 添加规则
                    HStack {
                        Spacer()
                        Menu {
                            let usedIDs = Set(scenario.bindings.map { $0.ruleSetID })
                            let available = state.editingProfile.ruleSets.filter { !usedIDs.contains($0.id) }
                            if available.isEmpty {
                                Button(state.tr("（无可用规则）", "(No rule available)")) {}.disabled(true)
                            } else {
                                ForEach(available) { rule in
                                    Button(rule.name) {
                                        let firstExit = state.editingProfile.lines.first?.id ?? ""
                                        scenario.bindings.append(RuleBinding(ruleSetID: rule.id, lineID: firstExit))
                                        state.saveEditingProfile()
                                    }
                                }
                            }
                        } label: {
                            Label(state.tr("添加规则", "Add Rule"), systemImage: "plus")
                        }
                        .menuStyle(.borderlessButton)
                        .controlSize(.small)
                    }
                }
                .disabled(sourceOwned)
            }
        )
    }

    private func addSSID(_ value: String) {
        ssidError = state.addSSID(value, to: scenario.id)
        if ssidError == nil {
            newSSID = ""
        }
    }

    private var iconPreset: ScenarioIconPreset {
        ScenarioIconCatalog.resolvedPreset(for: scenario)
    }

    private var iconAccessibilityValue: String {
        let name = state.tr(iconPreset.zhName, iconPreset.enName)
        return scenario.iconOverride == nil
            ? state.tr("自动：\(name)", "Automatic: \(name)")
            : state.tr("手动：\(name)", "Manual: \(name)")
    }

    private func scenarioSSIDCapsule(_ ssid: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "wifi")
                .font(.system(size: 8.5, weight: .medium))
            Text(ssid)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(XDialPalette.information)
        .padding(.horizontal, 7)
        .frame(minWidth: 48, maxWidth: 148, alignment: .leading)
        .frame(height: 20)
        .background(
            XDialPalette.information.opacity(0.08),
            in: Capsule()
        )
        .overlay {
            Capsule().stroke(
                XDialPalette.information.opacity(0.14),
                lineWidth: 0.5
            )
        }
        .help(ssid)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            state.tr("Wi-Fi：\(ssid)", "Wi-Fi: \(ssid)")
        )
        .accessibilityValue(ssid)
    }

    private func exitPicker(selectedID: SwiftUI.Binding<String>) -> some View {
        LineTargetPicker(state: state, selection: selectedID, label: state.tr("默认出口", "Default Exit"))
            .onChange(of: selectedID.wrappedValue) { _, _ in state.saveEditingProfile() }
    }

}

/// Keeps every saved SSID on one compact row. Wider capsules yield space first
/// until each reaches the two-CJK-character minimum; any remaining tail is
/// clipped by the caller instead of increasing card height or displacing the
/// Scenario name and trailing controls.
private struct ScenarioSSIDCapsuleLayout: Layout {
    let horizontalSpacing: CGFloat
    let minimumItemWidth: CGFloat
    let maximumItemWidth: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let idealSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let naturalWidth = idealSizes.reduce(0) {
            $0 + min(maximumItemWidth, max(minimumItemWidth, $1.width))
        } + spacingWidth(for: subviews.count)
        let availableWidth = max(0, proposal.width ?? naturalWidth)
        let widths = compressedWidths(
            idealSizes.map(\.width),
            availableWidth: availableWidth
        )
        let height = zip(subviews, widths).reduce(CGFloat.zero) { result, pair in
            max(
                result,
                pair.0.sizeThatFits(
                    ProposedViewSize(width: pair.1, height: nil)
                ).height
            )
        }
        return CGSize(
            width: min(availableWidth, widths.reduce(0, +) + spacingWidth(for: widths.count)),
            height: height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let widths = compressedWidths(
            subviews.map { $0.sizeThatFits(.unspecified).width },
            availableWidth: bounds.width
        )
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(
                    x: x,
                    y: bounds.midY
                ),
                anchor: .leading,
                proposal: ProposedViewSize(
                    width: widths[index],
                    height: bounds.height
                )
            )
            x += widths[index] + horizontalSpacing
        }
    }

    private func compressedWidths(
        _ idealWidths: [CGFloat],
        availableWidth: CGFloat
    ) -> [CGFloat] {
        guard !idealWidths.isEmpty else { return [] }
        let widths = idealWidths.map {
            min(maximumItemWidth, max(minimumItemWidth, $0))
        }
        let widthBudget = max(
            0,
            availableWidth - spacingWidth(for: widths.count)
        )
        guard widths.reduce(0, +) > widthBudget else { return widths }

        let minimumTotal = CGFloat(widths.count) * minimumItemWidth
        guard widthBudget > minimumTotal else {
            return Array(
                repeating: minimumItemWidth,
                count: widths.count
            )
        }

        // Water-fill from the widest capsules downward. Short SSIDs keep their
        // natural width until the longer ones have compressed to the same cap.
        var lowerBound = minimumItemWidth
        var upperBound = widths.max() ?? minimumItemWidth
        for _ in 0..<24 {
            let cap = (lowerBound + upperBound) / 2
            let cappedTotal = widths.reduce(0) {
                $0 + min($1, cap)
            }
            if cappedTotal > widthBudget {
                upperBound = cap
            } else {
                lowerBound = cap
            }
        }
        return widths.map { min($0, lowerBound) }
    }

    private func spacingWidth(for itemCount: Int) -> CGFloat {
        CGFloat(max(0, itemCount - 1)) * horizontalSpacing
    }
}

private struct ScenarioIconPicker: View {
    private static let automaticKey = "__automatic__"
    private let columns = Array(
        repeating: GridItem(.fixed(34), spacing: 8),
        count: 6
    )

    @SwiftUI.Binding var scenario: Scenario
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedKey: String?
    @State private var hoveredKey: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(previewName)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)

            automaticButton

            Divider()

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(ScenarioIconCatalog.presets) { preset in
                    iconButton(preset)
                }
            }
        }
        .padding(12)
        .frame(width: 268)
        .background(XDialPalette.elevated)
        .onAppear {
            focusedKey = scenario.iconOverride
                ?? Self.automaticKey
        }
        .onMoveCommand(perform: moveFocus)
        .onExitCommand { dismiss() }
    }

    private var automaticPreset: ScenarioIconPreset {
        ScenarioIconCatalog.automaticPreset(
            name: scenario.name,
            ssids: scenario.matchSSIDs
        )
    }

    private var previewName: String {
        if hoveredKey == Self.automaticKey {
            return automaticLabel
        }
        if let hoveredKey,
           let preset = ScenarioIconCatalog.preset(forKey: hoveredKey) {
            return state.tr(preset.zhName, preset.enName)
        }
        if scenario.iconOverride == nil {
            return automaticLabel
        }
        let preset = ScenarioIconCatalog.resolvedPreset(for: scenario)
        return state.tr(preset.zhName, preset.enName)
    }

    private var automaticLabel: String {
        let matched = state.tr(automaticPreset.zhName, automaticPreset.enName)
        return state.tr("自动匹配 · \(matched)", "Automatic · \(matched)")
    }

    private var automaticButton: some View {
        let selected = scenario.iconOverride == nil
        return Button {
            select(nil)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: automaticPreset.symbol)
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 20)
                Text(state.tr("自动匹配", "Automatic"))
                    .font(.system(size: 11.5, weight: .medium))
                Spacer()
                Image(systemName: selected ? "checkmark" : "sparkles")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(
                        selected ? XDialPalette.selection : Color.secondary
                    )
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(
                selected
                    ? XDialPalette.selection.opacity(0.10)
                    : Color.primary.opacity(0.025),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        selected
                            ? XDialPalette.selection.opacity(0.28)
                            : XDialPalette.divider.opacity(0.58),
                        lineWidth: selected ? 1 : 0.5
                    )
            }
        }
        .buttonStyle(.plain)
        .focused($focusedKey, equals: Self.automaticKey)
        .onHover { hoveredKey = $0 ? Self.automaticKey : nil }
        .accessibilityValue(selected
            ? state.tr("已选择", "Selected")
            : ""
        )
    }

    private func iconButton(_ preset: ScenarioIconPreset) -> some View {
        let selected = manualSelectionID == preset.id
        return Button {
            select(preset.id)
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: preset.symbol)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(
                        selected ? XDialPalette.selection : Color.primary.opacity(0.72)
                    )
                    .frame(width: 34, height: 34)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(XDialPalette.selection)
                        .offset(x: 2, y: -2)
                }
            }
            .background(
                selected
                    ? XDialPalette.selection.opacity(0.10)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        selected
                            ? XDialPalette.selection.opacity(0.32)
                            : Color.primary.opacity(0.07),
                        lineWidth: selected ? 1 : 0.5
                    )
            }
        }
        .buttonStyle(.plain)
        .focused($focusedKey, equals: preset.id)
        .onHover { hoveredKey = $0 ? preset.id : nil }
        .help(state.tr(preset.zhName, preset.enName))
        .accessibilityLabel(state.tr(preset.zhName, preset.enName))
        .accessibilityValue(selected
            ? state.tr("已选择", "Selected")
            : ""
        )
    }

    private var manualSelectionID: String? {
        guard let override = scenario.iconOverride else { return nil }
        return ScenarioIconCatalog.preset(forKey: override)?.id
            ?? ScenarioIconCatalog.fallback.id
    }

    private func select(_ key: String?) {
        scenario.iconOverride = key
        state.saveEditingProfile()
        dismiss()
    }

    private func moveFocus(_ direction: MoveCommandDirection) {
        let keys = [Self.automaticKey]
            + ScenarioIconCatalog.presets.map(\.id)
        guard let current = focusedKey,
              let index = keys.firstIndex(of: current) else {
            focusedKey = keys.first
            return
        }

        let nextIndex: Int
        switch direction {
        case .left:
            nextIndex = max(0, index - 1)
        case .right:
            nextIndex = min(keys.count - 1, index + 1)
        case .up:
            nextIndex = index <= 6 ? 0 : index - 6
        case .down:
            nextIndex = index == 0
                ? 1
                : min(keys.count - 1, index + 6)
        @unknown default:
            return
        }
        focusedKey = keys[nextIndex]
        hoveredKey = keys[nextIndex]
    }
}
