import Foundation

struct OutboundTLSFamilyProbeResult: Codable, Equatable {
    let available: Bool
    let attempts: Int
    let tcpConnected: Int
    let tlsAuthenticated: Int
    let failureCodes: [String: Int]

    enum CodingKeys: String, CodingKey {
        case available
        case attempts
        case tcpConnected = "tcp_connected"
        case tlsAuthenticated = "tls_authenticated"
        case failureCodes = "failure_codes"
    }
}

struct OutboundTLSCapabilityProbeResult: Codable, Equatable {
    let ipv4: OutboundTLSFamilyProbeResult
    let ipv6: OutboundTLSFamilyProbeResult
}

/// Immutable, per-transaction reachability facts for one active Line. These
/// facts are measured through the exact Line outbound and never enter Profile
/// persistence.
struct LineAddressFamilyCapability: Codable, Equatable {
    let ipv4Available: Bool
    let ipv6Available: Bool

    enum CodingKeys: String, CodingKey {
        case ipv4Available = "ipv4_available"
        case ipv6Available = "ipv6_available"
    }

    static let dualStack = LineAddressFamilyCapability(
        ipv4Available: true,
        ipv6Available: true
    )

    var isUsable: Bool {
        ipv4Available || ipv6Available
    }

    var isDegraded: Bool {
        isUsable && !(ipv4Available && ipv6Available)
    }

    var strategy: String? {
        switch (ipv4Available, ipv6Available) {
        case (true, true):
            nil
        case (true, false):
            "ipv4_only"
        case (false, true):
            "ipv6_only"
        case (false, false):
            nil
        }
    }

    var reportCode: String {
        switch (ipv4Available, ipv6Available) {
        case (true, true):
            "line-address-family-ready"
        case (true, false):
            "line-ipv6-egress-unavailable"
        case (false, true):
            "line-ipv4-egress-unavailable"
        case (false, false):
            "line-address-family-unavailable"
        }
    }

    var reportMessage: String {
        switch (ipv4Available, ipv6Available) {
        case (true, true):
            "线路已验证 IPv4 / IPv6 双栈出口"
        case (true, false):
            "线路 IPv6 出口不可用，本次事务已收敛到 IPv4"
        case (false, true):
            "线路 IPv4 出口不可用，本次事务已收敛到 IPv6"
        case (false, false):
            "线路 IPv4 / IPv6 出口均不可用"
        }
    }

    var reportFacts: [String: Bool] {
        [
            "ipv4_available": ipv4Available,
            "ipv6_available": ipv6Available,
            "degraded": isDegraded,
        ]
    }
}

enum LineAddressFamilyCapabilityConvergence {
    static func requiresRegeneration(
        capabilities: [String: LineAddressFamilyCapability],
        nonDirectLineIDs: Set<String>
    ) -> Bool {
        nonDirectLineIDs.contains { lineID in
            capabilities[lineID]?.isDegraded == true
        }
    }

    static func isStable(
        baseline: [String: LineAddressFamilyCapability],
        constrained: [String: LineAddressFamilyCapability]
    ) -> Bool {
        baseline == constrained
    }
}

enum LineAddressFamilyCapabilityCodec {
    private static let failureCodes: Set<String> = [
        "timeout",
        "cancelled",
        "tcp-connect-failed",
        "tls-peer-closed",
        "tls-authentication-failed",
        "tls-handshake-failed",
    ]

    static func decodeProbe(_ raw: String) throws
        -> OutboundTLSCapabilityProbeResult
    {
        guard let data = raw.data(using: .utf8) else {
            throw CodecError.invalidProbe
        }
        do {
            let result = try JSONDecoder().decode(
                OutboundTLSCapabilityProbeResult.self,
                from: data
            )
            guard
                result.ipv4.attempts > 0,
                result.ipv6.attempts > 0,
                result.ipv4.tcpConnected >= 0,
                result.ipv6.tcpConnected >= 0,
                result.ipv4.tlsAuthenticated >= 0,
                result.ipv6.tlsAuthenticated >= 0,
                result.ipv4.tcpConnected <= result.ipv4.attempts,
                result.ipv6.tcpConnected <= result.ipv6.attempts,
                result.ipv4.tlsAuthenticated <= result.ipv4.tcpConnected,
                result.ipv6.tlsAuthenticated <= result.ipv6.tcpConnected,
                result.ipv4.available ==
                    (result.ipv4.tlsAuthenticated > 0),
                result.ipv6.available ==
                    (result.ipv6.tlsAuthenticated > 0),
                isValidFailures(result.ipv4),
                isValidFailures(result.ipv6)
            else {
                throw CodecError.invalidProbe
            }
            return result
        } catch let error as CodecError {
            throw error
        } catch {
            throw CodecError.invalidProbe
        }
    }

    static func capability(
        from result: OutboundTLSCapabilityProbeResult
    ) -> LineAddressFamilyCapability {
        LineAddressFamilyCapability(
            ipv4Available: result.ipv4.available,
            ipv6Available: result.ipv6.available
        )
    }

    private static func isValidFailures(
        _ family: OutboundTLSFamilyProbeResult
    ) -> Bool {
        Set(family.failureCodes.keys).isSubset(of: failureCodes) &&
            family.failureCodes.values.allSatisfy({ $0 > 0 }) &&
            family.failureCodes.values.reduce(0, +) +
                family.tlsAuthenticated == family.attempts
    }

    static func encodeSnapshot(
        _ capabilities: [String: LineAddressFamilyCapability]
    ) throws -> String {
        guard
            !capabilities.isEmpty,
            capabilities.allSatisfy({
                !$0.key.isEmpty && $0.value.isUsable
            })
        else {
            throw CodecError.invalidSnapshot
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(capabilities)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw CodecError.invalidSnapshot
        }
        return encoded
    }

    enum CodecError: LocalizedError, Equatable {
        case invalidProbe
        case invalidSnapshot

        var errorDescription: String? {
            switch self {
            case .invalidProbe:
                "线路地址族探测结果无效"
            case .invalidSnapshot:
                "线路地址族能力快照无效"
            }
        }
    }
}
