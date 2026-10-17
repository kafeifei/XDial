import XCTest

final class FeedbackPackageTests: XCTestCase {
    private func failureReport(message: String = "PRIVATE_PASSWORD") -> ConnectionReport {
        let plan = ConnectionPlan(schemaVersion: 3,
            scenario: ConnectionPlanScenario(id: "PRIVATE_SCENARIO_ID", name: "PRIVATE_SCENARIO_NAME"),
            configurationFingerprint: "PRIVATE_FINGERPRINT", tasks: [
                ConnectionPlanTask(id: "PRIVATE_TASK", kind: "PRIVATE_KIND", name: "PRIVATE_NAME",
                    detail: "PRIVATE_DETAIL", preparation: "PRIVATE_PREPARATION", resourceID: "PRIVATE_RESOURCE",
                    resourceType: "PRIVATE_RESOURCE_TYPE")
            ])
        var report = ConnectionReport(transactionID: "PRIVATE_TRANSACTION", plan: plan)
        report.fail(code: "PRIVATE_CODE", message: message, taskID: "PRIVATE_TASK")
        report.setState(.failed)
        report.events.append(ConnectionReportEvent(sequence: 2, timestamp: Date(), type: "PRIVATE_TYPE",
            state: "PRIVATE_STATE", taskID: "PRIVATE_TASK", code: "PRIVATE_CODE", message: "PRIVATE_ERROR", facts: ["PRIVATE_KEY": true]))
        return report
    }

    private func snapshot() -> FeedbackRuntimeSnapshot {
        let report = failureReport()
        let projection = HostScenarioSwitchProjection(status: "PRIVATE_STATUS", fromScenarioID: "PRIVATE_SOURCE",
            toScenarioID: "PRIVATE_TARGET", sourceCommittedTransactionID: "source", candidateTransactionID: "target",
            activeCommittedTransactionID: "source", inFlight: false, candidateReport: report,
            reusedLineIDs: ["PRIVATE_LINE"], code: "PRIVATE_CODE", message: "PRIVATE_MESSAGE")
        return FeedbackRuntimeSnapshot(connectionStatus: "PRIVATE_STATUS", installationState: .ready,
            hasUnappliedChanges: true, connection: report, scenarioSwitch: projection)
    }

