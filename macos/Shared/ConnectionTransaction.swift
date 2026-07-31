import Darwin
import Foundation

final class ConnectionCancellation {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

struct ConnectionPlan: Codable, Equatable {
    let schemaVersion: Int
    let mode: ConnectionPlanMode
    let tasks: [ConnectionPlanTask]
    let warnings: [ConnectionPlanWarning]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case mode
        case tasks
        case warnings
    }

    init(
        schemaVersion: Int,
        mode: ConnectionPlanMode,
        tasks: [ConnectionPlanTask],
        warnings: [ConnectionPlanWarning] = []
    ) {
        self.schemaVersion = schemaVersion
        self.mode = mode
        self.tasks = tasks
        self.warnings = warnings
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        mode = try values.decode(ConnectionPlanMode.self, forKey: .mode)
        tasks = try values.decode([ConnectionPlanTask].self, forKey: .tasks)
        warnings = try values.decodeIfPresent(
            [ConnectionPlanWarning].self,
            forKey: .warnings
        ) ?? []
    }
}

struct ConnectionPlanMode: Codable, Equatable {
    let id: String
    let name: String
}

struct ConnectionPlanTask: Codable, Equatable, Identifiable {
    let id: String
    let kind: String
    let name: String
    let detail: String
    let preparation: String
    let dependencies: [String]
    let resourceID: String
    let resourceType: String

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case name
        case detail
        case preparation
        case dependencies
        case resourceID = "resource_id"
        case resourceType = "resource_type"
    }

    init(
        id: String,
        kind: String,
        name: String,
        detail: String = "",
        preparation: String,
        dependencies: [String] = [],
        resourceID: String = "",
        resourceType: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.detail = detail
        self.preparation = preparation
        self.dependencies = dependencies
        self.resourceID = resourceID
        self.resourceType = resourceType
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        kind = try values.decode(String.self, forKey: .kind)
        name = try values.decode(String.self, forKey: .name)
        detail = try values.decodeIfPresent(
            String.self,
            forKey: .detail
        ) ?? ""
        preparation = try values.decode(
            String.self,
            forKey: .preparation
        )
        dependencies = try values.decodeIfPresent(
            [String].self,
            forKey: .dependencies
        ) ?? []
        resourceID = try values.decodeIfPresent(
            String.self,
            forKey: .resourceID
        ) ?? ""
        resourceType = try values.decodeIfPresent(
            String.self,
            forKey: .resourceType
        ) ?? ""
    }
}

struct ConnectionPlanWarning: Codable, Equatable {
    let kind: String
    let modeID: String
    let ruleSetID: String
    let lineID: String
    let subscriptionID: String
    let message: String

    enum CodingKeys: String, CodingKey {
        case kind
        case modeID = "mode_id"
        case ruleSetID = "rule_set_id"
        case lineID = "line_id"
        case subscriptionID = "subscription_id"
        case message
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(String.self, forKey: .kind)
        modeID = try values.decodeIfPresent(
            String.self,
            forKey: .modeID
        ) ?? ""
        ruleSetID = try values.decodeIfPresent(
            String.self,
            forKey: .ruleSetID
        ) ?? ""
        lineID = try values.decodeIfPresent(
            String.self,
            forKey: .lineID
        ) ?? ""
        subscriptionID = try values.decodeIfPresent(
            String.self,
            forKey: .subscriptionID
        ) ?? ""
        message = try values.decode(String.self, forKey: .message)
    }
}

enum ConnectionTransactionState: String, Codable {
    case planning
    case preparing
    case readyToCommit = "ready_to_commit"
    case committing
    case committed
    case rollingBack = "rolling_back"
    case rolledBack = "rolled_back"
    case failed
    case cancelled
}

enum ConnectionTaskState: String, Codable {
    case pending
    case running
    case ready
    case committing
    case committed
    case rollingBack = "rolling_back"
    case rolledBack = "rolled_back"
    case failed
    case skipped
}

/// The callback is armed by libbox's structured connected event, not by a
/// later platform preparation milestone. This closes the window where an
/// AnyConnect session could die after `Start` returned but before the provider
/// finished preparing other active Lines.
struct EngineCallbackRuntimeGate: Equatable {
    enum Phase: Equatable {
        case starting
        case running
        case stopped
    }

    private(set) var phase: Phase = .starting

