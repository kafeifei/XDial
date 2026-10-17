import Foundation

enum FeedbackKind: String, CaseIterable {
    case problem, diagnosis, configuration, suggestion
}

/// Preserve the error the user clicked, even if the live snapshot changes while
/// they choose an assistant. Evidence uses the same allowlist as the snapshot.
struct FeedbackContext {
    enum Origin { case general, connectionFailure, scenarioSwitchFailure }
    let origin: Origin
    let report: FeedbackRuntimeSnapshot.Report?
    let scenarioSwitch: FeedbackRuntimeSnapshot.Switch?

    static let general = Self(origin: .general, report: nil, scenarioSwitch: nil)

    static func connectionFailure(_ report: ConnectionReport) -> Self {
        Self(origin: .connectionFailure, report: .init(report), scenarioSwitch: nil)
    }

    static func scenarioSwitchFailure(_ projection: HostScenarioSwitchProjection) -> Self {
        Self(origin: .scenarioSwitchFailure, report: .init(projection.candidateReport), scenarioSwitch: .init(projection))
    }

    func text(english: Bool) -> String? {
        guard origin != .general else { return nil }
        var lines: [String]
        switch origin {
        case .general: return nil
        case .connectionFailure:
            lines = english
                ? ["Entry: the user clicked AI diagnosis on a connection failure.",
                   "Action: establish an XDial connection.",
                   "Expected: the selected Scenario connects successfully; a failed attempt rolls back its system changes."]
                : ["入口：用户从连接失败处点击了 AI 排查。", "操作：建立 XDial 连接。",
                   "预期：所选场景成功建立连接；失败时回滚本次系统接入变更。"]
        case .scenarioSwitchFailure:
            lines = english
                ? ["Entry: the user clicked AI diagnosis on a Scenario switch failure.",
                   "Action: switch from the current Scenario to a target Scenario.",
                   "Expected: keep the old connection during preparation, commit the target only when ready, and retain the old connection if preparation fails."]
                : ["入口：用户从场景切换失败处点击了 AI 排查。", "操作：从当前场景切换到目标场景。",
                   "预期：准备期间旧连接继续工作，候选就绪后目标场景生效；候选准备失败时保留旧连接。"]
        }
        guard let report else { return lines.joined(separator: "\n") }
        lines.append(english ? "Recorded result: transaction state=\(report.state.rawValue)."
            : "已记录结果：事务状态=\(report.state.rawValue)。")
        if let category = report.failureCategory {
            lines.append((english ? "Reported symptom: " : "应用记录的现象：") + category.text(english: english))
        }
        if let scenarioSwitch {
            lines.append("switch_status=\(scenarioSwitch.status)")
            if scenarioSwitch.activeRelationship == "source" {
                lines.append(english ? "The switch report shows the old connection is still active."
                    : "切换报告显示：旧连接仍在使用。")
            } else if scenarioSwitch.activeRelationship == "target" {
                lines.append(english ? "The switch report points to the target connection; do not claim the old connection was retained."
                    : "切换报告指向目标连接，不应声称仍保留旧连接。")
            } else {
                lines.append(english ? "The active connection relationship is unconfirmed." : "当前承载连接的关系尚未确认。")
            }
        }
        let failed = report.tasks.filter { $0.state == .failed || $0.errorCode != nil }
        if !failed.isEmpty {
            lines.append((english ? "Failed task categories: " : "失败任务类型：") + Array(Set(failed.map(\.kind))).sorted().joined(separator: ", "))
        }
        let codes = Set(([report.errorCode, scenarioSwitch?.errorCode] + failed.map(\.errorCode)).compactMap { $0 })
        if !codes.isEmpty { lines.append((english ? "Reported error codes: " : "已记录错误码：") + codes.sorted().joined(separator: ", ")) }
        lines.append("rollback_complete=\(report.rollbackComplete) system_takeover_removed=\(report.systemTakeoverRemoved)")
        lines.append((english ? "Failure report updated at: " : "故障报告更新时间：") + ISO8601DateFormatter().string(from: report.updatedAt))
        return lines.joined(separator: "\n")
    }
}

