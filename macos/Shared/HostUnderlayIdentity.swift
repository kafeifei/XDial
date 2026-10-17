import CryptoKit
import Darwin
import Foundation

/// One address the kernel reports on an interface (`getifaddrs`). The host
/// passes every fact it sampled; only `HostUnderlayIdentity` decides which of
/// them identify the network attachment.
struct HostInterfaceAddressFact: Equatable {
    enum Family: Equatable {
        case ipv4
        case ipv6
    }

    let interfaceName: String
    let family: Family
    let address: String
}

/// Default routers published by configd for the primary service
/// (`State:/Network/Global/IPv4` / `IPv6` → `Router`). They are opaque system
/// facts: neither the service nor the interface behind them is interpreted.
struct HostDefaultRouterFacts: Equatable {
    let ipv4: String?
    let ipv6: String?

    static let none = HostDefaultRouterFacts(ipv4: nil, ipv6: nil)
}

/// Canonical identity of one host Underlay sample.
///
/// Every component is a fact macOS has already decided and that stays fixed
/// while the attachment is unchanged:
/// - kernel default interface (name + index) and the sorted NWPath interface
///   set (`index:name:type`);
/// - system resolver addresses in their published order;
/// - the default interface's IPv4 addresses (DHCP / static / VPN-assigned
///   addresses keep their value across renewals on one network);
/// - the IPv4 and IPv6 default routers of the primary service.
///
/// IPv6 interface addresses are intentionally excluded: macOS rotates RFC 4941
/// temporary addresses on a stable link and regenerates them after wake, and
/// even stable-privacy addresses follow delegated prefixes that some ISPs
/// renumber without the attachment moving. The IPv6 router is the router's
/// link-local address, which identifies the first hop without rotating.
///
/// Nothing here names a product, SSID or service, and nothing is produced by
/// XDial itself: a Transparent Proxy creates no interface, publishes no IPv4 /
/// IPv6 service state and sets no DNS settings, and its loopback SOCKS
/// listener adds no address to any interface in the set.
struct HostUnderlayIdentity: Equatable {
    struct Interface: Equatable {
        let name: String
        let index: Int
        let type: String

        fileprivate var key: String { "\(index):\(name):\(type)" }
    }

    let defaultInterface: Interface
    /// Sorted by canonical key; NWPath enumeration order is not identity.
    let interfaces: [Interface]
    /// Canonical JSON array exactly as handed to the Provider.
    let systemDNSJSON: String
    /// Canonical, sorted, de-duplicated IPv4 addresses on `defaultInterface`.
    let defaultInterfaceIPv4Addresses: [String]
    let ipv4Router: String?
    let ipv6Router: String?

    init(
        defaultInterface: Interface,
        interfaces: [Interface],
        systemDNSJSON: String,
        interfaceAddresses: [HostInterfaceAddressFact],
        routers: HostDefaultRouterFacts
    ) {
        self.defaultInterface = defaultInterface
        self.interfaces = interfaces.sorted { $0.key < $1.key }
        self.systemDNSJSON = systemDNSJSON
        self.defaultInterfaceIPv4Addresses = Array(Set(
            interfaceAddresses.compactMap { fact -> String? in
                guard fact.interfaceName == defaultInterface.name,
                      fact.family == .ipv4 else {
                    return nil
                }
                return Self.canonicalAddress(fact.address, family: AF_INET)
            }
        )).sorted()
        self.ipv4Router = routers.ipv4.flatMap {
            Self.canonicalAddress($0, family: AF_INET)
        }
        self.ipv6Router = routers.ipv6.flatMap {
            Self.canonicalAddress($0, family: AF_INET6)
        }
    }

    /// Exact canonical identity for coalescing host notifications. This value
    /// is never logged, persisted, sent to Provider, or exposed by Debug.
    var epochFingerprint: String {
        [
            "\(defaultInterface.index):\(defaultInterface.name)",
            interfaces.map(\.key).joined(separator: ","),
            systemDNSJSON,
            "a4=" + defaultInterfaceIPv4Addresses.joined(separator: ","),
            "r4=" + (ipv4Router ?? ""),
            "r6=" + (ipv6Router ?? ""),
        ].joined(separator: "\u{1F}")
    }

    /// Opaque identity of the path that already-established sockets use: the
    /// default interface, its IPv4 addresses and the default routers. DNS and
    /// the rest of the interface set are deliberately outside it, so a
    /// DNS-only change keeps the same path identity. Only equality is
    /// meaningful; the Provider never learns the underlying facts from it.
    var pathIdentity: String {
        let canonical = [
            "v1",
            defaultInterface.name,
            String(defaultInterface.index),
            defaultInterfaceIPv4Addresses.joined(separator: ","),
            ipv4Router ?? "",
            ipv6Router ?? "",
        ].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return Self.pathIdentityPrefix
            + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Distinct, stable labels for host logs. Several kinds can change in one
    /// physical move; each is reported independently.
    func differenceKinds(
        comparedTo other: HostUnderlayIdentity
    ) -> [String] {
        var kinds: [String] = []
        if defaultInterface.name != other.defaultInterface.name
            || defaultInterface.index != other.defaultInterface.index {
            kinds.append("default-interface")
        }
        if interfaces != other.interfaces {
            kinds.append("interface-set")
        }
        if systemDNSJSON != other.systemDNSJSON {
            kinds.append("system-dns")
        }
        if ipv4Router != other.ipv4Router || ipv6Router != other.ipv6Router {
            kinds.append("gateway")
        }
        if defaultInterfaceIPv4Addresses
            != other.defaultInterfaceIPv4Addresses {
            kinds.append("address")
        }
        return kinds
    }

    static let pathIdentityPrefix = "underlay-path-v1:"

    static func isValidPathIdentity(_ value: String) -> Bool {
        guard value.hasPrefix(pathIdentityPrefix) else { return false }
        let digest = value.dropFirst(pathIdentityPrefix.count)
        return digest.count == 64 && digest.allSatisfy {
            ("0"..."9").contains($0) || ("a"..."f").contains($0)
        }
    }

    /// Numeric canonical form. A zone suffix (`fe80::1%en0`) is dropped: the
    /// scope is the interface, which the identity already carries.
    private static func canonicalAddress(
        _ raw: String,
        family: Int32
    ) -> String? {
        var address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if family == AF_INET6, let zone = address.firstIndex(of: "%") {
            address = String(address[..<zone])
        }
        guard !address.isEmpty else { return nil }
        if family == AF_INET {
            var value = in_addr()
            guard address.withCString({ inet_pton(AF_INET, $0, &value) })
                == 1 else {
                return nil
            }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &value, &buffer, socklen_t(buffer.count))
                != nil else {
                return nil
            }
            return String(cString: buffer)
        }
        var value = in6_addr()
        guard address.withCString({ inet_pton(AF_INET6, $0, &value) })
            == 1 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &value, &buffer, socklen_t(buffer.count))
            != nil else {
            return nil
        }
        return String(cString: buffer)
    }
}
