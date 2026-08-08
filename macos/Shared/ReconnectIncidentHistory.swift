import Foundation

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
                "Library/Application Support/XDial",
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