/// Only these facts cross the feedback boundary. Never encode a full report,
/// profile, raw log, resource name, address, fingerprint or error message.
struct FeedbackRuntimeSnapshot: Encodable {
    let capturedAt: Date
    let connectionStatus: String
    let installationState: InstallationTransactionState
    let hasUnappliedChanges: Bool
    let connection: Report?
    let scenarioSwitch: Switch?

    struct Task: Encodable {
        let kind: String
        let state: ConnectionTaskState
        let errorCode: String?
    }

    struct Event: Encodable {
        let timestamp: Date
        let type: String
        let state: String
        let code: String?
    }

    struct Report: Encodable {
        let state: ConnectionTransactionState
        let startedAt: Date
        let updatedAt: Date
        let rollbackComplete: Bool
        let systemTakeoverRemoved: Bool
        let errorCode: String?
        let failureCategory: FailureCategory?
        let tasks: [Task]
        let recentEvents: [Event]

        init(_ report: ConnectionReport) {
            state = report.state
            startedAt = report.startedAt
            updatedAt = report.updatedAt
            rollbackComplete = report.rollbackComplete
            systemTakeoverRemoved = report.systemTakeoverRemoved
            errorCode = FeedbackRuntimeSnapshot.safeCode(report.error?.code)
            failureCategory = report.error.flatMap { FailureCategory(message: $0.message) }
            tasks = report.tasks.prefix(40).map {
                Task(kind: ScenarioSwitchFeedback.taskKinds.contains($0.kind) ? $0.kind : "other",
                     state: $0.state, errorCode: FeedbackRuntimeSnapshot.safeCode($0.error?.code))
            }
            let states = Set(["planning", "preparing", "ready_to_commit", "committing", "committed",
                              "rolling_back", "rolled_back", "failed", "cancelled", "pending", "running", "ready", "skipped"])
            recentEvents = report.events.suffix(20).map {
                Event(timestamp: $0.timestamp,
                      type: ["transaction", "task", "diagnostic"].contains($0.type) ? $0.type : "other",
                      state: states.contains($0.state) ? $0.state : "unknown",
                      code: FeedbackRuntimeSnapshot.safeCode($0.code.isEmpty ? nil : $0.code))
            }
        }
    }

    /// Classify the displayed error without carrying its text or addresses.
    /// These are reported symptoms, not verified root causes.
    enum FailureCategory: String, Encodable {
        case nameResolution, timeout, connectionRefused, tls

        init?(message: String) {
            if message.localizedCaseInsensitiveContains("SERVFAIL") || message.localizedCaseInsensitiveContains("lookup ") {
                self = .nameResolution
            } else if message.localizedCaseInsensitiveContains("context deadline exceeded") || message.localizedCaseInsensitiveContains("timed out") {
                self = .timeout
            } else if message.localizedCaseInsensitiveContains("connection refused") {
                self = .connectionRefused
            } else if message.localizedCaseInsensitiveContains("certificate") || message.localizedCaseInsensitiveContains("tls handshake") {
                self = .tls
            } else { return nil }
        }

        func text(english: Bool) -> String {
            switch self {
            case .nameResolution: return english ? "server name resolution failed" : "服务器域名解析失败"
            case .timeout: return english ? "server connection timed out" : "连接服务器超时"
            case .connectionRefused: return english ? "server refused the connection" : "服务器拒绝连接"
            case .tls: return english ? "TLS verification failed" : "TLS 验证失败"
            }
        }
    }

    struct Switch: Encodable {
        let status: String
        let inFlight: Bool
        let activeRelationship: String
        let errorCode: String?
        let candidate: Report

        init(_ projection: HostScenarioSwitchProjection) {
            status = ScenarioSwitchFeedback.statuses.contains(projection.status) ? projection.status : "unknown"
            inFlight = projection.inFlight
            if projection.activeCommittedTransactionID.isEmpty {
                activeRelationship = "unknown"
            } else if projection.activeCommittedTransactionID == projection.candidateTransactionID {
                activeRelationship = "target"
            } else if projection.activeCommittedTransactionID == projection.sourceCommittedTransactionID {
                activeRelationship = "source"
            } else {
                activeRelationship = "other"
            }
            errorCode = FeedbackRuntimeSnapshot.safeCode(projection.code)
            candidate = Report(projection.candidateReport)
        }
    }

