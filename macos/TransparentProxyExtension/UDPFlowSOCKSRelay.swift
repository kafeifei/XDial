import Foundation
import Network
@preconcurrency import NetworkExtension
import OSLog

enum UDPFlowSOCKSRelay {
    private enum RelayError: Error {
        case invalidEndpoint
        case socksUnavailable
        case socksProtocol(String)
        case fragmentedDatagram
    }

    static func makeHandle(
        flow: NEAppProxyUDPFlow,
        socksPort: UInt16,
        credentials: SOCKSCredentials? = nil,
        trialID: String,
        traffic: ProviderTrafficLedger,
        logger: Logger
    ) -> ProviderRelayHandle {
        let control = NWConnection(
            host: .ipv4(IPv4Address.loopback),
            port: Network.NWEndpoint.Port(rawValue: socksPort)!,
            using: .tcp
        )
        let resources = UDPRelayResources(flow: flow, control: control)
        let shutdown = RelayTaskShutdown { error in
            resources.close(with: error)
        }
        return ProviderRelayHandle(
            shutdown: shutdown,
            operation: {
                var stage = "flow-open"
                await withTaskCancellationHandler {
                    do {
                        // UDP callers may send and close before a SOCKS
                        // association can finish. Open immediately so
                        // NetworkExtension retains and buffers the flow while
                        // the fail-closed relay is prepared.
                        try await open(flow)
                        stage = "control-connect"
                        try await start(control)
                        stage = "udp-associate"
                        let relayEndpoint = try await associateUDP(
                            control,
                            credentials: credentials
                        )
                        stage = "relay-connect"
                        let udpRelay = NWConnection(
                            to: relayEndpoint,
                            using: .udp
                        )
                        resources.install(relay: udpRelay)
                        try await start(udpRelay)
                        logger.debug(
                            "udp-relay-started trial=\(trialID, privacy: .public) endpoint=\(String(describing: relayEndpoint), privacy: .public)"
                        )
                        stage = "relay"
                        try await relay(
                            flow: flow,
                            connection: udpRelay,
                            control: control,
                            trialID: trialID,
                            logger: logger,
                            shutdown: shutdown,
                            traffic: traffic
                        )
                        logger.debug(
                            "udp-relay-finished trial=\(trialID, privacy: .public)"
                        )
                        shutdown.finish(with: nil)
                    } catch {
                        if isExpectedFlowClosure(error) {
                            logger.debug(
                                "udp-relay-closed trial=\(trialID, privacy: .public) stage=\(stage, privacy: .public) code=\(diagnosticCode(error), privacy: .public)"
                            )
                        } else {
                            logger.error(
                                "udp-relay-error trial=\(trialID, privacy: .public) stage=\(stage, privacy: .public) code=\(diagnosticCode(error), privacy: .public)"
                            )
                        }
                        shutdown.finish(with: error)
                    }
                } onCancel: {
                    shutdown.finish(with: CancellationError())
                }
            }
        )
    }

    private static func isExpectedFlowClosure(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NEAppProxyErrorDomain else {
            return false
        }
        // NEAppProxyFlowErrorPeerReset / NEAppProxyFlowErrorAborted.
        return nsError.code == 2 || nsError.code == 5
    }

    private static func diagnosticCode(_ error: Error) -> String {
        switch error {
        case RelayError.invalidEndpoint:
            return "invalid-endpoint"
        case RelayError.socksUnavailable:
            return "socks-unavailable"
        case RelayError.socksProtocol:
            return "socks-protocol"
        case RelayError.fragmentedDatagram:
            return "fragmented-datagram"
        case let networkError as NWError:
            switch networkError {
            case let .posix(code):
                return "posix-\(code.rawValue)"
            case let .dns(code):
                return "dns-\(code)"
            case let .tls(code):
                return "tls-\(code)"
            case .wifiAware:
                return "wifi-aware"
            @unknown default:
                return "network-unknown"
            }
        default:
            let nsError = error as NSError
            return "ns-\(nsError.code)"
        }
    }

