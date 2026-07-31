import SwiftUI

struct MainPopover: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var showTransaction = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            modeRow
            if !state.activeSubscriptions.isEmpty && state.isConnected {
                subscriptionSummary
            }
            if state.configDirty {
                dirtyBanner
            }
            Divider()
            statusRow
            if let report = state.presentedConnectionReport {
                transactionSummary(report)
            }
            actionRow
        }
        .padding(12)
        .frame(width: 300)
    }

    private func transactionSummary(
        _ report: ConnectionReport
    ) -> some View {
        DisclosureGroup(isExpanded: $showTransaction) {
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(report.tasks) { task in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: taskIcon(task.state))
                                .foregroundStyle(taskColor(task.state))
                                .frame(width: 12)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(task.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                if task.state == .failed,
                                   let error = task.error {
                                    Text(error.message)
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                        .fixedSize(
                                            horizontal: false,
                                            vertical: true
                                        )
                                }
                            }
                            Spacer()
                            Text(taskStateText(task.state))
                                .font(.caption2)
                                .foregroundStyle(taskColor(task.state))
                        }
                    }
                    if report.rollbackComplete {
                        Divider()
                        Label(
                            report.systemTakeoverRemoved
                                ? state.tr(
                                    "已回滚，系统网络接管已移除",
                                    "Rolled back; system takeover removed"
                                )
                                : state.tr(
                                    "回滚未能证明系统网络已恢复",
                                    "Rollback could not prove network recovery"
                                ),
                            systemImage: report.systemTakeoverRemoved
                                ? "arrow.uturn.backward.circle.fill"
                                : "exclamationmark.triangle.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(
                            report.systemTakeoverRemoved
                                ? Color.secondary
                                : Color.red
                        )
                    } else if let rollbackError = report.rollbackError {
                        Divider()
                        Label(
                            rollbackError.message,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxHeight: 180)
            .padding(.top, 5)
        } label: {
            HStack {
                Text(state.tr("连接检查", "Connection checklist"))
                    .font(.caption)
                Spacer()
                Text(transactionStateText(report.state))
                    .font(.caption2)
                    .foregroundStyle(
                        report.state == .failed ? .red : .secondary
                    )
            }
        }
        .onChange(of: report.transactionID) {
            showTransaction = true
        }
        .onChange(of: report.state) {
            if report.state == .failed ||
                report.state == .rollingBack ||
                report.state == .preparing ||
                report.state == .committing {
                showTransaction = true
            }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "shield.checkered")
                .font(.system(size: 16))
                .foregroundStyle(state.isConnected ? .green : .secondary)
            Text("XDial")
                .font(.headline)
            Spacer()
        }
    }

    private var modeRow: some View {
        HStack(spacing: 6) {
            Text("🔀")
                .font(.caption)

            if state.profile.modes.isEmpty {
                Text("（请先在设置中创建）")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                // 已连接时不再禁用：切模式是允许的，只是不会立刻生效 ——
                // 由下面的 dirtyBanner 明说"重连后生效"，而不是把入口锁死。
                Picker("", selection: SwiftUI.Binding(
                    get: { state.profile.activeModeID },
                    set: { state.activateMode($0) }
                )) {
                    ForEach(state.profile.modes) { s in
                        Text(s.name).tag(s.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(state.isBusy)
            }
            Spacer()
        }
    }

    /// 配置改了但引擎还攥着旧快照 —— 必须让用户看见，并给出一步到位的出路。
    private var dirtyBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            Text(state.tr("配置已修改，重连后生效", "Config changed — reconnect to apply"))
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(state.tr("重连", "Reconnect")) { state.reconnect() }
                .controlSize(.small)
                .disabled(state.isBusy || !state.canConnect)
        }
        .padding(6)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var subscriptionSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(state.activeSubscriptions) { sub in
                HStack(spacing: 6) {
                    Text("📡").font(.caption2)
                    Text(sub.name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                }
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .animation(.easeInOut(duration: 0.3), value: state.engine.status)
            Text(state.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if state.isConnected, let t = state.engine.connectedAt {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(formatDuration(Int(Date().timeIntervalSince(t))))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            if state.wakeReconnectPhase != nil {
                Button(state.tr("恢复中…", "Recovering…")) {}
                    .controlSize(.small)
                    .disabled(true)
            } else {
                switch state.engine.status {
                case "connecting":
                    Button("连接中…") {}
                        .controlSize(.small)
                        .disabled(true)
                case "connected":
                    Button("断开") { state.disconnect() }
                        .tint(.red)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                case "reconnecting":
                    Button("重连中…") { state.disconnect() }
                        .tint(.orange)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                case "disconnecting":
                    Button("断开中…") {}
                        .controlSize(.small)
                        .disabled(true)
                default:
                    Button("连接") { state.connect() }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.small)
                        .disabled(!state.canConnect)
                }
            }

            Spacer()

            Button {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Menu {
                Button(
                    state.tr("安装状态…", "Installation Status…")
                ) {
                    state.installation.present()
                }
                Divider()
                Button("退出 XDial") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30)
        }
    }

    private var dotColor: Color {
        if state.isConnected { return .green }
        if state.isBusy { return .orange }
        return .secondary
    }

    private func taskIcon(_ taskState: ConnectionTaskState) -> String {
        switch taskState {
        case .pending:
            "circle"
        case .running, .committing, .rollingBack:
            "clock.fill"
        case .ready, .committed:
            "checkmark.circle.fill"
        case .rolledBack:
            "arrow.uturn.backward.circle.fill"
        case .failed:
            "xmark.octagon.fill"
        case .skipped:
            "minus.circle"
        }
    }

    private func taskColor(_ taskState: ConnectionTaskState) -> Color {
        switch taskState {
        case .ready, .committed:
            .green
        case .running, .committing, .rollingBack:
            .orange
        case .failed:
            .red
        default:
            .secondary
        }
    }

    private func taskStateText(_ taskState: ConnectionTaskState) -> String {
        switch taskState {
        case .pending: state.tr("等待", "Pending")
        case .running: state.tr("准备中", "Preparing")
        case .ready: state.tr("就绪", "Ready")
        case .committing: state.tr("提交中", "Committing")
        case .committed: state.tr("已提交", "Committed")
        case .rollingBack: state.tr("回滚中", "Rolling back")
        case .rolledBack: state.tr("已回滚", "Rolled back")
        case .failed: state.tr("失败", "Failed")
        case .skipped: state.tr("跳过", "Skipped")
        }
    }

    private func transactionStateText(
        _ transactionState: ConnectionTransactionState
    ) -> String {
        switch transactionState {
        case .planning: state.tr("生成计划", "Planning")
        case .preparing: state.tr("准备依赖", "Preparing")
        case .readyToCommit: state.tr("等待提交", "Ready")
        case .committing: state.tr("接管网络", "Committing")
        case .committed: state.tr("完成", "Committed")
        case .rollingBack: state.tr("正在回滚", "Rolling back")
        case .rolledBack: state.tr("已回滚", "Rolled back")
        case .failed: state.tr("失败", "Failed")
        case .cancelled: state.tr("已取消", "Cancelled")
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
