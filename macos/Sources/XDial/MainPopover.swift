import SwiftUI

struct MainPopover: View {
    @EnvironmentObject var state: AppState
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            credentials
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
            Picker("", selection: $state.activePreset) {
                Text("国外").tag("overseas")
                Text("国内").tag("domestic")
                Text("国内+机场").tag("domestic_airport")
            }
            .pickerStyle(.menu)
            .frame(width: 100)
            .disabled(state.isConnected || state.isBusy)
        }
    }

    private var credentials: some View {
        VStack(spacing: 6) {
            TextField("VPN 服务器", text: $state.server)
                .textFieldStyle(.roundedBorder)
                .disabled(state.isConnected || state.isBusy)
            TextField("用户名", text: $state.username)
                .textFieldStyle(.roundedBorder)
                .disabled(state.isConnected || state.isBusy)
            SecureField("密码", text: $state.password)
                .textFieldStyle(.roundedBorder)
                .disabled(state.isConnected || state.isBusy)
            HStack {
                Toggle("记住密码", isOn: $state.rememberPassword)
                    .font(.caption)
                    .disabled(state.isConnected || state.isBusy)
                Spacer()
            }
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
                showSettings.toggle()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .popover(isPresented: $showSettings, arrowEdge: .leading) {
                SettingsView()
                    .environmentObject(state)
                    .disabled(state.isConnected || state.isBusy)
            }

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
