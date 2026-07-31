import Foundation

final class ConnectionTransactionReporter {
    let transactionID: String
    private let failureLock = NSLock()
    private var updateFailure: Error?

    init(transactionID: String) throws {
        guard
            let report = ConnectionReportJournal.read(),
            report.transactionID == transactionID
        else {
            throw ReporterError.transactionNotFound
        }
        self.transactionID = transactionID
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
        guard plan.mode == report.mode, plannedIDs == reportIDs else {
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
        guard
            let report = ConnectionReportJournal.read(),
            report.transactionID == transactionID
        else {
            return nil
        }
        return report
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
        guard ConnectionReportJournal.update(
            transactionID: transactionID,
            mutation
        ) != nil else {
            failureLock.lock()
            if updateFailure == nil {
                updateFailure = ReporterError.reportUnavailable
            }
            failureLock.unlock()
            return
        }
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
    case planChanged
    case reportUnavailable
    case incompletePlan([String])

    var errorDescription: String? {
        switch self {
        case .transactionNotFound:
            "XDial 连接事务报告不存在"
        case .planChanged:
            "XDial 连接计划在宿主与数据面之间发生变化"
        case .reportUnavailable:
            "XDial 连接事务报告无法可靠写入"
        case let .incompletePlan(taskIDs):
            "XDial 连接计划尚未全部就绪（\(taskIDs.joined(separator: ", "))）"
        }
    }
}