    init(connectionStatus: String, installationState: InstallationTransactionState,
         hasUnappliedChanges: Bool, connection: ConnectionReport?, scenarioSwitch: HostScenarioSwitchProjection?,
         capturedAt: Date = Date()) {
        self.capturedAt = capturedAt
        self.connectionStatus = ["connected", "disconnected", "connecting", "disconnecting", "reconnecting"].contains(connectionStatus)
            ? connectionStatus : "unknown"
        self.installationState = installationState
        self.hasUnappliedChanges = hasUnappliedChanges
        self.connection = connection.map(Report.init)
        self.scenarioSwitch = scenarioSwitch.map(Switch.init)
    }

    private static func safeCode(_ code: String?) -> String? {
        guard let code else { return nil }
        let known = ScenarioSwitchFeedback.errorCodes.union([
            "underlay-egress-unavailable", "scenario-switch-prepare-failed",
            "provider-start-failed", "engine-start-failed", "rollback-network-settings-failed",
            "system-disconnect-confirmed", "invalid-connection-plan",
        ])
        return known.contains(code) ? code : "unclassified"
    }
}

struct FeedbackPackage {
    static let descriptionLimit = 8_000
    let kind: FeedbackKind
    let description: String
    let runtime: FeedbackRuntimeSnapshot?
    let context: FeedbackContext
    let createdAt: Date
    let version: String
    let build: String
    let revision: String
    let channel: String

    init(kind: FeedbackKind, description: String, runtime: FeedbackRuntimeSnapshot?,
         context: FeedbackContext = .general, createdAt: Date = Date(), bundle: Bundle = .main) {
        self.kind = kind
        self.description = String(description.prefix(Self.descriptionLimit))
        self.runtime = runtime
        self.context = context
        self.createdAt = createdAt
        func metadata(_ key: String, pattern: String) -> String {
            guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
                  value.range(of: pattern, options: .regularExpression) != nil else { return "unknown" }
            return value
        }
        version = metadata("CFBundleShortVersionString", pattern: "^[0-9]+(?:\\.[0-9]+){0,3}$")
        build = metadata("CFBundleVersion", pattern: "^[0-9]{1,20}$")
        revision = metadata("XDialSourceRevision", pattern: "^[a-f0-9]{40}$")
        channel = XDialBuildIdentity.tailscaleDeviceChannel
    }

