import AppKit
import SwiftUI
import UniformTypeIdentifiers

private extension UTType {
    static let xdialSettingsEntry = UTType(
        exportedAs: "com.kafeifei.xdial.settings-entry"
    )
}

private struct SettingsReorderItem: Codable, Transferable {
    let kind: String
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .xdialSettingsEntry)
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
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack {
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        settingsTab(
                            0,
                            title: state.tr("线路", "Lines"),
                            symbol: "point.3.connected.trianglepath.dotted"
                        )
                        settingsTab(
                            1,
                            title: state.tr("规则", "Rules"),
                            symbol: "list.bullet.rectangle"
                        )
                        settingsTab(
                            2,
                            title: state.tr("场景", "Scenarios"),
                            symbol: "square.grid.2x2"
                        )
                    }
                    .padding(4)
                    .frame(width: 292)
                    .background(Color.primary.opacity(0.04), in: Capsule())
                    .overlay {
                        Capsule().stroke(
                            XDialPalette.divider.opacity(0.65),
                            lineWidth: 0.5
                        )
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 0) {
                    settingsTab(
                        3,
                        title: state.tr("通用", "General"),
                        symbol: "gearshape"
                    )
                }
                .padding(4)
                .frame(width: 92)
                .background(Color.primary.opacity(0.04), in: Capsule())
                .overlay {
                    Capsule().stroke(
                        XDialPalette.divider.opacity(0.65),
                        lineWidth: 0.5
                    )
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background {
                LinearGradient(
                    colors: [
                        titleAccent.opacity(0.10),
                        titleAccent.opacity(0.035),
                        XDialPalette.accent.opacity(0.025),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }

            if !state.installation.isReady {
                installationBanner
            } else if state.configDirty {
                dirtyBanner
            }

            Divider()

            ZStack {
                if tab == 0 { LinesTab() }
                else if tab == 1 { RulesTab() }
                else if tab == 2 { ScenariosTab() }
                else { GeneralTab() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(XDialPalette.canvas)
        }
        .frame(width: 540, height: 520)
        .background(XDialPalette.canvas)
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
            tab = index
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
            .frame(maxWidth: .infinity)
            .frame(height: 28)
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

    /// 当前事务依赖的已保存配置发生变化时，四个 Tab 共用这一条状态轨。
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

// MARK: - 通用 Tab

struct GeneralTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                SettingsPanel {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(state.tr("外观", "Appearance"))
                                .font(.system(size: 12))
                            Spacer()
                            Picker(
                                state.tr("外观", "Appearance"),
                                selection: $state.appearance
                            ) {
                                appearanceOption(
                                    .system,
                                    title: state.tr(
                                        "跟随系统",
                                        "Follow System"
                                    ),
                                    symbol: "circle.lefthalf.filled"
                                )
                                appearanceOption(
                                    .light,
                                    title: state.tr("白天", "Light"),
                                    symbol: "sun.max.fill"
                                )
                                appearanceOption(
                                    .dark,
                                    title: state.tr("黑夜", "Dark"),
                                    symbol: "moon.fill"
                                )
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .controlSize(.small)
                            .frame(width: 132)
                            .accessibilityLabel(
                                state.tr("外观", "Appearance")
                            )
                        }
                        .frame(minHeight: 28)

                        HStack(spacing: 8) {
                            Text(state.tr("语言", "Language"))
                                .font(.system(size: 12))
                            Spacer()
                            Picker("", selection: $state.language) {
                                ForEach(Lang.allCases, id: \.self) { l in
                                    Text(l.displayName).tag(l)
                                }
                            }
                            .font(.system(size: 12))
                            .pickerStyle(.menu)
                            .controlSize(.small)
                            .frame(width: 136)
                        }
                        .frame(minHeight: 28)

                        Toggle(isOn: $state.launchAtLogin) {
                            Text(state.tr("开机自动启动", "Launch at login"))
                                .font(.system(size: 12))
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)

                        VStack(alignment: .leading, spacing: 3) {
                            Toggle(isOn: $state.autoConnect) {
                                Text(state.tr(
                                    "启动时自动连接",
                                    "Connect automatically on launch"
                                ))
                                .font(.system(size: 12))
                            }
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                            Text(state.tr(
                                "此选项控制 XDial 启动后连接当前场景。运行中断线时，XDial 会尝试自动恢复连接。",
                                "This controls connecting the active Scenario when XDial launches. If the connection drops while running, XDial attempts to restore it automatically."
                            ))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                SettingsPanel {
                    HStack(spacing: 8) {
                        Image(systemName: installationStatusSymbol)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(installationStatusColor)
                            .frame(width: 18, height: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.tr(
                                "安装与卸载",
                                "Install & Uninstall"
                            ))
                            .font(.system(size: 12, weight: .semibold))
                            Text(installationStatusText)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Button {
                            state.installation.present(
                                operation: .install
                            )
                        } label: {
                            Label(
                                state.tr("安装", "Install"),
                                systemImage: "square.and.arrow.down"
                            )
                            .font(.system(size: 11.5))
                        }
                        .controlSize(.small)

                        Button(role: .destructive) {
                            state.installation.present(
                                operation: .uninstall
                            )
                        } label: {
                            Label(
                                state.tr("卸载", "Uninstall"),
                                systemImage: "trash"
                            )
                            .font(.system(size: 11.5))
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private func appearanceOption(
        _ appearance: AppAppearance,
        title: String,
        symbol: String
    ) -> some View {
        Label(title, systemImage: symbol)
            .labelStyle(.iconOnly)
            .accessibilityLabel(title)
            .tag(appearance)
            .help(title)
    }

    private var installationStatusText: String {
        if state.installation.isReady {
            return state.tr(
                "后台服务与网络扩展均已安装",
                "Background service and network extension are installed"
            )
        }
        return state.installation.report.error?.message
            ?? state.tr(
                "安装尚未完成",
                "Installation is not complete"
            )
    }

    private var installationStatusSymbol: String {
        if state.installation.isReady { return "checkmark.shield.fill" }
        if state.installation.report.state == .failed {
            return "exclamationmark.shield.fill"
        }
        return "shield.lefthalf.filled"
    }

    private var installationStatusColor: Color {
        if state.installation.isReady { return XDialPalette.success }
        if state.installation.report.state == .failed {
            return XDialPalette.danger
        }
        return XDialPalette.progress
    }
}

// MARK: - 线路 Tab

struct LinesTab: View {
    @EnvironmentObject var state: AppState
    @State private var showAddSub = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($state.profile.lines) { $line in
                        LineRow(line: $line, onDelete: { delete(line) })
                            .draggable(SettingsReorderItem(kind: "line", id: line.id))
                            .dropDestination(for: SettingsReorderItem.self) { items, _ in
                                moveLine(items.first, to: line.id)
                            }
                    }
                    ForEach($state.profile.subscriptions) { $sub in
                        SubscriptionRow(sub: $sub, onDelete: { deleteSub(sub) })
                            .draggable(SettingsReorderItem(kind: "subscription", id: sub.id))
                            .dropDestination(for: SettingsReorderItem.self) { items, _ in
                                moveSubscription(items.first, to: sub.id)
                            }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            Divider()
            AddBar {
                Menu {
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
                    Divider()
                    Button {
                        showAddSub = true
                    } label: {
                        Label(
                            state.tr(
                                "从订阅导入…",
                                "Import from subscription…"
                            ),
                            systemImage: "tray.and.arrow.down"
                        )
                    }
                } label: {
                    Label(state.tr("添加线路", "Add Line"), systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSub) {
            AddSubscriptionSheet(isPresented: $showAddSub)
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
        state.profile.lines.append(Line(id: id, name: name, type: type))
        state.save()
    }

    private func delete(_ line: Line) {
        if line.type == "direct" { return }
        if line.type == "tailscale" {
            state.engine.stopTailscaleSetup(lineID: line.id)
        }
        state.profile.lines.removeAll { $0.id == line.id }
        state.save()
    }

    private func deleteSub(_ sub: Subscription) {
        state.deleteSubscription(sub.id)
    }

    private func moveLine(
        _ item: SettingsReorderItem?,
        to targetID: String
    ) -> Bool {
        guard let item, item.kind == "line",
              reorder(
                &state.profile.lines,
                draggedID: item.id,
                targetID: targetID,
                id: { $0.id }
              ) else { return false }
        state.save()
        return true
    }

    private func moveSubscription(
        _ item: SettingsReorderItem?,
        to targetID: String
    ) -> Bool {
        guard let item, item.kind == "subscription",
              reorder(
                &state.profile.subscriptions,
                draggedID: item.id,
                targetID: targetID,
                id: { $0.id }
              ) else { return false }
        state.save()
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
    @State private var expanded = false
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
            onDelete: isLocked ? nil : onDelete,
            enabled: Binding(get: { line.enabled }, set: { if !isLocked { line.enabled = $0; state.save() } }),
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
            },
            detail: {
                VStack(alignment: .leading, spacing: 4) {
                    runtimeFailure
                    HStack {
                        Text("名称").font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                        TextField("名称", text: $line.name)
                            .textFieldStyle(.roundedBorder).font(.caption)
                            .onChange(of: line.name) { _, _ in state.save() }
                    }
                    detailFields
                }
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
                        state.save()
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
            Text(state.profile.tailscale.hostname)
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
                    state.save()
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
            profileJSON: state.buildProfileJSON(),
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
            profileJSON: state.buildProfileJSON(),
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
        state.save()
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
    private let presetCatalog = RuleSetPresetCatalog.load()
    @State private var applicationSelectionError: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($state.profile.ruleSets) { $rule in
                        RuleSetRow(rule: $rule, onDelete: { delete(rule) })
                            .draggable(SettingsReorderItem(kind: "rule", id: rule.id))
                            .dropDestination(for: SettingsReorderItem.self) { items, _ in
                                moveRule(items.first, to: rule.id)
                            }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            Divider()
            AddBar {
                Menu {
                    Menu(state.tr("URL 规则", "URL Rule")) {
                        ForEach(presetCatalog.presets) { preset in
                            Button(
                                state.language == .zh
                                    ? preset.nameZH
                                    : preset.nameEN
                            ) {
                                add(preset: preset)
                            }
                        }
                    }
                    Button(state.tr("手动域名/IP", "Manual Domain/IP")) {
                        addManual()
                    }
                    Button(state.tr("应用程序", "Application")) {
                        addApplication()
                    }
                } label: {
                    Label(
                        state.tr("添加规则", "Add Rule"),
                        systemImage: "plus"
                    )
                }
            }
        }
        .alert(
            state.tr(
                "无法添加应用程序规则",
                "Could not add application rule"
            ),
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

    private func add(preset: RuleSetPreset) {
        let id = "rule-" + String(UUID().uuidString.prefix(6))
        state.profile.ruleSets.append(RuleSet(
            id: id,
            name: state.language == .zh
                ? preset.nameZH
                : preset.nameEN,
            type: "url",
            url: preset.url,
            format: preset.format,
            invert: preset.invert
        ))
        state.save()
    }

    private func addManual() {
        let id = "rule-" + String(UUID().uuidString.prefix(6))
        state.profile.ruleSets.append(RuleSet(
            id: id,
            name: state.tr("新手动规则", "New Manual Rule"),
            type: "manual"
        ))
        state.save()
    }

    private func addApplication() {
        do {
            let applications = try ApplicationRulePicker.chooseApplications()
            guard !applications.isEmpty else { return }
            let id = "rule-" + String(UUID().uuidString.prefix(6))
            state.profile.ruleSets.append(RuleSet(
                id: id,
                name: applications.count == 1
                    ? applications[0].name
                    : state.tr("应用程序规则", "Application Rule"),
                type: "application",
                applications: applications
            ))
            state.save()
        } catch {
            applicationSelectionError = error.localizedDescription
        }
    }

    private func delete(_ rule: RuleSet) {
        state.profile.ruleSets.removeAll { $0.id == rule.id }
        for i in state.profile.scenarios.indices {
            state.profile.scenarios[i].bindings.removeAll { $0.ruleSetID == rule.id }
        }
        state.save()
    }

    private func moveRule(
        _ item: SettingsReorderItem?,
        to targetID: String
    ) -> Bool {
        guard let item, item.kind == "rule",
              reorder(
                &state.profile.ruleSets,
                draggedID: item.id,
                targetID: targetID,
                id: { $0.id }
              ) else { return false }
        state.save()
        return true
    }
}

struct RuleSetRow: View {
    @SwiftUI.Binding var rule: RuleSet
    var onDelete: () -> Void
    @State private var expanded = false
    @State private var domainsText = ""
    @State private var cidrsText = ""
    @State private var processesText = ""
    @State private var loaded = false
    @State private var processesLoaded = false
    @State private var applicationSelectionError: String?
    @EnvironmentObject var state: AppState

    private func saveDomainsAndCIDRs() {
        rule.domains = domainsText.split(whereSeparator: \.isNewline)
            .map { RuleSet.sanitizeEntry(String($0)) }
            .filter { !$0.isEmpty }
        rule.cidrs = cidrsText.split(whereSeparator: \.isNewline)
            .map { RuleSet.sanitizeEntry(String($0)) }
            .filter { !$0.isEmpty }
        state.save()
    }

    private func saveProcesses() {
        rule.processes = RuleSet.sanitizeProcesses(
            processesText.split(whereSeparator: \.isNewline).map(String.init)
        )
        state.save()
    }

    var body: some View {
        CollapsibleCard(
            isExpanded: expanded,
            onToggle: { expanded.toggle() },
            onDelete: onDelete,
            enabled: Binding(get: { rule.enabled }, set: { rule.enabled = $0; state.save() }),
            header: {
                Text(rule.name).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(ruleTypeLabel)
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    rule.invert.toggle()
                    state.save()
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
            },
            detail: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(state.tr("名称", "Name")).font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                        TextField("", text: $rule.name)
                            .textFieldStyle(.roundedBorder).font(.caption)
                            .onChange(of: rule.name) { _, _ in state.save() }
                    }
                    if rule.type == "url" {
                        urlFields
                    } else if rule.type == "application" {
                        applicationFields
                    } else {
                        manualFields
                    }
                }
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
        switch rule.type {
        case "url":
            return "URL"
        case "application":
            return state.tr("应用程序", "Application")
        default:
            return state.tr("手动", "Manual")
        }
    }

    private var urlFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("URL").font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                ASCIITextField(placeholder: "https://...", text: $rule.url)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onChange(of: rule.url) { _, _ in state.save() }
                Picker("", selection: $rule.fetchLineID) {
                    Text(state.tr("直连", "Direct")).tag("direct")
                    ForEach(state.profile.lines.filter {
                        $0.enabled && $0.id != "direct"
                    }) { line in
                        Text(line.name).tag(line.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 120)
                .help(state.tr("选择获取线路", "Select fetch line"))
                .onChange(of: rule.fetchLineID) { _, _ in state.save() }
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
                .onChange(of: rule.format) { _, _ in state.save() }
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
                            state.save()
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
            state.save()
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
    @State private var expandedID: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($state.profile.scenarios) { $scenario in
                        let scenarioID = scenario.id
                        ScenarioRow(
                            scenario: $scenario,
                            isActive: scenarioID == state.profile.activeScenarioID,
                            isExpanded: expandedID == scenarioID,
                            onToggle: {
                                expandedID = expandedID == scenarioID
                                    ? nil
                                    : scenarioID
                            },
                            // 和主 popover 的 Picker、DebugServer 的 select-scenario
                            // 走同一个 intent，门禁与 dirty 置位只有一处实现
                            onActivate: { state.activateScenario(scenarioID) },
                            onDelete: {
                                if expandedID == scenarioID {
                                    expandedID = nil
                                }
                                state.deleteScenario(id: scenarioID)
                            }
                        )
                        .draggable(SettingsReorderItem(kind: "scenario", id: scenarioID))
                        .dropDestination(for: SettingsReorderItem.self) { items, _ in
                            moveScenario(items.first, to: scenarioID)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
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
                &state.profile.scenarios,
                draggedID: item.id,
                targetID: targetID,
                id: { $0.id }
              ) else { return false }
        state.save()
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

    private var bindingSummary: String {
        let n = scenario.bindings.count
        return n == 0 ? state.tr("无规则", "No rules") : "\(n) \(state.tr("条规则", "rules"))"
    }

    var body: some View {
        CollapsibleCard(
            isExpanded: isExpanded,
            onToggle: onToggle,
            onDelete: onDelete,
            accentBar: isActive,
            header: {
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(XDialPalette.selection)
                } else {
                    Image(systemName: "circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .onTapGesture { onActivate() }
                }
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
                            .onChange(of: scenario.name) { _, _ in state.save() }
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
                        Text(state.tr("规则", "Rule")).font(.caption).foregroundStyle(.secondary)
                            .frame(width: 200, alignment: .leading)
                        Text(state.tr("线路", "Line")).font(.caption).foregroundStyle(.secondary)
                    }

                    ForEach(scenario.bindings) { binding in
                        bindingRow(binding)
                    }

                    Divider()

                    HStack {
                        Text(state.tr("其他流量", "Other"))
                            .font(.caption)
                            .frame(width: 200, alignment: .leading)
                        exitPicker(selectedID: SwiftUI.Binding(
                            get: { scenario.defaultTargetID },
                            set: { scenario.defaultTargetID = $0; state.save() }
                        ))
                    }

                    // 添加规则
                    HStack {
                        Spacer()
                        Menu {
                            let usedIDs = Set(scenario.bindings.map { $0.ruleSetID })
                            let available = state.profile.ruleSets.filter { !usedIDs.contains($0.id) }
                            if available.isEmpty {
                                Button(state.tr("（无可用规则）", "(No rule available)")) {}.disabled(true)
                            } else {
                                ForEach(available) { rule in
                                    Button(rule.name) {
                                        let firstExit = state.profile.lines.first?.id ?? ""
                                        scenario.bindings.append(RuleBinding(ruleSetID: rule.id, lineID: firstExit))
                                        state.save()
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

    @ViewBuilder
    private func bindingRow(_ binding: RuleBinding) -> some View {
        if let idx = scenario.bindings.firstIndex(where: { $0.ruleSetID == binding.ruleSetID }) {
            let isEmpty = binding.lineID.isEmpty && binding.subscriptionID.isEmpty
            HStack {
                HStack(spacing: 4) {
                    if isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2).foregroundStyle(XDialPalette.warning)
                    }
                    Text(state.profile.ruleSets.first(where: { $0.id == binding.ruleSetID })?.name ?? "（已删除）")
                }
                .frame(width: 200, alignment: .leading)
                exitPicker(selectedID: $scenario.bindings[idx].targetID)
                Button {
                    scenario.bindings.removeAll { $0.ruleSetID == binding.ruleSetID }
                    state.save()
                } label: {
                    Image(systemName: "minus.circle").foregroundStyle(XDialPalette.danger)
                }
                .buttonStyle(.plain)
            }
            .draggable(SettingsReorderItem(
                kind: "scenario-binding:\(scenario.id)",
                id: binding.ruleSetID
            ))
            .dropDestination(for: SettingsReorderItem.self) { items, _ in
                guard let item = items.first,
                      item.kind == "scenario-binding:\(scenario.id)",
                      reorder(
                        &scenario.bindings,
                        draggedID: item.id,
                        targetID: binding.ruleSetID,
                        id: { $0.ruleSetID }
                      ) else { return false }
                state.save()
                return true
            }
        }
    }

    private func exitPicker(selectedID: SwiftUI.Binding<String>) -> some View {
        Picker("", selection: selectedID) {
            ForEach(state.profile.lines.filter { $0.enabled }) { e in
                Text(e.name).tag("port:\(e.id)")
            }
            if !state.profile.subscriptions.filter({ $0.enabled }).isEmpty {
                Divider()
                ForEach(state.profile.subscriptions.filter { $0.enabled }) { sub in
                    Label("\(sub.name) (\(sub.lines.count))", systemImage: "antenna.radiowaves.left.and.right")
                        .tag("sub:\(sub.id)")
                }
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .onChange(of: selectedID.wrappedValue) { _, _ in state.save() }
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
        state.save()
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

// MARK: - 订阅行

struct SubscriptionRow: View {
    @SwiftUI.Binding var sub: Subscription
    var onDelete: () -> Void
    @State private var expanded = false
    @State private var refreshing = false
    @EnvironmentObject var state: AppState

    private var groupCount: Int { sub.proxyGroups.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 折叠头
            HStack {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .foregroundStyle(.secondary)
                    .frame(width: 12)

                RuntimeResourceBadge(
                    kind: "subscription",
                    resourceID: sub.id,
                    enabled: sub.enabled
                )

                Text(sub.name)
                    .font(.system(size: 13, weight: .medium))

                if groupCount > 0 {
                    Text("\(groupCount)\(state.tr("组", "g"))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("\(sub.lines.count)\(state.tr("节点", "n"))")
                    .font(.caption).foregroundStyle(.secondary)

                if sub.updatedAt > 0 {
                    Text(formatDate(sub.updatedAt))
                        .font(.caption2).foregroundStyle(.tertiary)
                }

                Spacer()

                if refreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button { refreshSub() } label: {
                        Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(state.tr("刷新", "Refresh"))
                }

                Toggle("", isOn: $sub.enabled)
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .onChange(of: sub.enabled) { _, _ in state.save() }

                Button(action: onDelete) {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }

            // 展开内容
            if expanded {
                LazyVStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(state.tr("名称", "Name")).font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                        TextField("", text: $sub.name)
                            .textFieldStyle(.roundedBorder).font(.caption)
                            .onChange(of: sub.name) { _, _ in state.save() }
                    }
                    HStack {
                        Text("URL").font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                        TextField("", text: $sub.url)
                            .textFieldStyle(.roundedBorder).font(.caption)
                            .onChange(of: sub.url) { _, _ in state.save() }
                    }

                    // === 策略组 ===
                    if !sub.proxyGroups.isEmpty {
                        Divider()
                        Text(state.tr("策略组", "Groups"))
                            .font(.caption2).foregroundStyle(.tertiary).textCase(.uppercase)
                        // id 用 offset 而不是 name，订阅原始 YAML 里允许重名策略组，
                        // 用 name 当 id 会导致 SwiftUI ForEach 重复 key 渲染错乱
                        ForEach(Array(sub.proxyGroups.enumerated()), id: \.offset) { _, group in
                            groupRow(group: group)
                        }
                    }

                }
                .padding(.leading, 18)
            }
        }
        .padding(8)
        .background(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.06))
                HStack(spacing: 0) {
                    XDialPalette.divider.opacity(0.72)
                        .frame(width: 3)
                        .clipShape(RoundedRectangle(cornerRadius: 1.5))
                    Spacer()
                }
                .padding(.vertical, 2)
            }
        )
    }

    @ViewBuilder
    private func groupRow(group: SubProxyGroup) -> some View {
        HStack {
            Text(group.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text(groupTypeLabel(group.type))
                    .font(.caption)
                Text("\(group.proxies.count)\(state.tr("节点", " nodes"))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 180, alignment: .trailing)
        }
    }

    private func groupTypeLabel(_ type: String) -> String {
        switch type {
        case "select", "selector": return "select"
        case "url-test", "urltest": return "auto"
        case "fallback": return "fallback"
        case "load-balance": return "balance"
        default: return type
        }
    }

    private func refreshSub() {
        refreshing = true
        state.engine.parseSubscription(url: sub.url, format: sub.format) { result in
            refreshing = false
            switch result {
            case .success(let r):
                state.updateSubscription(sub.id, with: r)
            case .failure(let err):
                state.engine.lastError = err.localizedDescription
            }
        }
    }

    private func formatDate(_ ts: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: date, relativeTo: Date())
    }
}

struct AddSubscriptionSheet: View {
    @SwiftUI.Binding var isPresented: Bool
    @EnvironmentObject var state: AppState
    @State private var name = ""
    @State private var url = ""
    @State private var fileContent = ""
    @State private var format = "auto"
    @State private var strategy = "urltest"
    @State private var parsing = false
    @State private var parsedResult: GoEngine.ParseResult?
    @State private var parseError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(state.tr("添加订阅", "Add Subscription")).font(.headline)
                Spacer()
                Button(state.tr("取消", "Cancel")) { isPresented = false }
            }

            TextField(state.tr("名称", "Name"), text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                TextField(state.tr("订阅 URL 或本地文件", "URL or local file"), text: $url)
                    .textFieldStyle(.roundedBorder)
                Button(state.tr("选择文件", "File")) {
                    pickFile()
                }
                .controlSize(.small)
            }

            HStack {
                Text(state.tr("格式", "Format")).font(.caption)
                Picker("", selection: $format) {
                    Text(state.tr("自动", "Auto")).tag("auto")
                    Text("Clash").tag("clash")
                    Text("Surge").tag("surge")
                    Text("Base64").tag("base64")
                }
                .pickerStyle(.menu)
                .labelsHidden()

                Text(state.tr("策略", "Strategy")).font(.caption)
                Picker("", selection: $strategy) {
                    Text(state.tr("自动选优", "Auto Best")).tag("urltest")
                    Text(state.tr("手动选择", "Manual")).tag("selector")
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            if parsing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(state.tr("正在解析…", "Parsing…")).font(.caption)
                }
            }

            if let error = parseError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(XDialPalette.danger)
            }

            if let r = parsedResult {
                let summary = state.tr(
                    "解析到 \(r.lines.count) 个节点、\(r.proxyGroups?.count ?? 0) 个策略组、\(r.rules?.count ?? 0) 条规则",
                    "Found \(r.lines.count) nodes, \(r.proxyGroups?.count ?? 0) groups, \(r.rules?.count ?? 0) rules"
                )
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(XDialPalette.success)

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(r.lines) { line in
                            HStack {
                                Text(line.name).font(.caption)
                                Spacer()
                                Text(line.type).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 150)

                Button(state.tr("确认添加", "Add")) {
                    let n = name.isEmpty ? (URL(string: url)?.host ?? "Subscription") : name
                    state.addSubscription(name: n, url: url, format: format, strategy: strategy,
                                          lines: r.lines, proxyGroups: r.proxyGroups ?? [], rules: r.rules ?? [])
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(state.tr("解析", "Parse")) {
                    doParse()
                }
                .disabled((url.isEmpty && fileContent.isEmpty) || parsing)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .yaml, .data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let fileURL = panel.url {
            if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                fileContent = content
                url = fileURL.lastPathComponent
            }
        }
    }

    private func doParse() {
        parsing = true
        parseError = nil
        parsedResult = nil

        state.engine.parseSubscription(url: url, content: fileContent, format: format) { result in
            parsing = false
            switch result {
            case .success(let r):
                parsedResult = r
            case .failure(let err):
                parseError = err.localizedDescription
            }
        }
    }
}
