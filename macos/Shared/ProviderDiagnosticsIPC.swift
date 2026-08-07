import Foundation

enum ProviderDiagnosticsCommand: String, Codable {
    case probeLineOutboundAddress = "probe-line-outbound-address"
    case routingProbeSnapshot = "routing-probe-snapshot"
    case beginRouteProbe = "begin-route-probe"
    case applicationAttributionSnapshot = "application-attribution-snapshot"
    case trafficSnapshot = "traffic-snapshot"
}

struct ProviderDiagnosticsRequest: Codable, Equatable {
    let v: Int
    let cmd: ProviderDiagnosticsCommand
    let transactionID: String
    let lineID: String?
    let probeID: String?
    let host: String?
    let port: Int?
    let timeoutMS: Int?

    enum CodingKeys: String, CodingKey {
        case v
        case cmd
        case transactionID = "transaction_id"
        case lineID = "line_id"
        case probeID = "probe_id"
        case host
        case port
        case timeoutMS = "timeout_ms"
    }

    init(
        v: Int = ProviderDiagnosticsCodec.version,
        cmd: ProviderDiagnosticsCommand,
        transactionID: String,
        lineID: String? = nil,
        probeID: String? = nil,
        host: String? = nil,
        port: Int? = nil,
        timeoutMS: Int? = nil
    ) {
        self.v = v
        self.cmd = cmd
        self.transactionID = transactionID
        self.lineID = lineID
        self.probeID = probeID
        self.host = host
        self.port = port
        self.timeoutMS = timeoutMS
    }
}

struct ProviderRoutingProbeSnapshot: Codable, Equatable {
    let probeID: String
    let matchCount: Int
    let candidateAddressCount: Int
    let outboundTagCounts: [String: Int]
    let lineIDCounts: [String: Int]
    let ruleSetTag: String?

    enum CodingKeys: String, CodingKey {
        case probeID = "probe_id"
        case matchCount = "match_count"
        case candidateAddressCount = "candidate_address_count"
        case outboundTagCounts = "outbound_tag_counts"
        case lineIDCounts = "line_id_counts"
        case ruleSetTag = "rule_set_tag"
    }

    init(
        probeID: String,
        matchCount: Int,
        candidateAddressCount: Int = 0,
        outboundTagCounts: [String: Int],
        lineIDCounts: [String: Int] = [:],
        ruleSetTag: String? = nil
    ) {
        self.probeID = probeID
        self.matchCount = matchCount
        self.candidateAddressCount = candidateAddressCount
        self.outboundTagCounts = outboundTagCounts
        self.lineIDCounts = lineIDCounts
        self.ruleSetTag = ruleSetTag
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        probeID = try values.decode(String.self, forKey: .probeID)
        matchCount = try values.decode(Int.self, forKey: .matchCount)
        candidateAddressCount = try values.decodeIfPresent(
            Int.self,
            forKey: .candidateAddressCount
        ) ?? 0
        outboundTagCounts = try values.decode(
            [String: Int].self,
            forKey: .outboundTagCounts
        )
        lineIDCounts = try values.decodeIfPresent(
            [String: Int].self,
            forKey: .lineIDCounts
        ) ?? [:]
        ruleSetTag = try values.decodeIfPresent(
            String.self,
            forKey: .ruleSetTag
        )
    }

    func restrictedToActiveCapabilities(
        lineOutbounds: [String: String],
        ruleSetTags: Set<String>
    ) -> ProviderRoutingProbeSnapshot {
        var lineIDsByTag: [String: [String]] = [:]
        for (lineID, outboundTag) in lineOutbounds
        where !lineID.isEmpty && !outboundTag.isEmpty {
            lineIDsByTag[outboundTag, default: []].append(lineID)
        }

        var filteredTags: [String: Int] = [:]
        var attributedLines: [String: Int] = [:]
        for (outboundTag, count) in outboundTagCounts where count >= 0 {
            guard let lineIDs = lineIDsByTag[outboundTag] else {
                continue
            }
            filteredTags[outboundTag] = count
            // Multiple active Line IDs sharing one tag are ambiguous. Keep
            // the known tag evidence, but never guess which Line matched.
            guard lineIDs.count == 1, let lineID = lineIDs.first else {
                continue
            }
            attributedLines[lineID] = count
        }
        return ProviderRoutingProbeSnapshot(
            probeID: probeID,
            matchCount: max(0, matchCount),
            candidateAddressCount: max(0, candidateAddressCount),
            outboundTagCounts: filteredTags,
            lineIDCounts: attributedLines,
            ruleSetTag: ruleSetTag.flatMap {
                ruleSetTags.contains($0) ? $0 : nil
            }
        )
    }
}