    private static func associateUDP(
        _ connection: NWConnection,
        credentials: SOCKSCredentials?
    ) async throws -> Network.NWEndpoint {
        let method: UInt8 = credentials == nil ? 0x00 : 0x02
        try await send(Data([0x05, 0x01, method]), to: connection)
        let greeting = try await receiveExactly(2, from: connection)
        guard greeting == Data([0x05, method]) else {
            throw RelayError.socksProtocol("authentication rejected")
        }
        if let credentials {
            try await authenticate(credentials, connection: connection)
        }

        // UDP ASSOCIATE with 0.0.0.0:0 asks the server to select its relay.
        try await send(
            Data([0x05, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            to: connection
        )
        let header = try await receiveExactly(4, from: connection)
        guard header[0] == 0x05, header[1] == 0x00 else {
            throw RelayError.socksProtocol("UDP associate rejected")
        }
        let host: Network.NWEndpoint.Host
        switch header[3] {
        case 0x01:
            let raw = try await receiveExactly(4, from: connection)
            if raw == Data([0, 0, 0, 0]) {
                host = .ipv4(IPv4Address.loopback)
            } else {
                host = Network.NWEndpoint.Host(
                    "\(raw[0]).\(raw[1]).\(raw[2]).\(raw[3])"
                )
            }
        case 0x03:
            let length = try await receiveExactly(1, from: connection)
            let raw = try await receiveExactly(Int(length[0]), from: connection)
            guard let name = String(data: raw, encoding: .utf8) else {
                throw RelayError.socksProtocol("invalid relay hostname")
            }
            host = Network.NWEndpoint.Host(name)
        case 0x04:
            let raw = try await receiveExactly(16, from: connection)
            guard let address = IPv6Address(raw) else {
                throw RelayError.socksProtocol("invalid IPv6 relay address")
            }
            host = address == IPv6Address.any
                ? .ipv6(IPv6Address.loopback)
                : .ipv6(address)
        default:
            throw RelayError.socksProtocol("invalid relay address type")
        }
        let portData = try await receiveExactly(2, from: connection)
        let port = UInt16(portData[0]) << 8 | UInt16(portData[1])
        guard
            let relayPort = Network.NWEndpoint.Port(rawValue: port),
            port != 0
        else {
            throw RelayError.socksProtocol("invalid relay port")
        }
        return .hostPort(host: host, port: relayPort)
    }

    private static func authenticate(
        _ credentials: SOCKSCredentials,
        connection: NWConnection
    ) async throws {
        let username = Array(credentials.username.utf8)
        let password = Array(credentials.password.utf8)
        guard
            !username.isEmpty,
            username.count <= 255,
            !password.isEmpty,
            password.count <= 255
        else {
            throw RelayError.socksProtocol("invalid credentials")
        }
        var request = Data([0x01, UInt8(username.count)])
        request.append(contentsOf: username)
        request.append(UInt8(password.count))
        request.append(contentsOf: password)
        try await send(request, to: connection)
        let response = try await receiveExactly(2, from: connection)
        guard response == Data([0x01, 0x00]) else {
            throw RelayError.socksProtocol("authentication failed")
        }
    }

    private static func relay(
        flow: NEAppProxyUDPFlow,
        connection: NWConnection,
        control: NWConnection,
        trialID: String,
        logger: Logger,
        shutdown: RelayTaskShutdown,
        traffic: ProviderTrafficLedger
    ) async throws {
        try await RelayTaskGroup.run(
            operations: [
                {
                    while !Task.isCancelled {
                        let datagrams =
                            try await readDatagrams(from: flow)
                        guard let datagrams, !datagrams.isEmpty else {
                            return
                        }
                        for (payload, endpoint) in datagrams {
                            let packet = try encode(
                                payload: payload,
                                destination: endpoint
                            )
                            logger.debug(
                                "udp-send trial=\(trialID, privacy: .public) bytes=\(payload.count)"
                            )
                            try await send(packet, to: connection)
                            traffic.recordUpload(
                                payload.count,
                                transactionID: trialID
                            )
                        }
                    }
                },
                {
                    while !Task.isCancelled {
                        let packet =
                            try await receiveMessage(from: connection)
                        if packet.isEmpty {
                            return
                        }
                        let decoded = try decode(packet: packet)
                        logger.debug(
                            "udp-receive trial=\(trialID, privacy: .public) bytes=\(decoded.payload.count)"
                        )
                        try await writeDatagrams(
                            [(decoded.payload, decoded.endpoint)],
                            to: flow
                        )
                        traffic.recordDownload(
                            decoded.payload.count,
                            transactionID: trialID
                        )
                    }
                },
                {
                    try await monitorControl(control)
                },
            ],
            shutdown: shutdown
        )
    }

    private static func readDatagrams(
        from flow: NEAppProxyUDPFlow
    ) async throws -> [(Data, Network.NWEndpoint)]? {
        try await awaitRelayCallback { completion in
            flow.readDatagrams { datagrams, error in
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(datagrams))
                }
            }
        }
    }

