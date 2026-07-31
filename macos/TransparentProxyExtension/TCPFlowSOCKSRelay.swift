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

    static func makeHandle(
        flow: NEAppProxyTCPFlow,
        socksPort: UInt16,
        credentials: SOCKSCredentials? = nil,
        trialID: String,
        logger: Logger
    ) -> ProviderRelayHandle {
        let connection = NWConnection(
            host: .ipv4(IPv4Address.loopback),
            port: Network.NWEndpoint.Port(rawValue: socksPort)!,
            using: .tcp
        )
        let resources = TCPRelayResources(
            flow: flow,
            connection: connection
        )
        let shutdown = RelayTaskShutdown { error in
            resources.close(with: error)
        }
        return ProviderRelayHandle(
            shutdown: shutdown,
            operation: {
                var stage = "destination"
                await withTaskCancellationHandler {
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
                        try await relay(
                            flow: flow,
                            connection: connection,
                            resources: resources,
                            shutdown: shutdown
                        )
                        logger.debug(
                            "relay-finished trial=\(trialID, privacy: .public)"
                        )
                        shutdown.finish(with: nil)
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
        try await awaitRelayCallback { completion in
            let gate = OneShotGate()
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
        let _: Void = try await awaitRelayCallback { completion in
            let gate = OneShotGate()
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

    private static func relay(
        flow: NEAppProxyTCPFlow,
        connection: NWConnection,
        resources: TCPRelayResources,
        shutdown: RelayTaskShutdown
    ) async throws {
        try await RelayTaskPair.run(
            first: {
                while !Task.isCancelled {
                    let data = try await read(from: flow)
                    if data.isEmpty {
                        resources.closeFlowRead()
                        try await finishSending(to: connection)
                        return
                    }
                    try await send(data, to: connection)
                }
            },
            second: {
                while !Task.isCancelled {
                    let result = try await receive(from: connection)
                    if !result.data.isEmpty {
                        try await write(result.data, to: flow)
                    }
                    if let error = result.error {
                        throw error
                    }
                    if result.isComplete {
                        resources.closeFlowWrite()
                        return
                    }
                    guard !result.data.isEmpty else {
                        throw RelayError.socksUnavailable
                    }
                }
            },
            shutdown: shutdown
        )
    }

    /// Marks the SOCKS TCP stream complete in the sending direction. Network
    /// framework documents this as the TCP FIN equivalent; the receive side
    /// remains available until its own EOF or an error.
    private static func finishSending(
        to connection: NWConnection
    ) async throws {
        let _: Void = try await awaitRelayCallback { completion in
            connection.send(
                content: nil,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        completion(.failure(error))
                    } else {
                        completion(.success(()))
                    }
                }
            )
        }
    }

    private static func read(from flow: NEAppProxyTCPFlow) async throws -> Data {
        try await awaitRelayCallback { completion in
            let gate = OneShotGate()
            flow.readData { data, error in
                guard gate.take() else {
                    return
                }
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(data ?? Data()))
                }
            }
        }
    }

    private static func write(
        _ data: Data,
        to flow: NEAppProxyTCPFlow
    ) async throws {
        let _: Void = try await awaitRelayCallback { completion in
            let gate = OneShotGate()
            flow.write(data) { error in
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

    private struct ReceiveResult {
        let data: Data
        let isComplete: Bool
        let error: Error?
    }

    private static func receive(
        from connection: NWConnection
    ) async throws -> ReceiveResult {
        try await awaitRelayCallback { completion in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: 64 * 1024
            ) { data, _, isComplete, error in
                // Network.framework may deliver the final bytes together with
                // either FIN or an error. Preserve those bytes before applying
                // the terminal state; dropping them corrupts the stream tail.
                completion(
                    .success(
                        ReceiveResult(
                            data: data ?? Data(),
                            isComplete: isComplete,
                            error: error
                        )
                    )
                )
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

}

private final class TCPRelayResources: @unchecked Sendable {
    private let lock = NSLock()
    private let flow: NEAppProxyTCPFlow
    private let connection: NWConnection
    private var flowReadClosed = false
    private var flowWriteClosed = false
    private var closed = false

    init(
        flow: NEAppProxyTCPFlow,
        connection: NWConnection
    ) {
        self.flow = flow
        self.connection = connection
    }

    func closeFlowRead() {
        lock.lock()
        guard !closed, !flowReadClosed else {
            lock.unlock()
            return
        }
        flowReadClosed = true
        lock.unlock()
        flow.closeReadWithError(nil)
    }

    func closeFlowWrite() {
        lock.lock()
        guard !closed, !flowWriteClosed else {
            lock.unlock()
            return
        }
        flowWriteClosed = true
        lock.unlock()
        flow.closeWriteWithError(nil)
    }

    func close(with error: Error?) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let shouldCloseRead = !flowReadClosed
        let shouldCloseWrite = !flowWriteClosed
        flowReadClosed = true
        flowWriteClosed = true
        lock.unlock()

        connection.cancel()
        let sourceError = AppProxyFlowCloseError.normalize(error)
        if shouldCloseRead {
            flow.closeReadWithError(sourceError)
        }
        if shouldCloseWrite {
            flow.closeWriteWithError(sourceError)
        }
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
