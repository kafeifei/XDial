import Foundation

/// Host-to-Provider control messages for replacing one committed Scenario
/// transaction while the existing transaction remains live.
///
/// This is deliberately separate from `ProviderDiagnosticsIPC`: diagnostics
/// are read-only, whereas a Scenario switch owns a staged data-plane
/// transaction. The source `ConnectionReport` remains the runtime fact until a
/// successful response returns the target transaction's committed report.
enum ProviderScenarioSwitchCommand: String, Codable {
    case switchScenario = "switch-scenario"
    case cancelSwitch = "cancel-switch"
    /// Read-only recovery for the interval where Provider may have committed
    /// the target but the original `sendProviderMessage` response was lost.
    /// The answer is built from Provider memory, never inferred from either
    /// host or Provider journals.
    case reconcileSwitch = "reconcile-switch"
}

struct ProviderScenarioSwitchRequest: Codable, Equatable {
    let v: Int
    let cmd: ProviderScenarioSwitchCommand
    let requestID: String
    let expectedTransactionID: String
    let targetTransactionID: String?
    let profileJSON: String?
    let connectionReportJSON: String?
    let underlayInterfacesJSON: String?
    let underlayDefaultName: String?
    let underlayDefaultIndex: Int?
    let systemDNSJSON: String?

    enum CodingKeys: String, CodingKey {
        case v
        case cmd
        case requestID = "request_id"
        case expectedTransactionID = "expected_transaction_id"
        case targetTransactionID = "target_transaction_id"
        case profileJSON = "profile_json"
        case connectionReportJSON = "connection_report_json"
        case underlayInterfacesJSON = "underlay_interfaces"
        case underlayDefaultName = "underlay_default_name"
        case underlayDefaultIndex = "underlay_default_index"
        case systemDNSJSON = "system_dns"
    }

    static func switchScenario(
        requestID: String,
        expectedTransactionID: String,
        targetTransactionID: String,
        profileJSON: String,
        connectionReportJSON: String,
        underlayInterfacesJSON: String,
        underlayDefaultName: String,
        underlayDefaultIndex: Int,
        systemDNSJSON: String
    ) -> ProviderScenarioSwitchRequest {
        ProviderScenarioSwitchRequest(
            v: ProviderScenarioSwitchCodec.version,
            cmd: .switchScenario,
            requestID: requestID,
            expectedTransactionID: expectedTransactionID,
            targetTransactionID: targetTransactionID,
            profileJSON: profileJSON,
            connectionReportJSON: connectionReportJSON,
            underlayInterfacesJSON: underlayInterfacesJSON,
            underlayDefaultName: underlayDefaultName,
            underlayDefaultIndex: underlayDefaultIndex,
            systemDNSJSON: systemDNSJSON
        )
    }

    static func cancelSwitch(
        requestID: String,
        expectedTransactionID: String
    ) -> ProviderScenarioSwitchRequest {
        ProviderScenarioSwitchRequest(
            v: ProviderScenarioSwitchCodec.version,
            cmd: .cancelSwitch,
            requestID: requestID,
            expectedTransactionID: expectedTransactionID,
            targetTransactionID: nil,
            profileJSON: nil,
            connectionReportJSON: nil,
            underlayInterfacesJSON: nil,
            underlayDefaultName: nil,
            underlayDefaultIndex: nil,
            systemDNSJSON: nil
        )
    }

    static func reconcileSwitch(
        requestID: String,
        expectedTransactionID: String,
        targetTransactionID: String
    ) -> ProviderScenarioSwitchRequest {
        ProviderScenarioSwitchRequest(
            v: ProviderScenarioSwitchCodec.version,
            cmd: .reconcileSwitch,
            requestID: requestID,
            expectedTransactionID: expectedTransactionID,
            targetTransactionID: targetTransactionID,
            profileJSON: nil,
            connectionReportJSON: nil,
            underlayInterfacesJSON: nil,
            underlayDefaultName: nil,
            underlayDefaultIndex: nil,
            systemDNSJSON: nil
        )
    }
}

struct ProviderScenarioSwitchResponse: Codable, Equatable {
    let v: Int
    let cmd: ProviderScenarioSwitchCommand
    let requestID: String
    let ok: Bool
    let sourceTransactionID: String
    let activeTransactionID: String
    let code: String?
    let message: String?
    let reportJSON: String?
    /// Present only for `reconcile-switch`. `true` means the source report is
    /// still authoritative but the candidate has not crossed a terminal
    /// outcome, so the host must keep the result unknown and poll again.
    let switchInProgress: Bool?

    enum CodingKeys: String, CodingKey {
        case v
        case cmd
        case requestID = "request_id"
        case ok
        case sourceTransactionID = "source_transaction_id"
        case activeTransactionID = "active_transaction_id"
        case code
        case message
        case reportJSON = "report_json"
        case switchInProgress = "switch_in_progress"
    }

