import Foundation

/// Per-attempt failure facts are recorded by code only. Failure messages can
/// name a Line's server, address or domain; a structured code is a lowercase
/// kebab identifier, and anything else is withheld rather than persisted.
enum ReconnectIncidentFailureCode {
    static let unstructured = "unstructured-failure"

    static func recordable(_ code: String?) -> String {
        guard let code, !code.isEmpty else { return "" }
        guard
            code.count <= 64,
            code.unicodeScalars.allSatisfy({
                ($0.value >= 97 && $0.value <= 122) ||
                    ($0.value >= 48 && $0.value <= 57) ||
                    $0.value == 45
            })
        else {
            return unstructured
        }
        return code
    }
}

/// Event and outcome names written to the incident journal. Types are plain
/// strings, so readers that predate an event type still decode the record.
enum ReconnectIncidentEventType {
    static let parked = "parked"
    static let budgetGranted = "budget-granted"
    static let grantDeferred = "grant-deferred"
    static let wakeAttemptStarted = "wake-attempt-started"
    static let tailAttemptStarted = "tail-attempt-started"
    static let attemptFailed = "attempt-failed"

    static func singleAttemptStarted(
        _ kind: AutomaticRecoveryAttemptKind
    ) -> String {
        switch kind {
        case .budget: "retry-started"
        case .wake: wakeAttemptStarted
        case .tail: tailAttemptStarted
        }
    }
}

enum ReconnectIncidentOutcome {
    static let recovering = "recovering"
    static let parked = "parked"
}

struct ReconnectIncidentEvent: Codable, Equatable, Identifiable {
    let sequence: Int
    let timestamp: Date
    let type: String
    let attempt: Int
    let transactionID: String
    let code: String
    let message: String

    var id: Int { sequence }

    enum CodingKeys: String, CodingKey {
        case sequence
        case timestamp
        case type
        case attempt
        case transactionID = "transaction_id"
        case code
        case message
    }
}

struct ReconnectIncident: Codable, Equatable, Identifiable {
    let id: String
    let disconnectedAt: Date
    let trigger: AutomaticReconnectTrigger
    let originalTransactionID: String
    let scenarioID: String
    let scenarioName: String
    var reasonCode: String
    var reasonMessage: String
    var evidence: ConnectionFailureEvidence?
    var systemDisconnectCode: String?
    var systemDisconnectMessage: String?
    var outcome: String
    var events: [ReconnectIncidentEvent]

    enum CodingKeys: String, CodingKey {
        case id
        case disconnectedAt = "disconnected_at"
        case trigger
        case originalTransactionID = "original_transaction_id"
        case scenarioID = "scenario_id"
        case scenarioName = "scenario_name"
        case reasonCode = "reason_code"
        case reasonMessage = "reason_message"
        case evidence
        case systemDisconnectCode = "system_disconnect_code"
        case systemDisconnectMessage = "system_disconnect_message"
        case outcome
        case events
    }

    init(
        id: String,
        disconnectedAt: Date,
        trigger: AutomaticReconnectTrigger,
        originalTransactionID: String,
        scenarioID: String,
        scenarioName: String,
        reasonCode: String,
        reasonMessage: String,
        evidence: ConnectionFailureEvidence?,
        systemDisconnectCode: String?,
        systemDisconnectMessage: String?,
        outcome: String,
        events: [ReconnectIncidentEvent]
    ) {
        self.id = id
        self.disconnectedAt = disconnectedAt
        self.trigger = trigger
        self.originalTransactionID = originalTransactionID
        self.scenarioID = scenarioID
        self.scenarioName = scenarioName
        self.reasonCode = reasonCode
        self.reasonMessage = reasonMessage
        self.evidence = evidence
        self.systemDisconnectCode = systemDisconnectCode
        self.systemDisconnectMessage = systemDisconnectMessage
        self.outcome = outcome
        self.events = events
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        disconnectedAt = try values.decode(Date.self, forKey: .disconnectedAt)
        trigger = try values.decode(AutomaticReconnectTrigger.self, forKey: .trigger)
        originalTransactionID = try values.decode(String.self, forKey: .originalTransactionID)
        scenarioID = try values.decodeIfPresent(
            String.self,
            forKey: .scenarioID
        ) ?? ""
        scenarioName = try values.decodeIfPresent(
            String.self,
            forKey: .scenarioName
        ) ?? ""
        reasonCode = try values.decode(String.self, forKey: .reasonCode)
        reasonMessage = try values.decode(String.self, forKey: .reasonMessage)
        evidence = try values.decodeIfPresent(ConnectionFailureEvidence.self, forKey: .evidence)
        systemDisconnectCode = try values.decodeIfPresent(String.self, forKey: .systemDisconnectCode)
        systemDisconnectMessage = try values.decodeIfPresent(String.self, forKey: .systemDisconnectMessage)
        outcome = try values.decode(String.self, forKey: .outcome)
        events = try values.decode([ReconnectIncidentEvent].self, forKey: .events)
    }

