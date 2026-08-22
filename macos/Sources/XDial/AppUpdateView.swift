import SwiftUI

struct AppUpdateView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var updater: AppUpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            releaseNotes
            statusArea
            footer
        }
        .padding(22)
        .frame(width: 460)
        .background(XDialPalette.canvas)
        .tint(XDialPalette.accent)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: statusSymbol)
                .font(.system(size: 28))
                .foregroundStyle(statusColor)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(versionTitle)
                    .font(.title2.weight(.semibold))
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
        }
    }

    @ViewBuilder
    private var releaseNotes: some View {
        if let candidate = updater.releaseCandidate {
            VStack(alignment: .leading, spacing: 8) {
                Text(state.tr("更新了什么", "What’s New"))
                    .font(.system(size: 12, weight: .semibold))
                ScrollView {
                    Text(
                        candidate.releaseNotes
                            ?? state.tr(
                                "此版本没有更新说明。",
                                "No release notes were provided."
                            )
                    )
                    .font(.system(size: 11.5))
                    .foregroundStyle(XDialPalette.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 120, maxHeight: 220)
                .padding(12)
                .background(XDialPalette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(XDialPalette.divider, lineWidth: 0.75)
                }
            }
        }
    }

    @ViewBuilder
    private var statusArea: some View {
        if updater.phase == .downloading {
            VStack(alignment: .leading, spacing: 7) {
                ProgressView(value: updater.downloadProgress)
                Text(
                    updater.downloadProgress > 0
                        ? updater.downloadProgress.formatted(
                            .percent.precision(.fractionLength(0))
                        )
                        : state.tr("正在开始下载…", "Starting download…")
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        } else if updater.phase == .validating
            || updater.phase == .handingOff
            || updater.phase == .checking
        {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if let failure = updater.failure {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(XDialPalette.danger)
                VStack(alignment: .leading, spacing: 3) {
                    Text(failureTitle(failure.code))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(XDialPalette.danger)
                    Text(failure.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(XDialPalette.danger.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(footerNote)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            actionButton
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch updater.phase {
        case .available:
            Button(state.tr("下载更新", "Download Update")) {
                updater.downloadAndPrepare()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!ApplicationRelocator.permitsAutomaticUpdates)
        case .ready:
            Button(state.tr("安装并重新启动", "Install and Restart")) {
                updater.installPreparedUpdate(
                    reconnectScenarioID: reconnectScenarioID
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.isBusy)
        case .failed:
            if updater.releaseCandidate != nil {
                Button(state.tr("重新下载", "Download Again")) {
                    updater.downloadAndPrepare()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!ApplicationRelocator.permitsAutomaticUpdates)
            } else {
                Button(state.tr("重新检查", "Check Again")) {
                    Task { await updater.checkNow() }
                }
                .buttonStyle(.bordered)
            }
        case .idle, .upToDate:
            Button(state.tr("检查更新", "Check for Updates")) {
                Task { await updater.checkNow() }
            }
            .buttonStyle(.bordered)
        case .checking, .downloading, .validating, .handingOff:
            EmptyView()
        }
    }

    private var versionTitle: String {
        guard let candidate = updater.releaseCandidate else {
            return state.tr(
                "当前版本 v\(currentVersion)",
                "Current Version v\(currentVersion)"
            )
        }
        return state.tr(
            "v\(currentVersion) → v\(candidate.version)",
            "v\(currentVersion) → v\(candidate.version)"
        )
    }

    private var statusDetail: String {
        switch updater.phase {
        case .idle:
            state.tr("可以手动检查新版本", "Ready to check for updates")
        case .checking:
            state.tr("正在检查更新…", "Checking for updates…")
        case .upToDate:
            state.tr("已经是最新版本", "XDial is up to date")
        case .available:
            state.tr("新版本已经可以下载", "A new version is available")
        case .downloading:
            state.tr("正在下载更新…", "Downloading update…")
        case .validating:
            state.tr("正在验证签名与安装包…", "Verifying the signed app…")
        case .ready:
            state.tr("更新已验证，可以安全安装", "The update is verified and ready")
        case .handingOff:
            state.tr("正在安全断开并交接到新版本…", "Handing off to the new version…")
        case .failed:
            state.tr("更新没有完成，可以重试", "The update did not finish; you can retry")
        }
    }

    private var statusSymbol: String {
        switch updater.phase {
        case .upToDate: "checkmark.circle.fill"
        case .failed: "exclamationmark.octagon.fill"
        case .ready: "checkmark.seal.fill"
        case .downloading, .validating, .checking, .handingOff:
            "arrow.triangle.2.circlepath.circle.fill"
        case .idle, .available: "arrow.down.circle.fill"
        }
    }

    private var statusColor: Color {
        switch updater.phase {
        case .upToDate, .ready: XDialPalette.success
        case .failed: XDialPalette.danger
        case .available: XDialPalette.warning
        default: XDialPalette.progress
        }
    }

    private var footerNote: String {
        if !ApplicationRelocator.permitsAutomaticUpdates {
            return state.tr(
                "Debug 构建只用于验证界面，不会安装 GitHub Release。",
                "Debug builds only preview this interface and never install a GitHub release."
            )
        }
        if updater.phase == .ready {
            return reconnectScenarioID == nil
                ? state.tr(
                    "重新启动后保持断开。",
                    "XDial will remain disconnected after restarting."
                )
                : state.tr(
                    "安装会短暂断开；新版本启动后恢复当前场景。",
                    "Installation briefly disconnects; the new version restores the current Scenario."
                )
        }
        return state.tr(
            "下载与验证不会更改网络状态。",
            "Downloading and verification do not change network state."
        )
    }

    private var reconnectScenarioID: String? {
        guard state.isConnected,
              let report = state.presentedConnectionReport,
              report.state == .committed else {
            return nil
        }
        return report.scenario.id
    }

    private var currentVersion: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "?"
    }

    private func failureTitle(
        _ code: AppUpdateFailureCode
    ) -> String {
        switch code {
        case .checkUnavailable:
            state.tr("无法检查更新", "Couldn’t Check for Updates")
        case .downloadFailed:
            state.tr("更新包下载失败", "Update Download Failed")
        case .validationFailed:
            state.tr("更新包验证失败", "Update Verification Failed")
        }
    }
}
