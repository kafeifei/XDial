import SwiftUI

struct MainPopover: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

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
            actionRow
        }
        .padding(12)
        .frame(width: 300)
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

    @ObservedObject private var net = NetworkInfo.shared

    private var subscriptionSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(state.activeSubscriptions) { sub in
                HStack(spacing: 6) {
                    Text("📡").font(.caption2)
                    Text(sub.name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    if let info = net.perLine[sub.id] {
                        if !info.ip.isEmpty {
                            Text(info.summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else if !info.error.isEmpty {
                            Text(info.error)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .lineLimit(1)
                        }
                    }
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
            if !state.helperInstalled {
                if state.helperNeedsApproval {
                    Button(state.tr("去系统设置批准", "Approve in System Settings")) {
                        state.setupHelper(thenConnect: true)
                    }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
                } else {
                    Button(state.tr("一键配置", "Set Up")) {
                        state.setupHelper(thenConnect: true)
                    }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
                }
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
                if state.helperInstalled {
                    Button(state.tr("卸载后台服务", "Remove Background Service")) {
                        state.uninstall(deleteData: false) { _, error in
                            if let error {
                                state.engine.lastError = error
                            }
                        }
                    }
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

    private func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