    mutating func beginStart() {
        phase = .starting
    }

    mutating func consumeStatus(_ statusJSON: String?) {
        guard
            let statusJSON,
            let data = statusJSON.data(using: .utf8),
            let envelope = try? JSONDecoder().decode(
                EngineCallbackStatusEnvelope.self,
                from: data
            )
        else {
            return
        }
        switch envelope.status {
        case "connected":
            if phase != .stopped {
                phase = .running
            }
        case "disconnected":
            phase = .stopped
        default:
            break
        }
    }

    mutating func stop() {
        phase = .stopped
    }

    mutating func consumeFatalError() -> Bool {
        guard phase == .running else {
            return false
        }
        phase = .stopped
        return true
    }
}

private struct EngineCallbackStatusEnvelope: Decodable {
    let status: String
}

struct AnyConnectLineRuntimeStatus: Decodable, Equatable {
    enum State: String, Decodable {
        case reconnecting = "line_reconnecting"
        case connected = "line_connected"
    }

    let state: State
    let lineType: String
    let attempt: Int
    let maxAttempts: Int

    enum CodingKeys: String, CodingKey {
        case state = "status"
        case lineType = "line_type"
        case attempt
        case maxAttempts = "max_attempts"
    }

    var isAnyConnect: Bool {
        lineType == "vpn"
    }
}

struct ConnectionFailureEvidence: Codable, Equatable {
    let anyConnect: AnyConnectFailureEvidence?

    enum CodingKeys: String, CodingKey {
        case anyConnect = "anyconnect"
    }

    init(anyConnect: AnyConnectFailureEvidence? = nil) {
        self.anyConnect = anyConnect
    }
}

struct AnyConnectFailureEvidence: Codable, Equatable {
    let schemaVersion: Int
    let forceDPDSeconds: Int
    let sessionAgeMS: Int64?
    let negotiated: AnyConnectNegotiatedEvidence
    let tls: AnyConnectTLSChannelEvidence
    let dtls: AnyConnectDTLSChannelEvidence
    let close: AnyConnectCloseEvidence?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case forceDPDSeconds = "force_dpd_seconds"
        case sessionAgeMS = "session_age_ms"
        case negotiated
        case tls
        case dtls
        case close
    }

    var reportCode: String? {
        close?.reportCode
    }

    var publicFailureMessage: String {
        switch close?.code {
        case "tls-dpd-timeout":
            return "AnyConnect TLS 控制通道保活检测超时"
        case "tls-read-timeout":
            return "AnyConnect TLS 控制通道读取超时"
        case "tls-read-eof":
            return "AnyConnect TLS 控制通道被对端关闭"
        case "tls-read-reset", "tls-write-reset":
            return "AnyConnect TLS 控制通道被重置"
        case "tls-read-closed":
            return "AnyConnect TLS 控制通道已关闭"
        case "tls-write-timeout":
            return "AnyConnect TLS 控制通道写入超时"
        case "tls-write-eof", "tls-write-closed":
            return "AnyConnect TLS 控制通道写入时被关闭"
        case "peer-disconnect":
            return peerDisconnectPublicFailureMessage
        case "peer-terminate":
            return "AnyConnect 服务端终止了当前会话"
        default:
            return "AnyConnect 会话意外结束"
        }
    }

    private var peerDisconnectPublicFailureMessage: String {
        switch close?.peerReasonCategory {
        case "idle-timeout":
            return "AnyConnect 服务端因空闲超时结束了当前会话"
        case "session-timeout":
            return "AnyConnect 服务端因会话超时结束了当前会话"
        case "duplicate-session":
            return "AnyConnect 服务端因重复会话结束了当前会话"
        case "authentication":
            return "AnyConnect 服务端因认证失败结束了当前会话"
        case "policy":
            return "AnyConnect 服务端因策略限制结束了当前会话"
        case "rekey":
            return "AnyConnect 服务端在重新协商密钥时结束了当前会话"
        case "server-error":
            return "AnyConnect 服务端因内部错误结束了当前会话"
        default:
            return "AnyConnect 服务端结束了当前会话"
        }
    }
}

