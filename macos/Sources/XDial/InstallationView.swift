import AppKit
import SwiftUI

struct InstallationView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @EnvironmentObject private var state: AppState
    @ObservedObject var coordinator: InstallationCoordinator

    @State private var deleteDataOnUninstall = false
    @State private var confirmsUninstall = false
    @State private var isUninstalling = false
    @State private var uninstallError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if coordinator.presentedOperation == .install {
                installationTasks
            } else {
                uninstallOptions
            }

            footer
        }
        .padding(22)
        .frame(width: 480)
        .background(XDialPalette.canvas)
        .tint(XDialPalette.accent)
        .confirmationDialog(
            state.tr("确认卸载 XDial？", "Uninstall XDial?"),
            isPresented: $confirmsUninstall,
            titleVisibility: .visible
        ) {
            Button(
                deleteDataOnUninstall
                    ? state.tr(
                        "卸载并删除所有数据",
                        "Uninstall & Delete All Data"
                    )
                    : state.tr(
                        "卸载并保留配置",
                        "Uninstall & Keep Settings"
                    ),
                role: .destructive
            ) {
                runUninstall()
            }
            Button(state.tr("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(uninstallConfirmationMessage)
        }
        .onAppear {
            handleOperationChange()
        }
        .onChange(of: coordinator.presentedOperation) {
            handleOperationChange()
        }
        .onExitCommand {
            if !isUninstalling {
                closeWindow()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: headerSymbol)
                .font(.system(size: 28))
                .foregroundStyle(headerColor)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(headerTitle)
                    .font(.title2.weight(.semibold))
                Text(headerDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Picker(
                state.tr("操作", "Operation"),
                selection: operationBinding
            ) {
                Text(state.tr("安装", "Install"))
                    .tag(InstallationOperation.install)
                Text(state.tr("卸载", "Uninstall"))
                    .tag(InstallationOperation.uninstall)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 144)
            .disabled(isUninstalling)
        }
    }

    private var operationBinding: Binding<InstallationOperation> {
        Binding(
            get: { coordinator.presentedOperation },
            set: { coordinator.selectOperation($0) }
        )
    }

    private var installationTasks: some View {
        VStack(spacing: 0) {
            ForEach(coordinator.report.tasks) { task in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbol(for: task.state))
                        .foregroundStyle(color(for: task.state))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.name)
                            .font(.system(size: 13, weight: .medium))
                        Text(task.error?.message ?? task.detail)
                            .font(.caption)
                            .foregroundStyle(
                                task.state == .failed
                                    ? XDialPalette.danger
                                    : Color.secondary
                            )
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    if canRetry(task) {
                        Button(state.tr("重试安装", "Retry")) {
                            coordinator.retry()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else if task.state == .running {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(stateText(task.state))
                            .font(.caption)
                            .foregroundStyle(color(for: task.state))
                    }
                }
                .padding(.vertical, 10)
                if task.id != coordinator.report.tasks.last?.id {
                    Divider()
                }
            }
        }
        .padding(.horizontal, 14)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var uninstallOptions: some View {
        VStack(spacing: 0) {
            uninstallActionRow(
                symbol: "network.slash",
                title: state.tr(
                    "断开连接并移除网络配置",
                    "Disconnect and remove network configuration"
                )
            )
            Divider()
            uninstallActionRow(
                symbol: "shield.slash",
                title: state.tr(
                    "移除网络扩展与后台服务",
                    "Remove the network extension and background service"
                )
            )
            Divider()
            uninstallActionRow(
                symbol: "trash",
                title: state.tr(
                    "将 XDial 移到废纸篓",
                    "Move XDial to Trash"
                )
            )
            Divider()
            Toggle(isOn: $deleteDataOnUninstall) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.tr(
                        "同时删除配置与密码",
                        "Also delete settings and passwords"
                    ))
                    .font(.system(size: 12, weight: .medium))
                    Text(state.tr(
                        "包括线路、规则、场景，以及钥匙串中保存的密码",
                        "Includes lines, rules, scenarios, and Keychain-stored passwords"
                    ))
                    .font(.system(size: 10.5))
                    .foregroundStyle(
                        deleteDataOnUninstall
                            ? XDialPalette.danger
                            : Color.secondary
                    )
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .frame(minHeight: 48)

            if let uninstallError {
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(XDialPalette.danger)
                    Text(uninstallError)
                        .font(.system(size: 11))
                        .foregroundStyle(XDialPalette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 10)
            }
        }
        .padding(.horizontal, 14)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func uninstallActionRow(
        symbol: String,
        title: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Spacer()
        }
        .frame(minHeight: 38)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(footerNote)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if coordinator.presentedOperation == .install {
                installationFooterAction
            } else if isUninstalling {
                ProgressView()
                    .controlSize(.small)
            } else if coordinator.isInstalling {
                Text(state.tr("安装正在进行", "Installation in progress"))
                    .font(.caption)
                    .foregroundStyle(XDialPalette.progress)
            } else {
                Button(role: .destructive) {
                    confirmsUninstall = true
                } label: {
                    Text(
                        uninstallError == nil
                            ? state.tr("卸载 XDial", "Uninstall XDial")
                            : state.tr("重试卸载", "Retry Uninstall")
                    )
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var installationFooterAction: some View {
        if coordinator.report.state == .failed,
           !isExtensionFailure {
            Button(state.tr("重试", "Retry")) {
                coordinator.retry()
            }
            .buttonStyle(.borderedProminent)
        } else if coordinator.isReady {
            Button(state.tr("完成", "Done")) {
                closeWindow()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var footerNote: String {
        if coordinator.presentedOperation == .install {
            return state.tr(
                "安装过程不会创建网络配置或接管流量。",
                "Installation does not create network configuration or take over traffic."
            )
        }
        return state.tr(
            "卸载会先断开连接并移除 XDial 的系统接管。",
            "Uninstalling first disconnects and removes XDial's system takeover."
        )
    }

    private var headerTitle: String {
        if coordinator.presentedOperation == .uninstall {
            if isUninstalling {
                return state.tr("正在卸载 XDial", "Uninstalling XDial")
            }
            if uninstallError != nil {
                return state.tr("XDial 卸载未完成", "Uninstall Incomplete")
            }
            return state.tr("卸载 XDial", "Uninstall XDial")
        }

        switch coordinator.report.state {
        case .checking:
            return state.tr("正在检查 XDial", "Checking XDial")
        case .installing:
            return state.tr("正在配置 XDial", "Configuring XDial")
        case .waitingForApproval:
            return state.tr(
                "等待 macOS 批准",
                "Waiting for macOS Approval"
            )
        case .ready:
            return state.tr("XDial 已就绪", "XDial Is Ready")
        case .failed:
            return state.tr(
                "XDial 安装未完成",
                "Installation Incomplete"
            )
        }
    }

    private var headerDetail: String {
        if coordinator.presentedOperation == .uninstall {
            if isUninstalling {
                return state.tr(
                    "正在移除网络配置、系统组件和应用。",
                    "Removing network configuration, system components, and the app."
                )
            }
            if coordinator.isInstalling {
                return state.tr(
                    "当前安装事务结束后才能开始卸载。",
                    "Uninstalling becomes available after the current installation finishes."
                )
            }
            if let uninstallError { return uninstallError }
            return state.tr(
                "默认保留配置；需要时可以在下方一并删除。",
                "Settings are kept by default; you can delete them below."
            )
        }

        switch coordinator.report.state {
        case .waitingForApproval:
            return state.tr(
                "系统设置已经打开；完成 macOS 要求的批准后会自动继续。",
                "System Settings is open; setup continues after macOS approval."
            )
        case .ready:
            return state.tr(
                "后台服务和网络扩展均来自当前安装包。",
                "The background service and network extension match this app."
            )
        case .failed:
            return coordinator.report.error?.message
                ?? state.tr("请查看失败步骤。", "Review the failed step.")
        default:
            return state.tr(
                "首次安装与每次升级都使用同一份可观察流程。",
                "First install and upgrades use the same observable flow."
            )
        }
    }

    private var headerSymbol: String {
        if coordinator.presentedOperation == .uninstall {
            if uninstallError != nil { return "xmark.shield.fill" }
            return isUninstalling ? "trash.fill" : "trash"
        }
        switch coordinator.report.state {
        case .ready:
            return "checkmark.shield.fill"
        case .failed:
            return "xmark.shield.fill"
        default:
            return "shield.lefthalf.filled"
        }
    }

    private var headerColor: Color {
        if coordinator.presentedOperation == .uninstall {
            if uninstallError != nil { return XDialPalette.danger }
            return isUninstalling
                ? XDialPalette.progress
                : XDialPalette.warning
        }
        switch coordinator.report.state {
        case .ready:
            return XDialPalette.success
        case .failed:
            return XDialPalette.danger
        case .waitingForApproval:
            return XDialPalette.warning
        default:
            return XDialPalette.progress
        }
    }

    private var uninstallConfirmationMessage: String {
        if deleteDataOnUninstall {
            return state.tr(
                "XDial 将被移到废纸篓，线路、规则、场景和钥匙串密码也会被永久删除。",
                "XDial will be moved to Trash, and all lines, rules, scenarios, and Keychain passwords will be permanently deleted."
            )
        }
        return state.tr(
            "XDial 将被移到废纸篓；线路、规则、场景和密码会保留，方便以后重新安装。",
            "XDial will be moved to Trash; lines, rules, scenarios, and passwords will be kept for a future installation."
        )
    }

    private func handleOperationChange() {
        confirmsUninstall = false
        if coordinator.presentedOperation == .install {
            coordinator.start()
        }
    }

    private func runUninstall() {
        guard !coordinator.isInstalling else { return }
        uninstallError = nil
        isUninstalling = true
        state.uninstall(deleteData: deleteDataOnUninstall) { ok, error in
            isUninstalling = false
            if ok {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSApp.terminate(nil)
                }
            } else {
                uninstallError = error
                    ?? state.tr(
                        "卸载未完成，请重试。",
                        "Uninstall did not complete. Try again."
                    )
            }
        }
    }

    private func closeWindow() {
        dismissWindow(id: "installation")
    }

    private func symbol(for state: InstallationTaskState) -> String {
        switch state {
        case .pending:
            return "circle"
        case .running:
            return "clock.fill"
        case .waitingForApproval:
            return "hand.raised.fill"
        case .ready:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        }
    }

    private func color(for state: InstallationTaskState) -> Color {
        switch state {
        case .running:
            return XDialPalette.progress
        case .waitingForApproval:
            return XDialPalette.warning
        case .ready:
            return XDialPalette.success
        case .failed:
            return XDialPalette.danger
        case .pending:
            return .secondary
        }
    }

    private func stateText(_ taskState: InstallationTaskState) -> String {
        switch taskState {
        case .pending:
            return state.tr("等待", "Waiting")
        case .running:
            return state.tr("进行中", "In Progress")
        case .waitingForApproval:
            return state.tr("待批准", "Approval")
        case .ready:
            return state.tr("就绪", "Ready")
        case .failed:
            return state.tr("失败", "Failed")
        }
    }

    private func canRetry(_ task: InstallationTaskReport) -> Bool {
        task.state == .failed && task.id == "system-extension"
    }

    private var isExtensionFailure: Bool {
        coordinator.report.error?.taskID == "system-extension"
    }
}
