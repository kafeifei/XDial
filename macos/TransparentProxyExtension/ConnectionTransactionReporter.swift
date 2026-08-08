import Foundation

final class ConnectionTransactionReporter {
    let transactionID: String
    private let failureLock = NSLock()
    private var updateFailure: Error?
    private let keepsCandidateInMemory: Bool
    private let memoryLock = NSLock()
    private var memoryReport: ConnectionReport?

    init(transactionID: String) throws {
        guard
            let report = ConnectionReportJournal.read(),
            report.transactionID == transactionID
        else {
            throw ReporterError.transactionNotFound
        }
        self.transactionID = transactionID
        keepsCandidateInMemory = false
        memoryReport = nil
    }

    /// A Switch candidate must not replace the still-committed runtime report
    /// while it is only being prepared. Its task transitions stay in memory;
    /// the Provider persists the final committed report exactly once, at the
    /// same boundary where it publishes the new relay generation.
    init(candidate report: ConnectionReport) throws {
        guard
            !report.transactionID.isEmpty,
            report.state == .planning
        else {
            throw ReporterError.invalidCandidateReport
        }
        transactionID = report.transactionID
        keepsCandidateInMemory = true
        memoryReport = report
    }

    func setState(_ state: ConnectionTransactionState) {
        update { $0.setState(state) }
    }

    func setTask(
        id: String,
        state: ConnectionTaskState
    ) {
        update { $0.updateTask(id: id, state: state) }
    }

    func setTasks(
        kind: String,
        state: ConnectionTaskState,
        excludingResourceType: String? = nil,
        matchingResourceType: String? = nil
    ) {
        update { report in
            let ids = report.tasks.filter {
                $0.kind == kind &&
                    (excludingResourceType == nil ||
                        $0.resourceType != excludingResourceType) &&
                    (matchingResourceType == nil ||
                        $0.resourceType == matchingResourceType)
            }.map(\.id)
            for id in ids {
                report.updateTask(id: id, state: state)
            }
        }
    }

    func setPendingTasks(
        kind: String,
        state: ConnectionTaskState
    ) {
        update { report in
            let ids = report.tasks.filter {
                $0.kind == kind && $0.state == .pending
            }.map(\.id)
            for id in ids {
                report.updateTask(id: id, state: state)
            }
        }
    }

    /// Records that the Provider accepted the host-captured Underlay snapshot
    /// for this transaction. A Switch candidate receives its snapshot in the
    /// provider message instead of passing through the cold-start host journal
    /// update, so the candidate reporter must publish the same preparation
    /// fact before the commit gate is evaluated.
    func markUnderlaySnapshotReady() {
        setTask(id: "underlay:system", state: .ready)
    }

    func consumePreparationEvent(_ eventJSON: String) {
        guard
            let data = eventJSON.data(using: .utf8),
            let event = try? JSONDecoder().decode(
                PreparationEvent.self,
                from: data
            ),
            !event.taskID.isEmpty
        else {
            return
        }
        update { report in
            switch event.state {
            case "running":
                report.updateTask(
                    id: event.taskID,
                    state: .running
                )
            case "ready":
                report.updateTask(
                    id: event.taskID,
                    state: .ready
                )
            case "failed":
                report.fail(
                    code: event.code.isEmpty
                        ? "rule-set-prepare-failed"
                        : event.code,
                    message: event.message.isEmpty
                        ? "规则准备失败"
                        : event.message,
                    taskID: event.taskID
                )
            default:
                break
            }
        }
    }

    func validate(plan: ConnectionPlan) throws {
        try ensureHealthy()
        guard let report = currentReport() else {
            throw ReporterError.transactionNotFound
        }
        let plannedIDs = plan.tasks.map(\.id)
        let reportIDs = report.tasks.map(\.id)
        guard plan.scenario == report.scenario, plannedIDs == reportIDs else {
            throw ReporterError.planChanged
        }
    }

    func ensureHealthy() throws {
        failureLock.lock()
        let failure = updateFailure
        failureLock.unlock()
        if let failure {
            throw failure
        }
    }

    func ensureReadyForCommit() throws {
        try ensureHealthy()
        guard let report = currentReport() else {
            throw ReporterError.transactionNotFound
        }
        guard report.isReadyForCommit else {
            throw ReporterError.incompletePlan(
                report.incompletePrepareTaskIDs
            )
        }
    }

    func fail(
        _ error: Error,
        code: String,
        taskID: String? = nil,
        evidence: ConnectionFailureEvidence? = nil
    ) {
        update { report in
            guard report.error == nil else {
                return
            }
            let resolvedTaskID = taskID ??
                report.currentTask?.id ??
                ""
            report.fail(
                code: code,
                message: error.localizedDescription,
                taskID: resolvedTaskID,
                evidence: evidence
            )
        }
    }

    func fail(_ failure: ConnectionRuntimeFailure) {
        fail(
            failure,
            code: failure.code,
            taskID: failure.attributedTaskID,
            evidence: failure.evidence
        )
    }

    func failRollback(
        _ error: Error,
        code: String,
        taskID: String
    ) {
        update { report in
            report.failRollback(
                code: code,
                message: error.localizedDescription,
                taskID: taskID
            )
        }
    }