struct AnyConnectNegotiatedEvidence: Codable, Equatable {
    let tlsDPDSeconds: Int
    let tlsKeepaliveSeconds: Int
    let dtlsDPDSeconds: Int
    let dtlsKeepaliveSeconds: Int
    let cstpRekeySeconds: Int?
    let cstpRekeyMethod: String?
    let cstpLeaseDurationSeconds: Int?
    let cstpSessionTimeoutSeconds: Int?
    let cstpSessionTimeoutRemainingSeconds: Int?
    let cstpIdleTimeoutSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case tlsDPDSeconds = "tls_dpd_seconds"
        case tlsKeepaliveSeconds = "tls_keepalive_seconds"
        case dtlsDPDSeconds = "dtls_dpd_seconds"
        case dtlsKeepaliveSeconds = "dtls_keepalive_seconds"
        case cstpRekeySeconds = "cstp_rekey_seconds"
        case cstpRekeyMethod = "cstp_rekey_method"
        case cstpLeaseDurationSeconds =
            "cstp_lease_duration_seconds"
        case cstpSessionTimeoutSeconds =
            "cstp_session_timeout_seconds"
        case cstpSessionTimeoutRemainingSeconds =
            "cstp_session_timeout_remaining_seconds"
        case cstpIdleTimeoutSeconds =
            "cstp_idle_timeout_seconds"
    }
}

struct AnyConnectTLSChannelEvidence: Codable, Equatable {
    let effectiveDPDSeconds: Int
    let dpdRequestsQueued: UInt64
    let dpdRequestsDropped: UInt64
    let dpdRequestsWritten: UInt64
    let dpdResponsesReceived: UInt64
    let peerDPDRequestsReceived: UInt64
    let keepalivesReceived: UInt64
    let dataFramesReceived: UInt64?
    let dataFramesWritten: UInt64?
    let lastFrameAgeMS: Int64?
    let lastDPDWrittenAgeMS: Int64?
    let lastDPDResponseAgeMS: Int64?
    let lastDataReceivedAgeMS: Int64?
    let lastDataWrittenAgeMS: Int64?

    enum CodingKeys: String, CodingKey {
        case effectiveDPDSeconds = "effective_dpd_seconds"
        case dpdRequestsQueued = "dpd_requests_queued"
        case dpdRequestsDropped = "dpd_requests_dropped"
        case dpdRequestsWritten = "dpd_requests_written"
        case dpdResponsesReceived = "dpd_responses_received"
        case peerDPDRequestsReceived = "peer_dpd_requests_received"
        case keepalivesReceived = "keepalives_received"
        case dataFramesReceived = "data_frames_received"
        case dataFramesWritten = "data_frames_written"
        case lastFrameAgeMS = "last_frame_age_ms"
        case lastDPDWrittenAgeMS = "last_dpd_written_age_ms"
        case lastDPDResponseAgeMS = "last_dpd_response_age_ms"
        case lastDataReceivedAgeMS =
            "last_data_received_age_ms"
        case lastDataWrittenAgeMS =
            "last_data_written_age_ms"
    }
}

struct AnyConnectDTLSChannelEvidence: Codable, Equatable {
    let effectiveDPDSeconds: Int
    let dpdRequestsQueued: UInt64
    let dpdRequestsDropped: UInt64
    let dpdRequestsWritten: UInt64
    let dpdResponsesReceived: UInt64
    let peerDPDRequestsReceived: UInt64
    let keepalivesReceived: UInt64
    let dataFramesReceived: UInt64?
    let dataFramesWritten: UInt64?
    let lastFrameAgeMS: Int64?
    let lastDPDWrittenAgeMS: Int64?
    let lastDPDResponseAgeMS: Int64?
    let lastDataReceivedAgeMS: Int64?
    let lastDataWrittenAgeMS: Int64?
    let everConnected: Bool
    let currentlyConnected: Bool

    enum CodingKeys: String, CodingKey {
        case effectiveDPDSeconds = "effective_dpd_seconds"
        case dpdRequestsQueued = "dpd_requests_queued"
        case dpdRequestsDropped = "dpd_requests_dropped"
        case dpdRequestsWritten = "dpd_requests_written"
        case dpdResponsesReceived = "dpd_responses_received"
        case peerDPDRequestsReceived = "peer_dpd_requests_received"
        case keepalivesReceived = "keepalives_received"
        case dataFramesReceived = "data_frames_received"
        case dataFramesWritten = "data_frames_written"
        case lastFrameAgeMS = "last_frame_age_ms"
        case lastDPDWrittenAgeMS = "last_dpd_written_age_ms"
        case lastDPDResponseAgeMS = "last_dpd_response_age_ms"
        case lastDataReceivedAgeMS =
            "last_data_received_age_ms"
        case lastDataWrittenAgeMS =
            "last_data_written_age_ms"
        case everConnected = "ever_connected"
        case currentlyConnected = "currently_connected"
    }
}

