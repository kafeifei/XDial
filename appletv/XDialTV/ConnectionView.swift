import SwiftUI

/// 主视图：连接状态 + 当前模式 + 连接/断开按钮 + 进入模式选择/凭据/设置的导航入口。
///
/// 完全数据驱动：只读 AppState 暴露的派生属性（statusText / isConnected / isBusy /
/// canConnect / activeMode），不硬编码任何具体连接结果。引擎层未接入时，
/// NoopTunnelEngine 让状态停在 "disconnected"，视图照常渲染。
struct ConnectionView: View {
    @EnvironmentObject private var app: AppState

    /// 焦点锚点：进入主视图时把焦点落在主操作按钮上，符合 tvOS「一眼可操作」预期。
    private enum Field: Hashable {
        case primaryAction
    }
    @FocusState private var focus: Field?

    var body: some View {
        VStack(spacing: 48) {
            statusHero

            primaryButton

            navRow
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("XDial")
        .onAppear { focus = .primaryAction }
    }

    // MARK: - 状态展示

    private var statusHero: some View {
        VStack(spacing: 20) {
            Image(systemName: statusIcon)
                .font(.system(size: 96, weight: .medium))
                .foregroundStyle(statusColor)
                .symbolEffect(.pulse, isActive: app.isBusy)

            Text(app.statusText)
                .font(.title)
                .foregroundStyle(.primary)

            Text(modeSubtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var statusIcon: String {
        if app.isConnected { return "checkmark.shield.fill" }
        if app.isBusy { return "arrow.triangle.2.circlepath" }
        return "shield.slash"
    }

    private var statusColor: Color {
        if app.isConnected { return .green }
        if app.isBusy { return .yellow }
        return .secondary
    }

    private var modeSubtitle: String {
        if let c = app.activeMode {
            return app.tr("当前模式：", "Mode: ") + c.name
        }
        return app.tr("未选择模式", "No mode selected")
    }

    // MARK: - 主操作按钮（连接 / 断开）

    private var primaryButton: some View {
        Button(action: primaryAction) {
            HStack(spacing: 16) {
                Image(systemName: app.isConnected ? "stop.fill" : "play.fill")
                Text(primaryLabel)
                    .fontWeight(.semibold)
            }
            .frame(minWidth: 360)
            .padding(.vertical, 8)
        }
        .focused($focus, equals: .primaryAction)
        .disabled(primaryDisabled)
    }

    private var primaryLabel: String {
        if app.isConnected { return app.tr("断开", "Disconnect") }
        if app.isBusy { return app.tr("请稍候…", "Please wait…") }
        return app.tr("连接", "Connect")
    }

    private var primaryDisabled: Bool {
        if app.isBusy { return true }
        // 已连接时始终允许断开；未连接时按 canConnect 判定
        return app.isConnected ? false : !app.canConnect
    }

    private func primaryAction() {
        if app.isConnected {
            app.disconnect()
        } else {
            app.connect()
        }
    }

    // MARK: - 导航入口

    private var navRow: some View {
        HStack(spacing: 32) {
            NavigationLink(value: Route.modes) {
                navTile(icon: "shuffle", title: app.tr("选择模式", "Modes"))
            }
            NavigationLink(value: Route.credentials) {
                navTile(icon: "key.fill", title: app.tr("凭据", "Credentials"))
            }
            NavigationLink(value: Route.settings) {
                navTile(icon: "gearshape.fill", title: app.tr("设置", "Settings"))
            }
        }
    }

    private func navTile(icon: String, title: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
            Text(title)
                .font(.headline)
        }
        .frame(width: 220, height: 140)
    }
}