    private static func writeDatagrams(
        _ datagrams: [(Data, Network.NWEndpoint)],
        to flow: NEAppProxyUDPFlow
    ) async throws {
        let _: Void = try await awaitRelayCallback { completion in
            flow.writeDatagrams(datagrams) { error in
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(()))
                }
            }
        }
    }

    /// A SOCKS UDP association exists only while its TCP control connection is
    /// alive. Any EOF, error, or unexpected payload invalidates the UDP relay.
    private static func monitorControl(
        _ connection: NWConnection
    ) async throws {
        let _: Void = try await awaitRelayCallback { completion in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: 1
            ) { data, _, isComplete, error in
                if let error {
                    completion(.failure(error))
                } else if let data, !data.isEmpty {
                    completion(
                        .failure(
                            RelayError.socksProtocol(
                                "unexpected UDP control payload"
                            )
                        )
                    )
                } else if isComplete {
                    completion(.failure(CancellationError()))
                } else {
                    completion(.failure(RelayError.socksUnavailable))
                }
            }
        }
    }

    private static func encode(
        payload: Data,
        destination: Network.NWEndpoint
    ) throws -> Data {
        guard case let .hostPort(host, port) = destination else {
            throw RelayError.invalidEndpoint
        }
        var packet = Data([0x00, 0x00, 0x00])
        switch host {
        case let .ipv4(address):
            packet.append(0x01)
            packet.append(address.rawValue)
        case let .ipv6(address):
            packet.append(0x04)
            packet.append(address.rawValue)
        case let .name(name, _):
            let raw = Array(name.utf8)
            guard !raw.isEmpty, raw.count <= 255 else {
                throw RelayError.invalidEndpoint
            }
            packet.append(0x03)
            packet.append(UInt8(raw.count))
            packet.append(contentsOf: raw)
        @unknown default:
            throw RelayError.invalidEndpoint
        }
        packet.append(UInt8(port.rawValue >> 8))
        packet.append(UInt8(port.rawValue & 0xff))
        packet.append(payload)
        return packet
    }

    private static func decode(
        packet: Data
    ) throws -> (payload: Data, endpoint: Network.NWEndpoint) {
        guard packet.count >= 7, packet[0] == 0, packet[1] == 0 else {
            throw RelayError.socksProtocol("invalid UDP packet")
        }
        guard packet[2] == 0 else {
            throw RelayError.fragmentedDatagram
        }
        var offset = 4
        let host: Network.NWEndpoint.Host
        switch packet[3] {
        case 0x01:
            guard packet.count >= offset + 4 + 2 else {
                throw RelayError.socksProtocol("short IPv4 UDP packet")
            }
            host = Network.NWEndpoint.Host(
                "\(packet[offset]).\(packet[offset + 1]).\(packet[offset + 2]).\(packet[offset + 3])"
            )
            offset += 4
        case 0x03:
            guard packet.count > offset else {
                throw RelayError.socksProtocol("short domain UDP packet")
            }
            let length = Int(packet[offset])
            offset += 1
            guard packet.count >= offset + length + 2 else {
                throw RelayError.socksProtocol("short domain UDP packet")
            }
            guard
                let name = String(
                    data: packet.subdata(in: offset ..< offset + length),
                    encoding: .utf8
                )
            else {
                throw RelayError.socksProtocol("invalid UDP hostname")
            }
            host = Network.NWEndpoint.Host(name)
            offset += length
        case 0x04:
            guard packet.count >= offset + 16 + 2 else {
                throw RelayError.socksProtocol("short IPv6 UDP packet")
            }
            guard
                let address = IPv6Address(
                    packet.subdata(in: offset ..< offset + 16)
                )
            else {
                throw RelayError.socksProtocol("invalid IPv6 UDP packet")
            }
            host = .ipv6(address)
            offset += 16
        default:
            throw RelayError.socksProtocol("invalid UDP address type")
        }
        let port = UInt16(packet[offset]) << 8 | UInt16(packet[offset + 1])
        offset += 2
        guard
            let endpointPort = Network.NWEndpoint.Port(rawValue: port)
        else {
            throw RelayError.socksProtocol("invalid UDP port")
        }
        return (
            packet.subdata(in: offset ..< packet.count),
            .hostPort(host: host, port: endpointPort)
        )
    }

    private static func open(_ flow: NEAppProxyFlow) async throws {
        let _: Void = try await awaitRelayCallback { completion in
            let gate = UDPRelayGate()
            flow.open(withLocalFlowEndpoint: nil) { error in
                guard gate.take() else {
                    return
                }
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(()))
                }
            }
        }
    }

    private static func start(_ connection: NWConnection) async throws {
        let _: Void = try await awaitRelayCallback { completion in
            let gate = UDPRelayGate()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.take() {
                        completion(.success(()))
                    }
                case let .failed(error):
                    if gate.take() {
                        completion(.failure(error))
                    }
                case .cancelled:
                    if gate.take() {
                        completion(.failure(RelayError.socksUnavailable))
                    }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private static func send(
        _ data: Data,
        to connection: NWConnection
    ) async throws {
        let _: Void = try await awaitRelayCallback { completion in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(()))
                }
            })
        }
    }

    private static func receiveExactly(
        _ length: Int,
        from connection: NWConnection
    ) async throws -> Data {
        var result = Data()
        while result.count < length {
            let remaining = length - result.count
            let chunk: Data = try await awaitRelayCallback { completion in
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: remaining
                ) { data, _, _, error in
                    if let error {
                        completion(.failure(error))
                    } else if let data, !data.isEmpty {
                        completion(.success(data))
                    } else {
                        completion(.failure(RelayError.socksUnavailable))
                    }
                }
            }
            result.append(chunk)
        }
        return result
    }

    private static func receiveMessage(
        from connection: NWConnection
    ) async throws -> Data {
        try await awaitRelayCallback { completion in
            connection.receiveMessage { data, _, isComplete, error in
                if let error {
                    completion(.failure(error))
                } else if let data {
                    completion(.success(data))
                } else if isComplete {
                    completion(.success(Data()))
                } else {
                    completion(.failure(RelayError.socksUnavailable))
                }
            }
        }
    }

}

private final class UDPRelayGate: @unchecked Sendable {
    private let lock = NSLock()
    private var available = true

    func take() -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard available else {
            return false
        }
        available = false
        return true
    }
}

private final class UDPRelayResources: @unchecked Sendable {
    private let lock = NSLock()
    private let flow: NEAppProxyUDPFlow
    private let control: NWConnection
    private var relay: NWConnection?
    private var closed = false

    init(flow: NEAppProxyUDPFlow, control: NWConnection) {
        self.flow = flow
        self.control = control
    }

    func install(relay: NWConnection) {
        lock.lock()
        if closed {
            lock.unlock()
            relay.cancel()
            return
        }
        self.relay = relay
        lock.unlock()
    }

    func close(with error: Error?) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let currentRelay = relay
        relay = nil
        lock.unlock()

        control.cancel()
        currentRelay?.cancel()
        let sourceError = AppProxyFlowCloseError.normalize(error)
        flow.closeReadWithError(sourceError)
        flow.closeWriteWithError(sourceError)
    }
}