struct AnyConnectCloseEvidence: Codable, Equatable {
    let code: String
    let channel: String
    let operation: String
    let errorClass: String
    let occurredAtUnixMilli: Int64
    let peerPayloadLength: Int?
    let peerReasonCode: String?
    let peerHasReasonText: Bool?
    let peerReasonCategory: String?

    enum CodingKeys: String, CodingKey {
        case code
        case channel
        case operation
        case errorClass = "error_class"
        case occurredAtUnixMilli = "occurred_at_unix_milli"
        case peerPayloadLength = "peer_payload_length"
        case peerReasonCode = "peer_reason_code"
        case peerHasReasonText = "peer_has_reason_text"
        case peerReasonCategory = "peer_reason_category"
    }

    var reportCode: String? {
        guard
            !code.isEmpty,
            code.count <= 64,
            code.unicodeScalars.allSatisfy({
                ($0.value >= 97 && $0.value <= 122) ||
                    ($0.value >= 48 && $0.value <= 57) ||
                    $0.value == 45
            })
        else {
            return nil
        }
        return "anyconnect-\(code)"
    }
}

struct ConnectionRuntimeFailure: LocalizedError {
    static let dataPlaneTaskID = "data-plane:sing-box"

    let code: String
    let message: String
    let taskID: String
    let evidence: ConnectionFailureEvidence?

    var attributedTaskID: String {
        taskID.isEmpty ? Self.dataPlaneTaskID : taskID
    }

    var errorDescription: String? {
        message
    }
}

struct ConnectionReportError: Codable, Equatable {
    let code: String
    let message: String
    let taskID: String
    let evidence: ConnectionFailureEvidence?

    enum CodingKeys: String, CodingKey {
        case code
        case message
        case taskID = "task_id"
        case evidence
    }

    init(
        code: String,
        message: String,
        taskID: String,
        evidence: ConnectionFailureEvidence? = nil
    ) {
        self.code = code
        self.message = message
        self.taskID = taskID
        self.evidence = evidence
    }
}

struct ConnectionTaskReport: Codable, Equatable, Identifiable {
    let id: String
    let kind: String
    let name: String
    let detail: String
    let preparation: String
    let resourceID: String
    let resourceType: String
    var state: ConnectionTaskState
    var startedAt: Date?
    var finishedAt: Date?
    var error: ConnectionReportError?

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case name
        case detail
        case preparation
        case resourceID = "resource_id"
        case resourceType = "resource_type"
        case state
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case error
    }
}

struct ConnectionReportEvent: Codable, Equatable, Identifiable {
    let sequence: Int
    let timestamp: Date
    let type: String
    let state: String
    let taskID: String
    let code: String
    let message: String
    let facts: [String: Bool]?

    var id: Int { sequence }

    enum CodingKeys: String, CodingKey {
        case sequence
        case timestamp
        case type
        case state
        case taskID = "task_id"
        case code
        case message
        case facts
    }
}