struct ProviderLineOutboundAddress: Codable, Equatable {
    let lineID: String
    let address: String

    enum CodingKeys: String, CodingKey {
        case lineID = "line_id"
        case address
    }

    init(lineID: String, address: String) {
        self.lineID = lineID
        self.address = address
    }
}

struct ProviderBegunRouteProbe: Codable, Equatable {
    let probeID: String

    enum CodingKeys: String, CodingKey {
        case probeID = "probe_id"
    }

    init(probeID: String) {
        self.probeID = probeID
    }
}

/// 仅描述当前 Provider 事务内的应用归因结果，不包含目标域名、IP、路径或凭据。
struct ProviderApplicationAttributionSnapshot: Codable, Equatable {
    let activeSelectorKindCounts: [String: Int]
    let matchedFlowCount: Int
    let matchedSelectorKindCounts: [String: Int]
    let matchedRuleSetIDCounts: [String: Int]
    let matchedLineIDCounts: [String: Int]
    let matchedSubscriptionIDCounts: [String: Int]
    let baseFlowCount: Int
    let baseMissingSourceIdentityCount: Int
    let rejectedFlowCount: Int
    let rejectedUnresolvedAuditTokenCount: Int

    enum CodingKeys: String, CodingKey {
        case activeSelectorKindCounts = "active_selector_kind_counts"
        case matchedFlowCount = "matched_flow_count"
        case matchedSelectorKindCounts = "matched_selector_kind_counts"
        case matchedRuleSetIDCounts = "matched_rule_set_id_counts"
        case matchedLineIDCounts = "matched_line_id_counts"
        case matchedSubscriptionIDCounts = "matched_subscription_id_counts"
        case baseFlowCount = "base_flow_count"
        case baseMissingSourceIdentityCount =
            "base_missing_source_identity_count"
        case rejectedFlowCount = "rejected_flow_count"
        case rejectedUnresolvedAuditTokenCount =
            "rejected_unresolved_audit_token_count"
    }
}

/// 当前已提交 Provider 事务转发给应用层的净荷字节累计值。
///
/// 这里只统计 Transparent Proxy relay 实际完成转发的 TCP/UDP payload；不把
/// Underlay 接口、SOCKS framing 或其他进程流量混进来。
struct ProviderTrafficSnapshot: Codable, Equatable {
    let downloadBytes: UInt64
    let uploadBytes: UInt64

    enum CodingKeys: String, CodingKey {
        case downloadBytes = "download_bytes"
        case uploadBytes = "upload_bytes"
    }
}

struct ProviderDiagnosticsData: Codable, Equatable {
    let routingProbe: ProviderRoutingProbeSnapshot?
    let lineOutboundAddress: ProviderLineOutboundAddress?
    let begunRouteProbe: ProviderBegunRouteProbe?
    let applicationAttribution:
        ProviderApplicationAttributionSnapshot?
    let traffic: ProviderTrafficSnapshot?

    enum CodingKeys: String, CodingKey {
        case routingProbe = "routing_probe"
        case lineOutboundAddress = "line_outbound_address"
        case begunRouteProbe = "begun_route_probe"
        case applicationAttribution = "application_attribution"
        case traffic
    }

    init(
        routingProbe: ProviderRoutingProbeSnapshot? = nil,
        lineOutboundAddress: ProviderLineOutboundAddress? = nil,
        begunRouteProbe: ProviderBegunRouteProbe? = nil,
        applicationAttribution:
            ProviderApplicationAttributionSnapshot? = nil,
        traffic: ProviderTrafficSnapshot? = nil
    ) {
        self.routingProbe = routingProbe
        self.lineOutboundAddress = lineOutboundAddress
        self.begunRouteProbe = begunRouteProbe
        self.applicationAttribution = applicationAttribution
        self.traffic = traffic
    }
}

struct ProviderDiagnosticsResponse: Codable, Equatable {
    let v: Int
    let ok: Bool
    let transactionID: String
    let data: ProviderDiagnosticsData?
    let code: String?

    enum CodingKeys: String, CodingKey {
        case v
        case ok
        case transactionID = "transaction_id"
        case data
        case code
    }

