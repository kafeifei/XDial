import SwiftUI

struct MainPopover: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            strategyRow
            Divider()
            statusRow
            actionRow
        }
        .padding(12)
        .frame(width: 260)
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

    private var strategyRow: some View {
        HStack(spacing: 6) {
            Text("🚢")
                .font(.caption)

            if state.profile.cruises.isEmpty {
                Text("（请先在设置中创建）")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Picker("", selection: SwiftUI.Binding(
                    get: { state.profile.activeCruiseID },
                    set: { state.profile.activeCruiseID = $0; state.save() }
                )) {
                    ForEach(state.profile.cruises) { s in
                        Text(s.name).tag(s.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(state.isConnected || state.isBusy)
            }
            Spacer()
        }
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
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
                Button("一键配置") { state.installHelper(thenConnect: true) }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
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
                    Button("卸载 helper 配置") {
                        try? PrivilegeManager.uninstall()
                        state.helperInstalled = false
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