struct ConnectionReport: Codable, Equatable {
    let schemaVersion: Int
    let transactionID: String
    let mode: ConnectionPlanMode
    var state: ConnectionTransactionState
    let startedAt: Date
    var updatedAt: Date
    var tasks: [ConnectionTaskReport]
    let warnings: [ConnectionPlanWarning]
    var events: [ConnectionReportEvent]
    var error: ConnectionReportError?
    var rollbackError: ConnectionReportError?
    var rollbackComplete: Bool
    var systemTakeoverRemoved: Bool

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case transactionID = "transaction_id"
        case mode
        case state
        case startedAt = "started_at"
        case updatedAt = "updated_at"
        case tasks
        case warnings
        case events
        case error
        case rollbackError = "rollback_error"
        case rollbackComplete = "rollback_complete"
        case systemTakeoverRemoved = "system_takeover_removed"
    }

    init(transactionID: String, plan: ConnectionPlan) {
        let now = Date()
        schemaVersion = 1
        self.transactionID = transactionID
        mode = plan.mode
        state = .planning
        startedAt = now
        updatedAt = now
        tasks = plan.tasks.map {
            ConnectionTaskReport(
                id: $0.id,
                kind: $0.kind,
                name: $0.name,
                detail: $0.detail,
                preparation: $0.preparation,
                resourceID: $0.resourceID,
                resourceType: $0.resourceType,
                state: .pending
            )
        }
        warnings = plan.warnings
        events = []
        error = nil
        rollbackError = nil
        rollbackComplete = false
        systemTakeoverRemoved = true
        appendEvent(
            type: "transaction",
            state: ConnectionTransactionState.planning.rawValue
        )
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(
            Int.self,
            forKey: .schemaVersion
        )
        transactionID = try values.decode(
            String.self,
            forKey: .transactionID
        )
        mode = try values.decode(
            ConnectionPlanMode.self,
            forKey: .mode
        )
        state = try values.decode(
            ConnectionTransactionState.self,
            forKey: .state
        )
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        tasks = try values.decode(
            [ConnectionTaskReport].self,
            forKey: .tasks
        )
        warnings = try values.decodeIfPresent(
            [ConnectionPlanWarning].self,
            forKey: .warnings
        ) ?? []
        events = try values.decodeIfPresent(
            [ConnectionReportEvent].self,
            forKey: .events
        ) ?? []
        error = try values.decodeIfPresent(
            ConnectionReportError.self,
            forKey: .error
        )
        rollbackError = try values.decodeIfPresent(
            ConnectionReportError.self,
            forKey: .rollbackError
        )
        rollbackComplete = try values.decodeIfPresent(
            Bool.self,
            forKey: .rollbackComplete
        ) ?? false
        systemTakeoverRemoved = try values.decodeIfPresent(
            Bool.self,
            forKey: .systemTakeoverRemoved
        ) ?? false
    }

    var currentTask: ConnectionTaskReport? {
        tasks.last {
            $0.state == .running ||
                $0.state == .committing ||
                $0.state == .rollingBack ||
                $0.state == .failed
        }
    }

    var incompletePrepareTaskIDs: [String] {
        tasks.compactMap { task in
            if task.kind == "ingress" {
                return task.state == .pending ? nil : task.id
            }
            return task.state == .ready ? nil : task.id
        }
    }

    var isReadyForCommit: Bool {
        incompletePrepareTaskIDs.isEmpty
    }

    func task(
        kind: String,
        resourceID: String
    ) -> ConnectionTaskReport? {
        tasks.first {
            $0.kind == kind && $0.resourceID == resourceID
        }
    }

    mutating func setState(_ newState: ConnectionTransactionState) {
        state = newState
        updatedAt = Date()
        appendEvent(
            type: "transaction",
            state: newState.rawValue
        )
    }

    mutating func updateTask(
        id: String,
        state newState: ConnectionTaskState,
        error taskError: ConnectionReportError? = nil
    ) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            return
        }
        let now = Date()
        if tasks[index].startedAt == nil,
           newState != .pending,
           newState != .skipped {
            tasks[index].startedAt = now
        }
        tasks[index].state = newState
        tasks[index].error = taskError
        switch newState {
        case .ready, .committed, .rolledBack, .failed, .skipped:
            tasks[index].finishedAt = now
        case .pending, .running, .committing, .rollingBack:
            tasks[index].finishedAt = nil
        }
        updatedAt = now
        appendEvent(
            type: "task",
            state: newState.rawValue,
            taskID: id,
            code: taskError?.code ?? "",
            message: taskError?.message ?? ""
        )
    }

    mutating func updateTasks(
        kind: String,
        state: ConnectionTaskState
    ) {
        let ids = tasks.filter { $0.kind == kind }.map(\.id)
        for id in ids {
            updateTask(id: id, state: state)
        }
    }

    mutating func fail(
        code: String,
        message: String,
        taskID: String = "",
        evidence: ConnectionFailureEvidence? = nil
    ) {
        let failure = ConnectionReportError(
            code: code,
            message: message,
            taskID: taskID,
            evidence: evidence
        )
        error = failure
        if !taskID.isEmpty {
            updateTask(id: taskID, state: .failed, error: failure)
        }
        updatedAt = Date()
        appendEvent(
            type: "error",
            state: ConnectionTaskState.failed.rawValue,
            taskID: taskID,
            code: code,
            message: message
        )
    }

    mutating func failRollback(
        code: String,
        message: String,
        taskID: String
    ) {
        let failure = ConnectionReportError(
            code: code,
            message: message,
            taskID: taskID
        )
        rollbackError = failure
        if !taskID.isEmpty {
            updateTask(id: taskID, state: .failed, error: failure)
        }
        updatedAt = Date()
        appendEvent(
            type: "rollback_error",
            state: ConnectionTaskState.failed.rawValue,
            taskID: taskID,
            code: code,
            message: message
        )
    }

    mutating func note(
        code: String,
        message: String,
        taskID: String = "",
        facts: [String: Bool]? = nil
    ) {
        updatedAt = Date()
        appendEvent(
            type: "diagnostic",
            state: ConnectionTaskState.running.rawValue,
            taskID: taskID,
            code: code,
            message: message,
            facts: facts
        )
    }

    mutating func rollbackSessionTasks(
        systemTakeoverRemoved: Bool,
        cleanupComplete: Bool,
        finalState: ConnectionTransactionState
    ) {
        for index in tasks.indices.reversed() {
            let task = tasks[index]
            guard [
                "line",
                "subscription",
                "dns",
                "data_plane",
                "ingress",
            ].contains(task.kind) else {
                continue
            }
            guard [
                ConnectionTaskState.running,
                .ready,
                .committing,
                .committed,
                .rollingBack,
            ].contains(task.state) else {
                continue
            }
            if task.state != .rollingBack {
                updateTask(
                    id: task.id,
                    state: .rollingBack
                )
            }
            if cleanupComplete {
                updateTask(
                    id: task.id,
                    state: .rolledBack
                )
            }
        }
        rollbackComplete =
            cleanupComplete && systemTakeoverRemoved
        self.systemTakeoverRemoved = systemTakeoverRemoved
        if rollbackComplete {
            setState(.rolledBack)
        }
        setState(finalState)
    }

    /// Completes the system-owned half of a provider stop.
    ///
    /// `stopProxy` runs after Network Extension has begun tearing the session
    /// down, so the provider cannot prove removal by mutating network settings
    /// again. The host may call this only after the exact manager reports
    /// `.disconnected` or `.invalid`.
    @discardableResult
    mutating func confirmSystemDisconnectRollback() -> Bool {
        guard [
            ConnectionTransactionState.failed,
            .cancelled,
        ].contains(state),
            !rollbackComplete || !systemTakeoverRemoved
        else {
            return false
        }

        if let rollbackError {
            guard
                rollbackError.code ==
                    "rollback-network-settings-failed",
                rollbackError.taskID ==
                    "ingress:transparent-proxy"
            else {
                return false
            }
        }

        let sessionKinds = Set([
            "line",
            "subscription",
            "dns",
            "data_plane",
            "ingress",
        ])
        let cleanupStillRunning = tasks.contains {
            sessionKinds.contains($0.kind) && [
                ConnectionTaskState.running,
                .ready,
                .committing,
                .committed,
                .rollingBack,
            ].contains($0.state)
        }
        guard !cleanupStillRunning else {
            return false
        }

        if let ingressIndex = tasks.firstIndex(where: {
            $0.id == "ingress:transparent-proxy"
                && $0.kind == "ingress"
        }), tasks[ingressIndex].state == .failed,
           tasks[ingressIndex].error?.code ==
            "rollback-network-settings-failed" {
            updateTask(
                id: "ingress:transparent-proxy",
                state: .rollingBack
            )
            updateTask(
                id: "ingress:transparent-proxy",
                state: .rolledBack
            )
        }

        rollbackError = nil
        systemTakeoverRemoved = true
        rollbackComplete = true
        note(
            code: "system-disconnect-confirmed",
            message:
                "Network Extension manager confirmed system teardown",
            taskID: "ingress:transparent-proxy"
        )
        return true
    }

    /// Prevents the provider's final pre-disconnect journal entry from
    /// overwriting the host's later system-state confirmation.
    func isSystemDisconnectConfirmationSuccessor(
        of providerReport: ConnectionReport
    ) -> Bool {
        guard
            transactionID == providerReport.transactionID,
            state == providerReport.state,
            rollbackComplete,
            systemTakeoverRemoved,
            events.contains(where: {
                $0.type == "diagnostic"
                    && $0.code ==
                    "system-disconnect-confirmed"
            })
        else {
            return false
        }
        return (events.last?.sequence ?? 0) >
            (providerReport.events.last?.sequence ?? 0)
    }

    private mutating func appendEvent(
        type: String,
        state: String,
        taskID: String = "",
        code: String = "",
        message: String = "",
        facts: [String: Bool]? = nil
    ) {
        events.append(ConnectionReportEvent(
            sequence: (events.last?.sequence ?? 0) + 1,
            timestamp: Date(),
            type: type,
            state: state,
            taskID: taskID,
            code: code,
            message: message,
            facts: facts
        ))
    }
}

