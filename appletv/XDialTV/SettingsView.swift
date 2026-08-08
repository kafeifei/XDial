import SwiftUI

/// 设置：语言切换 + 配置状态信息 + 不引人注目的 debug 手测入口。
///
/// debug 入口：一行普通的「版本」文字，**长按**（遥控器中键按住）才触发
/// DebugSmokeTest.run()，普通点击无反应。只在 DEBUG 构建里挂长按手势，
/// release 构建下就是一行纯展示文字，不暴露手测能力。
struct SettingsView: View {
    @EnvironmentObject private var app: AppState

    /// 语言选择的本地镜像：Picker 需要一个可写绑定；tvOS 上把 .system 展开成
    /// 具体 zh/en 供选择。切换后写回 app.language（其 didSet 会持久化）。
    @State private var langSelection: Lang = .en

    /// 最近一次手测结果，长按触发后回填展示。
    @State private var smokeResult: String = ""

    var body: some View {
        Form {
            languageSection
            statusSection
            debugSection
        }
        .navigationTitle(app.tr("设置", "Settings"))
        .onAppear {
            langSelection = (app.language == .zh) ? .zh : .en
        }
    }

    // MARK: - 语言

    private var languageSection: some View {
        Section {
            Picker(app.tr("语言", "Language"), selection: $langSelection) {
                Text("简体中文").tag(Lang.zh)
                Text("English").tag(Lang.en)
            }
            .onChange(of: langSelection) { _, newValue in
                app.language = newValue
            }
        } header: {
            Text(app.tr("外观", "Appearance"))
        }
    }

    // MARK: - 状态信息（纯数据派生）

    private var statusSection: some View {
        Section {
            infoRow(
                label: app.tr("连接描述文件", "Connection profile"),
                value: app.helperInstalled
                    ? app.tr("已安装", "Installed")
                    : app.tr("未安装", "Not installed")
            )
            infoRow(
                label: app.tr("场景数量", "Scenarios"),
                value: "\(app.profile.scenarios.count)"
            )
            infoRow(
                label: app.tr("线路数量", "Lines"),
                value: "\(app.profile.lines.count)"
            )
            infoRow(
                label: app.tr("连接状态", "Connection"),
                value: app.statusText
            )
        } header: {
            Text(app.tr("状态", "Status"))
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 隐藏 debug 入口

    @ViewBuilder
    private var debugSection: some View {
        Section {
            let versionRow = HStack {
                Text(app.tr("版本", "Version"))
                Spacer()
                Text("0.4.1 (tvOS)")
                    .foregroundStyle(.secondary)
            }

            #if DEBUG
            versionRow
                .onLongPressGesture(minimumDuration: 1.0) {
                    smokeResult = app.tr("正在运行手测…", "Running smoke test…")
                    DebugSmokeTest.run { line in
                        smokeResult = line
                    }
                }
            if !smokeResult.isEmpty {
                HStack {
                    Text(app.tr("手测", "Smoke test"))
                    Spacer()
                    Text(smokeResult)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            #else
            versionRow
            #endif
        } header: {
            Text(app.tr("关于", "About"))
        }
    }
}
