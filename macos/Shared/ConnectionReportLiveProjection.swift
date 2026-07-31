import Foundation

/// Decides whether a persisted transaction is still part of the live runtime.
///
/// The journal is also the crash-recovery boundary, so a cold launch must not
/// delete it merely to clean up the UI. A failed or cancelled transaction whose
/// rollback has already proved removal of the system takeover is historical;
/// the new process must not adopt it as its current connection. Transactions
/// that are still active, committed, or unsafe to forget remain live.
enum ConnectionReportLiveProjection {
    static func shouldAdoptPersisted(
        _ report: ConnectionReport,
        currentTransactionID: String?
    ) -> Bool {
        if let currentTransactionID {
            return report.transactionID == currentTransactionID
        }
        return !isSafelySettledTerminal(report)
    }

    static func isSafelySettledTerminal(
        _ report: ConnectionReport
    ) -> Bool {
        [
            ConnectionTransactionState.failed,
            .cancelled,
        ].contains(report.state)
            && report.rollbackComplete
            && report.systemTakeoverRemoved
    }

    static func presentedReport(
        _ report: ConnectionReport?,
        status: String,
        coldLaunchSettledTransactionID: String?,
        explicitlyStoppedTransactionID: String?
    ) -> ConnectionReport? {
        guard let report else {
            return nil
        }
        // An active Network Extension state is always worth showing. It is a
        // live contradiction if a terminal journal claims the takeover was
        // removed while macOS still reports activity.
        guard status == "disconnected" else {
            return report
        }
        guard isSafelySettledTerminal(report) else {
            return report
        }
        if report.transactionID == coldLaunchSettledTransactionID ||
            report.transactionID == explicitlyStoppedTransactionID {
            return nil
        }
        return report
    }
}
