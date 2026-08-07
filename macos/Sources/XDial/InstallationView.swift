import AppKit
import SwiftUI

struct InstallationView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject var coordinator: InstallationCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: headerSymbol)
                    .font(.system(size: 28))
                    .foregroundStyle(headerColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headerTitle)
                        .font(.title2.weight(.semibold))
                    Text(headerDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

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
                                        ? Color.red
                                        : Color.secondary
                                )
                                .fixedSize(
                                    horizontal: false,
                                    vertical: true
                                )
                        }
                        Spacer()
                        if canRetry(task) {
                            Button(retryTitle(task)) {
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

            HStack {
                Text("安装过程中不会创建网络配置或接管流量。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if coordinator.report.state == .failed,
                   !isExtensionFailure {
                    Button("重试") {
                        coordinator.retry()
                    }
                    .buttonStyle(.borderedProminent)
                } else if coordinator.isReady {
                    Button("完成") {
                        closeWindow()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear {
            coordinator.start()
        }
        .onExitCommand {
            closeWindow()
        }
    }

    private func closeWindow() {
        dismissWindow(id: "installation")
    }

    private var headerTitle: String {
        switch coordinator.report.state {
        case .checking:
            "正在检查 XDial"
        case .installing:
            "正在配置 XDial"
        case .waitingForApproval:
            "等待 macOS 批准"
        case .ready:
            "XDial 已就绪"
        case .failed:
            "XDial 安装未完成"
        }
    }

    private var headerDetail: String {
        switch coordinator.report.state {
        case .waitingForApproval:
            "系统设置已经打开；完成 macOS 要求的批准后会自动继续。"
        case .ready:
            "后台服务和网络扩展均来自当前安装包。"
        case .failed:
            coordinator.report.error?.message ?? "请查看失败步骤。"
        default:
            "首次安装与每次升级都使用同一份可观察流程。"
        }
    }

    private var headerSymbol: String {
        switch coordinator.report.state {
        case .ready:
            "checkmark.shield.fill"
        case .failed:
            "xmark.shield.fill"
        default:
            "shield.lefthalf.filled"
        }
    }

    private var headerColor: Color {
        switch coordinator.report.state {
        case .ready:
            .green
        case .failed:
            .red
        case .waitingForApproval:
            .orange
        default:
            .accentColor
        }
    }

    private func symbol(for state: InstallationTaskState) -> String {
        switch state {
        case .pending:
            "circle"
        case .running:
            "clock.fill"
        case .waitingForApproval:
            "hand.raised.fill"
        case .ready:
            "checkmark.circle.fill"
        case .failed:
            "xmark.octagon.fill"
        }
    }

    private func color(for state: InstallationTaskState) -> Color {
        switch state {
        case .running, .waitingForApproval:
            .orange
        case .ready:
            .green
        case .failed:
            .red
        case .pending:
            .secondary
        }
    }

    private func stateText(_ state: InstallationTaskState) -> String {
        switch state {
        case .pending:
            "等待"
        case .running:
            "进行中"
        case .waitingForApproval:
            "待批准"
        case .ready:
            "就绪"
        case .failed:
            "失败"
        }
    }

    private func canRetry(_ task: InstallationTaskReport) -> Bool {
        task.state == .failed
            && task.id == "system-extension"
    }

    private func retryTitle(
        _ task: InstallationTaskReport
    ) -> String {
        "重试安装"
    }

    private var isExtensionFailure: Bool {
        guard let taskID = coordinator.report.error?.taskID else {
            return false
        }
        return taskID == "system-extension"
    }
}