    func note(
        code: String,
        message: String,
        taskID: String,
        facts: [String: Bool]? = nil
    ) {
        update { report in
            report.note(
                code: code,
                message: message,
                taskID: taskID,
                facts: facts
            )
        }
    }

    func beginRollback(
        _ error: Error?,
        code: String
    ) {
        update { report in
            if let error, report.error == nil {
                let taskID = report.currentTask?.id ?? ""
                report.fail(
                    code: code,
                    message: error.localizedDescription,
                    taskID: taskID
                )
            }
            report.setState(.rollingBack)
        }
    }

    func rollbackSessionTasks(
        systemTakeoverRemoved: Bool,
        cleanupComplete: Bool,
        finalState: ConnectionTransactionState = .failed
    ) {
        update { report in
            report.rollbackSessionTasks(
                systemTakeoverRemoved: systemTakeoverRemoved,
                cleanupComplete: cleanupComplete,
                finalState: finalState
            )
        }
    }

    func markCommitted() throws {
        update { report in
            report.updateTask(
                id: "ingress:transparent-proxy",
                state: .committed
            )
            report.systemTakeoverRemoved = false
            report.setState(.committed)
        }
        try ensureHealthy()
    }

    func currentReport() -> ConnectionReport? {
        if keepsCandidateInMemory {
            memoryLock.lock()
            let report = memoryReport
            memoryLock.unlock()
            return report
        }
        guard
            let report = ConnectionReportJournal.read(),
            report.transactionID == transactionID
        else {
            return nil
        }
        return report
    }

    /// Makes a successfully committed candidate authoritative. Calling this
    /// before `markCommitted()` or on a journal-backed reporter is a contract
    /// error; failed candidates therefore cannot erase the source report.
    @discardableResult
    func persistCommittedCandidate() throws -> ConnectionReport {
        guard keepsCandidateInMemory else {
            throw ReporterError.notCandidateReporter
        }
        try ensureHealthy()
        guard
            let report = currentReport(),
            report.state == .committed,
            !report.systemTakeoverRemoved
        else {
            throw ReporterError.candidateNotCommitted
        }
        try ConnectionReportJournal.stageSwitchCandidate(report)
        return try ConnectionReportJournal.commitStagedSwitchCandidate(
            transactionID: transactionID
        )
    }

    /// Preflights the same locked/atomic storage path before the relay handoff
    /// while leaving the source report authoritative.
    func stageCandidate() throws {
        guard keepsCandidateInMemory,
              let report = currentReport() else {
            throw ReporterError.notCandidateReporter
        }
        try ensureHealthy()
        try ConnectionReportJournal.stageSwitchCandidate(report)
    }

    func discardStagedCandidate() {
        guard keepsCandidateInMemory else { return }
        ConnectionReportJournal.discardStagedSwitchCandidate(
            transactionID: transactionID
        )
    }

    func firstTaskID(
        kind: String,
        resourceType: String? = nil
    ) -> String? {
        currentReport()?.tasks.first {
            $0.kind == kind &&
                (resourceType == nil ||
                    $0.resourceType == resourceType)
        }?.id
    }

    private func update(
        _ mutation: (inout ConnectionReport) -> Void
    ) {
        if keepsCandidateInMemory {
            memoryLock.lock()
            guard var report = memoryReport,
                  report.transactionID == transactionID else {
                memoryLock.unlock()
                recordUpdateFailure(ReporterError.reportUnavailable)
                return
            }
            mutation(&report)
            memoryReport = report
            memoryLock.unlock()
            return
        }
        guard ConnectionReportJournal.update(
            transactionID: transactionID,
            mutation
        ) != nil else {
            recordUpdateFailure(ReporterError.reportUnavailable)
            return
        }
    }

    private func recordUpdateFailure(_ error: Error) {
        failureLock.lock()
        if updateFailure == nil {
            updateFailure = error
        }
        failureLock.unlock()
    }
}

private struct PreparationEvent: Decodable {
    let taskID: String
    let state: String
    let code: String
    let message: String

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case state
        case code
        case message
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try values.decode(String.self, forKey: .taskID)
        state = try values.decode(String.self, forKey: .state)
        code = try values.decodeIfPresent(
            String.self,
            forKey: .code
        ) ?? ""
        message = try values.decodeIfPresent(
            String.self,
            forKey: .message
        ) ?? ""
    }
}

private enum ReporterError: LocalizedError {
    case transactionNotFound
    case invalidCandidateReport
    case notCandidateReporter
    case candidateNotCommitted
    case planChanged
    case reportUnavailable
    case incompletePlan([String])

    var errorDescription: String? {
        switch self {
        case .transactionNotFound:
            "XDial 连接事务报告不存在"
        case .invalidCandidateReport:
            "XDial Switch 候选事务报告无效"
        case .notCandidateReporter:
            "XDial 连接事务不是 Switch 候选"
        case .candidateNotCommitted:
            "XDial Switch 候选尚未完成提交"
        case .planChanged:
            "XDial 连接计划在宿主与数据面之间发生变化"
        case .reportUnavailable:
            "XDial 连接事务报告无法可靠写入"
        case let .incompletePlan(taskIDs):
            "XDial 连接计划尚未全部就绪（\(taskIDs.joined(separator: ", "))）"
        }
    }
}
