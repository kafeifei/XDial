import Foundation
import Network
import OSLog

/// 持有用户配置的本机 SOCKS5 端口。端口的生命周期属于 Provider，而不是某一代
/// sing-box：场景切换只改变新连接取得的会话入口，监听本身不动。
final class LocalSOCKSShareListener: @unchecked Sendable {
    private static let readyTimeout: DispatchTimeInterval = .seconds(5)

    private let queue: DispatchQueue
    private let accept: (NWConnection) -> Void
    private let logger: Logger
    private var listener: NWListener?
    private var listenerToken = UUID()
    private var status = LocalSOCKSShareStatus.off

    init(
        queueLabel: String,
        logger: Logger,
        accept: @escaping (NWConnection) -> Void
    ) {
        queue = DispatchQueue(label: queueLabel, qos: .userInitiated)
        self.logger = logger
        self.accept = accept
    }

    /// 同一端口已在监听时直接返回当前状态；其余情况重建监听并等到 ready 或失败。
    func configure(
        port: UInt16?,
        completion: @escaping (LocalSOCKSShareStatus) -> Void
    ) {
        queue.async {
            guard let port else {
                self.stopLocked()
                completion(self.status)
                return
            }
            if self.listener != nil,
               self.status == .listening(port) {
                completion(self.status)
                return
            }
            self.startLocked(port: port, completion: completion)
        }
    }

    func stop() {
        queue.sync { stopLocked() }
    }

    private func stopLocked() {
        listenerToken = UUID()
        listener?.cancel()
        listener = nil
        if status != .off {
            logger.notice("local-socks-share stopped")
        }
        status = .off
    }

    private func startLocked(
        port: UInt16,
        completion: @escaping (LocalSOCKSShareStatus) -> Void
    ) {
        stopLocked()
        let token = listenerToken
        var completed = false
        let finish: (LocalSOCKSShareStatus) -> Void = { status in
            guard !completed else { return }
            completed = true
            completion(status)
        }

        let parameters = NWParameters.tcp
        // 只绑回环，且不复用端口：被其他程序占用时必须如实失败，不能与之分流。
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: Network.NWEndpoint.Port(rawValue: port)!
        )
        parameters.acceptLocalOnly = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            status = .failed(port, code: (error as? NWError).map(
                LocalSOCKSShareStatus.failureCode(for:)
            ) ?? "listener-failed")
            finish(status)
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, self.listenerToken == token else { return }
            switch state {
            case .ready:
                self.status = .listening(port)
                self.logger.notice(
                    "local-socks-share listening port=\(port, privacy: .public)"
                )
                finish(self.status)
            case let .failed(error), let .waiting(error):
                self.fail(port: port, code: LocalSOCKSShareStatus.failureCode(for: error))
                finish(self.status)
            default:
                break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.readyTimeout) { [weak self] in
            guard let self, self.listenerToken == token, !completed else { return }
            self.fail(port: port, code: "listener-timeout")
            finish(self.status)
        }
    }

    private func fail(port: UInt16, code: String) {
        listenerToken = UUID()
        listener?.cancel()
        listener = nil
        status = .failed(port, code: code)
        logger.error(
            "local-socks-share failed port=\(port, privacy: .public) code=\(code, privacy: .public)"
        )
    }
}

