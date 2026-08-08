import SwiftUI
import UniformTypeIdentifiers

struct MobileSettingsView: View {
    @EnvironmentObject private var app: AppState

    @State private var exportDocument: MobileJSONDocument?
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var isConfirmingReset = false
    @State private var isConfirmingProfileRemoval = false
    @State private var notice: SettingsNotice?

    var body: some View {
        NavigationStack {
            Form {
                Section(app.tr("外观", "Appearance")) {
                    Picker(app.tr("语言", "Language"), selection: $app.language) {
                        Text("简体中文").tag(Lang.zh)
                        Text("English").tag(Lang.en)
                    }
                }

                Section {
                    LabeledContent(
                        app.tr("系统描述文件", "System profile"),
                        value: app.helperInstalled
                            ? app.tr("已安装", "Installed")
                            : app.tr("首次连接时安装", "Installed on first connect")
                    )
                    LabeledContent(app.tr("连接状态", "Connection"), value: app.statusText)
                    Button(app.tr("刷新系统状态", "Refresh system status")) {
                        app.refreshTunnelProfileStatus()
                        app.engine.syncStatus()
                    }

                    Toggle(
                        app.tr("意外断线自动重试", "Retry unexpected disconnects"),
                        isOn: $app.autoReconnectEnabled
                    )

                    Toggle(
                        app.tr("系统级按需重连", "System on-demand reconnect"),
                        isOn: $app.systemOnDemandEnabled
                    )
                    .accessibilityIdentifier("system-on-demand-reconnect")
                    LabeledContent(app.tr("按需重连状态", "On-demand status")) {
                        Text(systemOnDemandStatusText)
                            .accessibilityIdentifier("system-on-demand-status")
                    }

                    if app.helperInstalled {
                        Button(role: .destructive) {
                            isConfirmingProfileRemoval = true
                        } label: {
                            Label(app.tr("移除系统描述文件", "Remove System Profile"), systemImage: "trash")
                        }
                        .disabled(app.hasActiveTunnel || app.isBusy)
                    }
                } header: {
                    Text(app.tr("连接服务", "Connection service"))
                } footer: {
                    Text(app.tr(
                        "App 内重试最多 3 次。系统级按需重连仅在一次完整连接验收通过后启用；手动断开或验收失败会立即停用，下一次手动连接成功后再恢复。移除描述文件不会删除 XDial 内的线路、规则或账号。",
                        "In-app retry runs up to 3 times. System on-demand reconnect is armed only after a full connection check succeeds; a manual disconnect or failed check suspends it until the next successful manual connection. Removing the profile does not delete XDial lines, rules, or accounts."
                    ))
                }

                Section(app.tr("配置摘要", "Configuration")) {
                    LabeledContent(app.tr("线路", "Lines"), value: "\(app.profile.lines.count)")
                    LabeledContent(app.tr("规则", "Rules"), value: "\(app.profile.ruleSets.count)")
                    LabeledContent(app.tr("场景", "Scenarios"), value: "\(app.profile.scenarios.count)")
                    LabeledContent(app.tr("订阅", "Subscriptions"), value: "\(app.profile.subscriptions.count)")
                }

                Section {
                    Button {
                        prepareExport()
                    } label: {
                        Label(app.tr("导出配置", "Export configuration"), systemImage: "square.and.arrow.up")
                    }

                    Button {
                        isImporting = true
                    } label: {
                        Label(app.tr("导入配置", "Import configuration"), systemImage: "square.and.arrow.down")
                    }
                    .disabled(app.hasActiveTunnel || app.isBusy)

                    Button(role: .destructive) {
                        isConfirmingReset = true
                    } label: {
                        Label(app.tr("重置配置", "Reset configuration"), systemImage: "arrow.counterclockwise")
                    }
                    .disabled(app.hasActiveTunnel || app.isBusy)
                } header: {
                    Text(app.tr("配置文件", "Configuration file"))
                } footer: {
                    Text(app.tr(
                        "导出文件包含服务器地址和路由结构，但不包含账号、密码、节点密钥、订阅地址或远程规则地址。导入后需重新填写这些凭据。连接期间不可导入或重置。",
                        "Exports include server addresses and routing structure, but not accounts, passwords, node keys, subscription URLs, or remote-rule URLs. Re-enter those credentials after import. Import and reset are unavailable while connected."
                    ))
                }

                Section(app.tr("诊断", "Diagnostics")) {
                    if let summary = app.engine.dataPathSummary {
                        LabeledContent(app.tr("出口探针", "Egress probe"), value: summary)
                    }
                    NavigationLink {
                        MobileDiagnosticsDetailView(
                            title: app.tr("诊断详情", "Diagnostic details"),
                            shareTitle: app.tr("分享诊断", "Share diagnostics"),
                            report: diagnosticReport
                        )
                    } label: {
                        Label(app.tr("查看诊断详情", "View diagnostic details"), systemImage: "stethoscope")
                    }
                    Text(app.tr(
                        "诊断只包含版本、状态、系统描述文件状态、对象计数、出口探针地址和脱敏后的最近错误。",
                        "Diagnostics contain only version, status, system-profile state, object counts, egress probe addresses, and a redacted last error."
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Section(app.tr("能力", "Capabilities")) {
                    Label(app.tr(
                        "AnyConnect 与规则分流：连接时自动分层验收",
                        "AnyConnect and rule routing: verified in layers on every connection"
                    ), systemImage: "checkmark.shield")
                    Label(app.tr(
                        "Tailscale 可独立启动；在线路上勾选 MagicDNS 后可访问 Tailnet 节点",
                        "Tailscale can start independently; enable MagicDNS on the line to reach Tailnet peers"
                    ), systemImage: "checkmark.shield")
                }

                Section(app.tr("关于", "About")) {
                    LabeledContent(app.tr("版本", "Version"), value: version)
                    Text(app.tr(
                        "普通连接通过一次性启动参数交付；启用系统级按需重连后，仅把最近一次验收通过的启动包保存在 App 与扩展共享的系统钥匙串中。敏感启动配置不会写入 App Group。",
                        "Normal connections use one-time start options. With system on-demand reconnect enabled, only the most recently verified start package is kept in the system Keychain shared by the app and extension. Sensitive startup data is never written to the App Group."
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(app.tr("设置", "Settings"))
            .fileExporter(
                isPresented: $isExporting,
                document: exportDocument,
                contentType: .json,
                defaultFilename: "XDial-configuration"
            ) { result in
                if case .failure(let error) = result {
                    showError(app.tr("导出失败", "Export failed"), error: error)
                }
                exportDocument = nil
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
                handleImport(result)
            }
            .confirmationDialog(
                app.tr("重置所有配置？", "Reset all configuration?"),
                isPresented: $isConfirmingReset,
                titleVisibility: .visible
            ) {
                Button(app.tr("重置", "Reset"), role: .destructive) {
                    resetConfiguration()
                }
                Button(app.tr("取消", "Cancel"), role: .cancel) {}
            } message: {
                Text(app.tr(
                    "线路、规则、场景和订阅将恢复为初始配置。此操作不会保留当前配置。",
                    "Lines, rules, scenarios, and subscriptions will return to their initial configuration. The current configuration will not be kept."
                ))
            }
            .confirmationDialog(
                app.tr("移除系统描述文件？", "Remove the system profile?"),
                isPresented: $isConfirmingProfileRemoval,
                titleVisibility: .visible
            ) {
                Button(app.tr("移除", "Remove"), role: .destructive) {
                    removeSystemProfile()
                }
                Button(app.tr("取消", "Cancel"), role: .cancel) {}
            } message: {
                Text(app.tr(
                    "下次连接时系统会重新请求添加描述文件。XDial 配置和安全保存的账号不会被删除。",
                    "The system will request the profile again on the next connection. XDial configuration and securely saved accounts are kept."
                ))
            }
            .alert(item: $notice) { notice in
                Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    dismissButton: .default(Text(app.tr("好", "OK")))
                )
            }
        }
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    private var diagnosticStatus: String {
        switch app.engine.status {
        case "connected": return app.tr("已连接", "Connected")
        case "connecting": return app.tr("正在连接", "Connecting")
        case "checking": return app.tr("正在验证数据链路", "Checking data path")
        case "action-required": return app.tr("需要登录 Tailscale", "Tailscale sign-in required")
        case "disconnecting": return app.tr("正在断开", "Disconnecting")
        case "reconnecting": return app.tr("正在重连", "Reconnecting")
        default: return app.tr("未连接", "Not connected")
        }
    }

    private var systemOnDemandStatusText: String {
        switch app.systemOnDemandState {
        case .disabled:
            return app.tr("未启用", "Disabled")
        case .pending:
            return app.tr("待连接验收", "Pending connection check")
        case .active:
            return app.tr("系统已启用", "Enabled by system")
        case .failed:
            return app.tr("启用失败", "Enable failed")
        }
    }

    private var diagnosticReport: String {
        MobileDiagnosticsService.report(
            version: version,
            status: diagnosticStatus,
            systemProfileInstalled: app.helperInstalled,
            profile: app.profile,
            lastError: app.engine.lastError,
            dataPathSummary: app.engine.dataPathSummary,
            isChinese: app.language == .zh
        )
    }

    private func prepareExport() {
        do {
            exportDocument = MobileJSONDocument(data: try MobileConfigurationService.exportData(for: app.profile))
            isExporting = true
        } catch {
            showError(app.tr("导出失败", "Export failed"), error: error)
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        guard !app.hasActiveTunnel, !app.isBusy else {
            notice = SettingsNotice(
                title: app.tr("当前不可导入", "Import unavailable"),
                message: app.tr("请先断开连接并等待当前操作结束。", "Disconnect and wait for the current operation to finish.")
            )
            return
        }

        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }

            if let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
               size.intValue > MobileConfigurationService.maxImportBytes {
                throw MobileConfigurationError.fileTooLarge
            }

            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let imported = try MobileConfigurationService.importProfile(from: data)
            let previousProfile = app.profile
            app.engine.lastError = nil
            guard app.replaceProfileAndSave(imported) else {
                app.profile = previousProfile
                notice = SettingsNotice(
                    title: app.tr("导入失败", "Import failed"),
                    message: app.tr(
                        "配置未能安全保存，原配置仍保留。请解锁设备后重试。",
                        "The configuration could not be saved securely. Your previous configuration is still available. Unlock the device and try again."
                    )
                )
                return
            }
            notice = SettingsNotice(
                title: app.tr("导入成功", "Import complete"),
                message: app.tr(
                    "配置已保存。请重新填写账号、密码、节点密钥、订阅地址和远程规则地址。",
                    "The configuration was saved. Re-enter accounts, passwords, node keys, subscription URLs, and remote-rule URLs."
                )
            )
        } catch {
            showError(app.tr("导入失败", "Import failed"), error: error)
        }
    }

    private func resetConfiguration() {
        guard !app.hasActiveTunnel, !app.isBusy else { return }
        let previousProfile = app.profile
        app.engine.lastError = nil
        guard app.replaceProfileAndSave(Profile.bootstrap()) else {
            app.profile = previousProfile
            notice = SettingsNotice(
                title: app.tr("重置失败", "Reset failed"),
                message: app.tr(
                    "配置未能安全保存，原配置仍保留。请解锁设备后重试。",
                    "The configuration could not be saved securely. Your previous configuration is still available. Unlock the device and try again."
                )
            )
            return
        }
        notice = SettingsNotice(
            title: app.tr("已重置", "Reset complete"),
            message: app.tr("配置已恢复为初始状态。", "The initial configuration has been restored.")
        )
    }

    private func removeSystemProfile() {
        app.removeTunnelProfile { result in
            Task { @MainActor in
                switch result {
                case .success:
                    notice = SettingsNotice(
                        title: app.tr("已移除", "Profile removed"),
                        message: app.tr("系统描述文件已移除。", "The system profile was removed.")
                    )
                case .failure(let error):
                    showError(app.tr("移除失败", "Removal failed"), error: error)
                }
            }
        }
    }

    private func showError(_ title: String, error: Error) {
        notice = SettingsNotice(title: title, message: configurationErrorMessage(error))
    }

    private func configurationErrorMessage(_ error: Error) -> String {
        guard let error = error as? MobileConfigurationError else {
            let productText = userFacingConnectionText(error.localizedDescription)
            return MobileDiagnosticsService.redacted(productText, using: app.profile)
                ?? app.tr("操作失败，请重试。", "The operation failed. Please try again.")
        }
        switch error {
        case .invalidJSON:
            return app.tr("所选文件不是有效的 XDial JSON 配置。", "The selected file is not a valid XDial JSON configuration.")
        case .unsupportedFormat:
            return app.tr("不支持这个 XDial 配置格式或版本。", "This XDial configuration format or version is not supported.")
        case .missingField(let field):
            return app.tr("配置缺少必要字段：\(field)。", "The configuration is missing the required field: \(field).")
        case .invalidIdentifier(let kind):
            return app.tr("配置中有空的 \(kind) 标识。", "The configuration contains an empty \(kind) identifier.")
        case .duplicateIdentifier(let kind):
            return app.tr("配置中有重复的 \(kind) 标识。", "The configuration contains a duplicate \(kind) identifier.")
        case .unsupportedLineType(let type):
            return app.tr("配置包含不支持的线路类型：\(type)。", "The configuration contains an unsupported line type: \(type).")
        case .invalidActiveScenario:
            return app.tr("当前场景在导入配置中不存在。", "The active scenario does not exist in this configuration.")
        case .invalidReference(let reference):
            return app.tr("配置包含无效引用：\(reference)。", "The configuration contains an invalid reference: \(reference).")
        case .fileTooLarge:
            return app.tr("配置文件超过 2 MB，已拒绝导入。", "The configuration is larger than 2 MB and was not imported.")
        }
    }
}

private struct MobileDiagnosticsDetailView: View {
    let title: String
    let shareTitle: String
    let report: String

    var body: some View {
        ScrollView {
            Text(report)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: report, subject: Text("XDial Diagnostics")) {
                Label(shareTitle, systemImage: "square.and.arrow.up")
            }
        }
    }
}

private struct SettingsNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
