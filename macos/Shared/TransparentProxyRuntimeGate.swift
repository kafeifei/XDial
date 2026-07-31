import Foundation

/// Combines the system Network Extension state with the current transaction.
///
/// `NEVPNStatus.connected` proves only that the system configuration is up. It
/// cannot publish XDial as connected until the same transaction has committed
/// its Transparent Proxy ingress and still owns the system takeover.
enum TransparentProxyRuntimeGate {
    /// During automatic recovery the transaction which described the lost
    /// session is no longer eligible to prove connectivity. A retry becomes
    /// eligible only after that exact transaction has been handed to a new
    /// Network Extension session.
    static func connectionProofTransactionID(
        currentTransactionID: String?,
        automaticReconnectInProgress: Bool,
        reconnectTransactionID: String?,
        networkExtensionSessionTransactionID: String?
    ) -> String? {
        guard automaticReconnectInProgress else {
            return currentTransactionID
        }
        guard
            let reconnectTransactionID,
            reconnectTransactionID == currentTransactionID,
            reconnectTransactionID ==
                networkExtensionSessionTransactionID
        else {
            return nil
        }
        return reconnectTransactionID
    }

    static func resolve(
        systemStatus: String,
        report: ConnectionReport?,
        activeTransactionID: String?,
        previousStatus: String
    ) -> String {
        switch systemStatus {
        case "connected":
            guard
                let report,
                report.transactionID == activeTransactionID,
                report.state == .committed,
                !report.systemTakeoverRemoved,
                report.tasks.contains(where: {
                    $0.id == "ingress:transparent-proxy"
                        && $0.kind == "ingress"
                        && $0.state == .committed
                })
            else {
                if report?.state == .rollingBack
                    || report?.state == .rolledBack
                    || report?.state == .failed
                    || report?.state == .cancelled {
                    return "disconnecting"
                }
                return previousStatus == "reconnecting"
                    ? "reconnecting"
                    : "connecting"
            }
            return "connected"
        case "connecting":
            return "connecting"
        case "reconnecting":
            return "reconnecting"
        case "disconnecting":
            return "disconnecting"
        case "disconnected":
            return "disconnected"
        default:
            return "disconnected"
        }
    }
}
