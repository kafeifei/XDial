import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var app: AppState
    @State private var showingModes = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    statusHero
                    powerButton
                    modeCard

                    if !app.unsupportedActiveLineNames.isEmpty {
                        warningCard(
                            title: app.tr("移动端暂不支持 Tailscale", "Tailscale is not available on mobile yet"),
                            detail: app.unsupportedActiveLineNames.joined(separator: "、")
                        )
                    } else if !app.isConnectionConfigured && !app.isConnected {
                        warningCard(
                            title: app.tr("连接配置尚未完成", "Connection setup is incomplete"),
                            detail: app.tr("请在配置中补全当前模式使用的 AnyConnect 凭据。",
                                           "Complete the AnyConnect credentials used by this mode.")
                        )
                    }

                    activeLinesCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("XDial")
            .sheet(isPresented: $showingModes) {
                QuickModePicker()
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private var statusHero: some View {
        VStack(spacing: 10) {
            Image(systemName: statusIcon)
                .font(.system(size: 66, weight: .medium))
                .foregroundStyle(statusColor)
                .symbolEffect(.pulse, isActive: app.isBusy)
                .accessibilityHidden(true)

            Text(app.statusText)
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text(app.activeMode?.name ?? app.tr("未选择模式", "No mode selected"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    private var powerButton: some View {
        Button {
            app.isConnected ? app.disconnect() : app.connect()
        } label: {
            Image(systemName: app.isConnected ? "stop.fill" : "power")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 112, height: 112)
                .background(app.isConnected ? Color.red : Color.accentColor)
                .clipShape(Circle())
                .shadow(color: (app.isConnected ? Color.red : Color.accentColor).opacity(0.28), radius: 16, y: 8)
        }
        .disabled(app.isBusy || (!app.isConnected && !app.canConnect))
        .opacity(app.isBusy || (!app.isConnected && !app.canConnect) ? 0.45 : 1)
        .accessibilityLabel(app.isConnected ? app.tr("断开", "Disconnect") : app.tr("连接", "Connect"))
    }

    private var modeCard: some View {
        Button { showingModes = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "shuffle")
                    .font(.title3)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.tr("当前模式", "Current mode"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(app.activeMode?.name ?? app.tr("请选择", "Select"))
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private var activeLinesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(app.tr("本模式线路", "Lines in this mode"))
                .font(.headline)

            if activeLines.isEmpty {
                Text(app.tr("没有线路", "No lines"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(activeLines) { line in
                    HStack {
                        Image(systemName: lineSymbol(line.type))
                            .foregroundStyle(line.type == "tailscale" ? Color.orange : Color.accentColor)
                            .frame(width: 24)
                        VStack(alignment: .leading) {
                            Text(line.name)
                            Text(mobileLineTypeLabel(line.type))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if line.enabled {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func warningCard(title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.bold())
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var activeLines: [Line] {
        guard let mode = app.activeMode else { return [] }
        var ids = Set(mode.bindings.map(\.lineID))
        if !mode.defaultLineID.isEmpty { ids.insert(mode.defaultLineID) }
        return app.profile.lines.filter { ids.contains($0.id) }
    }

    private var statusIcon: String {
        if app.isConnected { return "checkmark.shield.fill" }
        if app.isBusy { return "arrow.triangle.2.circlepath" }
        return "shield.slash"
    }

    private var statusColor: Color {
        if app.isConnected { return .green }
        if app.isBusy { return .orange }
        return .secondary
    }
}

private struct QuickModePicker: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(app.profile.modes) { mode in
                Button {
                    app.profile.activeModeID = mode.id
                    app.save()
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mode.name)
                                .foregroundStyle(.primary)
                            Text(app.tr("\(mode.bindings.count) 条分流绑定", "\(mode.bindings.count) bindings"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if mode.id == app.profile.activeModeID {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
            .navigationTitle(app.tr("选择模式", "Select mode"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(app.tr("完成", "Done")) { dismiss() }
                }
            }
        }
    }
}

func lineSymbol(_ type: String) -> String {
    switch type {
    case "direct": return "arrow.right"
    case "vpn": return "building.2"
    case "tailscale": return "point.3.connected.trianglepath.dotted"
    default: return "network"
    }
}