    init(
        v: Int,
        cmd: ProviderScenarioSwitchCommand,
        requestID: String,
        ok: Bool,
        sourceTransactionID: String,
        activeTransactionID: String,
        code: String?,
        message: String?,
        reportJSON: String?,
        switchInProgress: Bool? = nil
    ) {
        self.v = v
        self.cmd = cmd
        self.requestID = requestID
        self.ok = ok
        self.sourceTransactionID = sourceTransactionID
        self.activeTransactionID = activeTransactionID
        self.code = code
        self.message = message
        self.reportJSON = reportJSON
        self.switchInProgress = switchInProgress
    }
}

enum ProviderScenarioSwitchCodecError: Error, Equatable {
    case requestTooLarge
    case responseTooLarge
    case malformed
    case unsupportedVersion
    case unknownCommand
}

enum ProviderScenarioSwitchReconciliationResolution: Equatable {
    case targetCommitted
    case sourceInProgress
    case sourceRestored
    case unrelatedTransaction
}

enum ProviderScenarioSwitchReconciliation {
    static func resolve(
        sourceTransactionID: String,
        targetTransactionID: String,
        activeTransactionID: String,
        switchInProgress: Bool
    ) -> ProviderScenarioSwitchReconciliationResolution {
        if activeTransactionID == targetTransactionID {
            return .targetCommitted
        }
        if activeTransactionID == sourceTransactionID {
            return switchInProgress
                ? .sourceInProgress
                : .sourceRestored
        }
        return .unrelatedTransaction
    }
}

enum ProviderScenarioSwitchCodec {
    static let version = 1
    static let maximumRequestBytes = 8 * 1_024 * 1_024
    static let maximumResponseBytes = 2 * 1_024 * 1_024

    static func encodeRequest(
        _ request: ProviderScenarioSwitchRequest
    ) throws -> Data {
        let data = try JSONEncoder().encode(request)
        guard data.count <= maximumRequestBytes else {
            throw ProviderScenarioSwitchCodecError.requestTooLarge
        }
        return data
    }

    static func decodeRequest(
        _ data: Data
    ) throws -> ProviderScenarioSwitchRequest {
        guard data.count <= maximumRequestBytes else {
            throw ProviderScenarioSwitchCodecError.requestTooLarge
        }
        let object = try dictionary(from: data)
        let version = try validatedVersion(in: object)
        guard version == self.version else {
            throw ProviderScenarioSwitchCodecError.unsupportedVersion
        }
        guard
            let rawCommand = object["cmd"] as? String,
            let command = ProviderScenarioSwitchCommand(rawValue: rawCommand)
        else {
            throw ProviderScenarioSwitchCodecError.unknownCommand
        }

        var allowedKeys: Set<String> = [
            "v", "cmd", "request_id", "expected_transaction_id",
        ]
        if command == .switchScenario {
            allowedKeys.formUnion([
                "target_transaction_id", "profile_json",
                "connection_report_json", "underlay_interfaces",
                "underlay_default_name", "underlay_default_index",
                "system_dns",
            ])
        } else if command == .reconcileSwitch {
            allowedKeys.insert("target_transaction_id")
        }
        guard Set(object.keys) == allowedKeys else {
            throw ProviderScenarioSwitchCodecError.malformed
        }
        guard
            let request = try? JSONDecoder().decode(
                ProviderScenarioSwitchRequest.self,
                from: data
            ),
            request.v == self.version,
            request.cmd == command,
            isSafeIdentifier(request.requestID),
            isSafeIdentifier(request.expectedTransactionID)
        else {
            throw ProviderScenarioSwitchCodecError.malformed
        }

        switch command {
        case .switchScenario:
            guard
                let targetTransactionID = request.targetTransactionID,
                isSafeIdentifier(targetTransactionID),
                targetTransactionID != request.expectedTransactionID,
                let profileJSON = request.profileJSON,
                isJSONObject(profileJSON),
                let connectionReportJSON = request.connectionReportJSON,
                isJSONObject(connectionReportJSON),
                let interfacesJSON = request.underlayInterfacesJSON,
                isJSONArray(interfacesJSON),
                let defaultName = request.underlayDefaultName,
                isSafeIdentifier(defaultName),
                let defaultIndex = request.underlayDefaultIndex,
                defaultIndex > 0,
                defaultIndex <= Int(Int32.max),
                let systemDNSJSON = request.systemDNSJSON,
                isJSONArray(systemDNSJSON)
            else {
                throw ProviderScenarioSwitchCodecError.malformed
            }
        case .cancelSwitch:
            guard
                request.targetTransactionID == nil,
                request.profileJSON == nil,
                request.connectionReportJSON == nil,
                request.underlayInterfacesJSON == nil,
                request.underlayDefaultName == nil,
                request.underlayDefaultIndex == nil,
                request.systemDNSJSON == nil
            else {
                throw ProviderScenarioSwitchCodecError.malformed
            }
        case .reconcileSwitch:
            guard
                let targetTransactionID = request.targetTransactionID,
                isSafeIdentifier(targetTransactionID),
                targetTransactionID != request.expectedTransactionID,
                request.profileJSON == nil,
                request.connectionReportJSON == nil,
                request.underlayInterfacesJSON == nil,
                request.underlayDefaultName == nil,
                request.underlayDefaultIndex == nil,
                request.systemDNSJSON == nil
            else {
                throw ProviderScenarioSwitchCodecError.malformed
            }
        }
        return request
    }