    /// A parked recovery can stay open across many wakes. Keep the opening
    /// disconnect event and the most recent history rather than growing
    /// without bound.
    static let eventLimit = 200

    mutating func append(
        type: String,
        at timestamp: Date = Date(),
        attempt: Int = 0,
        transactionID: String = "",
        code: String = "",
        message: String = ""
    ) {
        events.append(ReconnectIncidentEvent(
            sequence: (events.last?.sequence ?? 0) + 1,
            timestamp: timestamp,
            type: type,
            attempt: attempt,
            transactionID: transactionID,
            code: code,
            message: message
        ))
        if events.count > Self.eventLimit {
            events.removeSubrange(1 ..< (events.count - Self.eventLimit + 1))
        }
    }
}

struct ReconnectIncidentHistory: Codable, Equatable {
    var schemaVersion = 1
    var incidents: [ReconnectIncident] = []

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case incidents
    }

    mutating func begin(
        at timestamp: Date,
        trigger: AutomaticReconnectTrigger,
        report: ConnectionReport?,
        reasonCode: String,
        reasonMessage: String,
        limit: Int = 50
    ) -> String {
        let id = UUID().uuidString
        var incident = ReconnectIncident(
            id: id,
            disconnectedAt: timestamp,
            trigger: trigger,
            originalTransactionID: report?.transactionID ?? "",
            scenarioID: report?.scenario.id ?? "",
            scenarioName: report?.scenario.name ?? "",
            reasonCode: reasonCode,
            reasonMessage: reasonMessage,
            evidence: report?.error?.evidence,
            systemDisconnectCode: nil,
            systemDisconnectMessage: nil,
            outcome: "recovering",
            events: []
        )
        incident.append(
            type: "disconnected",
            at: timestamp,
            transactionID: report?.transactionID ?? "",
            code: reasonCode,
            message: reasonMessage
        )
        incidents.append(incident)
        if incidents.count > limit {
            incidents.removeFirst(incidents.count - limit)
        }
        return id
    }

    mutating func append(
        incidentID: String,
        type: String,
        at timestamp: Date = Date(),
        attempt: Int = 0,
        transactionID: String = "",
        code: String = "",
        message: String = ""
    ) {
        guard let index = incidents.firstIndex(where: {
            $0.id == incidentID
        }) else {
            return
        }
        incidents[index].append(
            type: type,
            at: timestamp,
            attempt: attempt,
            transactionID: transactionID,
            code: code,
            message: message
        )
    }

    /// The scheduled retry exists because `failedTransactionID` failed; keep
    /// that transaction's code so an incident shows why each attempt ended.
    mutating func recordRetryScheduled(
        incidentID: String,
        at timestamp: Date = Date(),
        attempt: Int,
        failedTransactionID: String,
        failureCode: String?,
        delay: TimeInterval
    ) {
        append(
            incidentID: incidentID,
            type: "retry-scheduled",
            at: timestamp,
            attempt: attempt,
            transactionID: failedTransactionID,
            code: ReconnectIncidentFailureCode.recordable(failureCode),
            message: "Retry scheduled after \(delay)s"
        )
    }

    /// The budget ended with a network-related failure. The incident stays
    /// open: later grants, wake / tail attempts and the final outcome are
    /// appended to it, and no further "exhausted" record is written.
    mutating func recordParked(
        incidentID: String,
        at timestamp: Date = Date(),
        attemptsUsed: Int,
        transactionID: String,
        failureCode: String?
    ) {
        setOutcome(
            incidentID: incidentID,
            outcome: ReconnectIncidentOutcome.parked
        )
        append(
            incidentID: incidentID,
            type: ReconnectIncidentEventType.parked,
            at: timestamp,
            attempt: attemptsUsed,
            transactionID: transactionID,
            code: ReconnectIncidentFailureCode.recordable(failureCode),
            message: "Automatic reconnect paused until the network changes"
        )
    }

    mutating func recordBudgetGranted(
        incidentID: String,
        at timestamp: Date = Date(),
        reason: AutomaticRecoveryGrantReason
    ) {
        setOutcome(
            incidentID: incidentID,
            outcome: ReconnectIncidentOutcome.recovering
        )
        append(
            incidentID: incidentID,
            type: ReconnectIncidentEventType.budgetGranted,
            at: timestamp,
            code: reason.rawValue,
            message: "New automatic reconnect budget granted"
        )
    }

    mutating func recordGrantDeferred(
        incidentID: String,
        at timestamp: Date = Date(),
        reason: AutomaticRecoveryGrantReason,
        until notBefore: Date
    ) {
        append(
            incidentID: incidentID,
            type: ReconnectIncidentEventType.grantDeferred,
            at: timestamp,
            code: reason.rawValue,
            message: "Deferred until "
                + ISO8601DateFormatter().string(from: notBefore)
        )
    }

    /// A wake or slow-tail attempt runs inside the parked epoch; the
    /// incident keeps its parked outcome while it runs.
    mutating func recordSingleAttemptStarted(
        incidentID: String,
        at timestamp: Date = Date(),
        kind: AutomaticRecoveryAttemptKind,
        transactionID: String
    ) {
        let attempt: Int
        switch kind {
        case let .budget(number), let .tail(number):
            attempt = number
        case .wake:
            attempt = 0
        }
        append(
            incidentID: incidentID,
            type: ReconnectIncidentEventType.singleAttemptStarted(kind),
            at: timestamp,
            attempt: attempt,
            transactionID: transactionID
        )
    }

    mutating func recordAttemptFailed(
        incidentID: String,
        at timestamp: Date = Date(),
        attempt: Int,
        transactionID: String,
        failureCode: String?
    ) {
        append(
            incidentID: incidentID,
            type: ReconnectIncidentEventType.attemptFailed,
            at: timestamp,
            attempt: attempt,
            transactionID: transactionID,
            code: ReconnectIncidentFailureCode.recordable(failureCode)
        )
    }

    private mutating func setOutcome(incidentID: String, outcome: String) {
        guard let index = incidents.firstIndex(where: {
            $0.id == incidentID
        }) else {
            return
        }
        incidents[index].outcome = outcome
    }

    mutating func recordSystemDisconnectReason(
        incidentID: String,
        code: String,
        message: String
    ) {
        guard let index = incidents.firstIndex(where: {
            $0.id == incidentID
        }) else {
            return
        }
        if !code.isEmpty {
            incidents[index].systemDisconnectCode = code
        }
        if !message.isEmpty {
            incidents[index].systemDisconnectMessage = message
        }
        incidents[index].append(
            type: "system-disconnect-reason",
            code: code,
            message: message
        )
    }

    mutating func finish(
        incidentID: String,
        outcome: String,
        transactionID: String = "",
        code: String = "",
        message: String = ""
    ) {
        guard let index = incidents.firstIndex(where: {
            $0.id == incidentID
        }) else {
            return
        }
        incidents[index].outcome = outcome
        incidents[index].append(
            type: outcome,
            transactionID: transactionID,
            code: code,
            message: message
        )
    }
}

