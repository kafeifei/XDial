import XCTest

final class ConnectionTransactionReporterCandidateTests: XCTestCase {
    func testCandidateUpdatesStayOutOfAuthoritativeJournal() throws {
        let authoritativeTransactionID =
            ConnectionReportJournal.read()?.transactionID
        let candidate = makeReport(transactionID: UUID().uuidString)
        let reporter = try ConnectionTransactionReporter(
            candidate: candidate
        )

        reporter.setState(.preparing)
        reporter.markUnderlaySnapshotReady()
        reporter.setTask(id: "line:test", state: .ready)
        reporter.note(
            code: ConnectionReportRuntimeFacts.lineRuntimeReusedCode,
            message: "runtime capability reused",
            taskID: "line:test",
            facts: ["reused": true]
        )
        reporter.setTask(id: "dns:scenario", state: .ready)
        reporter.setTask(id: "data-plane:sing-box", state: .ready)
        reporter.setState(.readyToCommit)
        reporter.setState(.committing)
        try reporter.markCommitted()
        try reporter.stageCandidate()

        let updated = try XCTUnwrap(reporter.currentReport())
        XCTAssertEqual(updated.state, .committed)
        XCTAssertFalse(updated.systemTakeoverRemoved)
        XCTAssertEqual(
            ConnectionReportRuntimeFacts.reusedLineIDs(report: updated),
            ["line-test"]
        )
        XCTAssertEqual(
            ConnectionReportJournal.read()?.transactionID,
            authoritativeTransactionID
        )
        reporter.discardStagedCandidate()
    }

    func testCandidateCannotPersistBeforeCommit() throws {
        let reporter = try ConnectionTransactionReporter(
            candidate: makeReport(transactionID: UUID().uuidString)
        )

        XCTAssertThrowsError(try reporter.persistCommittedCandidate())
    }

    func testCandidateCommitGateRequiresAcceptedUnderlaySnapshot() throws {
        let reporter = try ConnectionTransactionReporter(
            candidate: makeReport(transactionID: UUID().uuidString)
        )

        reporter.setState(.preparing)
        reporter.setTask(id: "line:test", state: .ready)
        reporter.setTask(id: "dns:scenario", state: .ready)
        reporter.setTask(id: "data-plane:sing-box", state: .ready)

        XCTAssertThrowsError(try reporter.ensureReadyForCommit()) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("underlay:system")
            )
        }

        reporter.markUnderlaySnapshotReady()
        XCTAssertNoThrow(try reporter.ensureReadyForCommit())
        XCTAssertEqual(
            reporter.currentReport()?.tasks.first {
                $0.id == "underlay:system"
            }?.state,
            .ready
        )
    }

    private func makeReport(transactionID: String) -> ConnectionReport {
        ConnectionReport(
            transactionID: transactionID,
            plan: ConnectionPlan(
                schemaVersion: 3,
                scenario: ConnectionPlanScenario(
                    id: "scenario-target",
                    name: "Target"
                ),
                configurationFingerprint:
                    "runtime-v1:" + String(repeating: "a", count: 64),
                tasks: [
                    ConnectionPlanTask(
                        id: "underlay:system",
                        kind: "underlay",
                        name: "Underlay",
                        preparation: "capture"
                    ),
                    ConnectionPlanTask(
                        id: "line:test",
                        kind: "line",
                        name: "Test",
                        preparation: "runtime",
                        resourceID: "line-test",
                        resourceType: "direct"
                    ),
                    ConnectionPlanTask(
                        id: "dns:scenario",
                        kind: "dns",
                        name: "DNS",
                        preparation: "runtime"
                    ),
                    ConnectionPlanTask(
                        id: "data-plane:sing-box",
                        kind: "data_plane",
                        name: "Data Plane",
                        preparation: "runtime"
                    ),
                    ConnectionPlanTask(
                        id: "ingress:transparent-proxy",
                        kind: "ingress",
                        name: "Ingress",
                        preparation: "commit"
                    ),
                ]
            )
        )
    }
}
