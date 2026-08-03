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

/// The credential selection decision is deliberately pure so path attribution
/// can be tested without constructing a Network Extension flow. Bundle order
/// is the active Mode binding order returned by Go and therefore must not be
/// sorted or converted to a dictionary before matching.
enum TransparentProxyApplicationCredentialDecision: Equatable {
    case base
    case application(bundlePath: String)
    case reject

    static func select(
        auditTokenPresent: Bool,
        auditExecutablePath: String?,
        activeBundlePaths: [String]
    ) -> Self {
        guard !activeBundlePaths.isEmpty else { return .base }
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
        for rawBundlePath in activeBundlePaths {
            guard let bundlePath = TransparentProxyApplicationBundlePath(
                rawBundlePath
            ) else {
                return .reject
            }
            if bundlePath.contains(executablePath: auditExecutablePath) {
                return .application(bundlePath: bundlePath.value)
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
