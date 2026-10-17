import AppKit
import XCTest

final class FeedbackAssistantTests: XCTestCase {
    func testDiscoveryRejectsMissingMismatchedAndNonexecutableBundles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Renamed Assistant.app")
        let executable = app.appendingPathComponent("Contents/MacOS/Assistant")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test executable".utf8).write(to: executable)
        let info: [String: Any] = ["CFBundleIdentifier": "com.xd.cindy", "CFBundleExecutable": "Assistant",
                                   "CFBundleDisplayName": "Renamed Cindy", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertTrue(FeedbackAssistant.discover(resolve: { _ in nil }).isEmpty)
        XCTAssertTrue(FeedbackAssistant.discover(resolve: { _ in app }).isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let discovered = FeedbackAssistant.discover(resolve: { _ in app })
        XCTAssertEqual(discovered.count, 1)
        XCTAssertEqual(discovered.first?.id, "com.xd.cindy")
        XCTAssertEqual(discovered.first?.name, "Renamed Cindy")
        XCTAssertEqual(discovered.first?.applicationURL, app)
    }

    @MainActor func testHandoffCopiesFileAndTextAndRemembersOnlySuccessfulOpen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "xdial-feedback-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let assistant = FeedbackAssistant(id: "com.xd.cindy", name: "Cindy", applicationURL: URL(fileURLWithPath: "/Applications/Cindy.app"))
        var opened: [FeedbackLaunchRequest] = []
        var finish: ((Bool) -> Void)?
        let coordinator = FeedbackCoordinator(defaults: defaults, directory: root, discover: { [assistant] }, open: {
            opened.append($0); finish = $1
        })
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        coordinator.refreshAssistants()
        coordinator.description = "现场说明"
        coordinator.continueInAssistant(english: false, pasteboard: pasteboard)
        XCTAssertEqual(opened.first?.applicationURL, assistant.applicationURL)
        XCTAssertTrue(opened.first?.urls.isEmpty == true)
        XCTAssertTrue(coordinator.isOpening)
        coordinator.continueInAssistant(english: false, pasteboard: pasteboard)
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(pasteboard.string(forType: .string)?.contains("现场说明") == true)
        XCTAssertNotNil(pasteboard.string(forType: .fileURL))
        XCTAssertNotNil(coordinator.fileURL)
        XCTAssertNil(defaults.string(forKey: "xdial.feedback.assistant"))
        finish?(true)
        XCTAssertEqual(coordinator.outcome, .opened("Cindy"))
        XCTAssertFalse(coordinator.isOpening)
        XCTAssertEqual(defaults.string(forKey: "xdial.feedback.assistant"), assistant.id)
    }

