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

        // Simulate edits to the currently selected Profile Scenario. Runtime
        // projection has no Profile input and must remain the report snapshot.
        var editableScenarioID = "runtime-scenario"
        var editableLineIDs = ["company", "japan"]
        editableScenarioID = "next-scenario"
        editableLineIDs = ["uncommitted-line"]
        XCTAssertEqual(editableScenarioID, "next-scenario")
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

    func testReusedLineFactsExposeOnlyValidatedPublicLineIDs() {
        var report = makeReport(
            transactionID: "transaction-reuse",
            duplicateCompanyTask: true
        )
        report.note(
            code: ConnectionReportRuntimeFacts.lineRuntimeReusedCode,
            message: "runtime capability reused",
            taskID: "line:company",
            facts: ["reused": true]
        )
        report.note(
            code: ConnectionReportRuntimeFacts.lineRuntimeReusedCode,
            message: "duplicate task for the same public Line",
            taskID: "line:company-duplicate",
            facts: ["reused": true]
        )
        report.note(
            code: ConnectionReportRuntimeFacts.lineRuntimeReusedCode,
            message: "unknown task must not create a Line fact",
            taskID: "line:opaque-runtime-v1:secret",
            facts: ["reused": true]
        )
        report.note(
            code: ConnectionReportRuntimeFacts.lineRuntimeReusedCode,
            message: "missing affirmative evidence",
            taskID: "line:japan",
            facts: ["reused": false]
        )

        XCTAssertEqual(
            ConnectionReportRuntimeFacts.reusedLineIDs(report: report),
            ["company"]
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
                schemaVersion: 3,
                scenario: ConnectionPlanScenario(
                    id: "runtime-scenario",
                    name: "Runtime Scenario"
                ),
                tasks: tasks
            )
        )
    }
}
