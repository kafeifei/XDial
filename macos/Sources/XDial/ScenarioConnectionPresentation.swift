import Foundation

/// Reads the committed transaction, never the editable Profile or the selected
/// scenario. A selected scenario and a prepared candidate are not a VPN login.
enum ScenarioConnectionPresentation: Equatable {
    case inactive, failed, preparing, disconnecting, reconnecting, direct, vpn, routed, unconfirmed
    case wakeReconnecting(WakeReconnectPhase)

    static func resolve(
        status: String,
        wakeReconnectPhase: WakeReconnectPhase? = nil,
        lastError: String? = nil,
        report: ConnectionReport?
    ) -> Self {
        // Match AppState.statusText's wake-phase priority; isBusy loses the
        // distinction between activation, teardown and recovery.
        if let wakeReconnectPhase { return .wakeReconnecting(wakeReconnectPhase) }
        switch status {
        case "connecting": return .preparing
        case "disconnecting": return .disconnecting
        case "reconnecting": return .reconnecting
        case "disconnected":
            return report?.error != nil || report?.rollbackError != nil
                || report?.state == .failed || lastError != nil ? .failed : .inactive
        case "connected": break
        default: return .unconfirmed
        }
        guard let report, report.state == .committed, report.error == nil else { return .unconfirmed }
        let targets = report.tasks.filter { $0.kind == "line" || $0.kind == "subscription" }
        guard !targets.isEmpty, targets.allSatisfy({
            ($0.state == .ready || $0.state == .committed) && $0.error == nil
        }) else { return .unconfirmed }
        if targets.allSatisfy({ $0.kind == "line" && $0.resourceType == "direct" }) { return .direct }
        if targets.contains(where: { $0.kind == "line" && $0.resourceType == "vpn" }) { return .vpn }
        // Groups, proxies, subscriptions and older reports must not be called
        // either a VPN connection or direct merely because their type is unknown.
        return .routed
    }

    /// AppState.statusText owns all lifecycle, task and failure wording.
    /// Only committed routing facts add a distinct title here.
    func title(_ tr: (String, String) -> String, statusText: String) -> String {
        switch self {
        case .inactive, .failed, .preparing, .disconnecting, .reconnecting, .wakeReconnecting:
            return statusText
        case .direct: return tr("直连运行中 · 未建立 VPN", "Direct routing · No XDial VPN")
        case .vpn: return tr("VPN 线路已连接", "VPN line connected")
        case .routed: return tr("分流运行中", "Routing is active")
        case .unconfirmed: return tr("正在确认线路状态", "Checking line status")
        }
    }

    func detail(_ tr: (String, String) -> String) -> String {
        switch self {
        case .inactive: return tr("XDial 当前未连接。选择场景并连接后，XDial 才会处理流量。", "XDial is not connected. Connect a scenario to let XDial handle traffic.")
        case .failed: return tr("连接发生错误。线路、回滚和原网络恢复情况需分别确认。", "A connection error occurred. Line readiness, rollback and network recovery must be checked separately.")
        case .preparing: return tr("尚未完成启用；请等待线路准备和网络接管完成。", "Activation is not complete. Waiting for routes and network setup.")
        case .disconnecting: return tr("正在停用 XDial 连接，请等待断开完成。", "Stopping the XDial connection. Waiting for disconnection to complete.")
        case .reconnecting, .wakeReconnecting:
            return tr("正在恢复 XDial 连接；恢复完成前不能确认线路就绪。", "Restoring the XDial connection. Line readiness cannot be confirmed until recovery completes.")
        case .direct: return tr("XDial 沿用原网络，不通过 XDial VPN，也不进行 VPN 账号认证。", "XDial uses your existing network without an XDial VPN or VPN sign-in.")
        case .vpn: return tr("仅按运行场景的规则使用 VPN；不代表所有流量都走 VPN。", "VPN use follows the running scenario's rules, not necessarily all traffic.")
        case .routed: return tr("流量按运行场景处理；场景启用不等于 VPN 已连接。", "Traffic follows the running scenario. An active scenario does not imply a VPN connection.")
        case .unconfirmed: return tr("尚无完整的已提交线路状态，暂时无法确认线路是否就绪。", "Complete committed line status is unavailable. Line readiness cannot be confirmed yet.")
        }
    }
}