enum ReconnectIncidentJournal {
    private static let lock = NSLock()

    private static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/"
                    + XDialBuildIdentity.applicationSupportDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent("reconnect-incidents.json")
    }

    static func read() -> ReconnectIncidentHistory {
        lock.lock()
        defer { lock.unlock() }
        return readUnlocked()
    }

    @discardableResult
    static func begin(
        at timestamp: Date,
        trigger: AutomaticReconnectTrigger,
        report: ConnectionReport?,
        reasonCode: String,
        reasonMessage: String
    ) -> String {
        mutate { history in
            history.begin(
                at: timestamp,
                trigger: trigger,
                report: report,
                reasonCode: reasonCode,
                reasonMessage: reasonMessage
            )
        } ?? ""
    }

    static func append(
        incidentID: String,
        type: String,
        attempt: Int = 0,
        transactionID: String = "",
        code: String = "",
        message: String = ""
    ) {
        _ = mutate { history in
            history.append(
                incidentID: incidentID,
                type: type,
                attempt: attempt,
                transactionID: transactionID,
                code: code,
                message: message
            )
        }
    }

    static func recordRetryScheduled(
        incidentID: String,
        attempt: Int,
        failedTransactionID: String,
        failureCode: String?,
        delay: TimeInterval
    ) {
        _ = mutate { history in
            history.recordRetryScheduled(
                incidentID: incidentID,
                attempt: attempt,
                failedTransactionID: failedTransactionID,
                failureCode: failureCode,
                delay: delay
            )
        }
    }

    static func recordParked(
        incidentID: String,
        attemptsUsed: Int,
        transactionID: String,
        failureCode: String?
    ) {
        _ = mutate { history in
            history.recordParked(
                incidentID: incidentID,
                attemptsUsed: attemptsUsed,
                transactionID: transactionID,
                failureCode: failureCode
            )
        }
    }

    static func recordBudgetGranted(
        incidentID: String,
        reason: AutomaticRecoveryGrantReason
    ) {
        _ = mutate { history in
            history.recordBudgetGranted(
                incidentID: incidentID,
                reason: reason
            )
        }
    }

    static func recordGrantDeferred(
        incidentID: String,
        reason: AutomaticRecoveryGrantReason,
        until notBefore: Date
    ) {
        _ = mutate { history in
            history.recordGrantDeferred(
                incidentID: incidentID,
                reason: reason,
                until: notBefore
            )
        }
    }

    static func recordSingleAttemptStarted(
        incidentID: String,
        kind: AutomaticRecoveryAttemptKind,
        transactionID: String
    ) {
        _ = mutate { history in
            history.recordSingleAttemptStarted(
                incidentID: incidentID,
                kind: kind,
                transactionID: transactionID
            )
        }
    }

    static func recordAttemptFailed(
        incidentID: String,
        attempt: Int,
        transactionID: String,
        failureCode: String?
    ) {
        _ = mutate { history in
            history.recordAttemptFailed(
                incidentID: incidentID,
                attempt: attempt,
                transactionID: transactionID,
                failureCode: failureCode
            )
        }
    }

    static func updateReason(
        incidentID: String,
        code: String,
        message: String
    ) {
        _ = mutate { history in
            history.recordSystemDisconnectReason(
                incidentID: incidentID,
                code: code,
                message: message
            )
        }
    }

    static func finish(
        incidentID: String,
        outcome: String,
        transactionID: String = "",
        code: String = "",
        message: String = ""
    ) {
        _ = mutate { history in
            history.finish(
                incidentID: incidentID,
                outcome: outcome,
                transactionID: transactionID,
                code: code,
                message: message
            )
        }
    }

    private static func mutate<T>(
        _ mutation: (inout ReconnectIncidentHistory) -> T
    ) -> T? {
        lock.lock()
        defer { lock.unlock() }
        var history = readUnlocked()
        let result = mutation(&history)
        guard writeUnlocked(history) else {
            return nil
        }
        return result
    }

    private static func readUnlocked() -> ReconnectIncidentHistory {
        guard
            let data = try? Data(contentsOf: fileURL),
            let history = try? JSONDecoder().decode(
                ReconnectIncidentHistory.self,
                from: data
            )
        else {
            return ReconnectIncidentHistory()
        }
        return history
    }

    private static func writeUnlocked(
        _ history: ReconnectIncidentHistory
    ) -> Bool {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder().encode(history)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
            return true
        } catch {
            return false
        }
    }
}
