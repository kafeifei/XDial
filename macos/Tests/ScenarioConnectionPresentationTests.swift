import XCTest

final class ScenarioConnectionPresentationTests: XCTestCase {
    private func report(_ types: [String], state: ConnectionTransactionState = .committed) -> ConnectionReport {
        var report = ConnectionReport(transactionID: "test", plan: ConnectionPlan(
            schemaVersion: 3,
            scenario: ConnectionPlanScenario(id: "office", name: "公司"),
            tasks: types.enumerated().map { index, type in
                ConnectionPlanTask(id: "line:\(index)", kind: "line", name: type,
                    preparation: "connect", resourceID: "\(index)", resourceType: type)
            }
        ))
        for task in report.tasks { report.updateTask(id: task.id, state: .ready) }
        report.setState(state)
        return report
    }

    func testOfficeNameDoesNotImplyVPNAuthentication() {
        let value = ScenarioConnectionPresentation.resolve(status: "connected", report: report(["direct"]))
        XCTAssertEqual(value, .direct)
        XCTAssertTrue(value.title({ zh, _ in zh }, statusText: "未连接").contains("未建立 VPN"))
    }

    func testOnlyCommittedReadyVPNIsConnected() {
        for state in [ConnectionTransactionState.preparing, .committing, .failed, .rolledBack] {
            XCTAssertEqual(ScenarioConnectionPresentation.resolve(status: "connected", report: report(["vpn"], state: state)), .unconfirmed)
        }
        var committed = report(["direct", "vpn"])
        XCTAssertEqual(ScenarioConnectionPresentation.resolve(status: "connected", report: committed), .vpn)
        committed.updateTask(id: "line:1", state: .failed)
        XCTAssertEqual(ScenarioConnectionPresentation.resolve(status: "connected", report: committed), .unconfirmed)
    }

    func testPreparingSwitchKeepsCommittedSourceStatus() {
        XCTAssertEqual(ScenarioConnectionPresentation.resolve(status: "connected", report: report(["direct"])), .direct)
        XCTAssertEqual(ScenarioConnectionPresentation.resolve(status: "connected", report: report(["vpn"])), .vpn)
    }

    func testInactiveIgnoresStaleSuccessfulReport() {
        XCTAssertEqual(ScenarioConnectionPresentation.resolve(status: "disconnected", report: report(["vpn"])), .inactive)
        XCTAssertEqual(ScenarioConnectionPresentation.resolve(status: "connecting", report: report(["vpn"])), .preparing)
    }

    func testMissingAndUnknownFactsNeverClaimDirectOrVPN() {
        XCTAssertEqual(ScenarioConnectionPresentation.resolve(status: "connected", report: nil), .unconfirmed)
        XCTAssertEqual(ScenarioConnectionPresentation.resolve(status: "connected", report: report([])), .unconfirmed)
        for type in ["", "selector", "trojan", "tailscale"] {
            XCTAssertEqual(ScenarioConnectionPresentation.resolve(status: "connected", report: report([type])), .routed)
        }
    }

    func testMissingReportExplainsUncertaintyWithoutLinkingToDetails() {
        // A connected engine alone cannot establish readiness when its report is missing.
        let value = ScenarioConnectionPresentation.resolve(status: "connected", report: nil)
        XCTAssertEqual(value, .unconfirmed)
        XCTAssertEqual(value.title({ zh, _ in zh }, statusText: "未连接"), "正在确认线路状态")
        XCTAssertEqual(value.title({ _, en in en }, statusText: "Not Connected"), "Checking line status")
        XCTAssertEqual(value.detail { zh, _ in zh }, "尚无完整的已提交线路状态，暂时无法确认线路是否就绪。")
        XCTAssertEqual(value.detail { _, en in en }, "Complete committed line status is unavailable. Line readiness cannot be confirmed yet.")
    }

    func testEngineLifecycleOverridesMissingOrStaleReports() {
        let phases: [(String, ScenarioConnectionPresentation, String, String)] = [
            ("connecting", .preparing, "正在连接…", "Connecting…"),
            ("disconnecting", .disconnecting, "正在断开…", "Disconnecting…"),
            ("reconnecting", .reconnecting, "正在重连…", "Reconnecting…"),
            ("disconnected", .inactive, "未连接", "Not Connected"),
            ("unknown", .unconfirmed, "正在确认线路状态", "Checking line status"),
        ]
        let reports: [ConnectionReport?] = [nil, report(["direct"]), report(["vpn"]), report(["vpn"], state: .failed)]
        for (status, expected, zhTitle, enTitle) in phases {
            for report in reports {
                let value = ScenarioConnectionPresentation.resolve(status: status, report: report)
                XCTAssertEqual(value, status == "disconnected" && report?.state == .failed ? .failed : expected, status)
                XCTAssertEqual(value.title({ zh, _ in zh }, statusText: zhTitle), zhTitle)
                XCTAssertEqual(value.title({ _, en in en }, statusText: enTitle), enTitle)
                if status == "disconnecting" || status == "reconnecting" {
                    XCTAssertFalse(value.detail { zh, _ in zh }.contains("尚未完成启用"))
                    XCTAssertFalse(value.detail { _, en in en }.contains("Activation is not complete"))
                }
            }
        }
    }