/// 一条本机 SOCKS5 客户端连接：先在本机完成无认证握手，再以会话凭据接入当前
/// generation 的 sing-box 入口，之后双向转发字节。
enum LocalSOCKSShareRelay {
    static func makeHandle(
        client: NWConnection,
        socksPort: UInt16,
        credentials: SOCKSCredentials,
        trialID: String,
        traffic: ProviderTrafficLedger,
        logger: Logger
    ) -> ProviderRelayHandle {
        let upstream = NWConnection(
            host: .ipv4(IPv4Address.loopback),
            port: Network.NWEndpoint.Port(rawValue: socksPort)!,
            using: .tcp
        )
        let shutdown = RelayTaskShutdown { error in
            RelayConnectionCancellation.cancel(upstream, error: error)
            RelayConnectionCancellation.cancel(client, error: error)
        }
        return ProviderRelayHandle(
            shutdown: shutdown,
            operation: {
                var stage = "client-connect"
                // 已经给客户端回过失败应答时要正常关闭（FIN），强制重置会让
                // 客户端在读到应答前就收到 RST，看不到失败原因。
                var answered = false
                await withTaskCancellationHandler {
                    do {
                        try await TCPFlowSOCKSRelay.start(client)
                        let read: LocalSOCKSHandshake.Read = { count in
                            try await TCPFlowSOCKSRelay.receiveExactly(count, from: client)
                        }
                        stage = "client-greeting"
                        do {
                            try await LocalSOCKSHandshake.readGreeting(read)
                        } catch LocalSOCKSHandshake.Failure.noAcceptableMethod {
                            try await TCPFlowSOCKSRelay.send(
                                LocalSOCKSHandshake.rejectAllMethods,
                                to: client
                            )
                            answered = true
                            throw LocalSOCKSHandshake.Failure.noAcceptableMethod
                        }
                        try await TCPFlowSOCKSRelay.send(
                            LocalSOCKSHandshake.acceptNoAuthentication,
                            to: client
                        )
                        stage = "client-request"
                        let destination: LocalSOCKSHandshake.Destination
                        do {
                            destination = try await LocalSOCKSHandshake.readRequest(read)
                        } catch let failure as LocalSOCKSHandshake.Failure {
                            if let code = failure.replyCode,
                               (try? await TCPFlowSOCKSRelay.send(
                                   LocalSOCKSHandshake.reply(code),
                                   to: client
                               )) != nil {
                                answered = true
                            }
                            throw failure
                        }
                        stage = "control-connect"
                        do {
                            try await TCPFlowSOCKSRelay.start(upstream)
                            stage = "socks-negotiate"
                            try await TCPFlowSOCKSRelay.negotiateSOCKS(
                                upstream,
                                credentials: credentials,
                                host: destination.host,
                                port: destination.port,
                                encodedFlowMetadata: nil
                            )
                        } catch {
                            let code: UInt8
                            if case let TCPFlowSOCKSRelay.RelayError.connectRejected(rejected) = error {
                                code = rejected
                            } else {
                                code = LocalSOCKSHandshake.generalFailure
                            }
                            if (try? await TCPFlowSOCKSRelay.send(
                                LocalSOCKSHandshake.reply(code),
                                to: client
                            )) != nil {
                                answered = true
                            }
                            throw error
                        }
                        try await TCPFlowSOCKSRelay.send(
                            LocalSOCKSHandshake.reply(0x00),
                            to: client
                        )
                        stage = "relay"
                        try await relay(
                            client: client,
                            upstream: upstream,
                            shutdown: shutdown,
                            transactionID: trialID,
                            traffic: traffic
                        )
                        shutdown.finish(with: nil)
                    } catch {
                        logger.debug(
                            "local-socks-share closed trial=\(trialID, privacy: .public) stage=\(stage, privacy: .public) code=\(diagnosticCode(error), privacy: .public)"
                        )
                        if answered {
                            await lingerAfterReply(client)
                        }
                        shutdown.finish(with: answered ? nil : error)
                    }
                } onCancel: {
                    shutdown.finish(with: CancellationError())
                }
            }
        )
    }

    /// 失败应答发出后先半关闭（FIN），再读掉客户端已经发出的剩余字节。拒绝发生在
    /// 请求读完之前时（例如主机名非法、端口字节未读），带着未读数据关闭 TCP 会让
    /// 内核回 RST，客户端可能在读到应答前就看到连接被重置。等待有上限，客户端不关
    /// 也不会占住这条连接。
    static func lingerAfterReply(
        _ client: NWConnection,
        timeout: TimeInterval = 2
    ) async {
        try? await TCPFlowSOCKSRelay.finishSending(to: client)
        let deadline = DispatchWorkItem { client.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout,
            execute: deadline
        )
        defer { deadline.cancel() }
        while let result = try? await TCPFlowSOCKSRelay.receive(from: client),
              result.error == nil,
              !result.isComplete,
              !result.data.isEmpty {}
    }

    private static func diagnosticCode(_ error: Error) -> String {
        switch error {
        case LocalSOCKSHandshake.Failure.invalidVersion:
            return "client-invalid-version"
        case LocalSOCKSHandshake.Failure.noAcceptableMethod:
            return "client-no-acceptable-method"
        case LocalSOCKSHandshake.Failure.commandNotSupported:
            return "client-command-not-supported"
        case LocalSOCKSHandshake.Failure.addressTypeNotSupported:
            return "client-address-type-not-supported"
        case LocalSOCKSHandshake.Failure.invalidDestination:
            return "client-invalid-destination"
        default:
            return TCPFlowSOCKSRelay.diagnosticCode(error)
        }
    }

    private static func relay(
        client: NWConnection,
        upstream: NWConnection,
        shutdown: RelayTaskShutdown,
        transactionID: String,
        traffic: ProviderTrafficLedger
    ) async throws {
        try await RelayTaskPair.run(
            first: {
                try await pump(from: client, to: upstream) {
                    traffic.recordUpload($0, transactionID: transactionID)
                }
            },
            second: {
                try await pump(from: upstream, to: client) {
                    traffic.recordDownload($0, transactionID: transactionID)
                }
            },
            shutdown: shutdown
        )
    }

    /// 单向转发到 EOF，再把 FIN 传给对端；另一方向继续工作，保留 TCP 半关闭。
    private static func pump(
        from source: NWConnection,
        to destination: NWConnection,
        record: @escaping @Sendable (Int) -> Void
    ) async throws {
        while !Task.isCancelled {
            let result = try await TCPFlowSOCKSRelay.receive(from: source)
            if !result.data.isEmpty {
                try await TCPFlowSOCKSRelay.send(result.data, to: destination)
                record(result.data.count)
            }
            if let error = result.error {
                throw error
            }
            if result.isComplete {
                try await TCPFlowSOCKSRelay.finishSending(to: destination)
                return
            }
            guard !result.data.isEmpty else {
                throw TCPFlowSOCKSRelay.RelayError.socksUnavailable
            }
        }
    }
}