enum ConnectionResourceRuntimeState: Equatable {
    case disabled
    case notObserved
    case notPlanned
    case task(ConnectionTaskState)

    static func resolve(
        enabled: Bool,
        report: ConnectionReport?,
        kind: String,
        resourceID: String
    ) -> ConnectionResourceRuntimeState {
        let task = report?.task(
            kind: kind,
            resourceID: resourceID
        )
        // An in-flight or committed transaction owns the runtime fact even if
        // the user has since disabled the resource in the editable Profile.
        // The dirty banner explains that the edit needs a reconnect; showing
        // "disabled" here would falsely describe the still-running snapshot.
        if let report,
           [
               ConnectionTransactionState.planning,
               .preparing,
               .readyToCommit,
               .committing,
               .committed,
               .rollingBack,
           ].contains(report.state),
           let task {
            return .task(task.state)
        }
        guard enabled else {
            return .disabled
        }
        guard report != nil else {
            return .notObserved
        }
        guard let task else {
            return .notPlanned
        }
        return .task(task.state)
    }
}

enum ConnectionReportCodec {
    static func encode(_ report: ConnectionReport) throws -> Data {
        try encoder.encode(report)
    }

    static func decode(_ data: Data) throws -> ConnectionReport {
        try decoder.decode(ConnectionReport.self, from: data)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum ConnectionReportJournal {
    private static let groupIdentifier =
        "UVZM439VGU.com.kafeifei.xdial.network"
    private static let fileName = "connection-report.json"
    private static let lockFileName = "connection-report.lock"

    static func read() -> ConnectionReport? {
        try? withJournalLock(exclusive: false) {
            readUnlocked()
        }
    }

    static func write(_ report: ConnectionReport) throws {
        try withJournalLock(exclusive: true) {
            try writeUnlocked(report)
        }
    }

    @discardableResult
    static func update(
        transactionID: String,
        _ mutation: (inout ConnectionReport) -> Void
    ) -> ConnectionReport? {
        try? withJournalLock(exclusive: true) {
            guard var report = readUnlocked(),
                  report.transactionID == transactionID else {
                return nil
            }
            mutation(&report)
            try writeUnlocked(report)
            return report
        }
    }

    private static func readUnlocked() -> ConnectionReport? {
        guard
            let url = journalURL(createDirectory: false),
            let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        return try? ConnectionReportCodec.decode(data)
    }

    private static func writeUnlocked(
        _ report: ConnectionReport
    ) throws {
        guard let url = journalURL(createDirectory: true) else {
            throw JournalError.groupContainerUnavailable
        }
        let data = try ConnectionReportCodec.encode(report)
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private static func withJournalLock<T>(
        exclusive: Bool,
        _ body: () throws -> T
    ) throws -> T {
        guard let url = journalURL(createDirectory: true) else {
            throw JournalError.groupContainerUnavailable
        }
        let lockURL = url.deletingLastPathComponent()
            .appendingPathComponent(lockFileName)
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw JournalError.lockUnavailable
        }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        guard flock(
            descriptor,
            exclusive ? LOCK_EX : LOCK_SH
        ) == 0 else {
            throw JournalError.lockUnavailable
        }
        return try body()
    }

    private static func journalURL(createDirectory: Bool) -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier
        ) else {
            return nil
        }
        let directory = container.appendingPathComponent(
            "Transactions",
            isDirectory: true
        )
        if createDirectory {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        return directory.appendingPathComponent(fileName)
    }
}

private enum JournalError: LocalizedError {
    case groupContainerUnavailable
    case lockUnavailable

    var errorDescription: String? {
        switch self {
        case .groupContainerUnavailable:
            "XDial 事务报告目录不可用"
        case .lockUnavailable:
            "XDial 事务报告锁不可用"
        }
    }
}