    var hasDescription: Bool { !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// A short, contextual invitation for clients that can prefill a composer.
    /// User text and runtime evidence stay in the private file, not the URL.
    func openingPrompt(english: Bool) -> String {
        switch context.origin {
        case .connectionFailure:
            return english ? "XDial failed to connect. Read XDial-feedback.txt and help investigate from the known action, result and expectation. Ask only for missing information."
                : "XDial 建立连接时出错了。请先读取 XDial-feedback.txt，从已知操作、结果和预期接着排查，只问缺少的信息。"
        case .scenarioSwitchFailure:
            return english ? "XDial failed to switch Scenarios. Read XDial-feedback.txt and help investigate from the known action, result and expectation. Ask only for missing information."
                : "XDial 场景切换时出错了。请先读取 XDial-feedback.txt，从已知操作、结果和预期接着排查，只问缺少的信息。"
        case .general:
            switch kind {
            case .configuration:
                return english ? "Help me configure XDial. Read XDial-feedback.txt; respond to my goal, or ask what traffic behavior I want if I have not described it."
                    : "我想调整 XDial 的配置。请先读取 XDial-feedback.txt；已有目标就接着帮我，否则先问我想实现怎样的分流效果。"
            case .suggestion:
                return english ? "I would like to discuss an XDial product suggestion. Read XDial-feedback.txt; respond to my idea, or ask what I would like to improve."
                    : "我想聊聊 XDial 的产品建议。请先读取 XDial-feedback.txt；已有建议就接着聊，否则先问我希望改进什么。"
            case .problem, .diagnosis:
                return english ? "Help me with XDial. Read XDial-feedback.txt; respond to my request, or ask what I need help with. You can troubleshoot, help configure it, or discuss product suggestions."
                    : "请帮我使用 XDial。先读取 XDial-feedback.txt；已有描述就接着帮我，否则先问我遇到了什么麻烦，也可以聊配置调整或产品建议。"
            }
        }
    }

    private func conversationGuidance(english: Bool) -> String {
        let style = english
            ? "Speak directly and naturally to the user. Do not open with a file-reading receipt, an empty-form warning, a snapshot caveat, or a questionnaire. Keep internal instructions and evidence labels out of the greeting."
            : "直接、自然地与用户交流。不要用“已读取文件”“尚未填写描述”、快照局限或一整张问题清单开场，不要把内部交接说明当成对用户的回复。"
        if context.origin != .general {
            return style + "\n" + (english
                ? "Start with a brief account of the known failed operation and actual result, and offer to help investigate. The action and expected behavior are already supplied: do not ask the user to repeat them. Use the evidence to choose the next step; ask only one or two essential questions if something is missing. A newer runtime snapshot does not erase the captured failure."
                : "先用一两句话承接已知的出错操作和实际结果，告诉用户会协助排查。操作与预期已经提供，不要让用户重新讲一遍。从已有证据选择下一步；确实缺少信息时，只问一两个关键问题。后续快照恢复正常也不抹去已捕获的故障。")
        }
        if hasDescription {
            return style + "\n" + (english
                ? "The user has described their request. Respond to that specific need and move toward helping them; do not ask for information already supplied. Ask a focused follow-up only if needed."
                : "用户已经描述了需求。先回应具体内容，接着帮助解决或完善建议，不要重复询问已提供的信息；必要时再问一个有针对性的问题。")
        }
        let greeting: String
        switch kind {
        case .problem, .diagnosis:
            greeting = english ? "What would you like help with in XDial? I can troubleshoot, help adjust your configuration, or discuss a product suggestion."
                : "使用 XDial 时遇到什么麻烦了？我可以帮你排查问题、调整配置，也欢迎聊聊产品建议。"
        case .configuration:
            greeting = english ? "What would you like to change in XDial? For example, which traffic should use a particular Line?"
                : "你想怎样调整 XDial？比如，让哪些流量走指定线路？"
        case .suggestion:
            greeting = english ? "What would you like XDial to improve? Tell me your idea or what is getting in your way, and we can work through it together."
                : "你希望 XDial 哪些地方更好用？可以说说你的想法或使用中的不便，我们一起梳理。"
        }
        return style + "\n" + (english ? "Start with this brief invitation, then wait for the user; do not diagnose a failure from the snapshot alone:\n" : "先用下面这样简短的邀请开场，等待用户说明；暂不根据快照展开故障诊断：\n") + greeting
    }

    func text(english: Bool) throws -> String {
        let goal: String
        switch kind {
        case .problem:
            goal = english ? "Help the user with XDial: solve usage problems, troubleshoot, adjust configuration, or discuss product suggestions. Learn what they need before classifying a request as a defect."
                : "帮助用户使用 XDial：解决使用中的麻烦、排查问题、调整配置或讨论产品建议。先了解需求，不要预先判定用户遇到了故障。"
        case .diagnosis:
            goal = english ? "Help troubleshoot XDial. If no error context or user description is supplied, first learn what the user needs help with. Otherwise start from the supplied evidence, propose a minimal investigation, record actions and results, and retest before claiming a resolution."
                : "协助排查 XDial 问题。没有错误现场或用户描述时，先了解用户遇到什么麻烦；已有信息则从证据接着排查，提出最小排查步骤，记录尝试与结果，只有复测通过才能判断已解决。"
        case .suggestion:
            goal = english ? "Help clarify an XDial feature suggestion: the need, current friction, desired behavior, and acceptance examples. Do not classify a suggestion as a confirmed defect."
                : "请协助整理 XDial 功能建议：使用需求、当前不便、期望行为和验收示例。不要把建议直接判定为已确认的故障。"
        case .configuration:
            goal = english ? "Help adjust XDial configuration to match the user's desired traffic behavior. Clarify the goal and explain the proposed changes first. Use XDial's settings UI or a verified supported interface, within the assistant's permissions. Never directly edit the encrypted profile store or Keychain. Saving is separate from applying: the user decides when to apply and reconnect."
                : "请协助调整 XDial 配置，实现用户想要的分流效果。先明确目标并说明修改方案，在助手已有权限内通过 XDial 设置界面或已核实的受支持接口操作。不要直接修改加密配置库或钥匙串。保存配置与应用配置独立，由用户决定何时应用并重连。"
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let date = ISO8601DateFormatter().string(from: createdAt)
        let userDescription = hasDescription ? """

        \(english ? "User description (user-provided text):" : "用户描述（用户自行填写）：")
        ---
        \(description)
        ---

        """ : ""
        var result = """
        XDial — \(english ? "Feedback & Diagnosis" : "反馈与诊断")
        \(english ? "Conversation guidance:" : "对话要求：")
        \(conversationGuidance(english: english))

        \(english ? "Task:" : "任务目标：")
        \(goal)

        \(userDescription)
        \(english ? "Application:" : "应用信息：")
        app=\(XDialBuildIdentity.productTitle) bundle_id=\(XDialBuildIdentity.applicationIdentifier)
        version=\(version) build=\(build) channel=\(channel)
        source=\(revision)
        macOS=\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)
        created_at=\(date)
        """
        if let context = context.text(english: english) {
            result += "\n\n" + (english ? "Captured error context:\n" : "已捕获的错误现场：\n") + context
        }
        if kind == .configuration {
            result += "\n\n" + (english
                ? "Configuration map: Settings → Lines / Rules / Line Groups / Scenarios. A Line provides an exit, a Rule describes matching traffic, and a Scenario binds Rules to Lines and chooses a default exit. Saving changes does not replace the running connection. This package contains no configuration values; ask the user for the necessary context or inspect it through authorized UI access. Do not invent CLI commands, HTTP endpoints or a configuration schema.\n"
                : "配置入口：设置 → 线路／规则／线路组／场景。线路提供出口，规则描述匹配流量，场景把规则绑定到线路并选择默认出口。保存修改不替换当前连接。此文件未附带配置值；请向用户确认必要上下文，或通过已授权的界面访问查看。不要编造 CLI 命令、HTTP 接口或配置格式。\n")
        }
        if let runtime {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            result += "\n\n" + (english ? "Allowlisted runtime facts (snapshot, not live state):\n" : "白名单运行事实（采集时快照，并非实时状态）：\n")
            result += String(decoding: try encoder.encode(runtime), as: UTF8.self)
        }
        result += "\n\n" + (english
            ? "The automatic snapshot excludes profiles, credentials, names, addresses, raw logs and raw errors. User text is included as written. A missing field is not proof of success. Opening the assistant does not submit feedback to the developer.\nBefore changing configuration, disconnecting, restarting, uploading data or submitting an issue, explain the action and obtain the user's authorization. When an investigation is complete, summarize confirmed facts, hypotheses, actions and results, resolution and retest status, and next steps. While still learning the user's needs, converse naturally rather than producing a diagnostic report.\n"
            : "自动快照不含配置、凭据、名称、地址、原始日志与原始错误；用户输入按原文保留。缺少字段不代表成功。打开助手不表示已向开发者提交反馈。\n修改配置、断开连接、重启、上传资料或创建问题卡片前，应说明动作并取得用户授权。排查完成后再整理：已确认事实、待验证假设、尝试与结果、已解决并复测／未解决／证据不足，以及下一步。仍在了解需求时自然交流，不要提前输出诊断报告。\n")
        return result
    }

    /// Each handoff is a new private file, so edits and retries never replace
    /// an earlier problem's evidence. Files remain available after app closure.
    func write(text: String, under root: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("XDial-feedback.txt")
        try Data(text.utf8).write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }
}