    init(
        v: Int = ProviderDiagnosticsCodec.version,
        ok: Bool,
        transactionID: String,
        data: ProviderDiagnosticsData? = nil,
        code: String? = nil
    ) {
        self.v = v
        self.ok = ok
        self.transactionID = transactionID
        self.data = data
        self.code = code
    }

    static func success(
        transactionID: String,
        data: ProviderDiagnosticsData
    ) -> ProviderDiagnosticsResponse {
        ProviderDiagnosticsResponse(
            ok: true,
            transactionID: transactionID,
            data: data
        )
    }

    static func failure(
        transactionID: String,
        code: String
    ) -> ProviderDiagnosticsResponse {
        ProviderDiagnosticsResponse(
            ok: false,
            transactionID: transactionID,
            code: code
        )
    }
}

enum ProviderDiagnosticsCodecError: Error, Equatable {
    case requestTooLarge
    case invalidRequest
    case unsupportedVersion
    case unknownCommand

    var responseCode: String {
        switch self {
        case .requestTooLarge:
            "request-too-large"
        case .invalidRequest:
            "invalid-request"
        case .unsupportedVersion:
            "unsupported-version"
        case .unknownCommand:
            "unknown-command"
        }
    }
}

struct ProviderDiagnosticsSessionState: Equatable {
    let transactionID: String
    let hasRuntime: Bool
    let hasSession: Bool
    let hasReporter: Bool
    let settingsCommitted: Bool
    let settingsCommitInFlight: Bool
    let rollbackInProgress: Bool

    init(
        transactionID: String,
        hasRuntime: Bool,
        hasSession: Bool,
        hasReporter: Bool,
        settingsCommitted: Bool,
        settingsCommitInFlight: Bool,
        rollbackInProgress: Bool
    ) {
        self.transactionID = transactionID
        self.hasRuntime = hasRuntime
        self.hasSession = hasSession
        self.hasReporter = hasReporter
        self.settingsCommitted = settingsCommitted
        self.settingsCommitInFlight = settingsCommitInFlight
        self.rollbackInProgress = rollbackInProgress
    }
}

enum ProviderDiagnosticsGate {
    static func rejectionCode(
        requestTransactionID: String,
        state: ProviderDiagnosticsSessionState
    ) -> String? {
        guard requestTransactionID == state.transactionID else {
            return "stale-session"
        }
        guard
            state.hasRuntime,
            state.hasSession,
            state.hasReporter,
            state.settingsCommitted,
            !state.settingsCommitInFlight,
            !state.rollbackInProgress
        else {
            return "session-not-committed"
        }
        return nil
    }

    static func commandRejectionCode(
        _ command: ProviderDiagnosticsCommand,
        debugCommandsEnabled: Bool
    ) -> String? {
        if !debugCommandsEnabled &&
            (command == .beginRouteProbe ||
                command == .routingProbeSnapshot)
        {
            return "debug-command-unavailable"
        }
        return nil
    }

    static func routeProbeSnapshotRejectionCode(
        expectedProbeID: String,
        actualProbeID: String
    ) -> String? {
        expectedProbeID == actualProbeID ? nil : "stale-probe"
    }
}

final class ProviderDiagnosticsOperationGate {
    struct Token: Equatable {
        fileprivate let epoch: UInt64
        let transactionID: String
    }

    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var inFlight = false

    func begin(transactionID: String) -> Token? {
        lock.lock()
        defer { lock.unlock() }
        guard !inFlight else { return nil }
        inFlight = true
        return Token(epoch: epoch, transactionID: transactionID)
    }

    func invalidate() {
        lock.lock()
        epoch &+= 1
        inFlight = false
        lock.unlock()
    }

    func isCurrent(_ token: Token) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token.epoch == epoch
    }

    func finish(_ token: Token) {
        lock.lock()
        if token.epoch == epoch {
            inFlight = false
        }
        lock.unlock()
    }
}

enum ProviderDiagnosticsCodec {
    static let version = 1
    static let maximumRequestBytes = 4 * 1_024
    static let maximumRouteProbeTimeoutMS = 15_000

    private static let baseKeys: Set<String> = [
        "v",
        "cmd",
        "transaction_id",
    ]

    static func encodeRequest(
        _ request: ProviderDiagnosticsRequest
    ) throws -> Data {
        try JSONEncoder().encode(request)
    }