    @MainActor func testFailedOpenKeepsFileForManualHandoff() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = FeedbackAssistant(id: "test", name: "Test", applicationURL: root)
        let coordinator = FeedbackCoordinator(directory: root, discover: { [assistant] }, open: { _, complete in complete(false) })
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        coordinator.refreshAssistants()
        coordinator.continueInAssistant(english: true, pasteboard: pasteboard)
        XCTAssertEqual(coordinator.outcome, .openFailed)
        XCTAssertNotNil(coordinator.fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: coordinator.fileURL!.path))
    }

    @MainActor func testMissingAssistantDoesNotLaunchAnotherOrLoseDraft() {
        let first = FeedbackAssistant(id: "first", name: "First", applicationURL: URL(fileURLWithPath: "/first"))
        let second = FeedbackAssistant(id: "second", name: "Second", applicationURL: URL(fileURLWithPath: "/second"))
        var installed = [first, second]
        var opened = false
        let coordinator = FeedbackCoordinator(discover: { installed }, open: { _, _ in opened = true })
        coordinator.refreshAssistants()
        coordinator.selectedAssistantID = first.id
        coordinator.description = "保留这份反馈"
        installed = [second]
        coordinator.refreshAssistants()
        XCTAssertNil(coordinator.selectedAssistant)
        XCTAssertEqual(coordinator.outcome, .assistantUnavailable)
        coordinator.continueInAssistant(english: false)
        XCTAssertFalse(opened)
        XCTAssertEqual(coordinator.outcome, .openFailed)
        XCTAssertEqual(coordinator.description, "保留这份反馈")
        installed = []
        coordinator.refreshAssistants()
        XCTAssertTrue(coordinator.assistants.isEmpty)
        XCTAssertEqual(coordinator.description, "保留这份反馈")
    }

    @MainActor func testSuggestionOmitsRuntimeAndConfigurationIncludesItByDefault() {
        let coordinator = FeedbackCoordinator(discover: { [] })
        coordinator.snapshot = FeedbackRuntimeSnapshot(connectionStatus: "connected", installationState: .ready,
            hasUnappliedChanges: false, connection: nil, scenarioSwitch: nil)
        coordinator.kind = .suggestion
        XCTAssertFalse(coordinator.includeDiagnostics)
        XCTAssertNil(coordinator.package().runtime)
        coordinator.kind = .configuration
        XCTAssertTrue(coordinator.includeDiagnostics)
        XCTAssertNotNil(coordinator.package().runtime)
    }

    @MainActor func testInstallingFirstAssistantResumesTheExistingDraft() {
        var installed: [FeedbackAssistant] = []
        let coordinator = FeedbackCoordinator(discover: { installed })
        coordinator.refreshAssistants()
        coordinator.description = "安装前已填写的建议"
        coordinator.kind = .suggestion
        installed = [FeedbackAssistant(id: "com.xd.cindy", name: "Cindy", applicationURL: URL(fileURLWithPath: "/Cindy.app"))]
        coordinator.refreshAssistants()
        XCTAssertEqual(coordinator.selectedAssistantID, "com.xd.cindy")
        XCTAssertEqual(coordinator.description, "安装前已填写的建议")
        XCTAssertEqual(coordinator.kind, .suggestion)
        XCTAssertFalse(coordinator.includeDiagnostics)
    }

    @MainActor func testExportFailureDoesNotLaunchOrReplaceClipboard() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = FeedbackAssistant(id: "test", name: "Test", applicationURL: root)
        var opened = false
        let coordinator = FeedbackCoordinator(directory: root, discover: { [assistant] }, open: { _, _ in opened = true })
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("previous contents", forType: .string)
        coordinator.refreshAssistants()
        coordinator.continueInAssistant(english: false, pasteboard: pasteboard)
        XCTAssertFalse(opened)
        XCTAssertEqual(coordinator.outcome, .exportFailed)
        XCTAssertEqual(pasteboard.string(forType: .string), "previous contents")
    }

    @MainActor func testCindyOpensTheNewFeedbackDirectoryAsAConversation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = FeedbackAssistant(id: "com.xd.cindy", name: "Cindy", applicationURL: root,
                                          conversationEntry: .folder)
        var request: FeedbackLaunchRequest?
        let coordinator = FeedbackCoordinator(directory: root, discover: { [assistant] }, open: { value, done in
            request = value
            done(true)
        })
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        coordinator.refreshAssistants()
        coordinator.description = "新对话现场"
        coordinator.continueInAssistant(english: false, pasteboard: pasteboard)
        XCTAssertEqual(request?.applicationURL, assistant.applicationURL)
        XCTAssertEqual(request?.urls, [coordinator.fileURL!.deletingLastPathComponent()])
        XCTAssertEqual(coordinator.outcome, .conversationRequested("Cindy", .folder))
        XCTAssertTrue(try String(contentsOf: coordinator.fileURL!).contains("新对话现场"))
    }

    func testCodexNewConversationEncodesWorkspaceAndOnlyPrefillsShortFileInstruction() throws {
        let assistant = FeedbackAssistant(id: "com.openai.codex", name: "Codex",
            applicationURL: URL(fileURLWithPath: "/Applications/Renamed.app"), conversationEntry: .codex)
        let file = URL(fileURLWithPath: "/tmp/诊断 + & context?#/XDial-feedback.txt")
        let prompt = FeedbackPackage(kind: .problem, description: "", runtime: nil).openingPrompt(english: false)
        let request = assistant.launchRequest(file: file, prompt: prompt)
        XCTAssertEqual(request.applicationURL, assistant.applicationURL)
        XCTAssertEqual(request.urls.count, 1)
        let parts = try XCTUnwrap(URLComponents(url: request.urls[0], resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.scheme, "codex")
        XCTAssertEqual(parts.host, "threads")
        XCTAssertEqual(parts.path, "/new")
        XCTAssertFalse(parts.percentEncodedQuery?.contains("+") == true)
        XCTAssertTrue(parts.percentEncodedQuery?.contains("%2B") == true)
        let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["path"], file.deletingLastPathComponent().path)
        XCTAssertEqual(query["mode"], "work")
        XCTAssertTrue(query["prompt"]?.contains("XDial-feedback.txt") == true)
        XCTAssertEqual(query["prompt"], prompt)
        XCTAssertLessThan(request.urls[0].absoluteString.count, 2_000)
        XCTAssertEqual(Set(query.keys), ["path", "prompt", "mode"])
    }

    func testDiscoveryEnablesOnlyAdvertisedConversationTransports() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var bundles: [String: URL] = [:]
        for (id, extra) in [
            ("com.xd.cindy", ["CFBundleDocumentTypes": [["LSItemContentTypes": ["public.folder"]]]] as [String: Any]),
            ("com.openai.codex", ["CFBundleURLTypes": [["CFBundleURLSchemes": ["codex"]]]] as [String: Any]),
        ] {
            let app = root.appendingPathComponent(id + ".app")
            let executable = app.appendingPathComponent("Contents/MacOS/Assistant")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("test".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            var info = extra
            info["CFBundleIdentifier"] = id
            info["CFBundleExecutable"] = "Assistant"
            info["CFBundlePackageType"] = "APPL"
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
            bundles[id] = app
        }
        let assistants = FeedbackAssistant.discover(resolve: { bundles[$0] })
        XCTAssertEqual(assistants.count, 2)
        XCTAssertEqual(assistants.first { $0.id == "com.xd.cindy" }?.conversationEntry, .folder)
        XCTAssertEqual(assistants.first { $0.id == "com.openai.codex" }?.conversationEntry, .codex)
    }

    private func clickedFailure() -> ConnectionReport {
        let plan = ConnectionPlan(schemaVersion: 3, scenario: .init(id: "PRIVATE_ID", name: "PRIVATE_NAME"),
                                  configurationFingerprint: "PRIVATE_FINGERPRINT", tasks: [])
        var report = ConnectionReport(transactionID: "PRIVATE_TRANSACTION", plan: plan)
        report.fail(code: "engine-start-failed", message: "PRIVATE_RAW_ERROR")
        report.setState(.failed)
        return report
    }

    @MainActor func testClickedFailureSurvivesSnapshotRefreshAndHonorsDiagnosticOptOut() throws {
        let coordinator = FeedbackCoordinator(discover: { [] })
        coordinator.begin(context: .connectionFailure(clickedFailure()))
        coordinator.snapshot = FeedbackRuntimeSnapshot(connectionStatus: "connected", installationState: .ready,
            hasUnappliedChanges: false, connection: nil, scenarioSwitch: nil)
        XCTAssertEqual(coordinator.kind, .diagnosis)
        var text = try coordinator.package().text(english: false)
        XCTAssertTrue(text.contains("engine-start-failed"))
        XCTAssertTrue(text.contains("事务状态=failed"))
        XCTAssertTrue(text.contains("connected"))
        XCTAssertFalse(text.contains("PRIVATE"))

        coordinator.includeDiagnostics = false
        text = try coordinator.package().text(english: false)
        XCTAssertFalse(text.contains("操作：建立 XDial 连接"))
        XCTAssertEqual(coordinator.package().context.origin, .general)
        XCTAssertFalse(coordinator.package().openingPrompt(english: false).contains("建立连接时出错"))
        XCTAssertFalse(text.contains("engine-start-failed"))
        XCTAssertFalse(text.contains("rollback_complete"))
        XCTAssertFalse(text.contains("connected"))
        coordinator.includeDiagnostics = true
        XCTAssertTrue(try coordinator.package().text(english: false).contains("engine-start-failed"))
    }

    @MainActor func testOrdinaryEntryAndSuggestionClearOldFailureWithoutLosingUserText() throws {
        let coordinator = FeedbackCoordinator(discover: { [] })
        coordinator.description = "我想聊其他建议"
        coordinator.begin(context: .connectionFailure(clickedFailure()))
        coordinator.begin()
        XCTAssertEqual(coordinator.context.origin, .general)
        XCTAssertEqual(coordinator.kind, .problem)
        XCTAssertFalse(try coordinator.package().text(english: false).contains("engine-start-failed"))
        XCTAssertEqual(coordinator.description, "我想聊其他建议")

        coordinator.begin(context: .connectionFailure(clickedFailure()))
        coordinator.kind = .suggestion
        XCTAssertEqual(coordinator.context.origin, .general)
        XCTAssertFalse(coordinator.includeDiagnostics)
        XCTAssertFalse(coordinator.package().openingPrompt(english: false).contains("建立连接时出错"))
        XCTAssertTrue(coordinator.package().openingPrompt(english: false).contains("产品建议"))
    }
}
