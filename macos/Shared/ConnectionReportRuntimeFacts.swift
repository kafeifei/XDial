import Foundation

/// The Line facts owned by one fully committed connection transaction.
///
/// Editable Profile state is deliberately absent: changing a Scenario or Line in
/// Settings cannot rewrite what the currently running transaction prepared.
struct CommittedLineRuntimeFacts: Equatable {
    let transactionID: String
    let lineIDs: [String]
}

enum ConnectionReportRuntimeFacts {
    static let lineRuntimeReusedCode = "line-runtime-reused"

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

    /// Returns only public Line IDs whose candidate report contains explicit
    /// pool-reuse evidence. Runtime identities never enter the report; task
    /// membership also prevents an unrecognised event from inventing a Line.
    static func reusedLineIDs(
        report: ConnectionReport
    ) -> [String] {
        let reusedTaskIDs: Set<String> = Set(
            report.events.compactMap { event -> String? in
            guard
                event.type == "diagnostic",
                event.code == lineRuntimeReusedCode,
                event.facts?["reused"] == true,
                !event.taskID.isEmpty
            else {
                return nil
            }
            return event.taskID
            }
        )
        var seen = Set<String>()
        return report.tasks.compactMap { task in
            guard
                task.kind == "line",
                !task.resourceID.isEmpty,
                reusedTaskIDs.contains(task.id),
                seen.insert(task.resourceID).inserted
            else {
                return nil
            }
            return task.resourceID
        }
    }
}