    static func decodeRequest(
        _ data: Data
    ) throws -> ProviderDiagnosticsRequest {
        guard data.count <= maximumRequestBytes else {
            throw ProviderDiagnosticsCodecError.requestTooLarge
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any],
            let rawVersion = dictionary["v"] as? NSNumber,
            CFGetTypeID(rawVersion) != CFBooleanGetTypeID()
        else {
            throw ProviderDiagnosticsCodecError.invalidRequest
        }
        guard rawVersion.intValue == version else {
            throw ProviderDiagnosticsCodecError.unsupportedVersion
        }
        guard
            let rawCommand = dictionary["cmd"] as? String
        else {
            throw ProviderDiagnosticsCodecError.invalidRequest
        }
        guard
            let command = ProviderDiagnosticsCommand(
                rawValue: rawCommand
            )
        else {
            throw ProviderDiagnosticsCodecError.unknownCommand
        }

        var allowedKeys = baseKeys
        switch command {
        case .applicationAttributionSnapshot, .trafficSnapshot:
            break
        case .routingProbeSnapshot:
            allowedKeys.insert("probe_id")
        case .probeLineOutboundAddress:
            allowedKeys.insert("line_id")
        case .beginRouteProbe:
            allowedKeys.formUnion(["host", "port", "timeout_ms"])
        }
        guard Set(dictionary.keys) == allowedKeys else {
            throw ProviderDiagnosticsCodecError.invalidRequest
        }
        guard
            let request = try? JSONDecoder().decode(
                ProviderDiagnosticsRequest.self,
                from: data
            ),
            request.v == version,
            request.cmd == command,
            isSafeOpaqueID(request.transactionID, maximumBytes: 128)
        else {
            throw ProviderDiagnosticsCodecError.invalidRequest
        }
        switch request.cmd {
        case .applicationAttributionSnapshot, .trafficSnapshot:
            break
        case .routingProbeSnapshot:
            guard
                let probeID = request.probeID,
                isSafeOpaqueID(probeID, maximumBytes: 128)
            else {
                throw ProviderDiagnosticsCodecError.invalidRequest
            }
        case .probeLineOutboundAddress:
            guard
                let lineID = request.lineID,
                isSafeOpaqueID(lineID, maximumBytes: 256)
            else {
                throw ProviderDiagnosticsCodecError.invalidRequest
            }
        case .beginRouteProbe:
            guard
                let host = request.host,
                isValidASCIIHostname(host),
                request.port == 443,
                let timeoutMS = request.timeoutMS,
                timeoutMS > 0,
                timeoutMS <= maximumRouteProbeTimeoutMS
            else {
                throw ProviderDiagnosticsCodecError.invalidRequest
            }
        }
        return request
    }

    static func encodeResponse(
        _ response: ProviderDiagnosticsResponse
    ) throws -> Data {
        try JSONEncoder().encode(response)
    }

    static func decodeResponse(
        _ data: Data
    ) throws -> ProviderDiagnosticsResponse {
        let response = try JSONDecoder().decode(
            ProviderDiagnosticsResponse.self,
            from: data
        )
        guard
            response.v == version,
            isSafeOpaqueID(
                response.transactionID,
                maximumBytes: 128,
                allowEmpty: true
            ),
            response.ok != (response.code != nil),
            response.ok == (response.data != nil)
        else {
            throw ProviderDiagnosticsCodecError.invalidRequest
        }
        return response
    }

    private static func isSafeOpaqueID(
        _ value: String,
        maximumBytes: Int,
        allowEmpty: Bool = false
    ) -> Bool {
        if value.isEmpty {
            return allowEmpty
        }
        guard
            value == value.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            !value.utf8.isEmpty,
            value.utf8.count <= maximumBytes
        else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }

    private static func isValidASCIIHostname(_ hostname: String) -> Bool {
        guard
            hostname == hostname.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            !hostname.isEmpty,
            hostname.utf8.count <= 253,
            hostname.unicodeScalars.allSatisfy({ $0.value <= 0x7f })
        else {
            return false
        }
        let labels = hostname.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard !labels.isEmpty else { return false }
        for label in labels {
            guard
                !label.isEmpty,
                label.utf8.count <= 63,
                label.first != "-",
                label.last != "-"
            else {
                return false
            }
            for byte in label.utf8 {
                guard
                    (byte >= 0x41 && byte <= 0x5a) ||
                    (byte >= 0x61 && byte <= 0x7a) ||
                    (byte >= 0x30 && byte <= 0x39) ||
                    byte == 0x2d
                else {
                    return false
                }
            }
        }
        // A route experiment needs a hostname, not an address literal.
        return hostname.split(separator: ".").contains {
            $0.utf8.contains { $0 < 0x30 || $0 > 0x39 }
        }
    }
}
