import Foundation
import Network
@preconcurrency import NetworkExtension
import OSLog

enum TCPFlowSOCKSRelay {
    private enum RelayError: Error {
        case invalidDestination
        case socksUnavailable
        case socksProtocol(String)
        case flowClosed
    }

    static func start(
        flow: NEAppProxyTCPFlow,
        socksPort: UInt16,
        credentials: SOCKSCredentials? = nil,
        trialID: String,
        logger: Logger
    ) {
        Task {
            var stage = "destination"
            let connection = NWConnection(
                host: .ipv4(IPv4Address.loopback),
                port: Network.NWEndpoint.Port(rawValue: socksPort)!,
                using: .tcp
            )
            do {
                let destination = try destination(for: flow)
                stage = "control-connect"
                try await start(connection)
                stage = "socks-negotiate"
                try await negotiateSOCKS(
                    connection,
                    credentials: credentials,
                    host: destination.host,
                    port: destination.port
                )
                stage = "flow-open"
                try await open(flow)
                logger.debug(
                    "relay-started trial=\(trialID, privacy: .public)"
                )
                stage = "relay"
                try await relay(flow: flow, connection: connection)
                logger.debug(
                    "relay-finished trial=\(trialID, privacy: .public)"
                )
                close(flow: flow, connection: connection, error: nil)
            } catch {
                if isExpectedFlowClosure(error) {
                    logger.debug(
                        "relay-closed trial=\(trialID, privacy: .public) stage=\(stage, privacy: .public) code=\(diagnosticCode(error), privacy: .public)"
                    )
                } else {
                    logger.error(
                        "relay-error trial=\(trialID, privacy: .public) stage=\(stage, privacy: .public) code=\(diagnosticCode(error), privacy: .public)"
                    )
                }
                close(flow: flow, connection: connection, error: error)
            }
        }
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
        case RelayError.invalidDestination:
            return "invalid-destination"
        case RelayError.socksUnavailable:
            return "socks-unavailable"
        case RelayError.socksProtocol:
            return "socks-protocol"
        case RelayError.flowClosed:
            return "flow-closed"
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

    private static func destination(
        for flow: NEAppProxyTCPFlow
    ) throws -> (host: String, port: UInt16) {
        guard case let .hostPort(endpointHost, endpointPort) = flow.remoteFlowEndpoint else {
            throw RelayError.invalidDestination
        }
        let host = flow.remoteHostname ?? String(describing: endpointHost)
        guard !host.isEmpty else {
            throw RelayError.invalidDestination
        }
        return (host, endpointPort.rawValue)
    }

    private static func start(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = OneShotGate()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.take() {
                        continuation.resume()
                    }
                case let .failed(error):
                    if gate.take() {
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    if gate.take() {
                        continuation.resume(throwing: RelayError.socksUnavailable)
                    }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private static func negotiateSOCKS(
        _ connection: NWConnection,
        credentials: SOCKSCredentials?,
        host: String,
        port: UInt16
    ) async throws {
        let method: UInt8 = credentials == nil ? 0x00 : 0x02
        try await send(Data([0x05, 0x01, method]), to: connection)
        let greeting = try await receiveExactly(2, from: connection)
        guard greeting == Data([0x05, method]) else {
            throw RelayError.socksProtocol("authentication rejected")
        }
        if let credentials {
            try await authenticate(credentials, connection: connection)
        }

        var request = Data([0x05, 0x01, 0x00])
        if let address = IPv4Address(host) {
            request.append(0x01)
            request.append(contentsOf: address.rawValue)
        } else if let address = IPv6Address(host) {
            request.append(0x04)
            request.append(contentsOf: address.rawValue)
        } else {
            let bytes = Array(host.utf8)
            guard !bytes.isEmpty, bytes.count <= 255 else {
                throw RelayError.invalidDestination
            }
            request.append(0x03)
            request.append(UInt8(bytes.count))
            request.append(contentsOf: bytes)
        }
        request.append(UInt8(port >> 8))
        request.append(UInt8(port & 0xff))
        try await send(request, to: connection)

        let response = try await receiveExactly(4, from: connection)
        guard response[response.startIndex] == 0x05 else {
            throw RelayError.socksProtocol("invalid response version")
        }
        guard response[response.index(response.startIndex, offsetBy: 1)] == 0x00 else {
            let code = response[response.index(response.startIndex, offsetBy: 1)]
            throw RelayError.socksProtocol("connect rejected with code \(code)")
        }
        switch response[response.index(response.startIndex, offsetBy: 3)] {
        case 0x01:
            _ = try await receiveExactly(6, from: connection)
        case 0x04:
            _ = try await receiveExactly(18, from: connection)
        case 0x03:
            let length = try await receiveExactly(1, from: connection)
            _ = try await receiveExactly(Int(length[length.startIndex]) + 2, from: connection)
        default:
            throw RelayError.socksProtocol("invalid address type")
        }
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

    private static func open(_ flow: NEAppProxyFlow) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let gate = OneShotGate()
            flow.open(withLocalFlowEndpoint: nil) { error in
                guard gate.take() else {
                    return
                }
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func relay(
        flow: NEAppProxyTCPFlow,
        connection: NWConnection
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    let data = try await read(from: flow)
                    if data.isEmpty {
                        return
                    }
                    try await send(data, to: connection)
                }
            }
            group.addTask {
                while !Task.isCancelled {
                    let data = try await receive(from: connection)
                    if data.isEmpty {
                        return
                    }
                    try await write(data, to: flow)
                }
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private static func read(from flow: NEAppProxyTCPFlow) async throws -> Data {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in
            let gate = OneShotGate()
            flow.readData { data, error in
                guard gate.take() else {
                    return
                }
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
    }

    private static func write(
        _ data: Data,
        to flow: NEAppProxyTCPFlow
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let gate = OneShotGate()
            flow.write(data) { error in
                guard gate.take() else {
                    return
                }
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func send(
        _ data: Data,
        to connection: NWConnection
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private static func receive(
        from connection: NWConnection
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: 64 * 1024
            ) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(throwing: RelayError.socksUnavailable)
                }
            }
        }
    }

    private static func receiveExactly(
        _ length: Int,
        from connection: NWConnection
    ) async throws -> Data {
        var result = Data()
        while result.count < length {
            let remaining = length - result.count
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: remaining
                ) { data, _, _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: RelayError.socksUnavailable)
                    }
                }
            }
            result.append(chunk)
        }
        return result
    }

    private static func close(
        flow: NEAppProxyTCPFlow,
        connection: NWConnection,
        error: Error?
    ) {
        connection.cancel()
        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
    }
}

private final class OneShotGate: @unchecked Sendable {
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
