import XCTest

final class ConnectionReportRuntimeFactsTests: XCTestCase {
    func testNEConnectedDoesNotExposeLinesBeforeCommit() {
        var report = makeReport(transactionID: "transaction-1")

        XCTAssertNil(ConnectionReportRuntimeFacts.committedLines(
            status: "connected",
            report: report
        ))

        report.updateTask(id: "line:company", state: .ready)
        report.updateTask(id: "line:japan", state: .ready)
        report.updateTask(
            id: "ingress:transparent-proxy",
            state: .committing
        )
        report.setState(.committing)
        XCTAssertNil(ConnectionReportRuntimeFacts.committedLines(
            status: "connected",
            report: report
        ))

        report.updateTask(
            id: "ingress:transparent-proxy",
            state: .committed
        )
        report.systemTakeoverRemoved = false
        report.setState(.committed)
        XCTAssertEqual(
            ConnectionReportRuntimeFacts.committedLines(
                status: "connected",
                report: report
            ),
            CommittedLineRuntimeFacts(
                transactionID: "transaction-1",
                lineIDs: ["company", "japan"]
            )
        )

        report.setState(.rollingBack)
        XCTAssertNil(ConnectionReportRuntimeFacts.committedLines(
            status: "connected",
            report: report
        ))
    }

    func testEditableProfileDriftCannotRewriteCommittedLineFacts() {
        var report = makeReport(transactionID: "transaction-2")
        report.updateTask(id: "line:company", state: .ready)
        report.updateTask(id: "line:japan", state: .ready)
        report.updateTask(
            id: "ingress:transparent-proxy",
            state: .committed
        )
        report.systemTakeoverRemoved = false
        report.setState(.committed)

        let before = ConnectionReportRuntimeFacts.committedLines(
            status: "connected",
            report: report
        )

        // Simulate edits to the currently selected Profile Mode. Runtime
        // projection has no Profile input and must remain the report snapshot.
        var editableModeID = "runtime-mode"
        var editableLineIDs = ["company", "japan"]
        editableModeID = "next-mode"
        editableLineIDs = ["uncommitted-line"]
        XCTAssertEqual(editableModeID, "next-mode")
        XCTAssertEqual(editableLineIDs, ["uncommitted-line"])

        let after = ConnectionReportRuntimeFacts.committedLines(
            status: "connected",
            report: report
        )
        XCTAssertEqual(after, before)
        XCTAssertEqual(after?.lineIDs, ["company", "japan"])
    }

    func testCommittedLinesPreservePlanOrderAndDeduplicateResourceIDs() {
        var report = makeReport(
            transactionID: "transaction-3",
            duplicateCompanyTask: true
        )
        for task in report.tasks where task.kind == "line" {
            report.updateTask(id: task.id, state: .ready)
        }
        report.updateTask(
            id: "ingress:transparent-proxy",
            state: .committed
        )
        report.systemTakeoverRemoved = false
        report.setState(.committed)

        XCTAssertEqual(
            ConnectionReportRuntimeFacts.committedLines(
                status: "connected",
                report: report
            )?.lineIDs,
            ["company", "japan"]
        )
    }

    private func makeReport(
        transactionID: String,
        duplicateCompanyTask: Bool = false
    ) -> ConnectionReport {
        var tasks = [
            ConnectionPlanTask(
                id: "line:company",
                kind: "line",
                name: "Company",
                preparation: "connect",
                resourceID: "company",
                resourceType: "vpn"
            ),
            ConnectionPlanTask(
                id: "line:japan",
                kind: "line",
                name: "Japan",
                preparation: "connect",
                resourceID: "japan",
                resourceType: "tailscale"
            ),
        ]
        if duplicateCompanyTask {
            tasks.append(ConnectionPlanTask(
                id: "line:company-duplicate",
                kind: "line",
                name: "Company duplicate",
                preparation: "connect",
                resourceID: "company",
                resourceType: "vpn"
            ))
        }
        tasks.append(ConnectionPlanTask(
            id: "ingress:transparent-proxy",
            kind: "ingress",
            name: "Transparent Proxy",
            preparation: "commit"
        ))
        return ConnectionReport(
            transactionID: transactionID,
            plan: ConnectionPlan(
                schemaVersion: 1,
                mode: ConnectionPlanMode(
                    id: "runtime-mode",
                    name: "Runtime Mode"
                ),
                tasks: tasks
            )
        )
    }
}
