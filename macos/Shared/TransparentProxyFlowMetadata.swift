import Foundation
import Network

/// A stable macOS code-signing identity. The value must stay byte-for-byte
/// aligned with the identity collected by the control plane; it is the only
/// application fact allowed across the transparent-proxy relay boundary.
struct TransparentProxyApplicationIdentity: Sendable, Equatable {
    let teamIdentifier: String
    let signingIdentifier: String

    init?(teamIdentifier: String, signingIdentifier: String) {
        guard
            Self.isValidTeamIdentifier(teamIdentifier),
            Self.isValidSigningIdentifier(signingIdentifier)
        else {
            return nil
        }
        self.teamIdentifier = teamIdentifier
        self.signingIdentifier = signingIdentifier
    }

    var canonical: String {
        "\(teamIdentifier)/\(signingIdentifier)"
    }

    private static func isValidTeamIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 10 && bytes.allSatisfy {
            ($0 >= 0x41 && $0 <= 0x5a) || ($0 >= 0x30 && $0 <= 0x39)
        }
    }

    private static func isValidSigningIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard
            let first = bytes.first,
            let last = bytes.last,
            isASCIIAlphanumeric(first),
            isASCIIAlphanumeric(last)
        else {
            return false
        }
        return bytes.dropFirst().dropLast().allSatisfy {
            isASCIIAlphanumeric($0) || $0 == 0x2e || $0 == 0x2d
        }
    }

    private static func isASCIIAlphanumeric(_ value: UInt8) -> Bool {
        (value >= 0x41 && value <= 0x5a) ||
            (value >= 0x61 && value <= 0x7a) ||
            (value >= 0x30 && value <= 0x39)
    }
}

/// The credential selection decision is deliberately pure so the security
/// boundary can be tested without constructing a Network Extension flow. The
/// application identity remains a routing *fact* only: the derived SOCKS user
/// is selected here, while sing-box still makes the RuleSet decision.
enum TransparentProxyApplicationCredentialDecision: Equatable {
    case base
    case application(canonicalIdentity: String)
    case reject

    /// Selects a credential identity only when the audit-token identity is an
    /// exact active canonical identity. The metadata signing identifier is
    /// never trusted as an identity; it may only corroborate the audit value.
    static func select(
        metadataSigningIdentifier: String,
        auditIdentity: TransparentProxyApplicationIdentity?,
        activeCanonicalIdentities: Set<String>
    ) -> Self {
        let metadataMatchesActive = activeCanonicalIdentities.contains {
            $0.hasSuffix("/\(metadataSigningIdentifier)")
        }

        guard let auditIdentity else {
            return metadataMatchesActive ? .reject : .base
        }
        let auditCanonicalIdentity = auditIdentity.canonical
        let auditMatchesActive = activeCanonicalIdentities.contains(
            auditCanonicalIdentity
        )
        guard
            metadataSigningIdentifier.isEmpty ||
                metadataSigningIdentifier == auditIdentity.signingIdentifier
        else {
            return metadataMatchesActive || auditMatchesActive ? .reject : .base
        }
        if auditMatchesActive {
            return .application(canonicalIdentity: auditCanonicalIdentity)
        }
        return metadataMatchesActive ? .reject : .base
    }
}

enum TransparentProxyFlowMetadata {
    private static let magic = Data([0x00, 0x58, 0x44, 0x01])

    static func encode(
        hostname: String,
        endpointHost: Network.NWEndpoint.Host
    ) -> Data? {
        let hostnameBytes = Data(hostname.utf8)
        guard
            !hostnameBytes.isEmpty,
            hostnameBytes.count <= 253,
            !hostnameBytes.contains(0)
        else {
            return nil
        }

        let family: UInt8
        let address: Data
        switch endpointHost {
        case let .ipv4(value):
            family = 0x01
            address = value.rawValue
        case let .ipv6(value):
            family = 0x04
            address = value.rawValue
        case .name:
            return nil
        @unknown default:
            return nil
        }

        var encoded = magic
        encoded.append(family)
        encoded.append(address)
        encoded.append(hostnameBytes)
        guard encoded.count <= 255 else {
            return nil
        }
        return encoded
    }
}