    static func encodeResponse(
        _ response: ProviderScenarioSwitchResponse
    ) throws -> Data {
        let data = try JSONEncoder().encode(response)
        guard data.count <= maximumResponseBytes else {
            throw ProviderScenarioSwitchCodecError.responseTooLarge
        }
        return data
    }

    static func decodeResponse(
        _ data: Data
    ) throws -> ProviderScenarioSwitchResponse {
        guard data.count <= maximumResponseBytes else {
            throw ProviderScenarioSwitchCodecError.responseTooLarge
        }
        let object = try dictionary(from: data)
        let version = try validatedVersion(in: object)
        guard version == self.version else {
            throw ProviderScenarioSwitchCodecError.unsupportedVersion
        }
        guard
            let rawCommand = object["cmd"] as? String,
            ProviderScenarioSwitchCommand(rawValue: rawCommand) != nil,
            let response = try? JSONDecoder().decode(
                ProviderScenarioSwitchResponse.self,
                from: data
            ),
            response.v == self.version,
            isSafeIdentifier(response.requestID),
            isSafeIdentifier(response.sourceTransactionID),
            isSafeIdentifier(response.activeTransactionID)
        else {
            throw ProviderScenarioSwitchCodecError.malformed
        }

        let allowedKeys: Set<String> = [
            "v", "cmd", "request_id", "ok", "source_transaction_id",
            "active_transaction_id", "code", "message", "report_json",
            "switch_in_progress",
        ]
        guard Set(object.keys).isSubset(of: allowedKeys) else {
            throw ProviderScenarioSwitchCodecError.malformed
        }
        if response.ok {
            guard response.code == nil else {
                throw ProviderScenarioSwitchCodecError.malformed
            }
            switch response.cmd {
            case .switchScenario:
                guard
                    let reportJSON = response.reportJSON,
                    isJSONObject(reportJSON),
                    response.switchInProgress == nil,
                    response.activeTransactionID
                        != response.sourceTransactionID
                else {
                    throw ProviderScenarioSwitchCodecError.malformed
                }
            case .cancelSwitch:
                guard
                    response.reportJSON == nil,
                    response.switchInProgress == nil,
                    response.activeTransactionID
                        == response.sourceTransactionID
                else {
                    throw ProviderScenarioSwitchCodecError.malformed
                }
            case .reconcileSwitch:
                guard
                    let reportJSON = response.reportJSON,
                    isJSONObject(reportJSON),
                    response.switchInProgress != nil
                else {
                    throw ProviderScenarioSwitchCodecError.malformed
                }
            }
        } else {
            guard
                let code = response.code,
                isSafeCode(code),
                response.reportJSON == nil,
                response.switchInProgress == nil
            else {
                throw ProviderScenarioSwitchCodecError.malformed
            }
            switch response.cmd {
            case .switchScenario:
                guard response.activeTransactionID
                        == response.sourceTransactionID else {
                    throw ProviderScenarioSwitchCodecError.malformed
                }
            case .cancelSwitch:
                // Cancellation loses a race only after the target's commit
                // point. That one response must identify the committed target;
                // every other cancellation failure still leaves source active.
                if code == "switch-already-committed" {
                    guard response.activeTransactionID
                            != response.sourceTransactionID else {
                        throw ProviderScenarioSwitchCodecError.malformed
                    }
                } else {
                    guard response.activeTransactionID
                            == response.sourceTransactionID else {
                        throw ProviderScenarioSwitchCodecError.malformed
                    }
                }
            case .reconcileSwitch:
                break
            }
        }
        return response
    }

    private static func dictionary(
        from data: Data
    ) throws -> [String: Any] {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            throw ProviderScenarioSwitchCodecError.malformed
        }
        return dictionary
    }

    private static func validatedVersion(
        in object: [String: Any]
    ) throws -> Int {
        guard
            let number = object["v"] as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            throw ProviderScenarioSwitchCodecError.malformed
        }
        return number.intValue
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        guard
            !value.isEmpty,
            value.utf8.count <= 128,
            value == value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || $0 == "-" || $0 == "_" || $0 == "."
        }
    }

    private static func isSafeCode(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy {
            ($0.value >= 97 && $0.value <= 122)
                || ($0.value >= 48 && $0.value <= 57)
                || $0 == "-"
        }
    }

    private static func isJSONObject(_ value: String) -> Bool {
        guard
            let data = value.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return false
        }
        return object is [String: Any]
    }

    private static func isJSONArray(_ value: String) -> Bool {
        guard
            let data = value.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return false
        }
        return object is [Any]
    }
}