    func testWakeRecoveryUsesTheSamePhaseTextAsTheStatusBand() {
        let reports: [ConnectionReport?] = [nil, report(["vpn"])]
        for phase in WakeReconnectPhase.allCases {
            for status in ["connected", "disconnected", "disconnecting", "connecting", "reconnecting"] {
                for report in reports {
                    let value = ScenarioConnectionPresentation.resolve(
                        status: status, wakeReconnectPhase: phase, report: report)
                    XCTAssertEqual(value, .wakeReconnecting(phase))
                    XCTAssertEqual(value.title({ zh, _ in zh }, statusText: phase.zhStatusText), phase.zhStatusText)
                    XCTAssertEqual(value.title({ _, en in en }, statusText: phase.enStatusText), phase.enStatusText)
                    XCTAssertFalse(value.detail { zh, _ in zh }.contains("尚未完成启用"))
                }
            }
        }
    }

    func testDisconnectedFailuresDoNotClaimNetworkRecovery() {
        let failure = ConnectionReportError(code: "test", message: "连接失败", taskID: "line:0")
        var failed = report(["vpn"], state: .failed)
        failed.error = failure
        var rollbackFailed = report(["vpn"], state: .rolledBack)
        rollbackFailed.rollbackError = failure
        let cases: [(ConnectionReport?, String?)] = [
            (failed, nil), (rollbackFailed, nil),
            (report(["vpn"], state: .failed), nil), (nil, "Engine failure"),
        ]
        for (report, lastError) in cases {
            let value = ScenarioConnectionPresentation.resolve(status: "disconnected", lastError: lastError, report: report)
            XCTAssertEqual(value, .failed)
            XCTAssertEqual(value.title({ zh, _ in zh }, statusText: "连接失败"), "连接失败")
            XCTAssertEqual(value.title({ _, en in en }, statusText: "Connection failed"), "Connection failed")
            XCTAssertFalse(value.detail { zh, _ in zh }.contains("沿用原网络"))
            XCTAssertFalse(value.detail { _, en in en }.contains("Using your existing network"))
        }
    }

    func testLifecycleTitleUsesStatusBandTextIncludingTaskAndError() {
        let states: [ScenarioConnectionPresentation] = [
            .inactive, .preparing, .disconnecting, .reconnecting, .failed,
        ] + WakeReconnectPhase.allCases.map { .wakeReconnecting($0) }
        for state in states {
            for text in ["未连接", "正在连接…", "准备公司 VPN", "认证失败", "Not Connected", "Connecting…", "Preparing VPN", "Authentication failed"] {
                XCTAssertEqual(state.title({ zh, _ in zh }, statusText: text), text)
                XCTAssertEqual(state.title({ _, en in en }, statusText: text), text)
            }
        }
    }

    func testSubscriptionsAreRoutedWithOrWithoutDirectLines() {
        for types in [[], ["direct"]] {
            for strategy in ["selector", "urltest", "direct", "vpn", ""] {
                var committed = report(types)
                committed.tasks.append(ConnectionTaskReport(
                    id: "subscription:s", kind: "subscription", name: "Subscription", detail: "",
                    preparation: "start-with-data-plane", resourceID: "s", resourceType: strategy, state: .pending))
                committed.updateTask(id: "subscription:s", state: .ready)
                XCTAssertEqual(ScenarioConnectionPresentation.resolve(status: "connected", report: committed), .routed)
                for state in [ConnectionTaskState.pending, .running, .failed] {
                    var incomplete = committed
                    incomplete.updateTask(id: "subscription:s", state: state)
                    XCTAssertEqual(ScenarioConnectionPresentation.resolve(status: "connected", report: incomplete), .unconfirmed)
                }
            }
        }
    }

    func testVPNWithSubscriptionStillRequiresEveryTargetReady() {
        var committed = report(["vpn"])
        committed.tasks.append(ConnectionTaskReport(
            id: "subscription:s", kind: "subscription", name: "Subscription", detail: "",
            preparation: "start-with-data-plane", resourceID: "s", resourceType: "selector", state: .pending))
        XCTAssertEqual(ScenarioConnectionPresentation.resolve(status: "connected", report: committed), .unconfirmed)
        committed.updateTask(id: "subscription:s", state: .committed)
        XCTAssertEqual(ScenarioConnectionPresentation.resolve(status: "connected", report: committed), .vpn)
    }
}