    func testRuntimeSnapshotStripsIdentitiesMessagesAndUnknownFields() throws {
        let data = try JSONEncoder().encode(snapshot())
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("PRIVATE"))
        XCTAssertFalse(text.contains("transactionID"))
        XCTAssertFalse(text.contains("configurationFingerprint"))
        XCTAssertTrue(text.contains("unclassified"))
        XCTAssertTrue(text.contains("source"))
        XCTAssertEqual(snapshot().connectionStatus, "unknown")
    }

    func testRuntimeCanBeOmittedAndUserDescriptionIsPreserved() throws {
        let package = FeedbackPackage(kind: .suggestion, description: "用户自己填写的描述 PRIVATE_USER_TEXT", runtime: nil)
        let text = try package.text(english: false)
        XCTAssertTrue(text.contains("用户自己填写的描述 PRIVATE_USER_TEXT"))
        XCTAssertFalse(text.contains("connectionStatus"))
        XCTAssertFalse(text.contains("白名单运行事实"))
        XCTAssertTrue(text.contains("功能建议"))
        XCTAssertTrue(try package.text(english: true).contains("feature suggestion"))
    }

    func testConfigurationTaskExplainsSupportedEditingAndSeparateApply() throws {
        let text = try FeedbackPackage(kind: .configuration, description: "办公域名走指定线路", runtime: snapshot()).text(english: false)
        XCTAssertTrue(text.contains("不要直接修改加密配置库或钥匙串"))
        XCTAssertTrue(text.contains("由用户决定何时应用并重连"))
        XCTAssertTrue(text.contains("办公域名走指定线路"))
        XCTAssertFalse(text.contains("PRIVATE"))
    }

    func testDescriptionAndReportEventsAreBounded() throws {
        let package = FeedbackPackage(kind: .problem, description: String(repeating: "长", count: 20_000), runtime: nil)
        XCTAssertEqual(package.description.count, FeedbackPackage.descriptionLimit)
        let plan = ConnectionPlan(schemaVersion: 3, scenario: ConnectionPlanScenario(id: "id", name: "name"),
                                  configurationFingerprint: "fingerprint", tasks: [])
        var report = ConnectionReport(transactionID: "id", plan: plan)
        for sequence in 0..<50 {
            report.events.append(ConnectionReportEvent(sequence: sequence, timestamp: Date(), type: "task",
                state: "running", taskID: "PRIVATE", code: "", message: "PRIVATE", facts: nil))
        }
        let summary = FeedbackRuntimeSnapshot.Report(report)
        XCTAssertEqual(summary.recentEvents.count, 20)
    }

    func testFilesArePrivateAndRetriesDoNotOverwriteEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = FeedbackPackage(kind: .diagnosis, description: "问题", runtime: snapshot())
        let first = try package.write(text: "first", under: root)
        let second = try package.write(text: "second", under: root)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try String(contentsOf: first), "first")
        XCTAssertEqual(try String(contentsOf: second), "second")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: first.deletingLastPathComponent().path)[.posixPermissions] as? Int, 0o700)
    }

    func testOrdinaryHelpInvitesConversationAndRespondsToExistingDescription() throws {
        let blank = FeedbackPackage(kind: .problem, description: " \n ", runtime: snapshot())
        let text = try blank.text(english: false)
        XCTAssertFalse(blank.hasDescription)
        XCTAssertTrue(text.contains("使用 XDial 时遇到什么麻烦了？"))
        XCTAssertTrue(text.contains("等待用户说明；暂不根据快照展开故障诊断"))
        XCTAssertFalse(text.contains("已捕获的错误现场："))
        XCTAssertFalse(text.contains("用户描述（用户自行填写）："))
        XCTAssertFalse(text.contains("用户尚未补充文字说明"))
        XCTAssertTrue(try blank.text(english: true).contains("What would you like help with in XDial?"))

        let supplied = FeedbackPackage(kind: .problem, description: "PRIVATE_USER_TEXT", runtime: nil)
        XCTAssertTrue(try supplied.text(english: false).contains("先回应具体内容"))
        XCTAssertFalse(try supplied.text(english: false).contains("先用下面这样简短的邀请开场"))
        XCTAssertFalse(supplied.openingPrompt(english: false).contains("PRIVATE_USER_TEXT"))
        let suggestion = FeedbackPackage(kind: .suggestion, description: "", runtime: nil)
        XCTAssertTrue(try suggestion.text(english: false).contains("你希望 XDial 哪些地方更好用？"))
    }

    func testErrorContextCarriesOperationExpectedResultAndSafeSymptom() throws {
        let report = failureReport(message: "lookup PRIVATE_HOST: SERVFAIL PRIVATE_PASSWORD")
        let projection = HostScenarioSwitchProjection(status: "failed", fromScenarioID: "PRIVATE_SOURCE",
            toScenarioID: "PRIVATE_TARGET", sourceCommittedTransactionID: "source", candidateTransactionID: "target",
            activeCommittedTransactionID: "source", inFlight: false, candidateReport: report,
            reusedLineIDs: [], code: "switch-failed", message: "PRIVATE_MESSAGE")
        for context in [FeedbackContext.connectionFailure(report), .scenarioSwitchFailure(projection)] {
            let package = FeedbackPackage(kind: .diagnosis, description: "", runtime: nil, context: context)
            let text = try package.text(english: false)
            XCTAssertTrue(text.contains("预期："))
            XCTAssertTrue(text.contains("服务器域名解析失败"))
            XCTAssertTrue(text.contains("事务状态=failed"))
            XCTAssertTrue(text.contains("不要让用户重新讲一遍"))
            XCTAssertFalse(text.contains("PRIVATE"))
            XCTAssertFalse(package.openingPrompt(english: false).contains("PRIVATE"))
        }
        let text = try XCTUnwrap(FeedbackContext.scenarioSwitchFailure(projection).text(english: false))
        XCTAssertTrue(text.contains("旧连接仍在使用"))
        XCTAssertTrue(text.contains("switch-failed"))
    }

    func testOpeningPromptKeepsEvidenceInTheFile() {
        let package = FeedbackPackage(kind: .diagnosis, description: "PRIVATE_USER_TEXT", runtime: snapshot(),
                                      context: .connectionFailure(failureReport()))
        for english in [false, true] {
            let prompt = package.openingPrompt(english: english)
            XCTAssertLessThan(prompt.count, 150)
            XCTAssertTrue(prompt.contains("XDial-feedback.txt"))
            XCTAssertFalse(prompt.contains("PRIVATE"))
            XCTAssertFalse(prompt.contains("rollback"))
        }
    }

    func testUnknownActiveConnectionDoesNotClaimOldConnectionWasRetained() throws {
        let projection = HostScenarioSwitchProjection(status: "failed", fromScenarioID: "source-scenario",
            toScenarioID: "target-scenario", sourceCommittedTransactionID: "source", candidateTransactionID: "target",
            activeCommittedTransactionID: "", inFlight: false, candidateReport: failureReport(),
            reusedLineIDs: [], code: "switch-failed", message: "PRIVATE_MESSAGE")
        let text = try XCTUnwrap(FeedbackContext.scenarioSwitchFailure(projection).text(english: false))
        XCTAssertTrue(text.contains("当前承载连接的关系尚未确认"))
        XCTAssertFalse(text.contains("切换报告显示：旧连接仍在使用"))
    }
}
