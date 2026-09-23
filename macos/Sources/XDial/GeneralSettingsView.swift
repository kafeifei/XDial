import AppKit
import SwiftUI

private enum GeneralSettingsSection: CaseIterable, Hashable {
    case startup, appearance, system, about

    @MainActor func title(_ state: AppState) -> String {
        switch self {
        case .startup: return state.tr("启动与连接", "Startup & Connection")
        case .appearance: return state.tr("外观与语言", "Appearance & Language")
        case .system: return state.tr("系统与权限", "System & Permissions")
        case .about: return state.tr("关于与更新", "About & Updates")
        }
    }

    var symbol: String {
        switch self {
        case .startup: return "power"
        case .appearance: return "circle.lefthalf.filled"
        case .system: return "checkmark.shield"
        case .about: return "info.circle"
        }
    }
}

/// Application preferences share the configuration window and do not change the selected source.
struct GeneralSettingsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var section: GeneralSettingsSection = .startup

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(state.tr("通用", "General"))
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                ForEach(GeneralSettingsSection.allCases, id: \.self) { item in
                    Button { section = item } label: {
                        Label(item.title(state), systemImage: item.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .background(
                                section == item ? XDialPalette.selection.opacity(0.14) : .clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(section == item ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(width: state.language == .en ? 202 : 154)
            .background(XDialPalette.surface)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(section.title(state))
                        .font(.system(size: 15, weight: .semibold))
                    switch section {
                    case .startup: startup
                    case .appearance: appearance
                    case .system: system
                    case .about: about
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(XDialPalette.canvas)
    }

    private var startup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(state.tr("登录时启动", "Launch at login"), isOn: $state.launchAtLogin)
                .toggleStyle(.switch)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Toggle(state.tr("启动时自动连接", "Connect automatically on launch"), isOn: $state.autoConnect)
                    .toggleStyle(.switch)
                note(state.tr(
                    "下次启动时连接上次使用的场景。修改此选项不会立即连接。",
                    "Connect to the last used Scenario on the next launch. Changing this option does not connect now."
                ))
            }
            Divider()
            note(state.tr(
                "意外断线后会尝试恢复连接；手动断开后不会自动恢复。",
                "An unexpected disconnection triggers recovery. Disconnecting manually does not."
            ))
        }
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(state.tr("外观", "Appearance"))
                Spacer()
                Picker(state.tr("外观", "Appearance"), selection: $state.appearance) {
                    Text(state.tr("系统", "System")).tag(AppAppearance.system)
                    Text(state.tr("浅色", "Light")).tag(AppAppearance.light)
                    Text(state.tr("深色", "Dark")).tag(AppAppearance.dark)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 200)
                .accessibilityLabel(state.tr("外观", "Appearance"))
            }
            Divider()
            HStack {
                Text(state.tr("语言", "Language"))
                Spacer()
                Picker(state.tr("语言", "Language"), selection: $state.language) {
                    ForEach(Lang.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 150)
                .accessibilityLabel(state.tr("语言", "Language"))
            }
            note(state.tr(
                "配置名称和个人输入保持原样。",
                "Configuration names and your own text remain unchanged."
            ))
        }
    }

    private var system: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: state.installation.isReady ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                    .foregroundStyle(state.installation.isReady ? XDialPalette.success : XDialPalette.warning)
                VStack(alignment: .leading, spacing: 5) {
                    Text(state.tr("系统组件", "System components"))
                        .fontWeight(.medium)
                    note(installationStatus)
                }
                Spacer(minLength: 0)
            }
            Button(state.tr("安装与维护…", "Install & Maintain…")) {
                state.installation.present(operation: .install)
            }
            Divider()
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(state.tr("Wi-Fi 名称读取", "Wi-Fi name access"))
                        .fontWeight(.medium)
                    note(wifiAccessStatus)
                }
                Spacer(minLength: 0)
                if state.wifiSSIDAccessState != .ready {
                    Button(state.tr("设置…", "Set Up…")) { state.requestSSIDAccess() }
                        .disabled(state.wifiSSIDAccessState == .checking)
                }
            }
            Divider()
            HStack(alignment: .top, spacing: 12) {
                note(state.tr(
                    "配置和凭据加密保存，与其他版本的数据独立。",
                    "Configurations and credentials are encrypted and stored separately from other editions."
                ))
                Spacer(minLength: 0)
                Button(state.tr("卸载…", "Uninstall…"), role: .destructive) {
                    state.installation.present(operation: .uninstall)
                }
            }
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(XDialBuildIdentity.productTitle)
                .font(.system(size: 18, weight: .semibold))
            Text(appVersionText).foregroundStyle(.secondary).textSelection(.enabled)
            Divider()
            if XDialBuildIdentity.allowsAutomaticUpdates {
                Button(state.tr("检查更新…", "Check for Updates…")) {
                    ApplicationWindowLifecycleController.shared.prepareToPresentUpdateWindow()
                    openWindow(id: "update")
                    NSApp.activate(ignoringOtherApps: true)
                }
            } else {
                Text(state.tr("独立开发版 · 手动更新", "Independent build · Manual updates"))
                note(state.tr(
                    "使用同一 Next 通道的安装包升级。",
                    "Upgrade using an installation package from the same Next channel."
                ))
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var installationStatus: String {
        if state.installation.isReady {
            return state.tr("后台服务与网络扩展已就绪", "Background service and network extension are ready")
        }
        return state.installation.report.error?.message
            ?? state.tr("尚未完成安装，可以先编辑配置。", "Installation is incomplete. You can still edit configurations.")
    }

    private var wifiAccessStatus: String {
        switch state.wifiSSIDAccessState {
        case .ready: return state.tr("已允许，可按 Wi-Fi 自动选择场景。", "Allowed. Scenarios can follow the current Wi-Fi.")
        case .checking: return state.tr("正在检查权限", "Checking permission")
        case .permissionRequired: return state.tr("未开启，手动连接仍可用。", "Not enabled. Manual connections remain available.")
        case .denied: return state.tr("请在系统设置中允许位置访问。", "Allow location access in System Settings.")
        case .unavailable: return state.tr("暂时无法读取，手动连接仍可用。", "Currently unavailable. Manual connections remain available.")
        }
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "v\(version) · build \(build)"
    }
}
