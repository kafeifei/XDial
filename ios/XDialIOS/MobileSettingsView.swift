import SwiftUI

struct MobileSettingsView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        NavigationStack {
            Form {
                Section(app.tr("外观", "Appearance")) {
                    Picker(app.tr("语言", "Language"), selection: $app.language) {
                        Text("简体中文").tag(Lang.zh)
                        Text("English").tag(Lang.en)
                    }
                }

                Section(app.tr("连接服务", "Connection service")) {
                    LabeledContent(
                        app.tr("系统描述文件", "System profile"),
                        value: app.helperInstalled ? app.tr("已安装", "Installed") : app.tr("首次连接时安装", "Installed on first connect")
                    )
                    LabeledContent(app.tr("连接状态", "Connection"), value: app.statusText)
                    Button(app.tr("刷新系统状态", "Refresh system status")) {
                        app.refreshTunnelProfileStatus()
                        app.engine.syncStatus()
                    }
                }

                Section(app.tr("配置摘要", "Configuration")) {
                    LabeledContent(app.tr("线路", "Lines"), value: "\(app.profile.lines.count)")
                    LabeledContent(app.tr("规则", "Rules"), value: "\(app.profile.ruleSets.count)")
                    LabeledContent(app.tr("模式", "Modes"), value: "\(app.profile.modes.count)")
                }

                Section(app.tr("能力", "Capabilities")) {
                    Label(app.tr("AnyConnect 与规则分流：已接线，等待真机验证",
                                 "AnyConnect and rule routing: wired, device validation pending"),
                          systemImage: "checkmark.shield")
                    Label(app.tr("Tailscale：移动数据面尚未接入",
                                 "Tailscale: mobile data plane not connected"),
                          systemImage: "clock")
                        .foregroundStyle(.secondary)
                }

                Section(app.tr("关于", "About")) {
                    LabeledContent(app.tr("版本", "Version"), value: version)
                    Text(app.tr("连接凭据和完整配置通过一次性启动参数交给扩展，不写入 App Group。",
                                "Credentials and the full configuration are delivered through one-time start options and are not stored in the App Group."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(app.tr("设置", "Settings"))
        }
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }
}
