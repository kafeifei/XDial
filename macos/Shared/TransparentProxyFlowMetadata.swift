import Foundation
import Network

/// A normalized Surge-style App Bundle selector. The path is a directory
/// boundary, not a raw string prefix: `/Applications/Foo.app2` must never
/// match `/Applications/Foo.app`.
struct TransparentProxyApplicationBundlePath: Sendable, Equatable {
    let value: String

    init?(_ rawValue: String) {
        guard
            rawValue.hasPrefix("/"),
            rawValue.utf8.count <= 4096,
            !rawValue.contains("\0")
        else {
            return nil
        }
        let standardized = (rawValue as NSString).standardizingPath
        let url = URL(fileURLWithPath: standardized)
        guard
            standardized == rawValue,
            url.pathExtension.localizedCaseInsensitiveCompare("app")
                == .orderedSame,
            !url.deletingPathExtension().lastPathComponent.isEmpty
        else {
            return nil
        }
        value = standardized
    }

    func contains(executablePath rawExecutablePath: String) -> Bool {
        guard rawExecutablePath.hasPrefix("/") else { return false }
        let executablePath = (rawExecutablePath as NSString).standardizingPath
        return executablePath == value || executablePath.hasPrefix(value + "/")
    }
}

enum TransparentProxyProcessSelectorKind: String, Sendable, Codable {
    case bundlePath = "bundle_path"
    case bundleIdentifier = "bundle_identifier"
    case name
    case exactPath = "exact_path"
    case pathPrefix = "path_prefix"
}

/// The three PROCESS-NAME modes exposed by Surge Mac, plus a distinct bundle
/// kind retained for the App picker. Matching is performed only against the
/// executable path macOS attributes to the current flow.
struct TransparentProxyProcessSelector: Sendable, Equatable {
    let kind: TransparentProxyProcessSelectorKind
    let value: String

    init?(kind: TransparentProxyProcessSelectorKind, value: String) {
        guard
            !value.isEmpty,
            value.utf8.count <= 4096,
            value.trimmingCharacters(in: .whitespacesAndNewlines) == value,
            value.unicodeScalars.allSatisfy({ scalar in
                !CharacterSet.controlCharacters.contains(scalar)
            })
        else { return nil }

        switch kind {
        case .bundlePath:
            guard TransparentProxyApplicationBundlePath(value) != nil
            else { return nil }
        case .bundleIdentifier:
            guard
                value.utf8.count <= 255,
                value.unicodeScalars.allSatisfy({ scalar in
                    scalar.value < 128
                        && !CharacterSet.whitespacesAndNewlines.contains(scalar)
                })
            else { return nil }
        case .name:
            guard
                !value.hasPrefix("/"),
                !value.contains("/"),
                value.utf8.count <= 255
            else { return nil }
        case .exactPath, .pathPrefix:
            guard
                value.hasPrefix("/"),
                value != "/",
                !value.hasSuffix("/"),
                (value as NSString).standardizingPath == value
            else { return nil }
        }
        self.kind = kind
        self.value = value
    }

    func matches(executablePath rawExecutablePath: String) -> Bool {
        guard rawExecutablePath.hasPrefix("/") else { return false }
        let executablePath = (rawExecutablePath as NSString).standardizingPath
        switch kind {
        case .bundlePath:
            return TransparentProxyApplicationBundlePath(value)?
                .contains(executablePath: executablePath) == true
        case .bundleIdentifier:
            return false
        case .name:
            return Self.wildcardMatch(
                pattern: value,
                candidate: URL(fileURLWithPath: executablePath)
                    .lastPathComponent
            )
        case .exactPath:
            return executablePath == value
        case .pathPrefix:
            return executablePath.hasPrefix(value + "/")
        }
    }

    func matches(signingIdentifier: String) -> Bool {
        kind == .bundleIdentifier && value == signingIdentifier
    }

    private static func wildcardMatch(
        pattern: String,
        candidate: String
    ) -> Bool {
        let patternCharacters = Array(pattern)
        let candidateCharacters = Array(candidate)
        var patternIndex = 0
        var candidateIndex = 0
        var starIndex: Int?
        var starCandidateIndex = 0

        while candidateIndex < candidateCharacters.count {
            if patternIndex < patternCharacters.count,
               patternCharacters[patternIndex] == "?"
                || patternCharacters[patternIndex]
                    == candidateCharacters[candidateIndex] {
                patternIndex += 1
                candidateIndex += 1
            } else if patternIndex < patternCharacters.count,
                      patternCharacters[patternIndex] == "*" {
                starIndex = patternIndex
                patternIndex += 1
                starCandidateIndex = candidateIndex
            } else if let starIndex {
                patternIndex = starIndex + 1
                starCandidateIndex += 1
                candidateIndex = starCandidateIndex
            } else {
                return false
            }
        }
        while patternIndex < patternCharacters.count,
              patternCharacters[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == patternCharacters.count
    }
}

/// The credential selection decision is deliberately pure so path attribution
/// can be tested without constructing a Network Extension flow. Bundle order
/// is the active Mode binding order returned by Go and therefore must not be
/// sorted or converted to a dictionary before matching.
enum TransparentProxyApplicationCredentialDecision: Equatable {
    case base
    case application(selector: TransparentProxyProcessSelector)
    case reject

    static func select(
        sourceAppSigningIdentifier: String?,
        auditTokenPresent: Bool,
        auditExecutablePath: String?,
        activeSelectors: [TransparentProxyProcessSelector]
    ) -> Self {
        guard !activeSelectors.isEmpty else { return .base }
        if let signingIdentifier = sourceAppSigningIdentifier,
           !signingIdentifier.isEmpty {
            for selector in activeSelectors
            where selector.matches(signingIdentifier: signingIdentifier) {
                return .application(selector: selector)
            }
        }
        guard auditTokenPresent else {
            // System flows can legitimately omit sourceAppAuditToken.
            return .base
        }
        guard let auditExecutablePath else {
            // A user process supplied an audit token but Security.framework
            // could not resolve it. Do not silently send a selected app through
            // the Mode default when attribution is unavailable.
            return .reject
        }
        for selector in activeSelectors {
            if selector.matches(executablePath: auditExecutablePath) {
                return .application(selector: selector)
            }
        }
        return .base
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
