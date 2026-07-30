import Foundation

/// The Line facts owned by one fully committed connection transaction.
///
/// Editable Profile state is deliberately absent: changing a Mode or Line in
/// Settings cannot rewrite what the currently running transaction prepared.
struct CommittedLineRuntimeFacts: Equatable {
    let transactionID: String
    let lineIDs: [String]
}

enum ConnectionReportRuntimeFacts {
    static func committedLines(
        status: String,
        report: ConnectionReport?
    ) -> CommittedLineRuntimeFacts? {
        guard
            status == "connected",
            let report,
            report.state == .committed,
            !report.systemTakeoverRemoved,
            report.tasks.contains(where: {
                $0.id == "ingress:transparent-proxy"
                    && $0.kind == "ingress"
                    && $0.state == .committed
            })
        else {
            return nil
        }

        var seen = Set<String>()
        let lineIDs = report.tasks.compactMap {
            task -> String? in
            guard
                task.kind == "line",
                !task.resourceID.isEmpty,
                task.state == .ready || task.state == .committed,
                seen.insert(task.resourceID).inserted
            else {
                return nil
            }
            return task.resourceID
        }
        return CommittedLineRuntimeFacts(
            transactionID: report.transactionID,
            lineIDs: lineIDs
        )
    }
}
