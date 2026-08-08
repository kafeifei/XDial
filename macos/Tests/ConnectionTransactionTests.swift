import XCTest

final class ConnectionTransactionTests: XCTestCase {
    func testCancellationSignalIsThreadSafeAndSticky() {
        let cancellation = ConnectionCancellation()
        XCTAssertFalse(cancellation.isCancelled)

        let group = DispatchGroup()
        for _ in 0 ..< 100 {
            DispatchQueue.global().async(group: group) {
                cancellation.cancel()
                _ = cancellation.isCancelled
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(cancellation.isCancelled)
    }

    func testRollbackIsReverseOrderAndPreservesPersistentAssets() {
        var report = makeReport()
        for id in [
            "line:vpn",
            "line:tailscale",
            "dns:scenario",
            "data-plane:sing-box",
        ] {
            report.updateTask(id: id, state: .ready)
        }
        report.updateTask(
            id: "ingress:transparent-proxy",
            state: .committed
        )
        report.setState(.rollingBack)
        report.rollbackSessionTasks(
            systemTakeoverRemoved: true,
            cleanupComplete: true,
            finalState: .failed
        )

        let rollbackOrder = report.events.filter {
            $0.type == "task" && $0.state == "rolling_back"
        }.map(\.taskID)
        XCTAssertEqual(rollbackOrder, [
            "ingress:transparent-proxy",
            "data-plane:sing-box",
            "dns:scenario",
            "line:tailscale",
            "line:vpn",
        ])
        XCTAssertEqual(
            report.tasks.first { $0.id == "rule-set:cnip" }?.state,
            .pending
        )
        XCTAssertEqual(
            report.tasks.first { $0.id == "underlay:system" }?.state,
            .pending
        )
        XCTAssertTrue(report.rollbackComplete)
        XCTAssertTrue(report.systemTakeoverRemoved)
        XCTAssertEqual(report.state, .failed)
    }

    func testCommitGateRequiresEveryPreparedTaskAndPendingIngress() {
        var report = makeReport()
        for task in report.tasks where task.kind != "ingress" {
            report.updateTask(id: task.id, state: .ready)
        }
        XCTAssertTrue(report.isReadyForCommit)

        report.updateTask(id: "line:tailscale", state: .running)
        XCTAssertFalse(report.isReadyForCommit)
        XCTAssertEqual(
            report.incompletePrepareTaskIDs,
            ["line:tailscale"]
        )
    }

    func testFailurePointSurvivesRollbackReport() {
        var report = makeReport()
        report.updateTask(
            id: "line:tailscale",
            state: .running
        )
        report.fail(
            code: "tailscale-egress-unavailable",
            message: "Exit Node 无法承载真实流量",
            taskID: "line:tailscale"
        )
        report.setState(.rollingBack)
        report.rollbackSessionTasks(
            systemTakeoverRemoved: true,
            cleanupComplete: true,
            finalState: .failed
        )

        XCTAssertEqual(
            report.tasks.first { $0.id == "line:tailscale" }?.state,
            .failed
        )
        XCTAssertEqual(report.error?.taskID, "line:tailscale")
        XCTAssertEqual(
            report.events.map(\.sequence),
            Array(1 ... report.events.count)
        )
    }

    func testDiagnosticNotePreservesTaskAndTransactionState() {
        var report = makeReport()
        report.updateTask(id: "line:tailscale", state: .running)
        let taskState = report.tasks.first {
            $0.id == "line:tailscale"
        }?.state

        report.note(
            code: "tailscale-homederp-reselection",
            message: "重选 HomeDERP",
            taskID: "line:tailscale",
            facts: [
                "control_self_present": true,
                "control_self_home_matches_plan_original": false,
            ]
        )

        XCTAssertEqual(report.state, .planning)
        XCTAssertEqual(
            report.tasks.first { $0.id == "line:tailscale" }?.state,
            taskState
        )
        XCTAssertEqual(report.error, nil)
        XCTAssertEqual(report.events.last?.type, "diagnostic")
        XCTAssertEqual(
            report.events.last?.code,
            "tailscale-homederp-reselection"
        )
        XCTAssertEqual(
            report.events.last?.facts?["control_self_present"],
            true
        )
        XCTAssertEqual(
            report.events.last?.facts?[
                "control_self_home_matches_plan_original"
            ],
            false
        )
    }

    func testIncompleteCleanupNeverClaimsSuccessfulRollback() {
        var report = makeReport()
        report.updateTask(
            id: "data-plane:sing-box",
            state: .ready
        )
        report.fail(
            code: "prepare-failed",
            message: "数据面启动失败",
            taskID: "data-plane:sing-box"
        )
        report.setState(.rollingBack)
        report.failRollback(
            code: "rollback-runtime-timeout",
            message: "数据面停止超时",
            taskID: "data-plane:sing-box"
        )
        report.rollbackSessionTasks(
            systemTakeoverRemoved: true,
            cleanupComplete: false,
            finalState: .failed
        )

        XCTAssertFalse(report.rollbackComplete)
        XCTAssertEqual(report.error?.code, "prepare-failed")
        XCTAssertEqual(
            report.rollbackError?.code,
            "rollback-runtime-timeout"
        )
        XCTAssertEqual(
            report.tasks.first {
                $0.id == "data-plane:sing-box"
            }?.state, .failed
        )
    }

    func testSystemDisconnectCompletesDeferredProviderStop() {
        var report = preparedCommittedReport()
        report.setState(.rollingBack)
        report.rollbackSessionTasks(
            systemTakeoverRemoved: false,
            cleanupComplete: true,
            finalState: .cancelled
        )
        let providerReport = report

        XCTAssertTrue(report.confirmSystemDisconnectRollback())
        XCTAssertTrue(report.rollbackComplete)
        XCTAssertTrue(report.systemTakeoverRemoved)
        XCTAssertEqual(report.state, .cancelled)
        XCTAssertEqual(
            report.events.last?.code,
            "system-disconnect-confirmed"
        )
        XCTAssertTrue(
            report.isSystemDisconnectConfirmationSuccessor(
                of: providerReport
            )
        )
    }

    func testSystemDisconnectRepairsLegacySettingsRemovalError() {
        var report = preparedCommittedReport()
        report.setState(.rollingBack)
        report.failRollback(
            code: "rollback-network-settings-failed",
            message: "NEAgentErrorDomain error 1",
            taskID: "ingress:transparent-proxy"
        )
        report.rollbackSessionTasks(
            systemTakeoverRemoved: false,
            cleanupComplete: true,
            finalState: .cancelled
        )

        XCTAssertTrue(report.confirmSystemDisconnectRollback())
        XCTAssertNil(report.rollbackError)
        XCTAssertEqual(
            report.tasks.first {
                $0.id == "ingress:transparent-proxy"
            }?.state,
            .rolledBack
        )
        XCTAssertTrue(report.events.contains {
            $0.type == "rollback_error"
                && $0.code ==
                "rollback-network-settings-failed"
        })
    }

    func testSystemDisconnectDoesNotHideRuntimeCleanupFailure() {
        var report = preparedCommittedReport()
        report.setState(.rollingBack)
        report.failRollback(
            code: "rollback-runtime-timeout",
            message: "数据面停止超时",
            taskID: "data-plane:sing-box"
        )
        report.rollbackSessionTasks(
            systemTakeoverRemoved: false,
            cleanupComplete: false,
            finalState: .failed
        )

        XCTAssertFalse(report.confirmSystemDisconnectRollback())
        XCTAssertFalse(report.rollbackComplete)
        XCTAssertFalse(report.systemTakeoverRemoved)
        XCTAssertEqual(
            report.rollbackError?.code,
            "rollback-runtime-timeout"
        )
    }

    func testResourceRuntimeStateUsesPlanIdentityNotDisplayName() {
        let report = makeReport()

        XCTAssertEqual(
            ConnectionResourceRuntimeState.resolve(
                enabled: true,
                report: report,
                kind: "line",
                resourceID: "tailscale"
            ),
            .task(.pending)
        )
        XCTAssertEqual(
            ConnectionResourceRuntimeState.resolve(
                enabled: true,
                report: report,
                kind: "subscription",
                resourceID: "tailscale"
            ),
            .notPlanned
        )
        XCTAssertEqual(
            ConnectionResourceRuntimeState.resolve(
                enabled: false,
                report: report,
                kind: "line",
                resourceID: "tailscale"
            ),
            .task(.pending)
        )
        XCTAssertEqual(
            ConnectionResourceRuntimeState.resolve(
                enabled: true,
                report: nil,
                kind: "line",
                resourceID: "tailscale"
            ),
            .notObserved
        )

        var finishedReport = report
        finishedReport.setState(.failed)
        XCTAssertEqual(
            ConnectionResourceRuntimeState.resolve(
                enabled: false,
                report: finishedReport,
                kind: "line",
                resourceID: "tailscale"
            ),
            .disabled
        )
    }

    func testConfigurationFingerprintSurvivesReportRoundTrip() throws {
        let plan = ConnectionPlan(
            schemaVersion: 3,
            scenario: ConnectionPlanScenario(id: "scenario", name: "Test"),
            configurationFingerprint: "runtime-v1:abc123",
            tasks: []
        )
        let report = ConnectionReport(
            transactionID: "transaction",
            plan: plan
        )

        let encoded = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(
            ConnectionReport.self,
            from: encoded
        )

        XCTAssertEqual(
            decoded.configurationFingerprint,
            "runtime-v1:abc123"
        )
    }

    private func preparedCommittedReport() -> ConnectionReport {
        var report = makeReport()
        for task in report.tasks where [
            "line",
            "dns",
            "data_plane",
        ].contains(task.kind) {
            report.updateTask(id: task.id, state: .ready)
        }
        report.updateTask(
            id: "ingress:transparent-proxy",
            state: .committed
        )
        report.setState(.committed)
        return report
    }

    private func makeReport() -> ConnectionReport {
        let plan = ConnectionPlan(
            schemaVersion: 3,
            scenario: ConnectionPlanScenario(id: "scenario", name: "Test"),
            tasks: [
                task("underlay:system", kind: "underlay"),
                task("rule-set:cnip", kind: "rule_set"),
                task("line:vpn", kind: "line"),
                ConnectionPlanTask(
                    id: "line:tailscale",
                    kind: "line",
                    name: "Tailscale",
                    preparation: "test",
                    resourceID: "tailscale",
                    resourceType: "tailscale"
                ),
                task("dns:scenario", kind: "dns"),
                task("data-plane:sing-box", kind: "data_plane"),
                task(
                    "ingress:transparent-proxy",
                    kind: "ingress"
                ),
            ]
        )
        return ConnectionReport(
            transactionID: "transaction",
            plan: plan
        )
    }

    private func task(
        _ id: String,
        kind: String
    ) -> ConnectionPlanTask {
        ConnectionPlanTask(
            id: id,
            kind: kind,
            name: id,
            preparation: "test"
        )
    }
}
