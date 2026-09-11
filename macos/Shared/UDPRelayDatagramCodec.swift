import Foundation
import Network

enum UDPRelayDatagramError: Error, Equatable {
    case invalidDestination
    case malformedPacket(String)
    case fragmentedDatagram
}

/// SOCKS5 UDP request header codec for one app-proxy flow.
///
/// `encode` keeps the known-target-ownership invariant: a connect-by-name flow
/// hands its hostname to sing-box so the owning Line performs resolution (see
/// `TransparentProxyFlowMetadata.datagramSOCKSHost`). The reply then echoes
/// that same domain back in ATYP=0x03 form, and `NEAppProxyUDPFlow`
/// `writeDatagrams` rejects a `.name` host — it demands a concrete endpoint and
/// otherwise fails the whole flow with `invalidArgument`.
///
/// The codec therefore remembers which endpoint each encoded name stands for
/// and returns the reply as the endpoint the application is actually talking
/// to. A name it has never sent to resolves to the flow's last destination, and
/// failing that the datagram is dropped — never surfaced as a `.name` host.
final class UDPRelayDatagramCodec: @unchecked Sendable {
    /// One flow addresses very few names; the bound only stops a pathological
    /// sender from growing the map without limit.
    private static let maximumTrackedNames = 8

    private let lock = NSLock()
    private var endpointsByName: [String: Network.NWEndpoint] = [:]
    private var trackedNames: [String] = []
    private var lastDestination: Network.NWEndpoint?

    init() {}

    func encode(
        payload: Data,
        destination: Network.NWEndpoint,
        remoteHostname: String?
    ) throws -> Data {
        guard case let .hostPort(host, port) = destination else {
            throw UDPRelayDatagramError.invalidDestination
        }
        let socksHost = TransparentProxyFlowMetadata.datagramSOCKSHost(
            hostname: remoteHostname,
            endpointHost: host,
            endpointPort: port
        )
        var packet = Data([0x00, 0x00, 0x00])
        switch socksHost {
        case let .ipv4(address):
            packet.append(0x01)
            packet.append(address.rawValue)
        case let .ipv6(address):
            packet.append(0x04)
            packet.append(address.rawValue)
        case let .name(name, _):
            let raw = Array(name.utf8)
            guard !raw.isEmpty, raw.count <= 255 else {
                throw UDPRelayDatagramError.invalidDestination
            }
            packet.append(0x03)
            packet.append(UInt8(raw.count))
            packet.append(contentsOf: raw)
            rememberName(name, endpoint: destination)
        @unknown default:
            throw UDPRelayDatagramError.invalidDestination
        }
        packet.append(UInt8(port.rawValue >> 8))
        packet.append(UInt8(port.rawValue & 0xff))
        packet.append(payload)
        noteDestination(destination)
        return packet
    }

    /// - Returns: the datagram to hand back to the application, or `nil` when a
    ///   domain-form reply cannot be mapped to a concrete endpoint.
    func decode(
        packet: Data
    ) throws -> (payload: Data, endpoint: Network.NWEndpoint)? {
        guard packet.count >= 7, packet[0] == 0, packet[1] == 0 else {
            throw UDPRelayDatagramError.malformedPacket("invalid UDP packet")
        }
        guard packet[2] == 0 else {
            throw UDPRelayDatagramError.fragmentedDatagram
        }
        var offset = 4
        var name: String?
        let host: Network.NWEndpoint.Host?
        switch packet[3] {
        case 0x01:
            guard packet.count >= offset + 4 + 2 else {
                throw UDPRelayDatagramError.malformedPacket(
                    "short IPv4 UDP packet"
                )
            }
            host = Network.NWEndpoint.Host(
                "\(packet[offset]).\(packet[offset + 1]).\(packet[offset + 2]).\(packet[offset + 3])"
            )
            offset += 4
        case 0x03:
            guard packet.count > offset else {
                throw UDPRelayDatagramError.malformedPacket(
                    "short domain UDP packet"
                )
            }
            let length = Int(packet[offset])
            offset += 1
            guard packet.count >= offset + length + 2 else {
                throw UDPRelayDatagramError.malformedPacket(
                    "short domain UDP packet"
                )
            }
            guard
                let decoded = String(
                    data: packet.subdata(in: offset ..< offset + length),
                    encoding: .utf8
                )
            else {
                throw UDPRelayDatagramError.malformedPacket(
                    "invalid UDP hostname"
                )
            }
            name = decoded
            host = nil
            offset += length
        case 0x04:
            guard packet.count >= offset + 16 + 2 else {
                throw UDPRelayDatagramError.malformedPacket(
                    "short IPv6 UDP packet"
                )
            }
            guard
                let address = IPv6Address(
                    packet.subdata(in: offset ..< offset + 16)
                )
            else {
                throw UDPRelayDatagramError.malformedPacket(
                    "invalid IPv6 UDP packet"
                )
            }
            host = .ipv6(address)
            offset += 16
        default:
            throw UDPRelayDatagramError.malformedPacket(
                "invalid UDP address type"
            )
        }
        let port = UInt16(packet[offset]) << 8 | UInt16(packet[offset + 1])
        offset += 2
        guard let endpointPort = Network.NWEndpoint.Port(rawValue: port) else {
            throw UDPRelayDatagramError.malformedPacket("invalid UDP port")
        }
        let payload = packet.subdata(in: offset ..< packet.count)
        if let host {
            return (payload, .hostPort(host: host, port: endpointPort))
        }
        guard
            let name,
            let endpoint = resolve(name: name, port: endpointPort)
        else {
            return nil
        }
        return (payload, endpoint)
    }

    private func rememberName(
        _ name: String,
        endpoint: Network.NWEndpoint
    ) {
        let key = name.lowercased()
        lock.lock()
        if endpointsByName.updateValue(endpoint, forKey: key) == nil {
            trackedNames.append(key)
            while trackedNames.count > Self.maximumTrackedNames {
                let evicted = trackedNames.removeFirst()
                endpointsByName.removeValue(forKey: evicted)
            }
        }
        lock.unlock()
    }

    private func noteDestination(_ endpoint: Network.NWEndpoint) {
        lock.lock()
        lastDestination = endpoint
        lock.unlock()
    }

    /// Domain replies are answered with the endpoint the application addressed.
    /// The port comes from the reply so a server which answers from a different
    /// port is still attributed to the destination the application knows.
    private func resolve(
        name: String,
        port: Network.NWEndpoint.Port
    ) -> Network.NWEndpoint? {
        lock.lock()
        let match = endpointsByName[name.lowercased()] ?? lastDestination
        lock.unlock()
        guard case let .hostPort(host, _) = match else {
            return nil
        }
        switch host {
        case .ipv4, .ipv6:
            return .hostPort(host: host, port: port)
        default:
            // A tracked destination is always an NE endpoint, so this only
            // guards a caller which stored a name endpoint by mistake.
            return nil
        }
    }
}
