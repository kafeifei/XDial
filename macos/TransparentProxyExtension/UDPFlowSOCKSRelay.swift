import Foundation
import Network
@preconcurrency import NetworkExtension
import OSLog

/// Relays one `NEAppProxyUDPFlow` over SOCKS5 UDP ASSOCIATE.
///
/// The flow and the association have different lifetimes. A SOCKS association
/// belongs to one engine generation and dies with it; the flow belongs to an
/// application socket that macOS will never hand us again. The supervisor
/// therefore owns the flow, each association registers itself with the relay
/// registry on its own, and a replaced generation only tears the association
/// down — the flow is re-associated against the new generation instead of
/// being closed underneath the application.
enum UDPFlowSOCKSRelay {
    /// One association attempt against the registry's current generation.
    struct AssociationTicket: @unchecked Sendable {
        let socksPort: UInt16
        let credentials: SOCKSCredentials?
        let generation: String
        /// Registers the association handle with the relay registry.
        let attach: (ProviderRelayHandle) -> Bool
        /// Releases the registry reservation this ticket holds.
        let finish: () -> Void

        init(
            socksPort: UInt16,
            credentials: SOCKSCredentials?,
            generation: String,
            attach: @escaping (ProviderRelayHandle) -> Bool,
            finish: @escaping () -> Void
        ) {
            self.socksPort = socksPort
            self.credentials = credentials
            self.generation = generation
            self.attach = attach
            self.finish = finish
        }
    }

    private enum RelayError: Error {
        case invalidEndpoint
        case socksUnavailable
        case socksProtocol(String)
        case flowClosed
        case generationUnavailable
        case associationEnded
    }

    /// Raised by the downlink half when the application flow itself failed.
    /// Re-associating cannot help, so the supervisor stops.
    private struct FlowFailure: Error {
        let underlying: Error
    }

    private enum AssociationOutcome {
        case associationEnded(stage: String, error: Error?, duration: TimeInterval)
        case flowEnded(stage: String, error: Error?)
    }

    static func start(
        flow: NEAppProxyUDPFlow,
        initialTicket: AssociationTicket,
        nextTicket: @escaping @Sendable () -> AssociationTicket?,
        policy: RelayReassociationPolicy = .default,
        traffic: ProviderTrafficLedger,
        logger: Logger
    ) {
        let channel = UDPFlowChannel(flow: flow)
        Task.detached(priority: .userInitiated) {
            await supervise(
                channel: channel,
                initialTicket: initialTicket,
                nextTicket: nextTicket,
                policy: policy,
                traffic: traffic,
                logger: logger
            )
        }
    }

    private static func supervise(
        channel: UDPFlowChannel,
        initialTicket: AssociationTicket,
        nextTicket: @escaping @Sendable () -> AssociationTicket?,
        policy: RelayReassociationPolicy,
        traffic: ProviderTrafficLedger,
        logger: Logger
    ) async {
        let trialID = initialTicket.generation
        do {
            // UDP callers may send and close before a SOCKS association can
            // finish. Open immediately so NetworkExtension retains and buffers
            // the flow while the fail-closed relay is prepared.
            try await open(channel.flow)
        } catch {
            if isExpectedFlowClosure(error) {
                logger.debug(
                    "udp-relay-closed trial=\(trialID, privacy: .public) stage=flow-open code=\(diagnosticCode(error), privacy: .public)"
                )
            } else {
                logger.error(
                    "udp-relay-error trial=\(trialID, privacy: .public) stage=flow-open code=\(diagnosticCode(error), privacy: .public)"
                )
            }
            initialTicket.finish()
            channel.close(with: error)
            return
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await uplink(
                    channel: channel,
                    trialID: trialID,
                    traffic: traffic,
                    logger: logger
                )
            }
            group.addTask {
                await associationLoop(
                    channel: channel,
                    initialTicket: initialTicket,
                    nextTicket: nextTicket,
                    policy: policy,
                    traffic: traffic,
                    logger: logger
                )
            }
            await group.next()
            // Whichever half finished has already closed the channel, which
            // unblocks the pending NetworkExtension callback of the other.
            group.cancelAll()
            await group.waitForAll()
        }
        logger.debug(
            "udp-relay-finished trial=\(trialID, privacy: .public)"
        )
    }

    /// Reads the application's datagrams for the whole life of the flow.
    ///
    /// When no association is ready, this loop retains only the bounded batch
    /// already returned by NetworkExtension. This prevents the first datagram
    /// from being consumed during the initial SOCKS handshake without creating
    /// an unbounded application-side queue.
    private static func uplink(
        channel: UDPFlowChannel,
        trialID: String,
        traffic: ProviderTrafficLedger,
        logger: Logger
    ) async {
        let remoteHostname = channel.flow.remoteHostname
        do {
            while !Task.isCancelled {
                let datagrams = try await readDatagrams(from: channel.flow)
                guard let datagrams, !datagrams.isEmpty else {
                    channel.close(with: nil)
                    return
                }
                for (payload, endpoint) in datagrams {
                    guard let association = try await channel.waitForCurrent()
                    else { return }
                    try Task.checkCancellation()
                    guard let datagramConnection = association.datagramConnection
                    else {
                        channel.release(association)
                        continue
                    }
                    let packet: Data
                    do {
                        packet = try channel.codec.encode(
                            payload: payload,
                            destination: endpoint,
                            remoteHostname: remoteHostname
                        )
                    } catch {
                        logger.debug(
                            "udp-send-dropped trial=\(trialID, privacy: .public) code=\(diagnosticCode(error), privacy: .public)"
                        )
                        continue
                    }
                    do {
                        try await send(packet, to: datagramConnection)
                    } catch {
                        // An upstream send failure invalidates the association,
                        // not the flow. Retire it and let the supervisor
                        // re-associate.
                        channel.release(association, with: error)
                        continue
                    }
                    traffic.recordUpload(
                        payload.count,
                        transactionID: association.generation
                    )
                }
            }
        } catch {
            if Task.isCancelled {
                return
            }
            if isExpectedFlowClosure(error) {
                logger.debug(
                    "udp-relay-closed trial=\(trialID, privacy: .public) stage=flow-read code=\(diagnosticCode(error), privacy: .public)"
                )
            } else {
                logger.error(
                    "udp-relay-error trial=\(trialID, privacy: .public) stage=flow-read code=\(diagnosticCode(error), privacy: .public)"
                )
            }
            channel.close(with: error)
        }
    }

    private static func associationLoop(
        channel: UDPFlowChannel,
        initialTicket: AssociationTicket,
        nextTicket: @escaping @Sendable () -> AssociationTicket?,
        policy: RelayReassociationPolicy,
        traffic: ProviderTrafficLedger,
        logger: Logger
    ) async {
        let trialID = initialTicket.generation
        var ticket = initialTicket
        var budget = RelayReassociationBudget(policy: policy)

        while !Task.isCancelled {
            let outcome = await runAssociation(
                channel: channel,
                ticket: ticket,
                traffic: traffic,
                logger: logger
            )
            if channel.isClosed || Task.isCancelled {
                return
            }
            switch outcome {
            case let .flowEnded(stage, error):
                if let error, !isExpectedFlowClosure(error) {
                    logger.error(
                        "udp-relay-error trial=\(trialID, privacy: .public) stage=\(stage, privacy: .public) code=\(diagnosticCode(error), privacy: .public)"
                    )
                }
                channel.close(with: error)
                return
            case let .associationEnded(stage, error, duration):
                guard
                    let delay = budget.nextDelay(
                        afterAssociationLasting: duration
                    )
                else {
                    logger.error(
                        "udp-relay-reassociate-exhausted trial=\(trialID, privacy: .public) stage=\(stage, privacy: .public) attempt=\(budget.attempt) code=\(diagnosticCode(error), privacy: .public)"
                    )
                    channel.close(
                        with: error ?? AppProxyFlowCloseError.aborted
                    )
                    return
                }
                if delay > 0 {
                    do {
                        try await Task.sleep(
                            nanoseconds: UInt64(delay * 1_000_000_000)
                        )
                    } catch {
                        return
                    }
                }
                guard let next = nextTicket() else {
                    logger.notice(
                        "udp-relay-reassociate-unavailable trial=\(trialID, privacy: .public) stage=\(stage, privacy: .public) attempt=\(budget.attempt)"
                    )
                    channel.close(with: AppProxyFlowCloseError.aborted)
                    return
                }
                logger.notice(
                    "udp-relay-reassociate trial=\(trialID, privacy: .public) generation=\(next.generation, privacy: .public) attempt=\(budget.attempt) stage=\(stage, privacy: .public) code=\(diagnosticCode(error), privacy: .public)"
                )
                ticket = next
            }
        }
    }

    /// Runs one association to completion and reports why it ended.
    ///
    /// The handle registered here owns only the association's loopback
    /// connections: registry cancellation tears those down promptly — keeping
    /// the bounded handoff drain honest — and never touches the flow.
    private static func runAssociation(
        channel: UDPFlowChannel,
        ticket: AssociationTicket,
        traffic: ProviderTrafficLedger,
        logger: Logger
    ) async -> AssociationOutcome {
        guard
            let socksPort = Network.NWEndpoint.Port(
                rawValue: ticket.socksPort
            )
        else {
            ticket.finish()
            return .associationEnded(
                stage: "control-connect",
                error: RelayError.invalidEndpoint,
                duration: 0
            )
        }
        let control = NWConnection(
            host: .ipv4(IPv4Address.loopback),
            port: socksPort,
            using: .tcp
        )
        let association = UDPAssociation(
            control: control,
            generation: ticket.generation
        )
        let shutdown = RelayTaskShutdown { error in
            association.tearDown(with: error)
        }
        let box = UDPRelayOneShotBox<AssociationOutcome>()
        let handle = ProviderRelayHandle(
            shutdown: shutdown,
            operation: {
                let outcome = await withTaskCancellationHandler {
                    await establish(
                        channel: channel,
                        association: association,
                        control: control,
                        ticket: ticket,
                        shutdown: shutdown,
                        traffic: traffic,
                        logger: logger
                    )
                } onCancel: {
                    shutdown.finish(with: AppProxyFlowCloseError.aborted)
                }
                channel.release(association)
                shutdown.finish(with: AppProxyFlowCloseError.aborted)
                box.resolve(
                    outcome
                )
            }
        )
        guard ticket.attach(handle) else {
            // The generation moved on between the reservation and here.
            ticket.finish()
            association.tearDown(with: AppProxyFlowCloseError.aborted)
            return .associationEnded(
                stage: "attach",
                error: RelayError.generationUnavailable,
                duration: 0
            )
        }
        guard handle.start(onFinish: { ticket.finish() }) else {
            ticket.finish()
            association.tearDown(with: AppProxyFlowCloseError.aborted)
            return .associationEnded(
                stage: "attach",
                error: RelayError.generationUnavailable,
                duration: 0
            )
        }
        return await box.wait()
    }

    private static func establish(
        channel: UDPFlowChannel,
        association: UDPAssociation,
        control: NWConnection,
        ticket: AssociationTicket,
        shutdown: RelayTaskShutdown,
        traffic: ProviderTrafficLedger,
        logger: Logger
    ) async -> AssociationOutcome {
        var stage = "control-connect"
        var healthClock = RelayAssociationHealthClock()
        do {
            try await start(control)
            stage = "udp-associate"
            let boundInterface: String?
            if channel.flow.isBound {
                guard
                    let interfaceName = channel.flow.interface?.name,
                    !interfaceName.isEmpty
                else {
                    throw RelayError.invalidEndpoint
                }
                boundInterface = interfaceName
            } else {
                boundInterface = nil
            }
            let relayEndpoint = try await associateUDP(
                control,
                credentials: ticket.credentials,
                boundInterface: boundInterface
            )
            stage = "relay-connect"
            let datagramConnection = NWConnection(
                to: relayEndpoint,
                using: .udp
            )
            association.install(datagram: datagramConnection)
            try await start(datagramConnection)
            guard channel.adopt(association) else {
                throw RelayError.flowClosed
            }
            healthClock.markReady()
            logger.debug(
                "udp-relay-started trial=\(ticket.generation, privacy: .public) endpoint=\(String(describing: relayEndpoint), privacy: .public)"
            )
            stage = "relay"
            try await RelayTaskGroup.run(
                operations: [
                    {
                        try await downlink(
                            channel: channel,
                            association: association,
                            traffic: traffic,
                            logger: logger
                        )
                    },
                    {
                        try await monitorControl(control)
                    },
                ],
                shutdown: shutdown
            )
            return .associationEnded(
                stage: stage,
                error: RelayError.associationEnded,
                duration: healthClock.duration()
            )
        } catch let failure as FlowFailure {
            return .flowEnded(stage: stage, error: failure.underlying)
        } catch {
            return .associationEnded(
                stage: stage,
                error: error,
                duration: healthClock.duration()
            )
        }
    }

    private static func downlink(
        channel: UDPFlowChannel,
        association: UDPAssociation,
        traffic: ProviderTrafficLedger,
        logger: Logger
    ) async throws {
        while !Task.isCancelled {
            guard let datagramConnection = association.datagramConnection else {
                throw RelayError.socksUnavailable
            }
            let packet = try await receiveMessage(from: datagramConnection)
            if packet.isEmpty {
                return
            }
            let decoded: (payload: Data, endpoint: Network.NWEndpoint)?
            do {
                decoded = try channel.codec.decode(packet: packet)
            } catch {
                // A single malformed datagram is not a reason to retire the
                // association, let alone the application's socket.
                logger.debug(
                    "udp-receive-dropped trial=\(association.generation, privacy: .public) code=\(diagnosticCode(error), privacy: .public)"
                )
                continue
            }
            guard let decoded else {
                logger.debug(
                    "udp-receive-unmapped trial=\(association.generation, privacy: .public)"
                )
                continue
            }
            do {
                try await writeDatagrams(
                    [(decoded.payload, decoded.endpoint)],
                    to: channel.flow
                )
            } catch {
                throw FlowFailure(underlying: error)
            }
            traffic.recordDownload(
                decoded.payload.count,
                transactionID: association.generation
            )
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

    private static func diagnosticCode(_ error: Error?) -> String {
        guard let error else {
            return "none"
        }
        switch error {
        case RelayError.invalidEndpoint:
            return "invalid-endpoint"
        case RelayError.socksUnavailable:
            return "socks-unavailable"
        case RelayError.socksProtocol:
            return "socks-protocol"
        case RelayError.flowClosed:
            return "flow-closed"
        case RelayError.generationUnavailable:
            return "generation-unavailable"
        case RelayError.associationEnded:
            return "association-ended"
        case UDPRelayDatagramError.invalidDestination:
            return "invalid-endpoint"
        case UDPRelayDatagramError.fragmentedDatagram:
            return "fragmented-datagram"
        case UDPRelayDatagramError.malformedPacket:
            return "socks-protocol"
        case let networkError as NWError:
            switch networkError {
            case let .posix(code):
                return "posix-\(code.rawValue)"
            case let .dns(code):
                return "dns-\(code)"
            case let .tls(code):
                return "tls-\(code)"
#if compiler(>=6.2)
            case .wifiAware:
                return "wifi-aware"
#endif
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
        credentials: SOCKSCredentials?,
        boundInterface: String?
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
        // A bound flow uses the authenticated domain envelope to preserve the
        // interface macOS already selected; it is not a routing destination.
        var request = Data([0x05, 0x03, 0x00])
        if let boundInterface {
            guard let metadata =
                    TransparentProxyFlowMetadata.encodeBoundAssociation(
                        boundInterface: boundInterface
                    )
            else {
                throw RelayError.invalidEndpoint
            }
            request.append(0x03)
            request.append(UInt8(metadata.count))
            request.append(metadata)
        } else {
            request.append(contentsOf: [0x01, 0x00, 0x00, 0x00, 0x00])
        }
        request.append(contentsOf: [0x00, 0x00])
        try await send(request, to: connection)
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
                    completion(.failure(RelayError.associationEnded))
                } else {
                    completion(.failure(RelayError.socksUnavailable))
                }
            }
        }
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

/// The loopback connections of one SOCKS UDP association.
///
/// Tearing an association down is idempotent and never touches the flow, so a
/// registry cancellation and a natural failure cannot turn into a double close
/// or into an application-visible socket death.
private final class UDPAssociation: @unchecked Sendable {
    let id = UUID()
    let generation: String

    private let lock = NSLock()
    private let control: NWConnection
    private var datagram: NWConnection?
    private var torn = false

    init(control: NWConnection, generation: String) {
        self.control = control
        self.generation = generation
    }

    var datagramConnection: NWConnection? {
        lock.lock()
        defer { lock.unlock() }
        return torn ? nil : datagram
    }

    func install(datagram: NWConnection) {
        lock.lock()
        if torn {
            lock.unlock()
            datagram.forceCancel()
            return
        }
        self.datagram = datagram
        lock.unlock()
    }

    func tearDown(with error: Error?) {
        lock.lock()
        guard !torn else {
            lock.unlock()
            return
        }
        torn = true
        let datagramConnection = datagram
        datagram = nil
        lock.unlock()

        // An association is only ever retired because its engine generation or
        // its listener is gone. Graceful protocol shutdown of a loopback
        // connection whose peer has vanished can hang, so always force.
        let cancellationError = error ?? AppProxyFlowCloseError.aborted
        RelayConnectionCancellation.cancel(control, error: cancellationError)
        if let datagramConnection {
            RelayConnectionCancellation.cancel(
                datagramConnection,
                error: cancellationError
            )
        }
    }
}

/// Owns the application-facing flow across every association it outlives.
private final class UDPFlowChannel: @unchecked Sendable {
    let flow: NEAppProxyUDPFlow
    let codec = UDPRelayDatagramCodec()

    private let associationSlot = RelayAssociationSlot<UDPAssociation>()

    init(flow: NEAppProxyUDPFlow) {
        self.flow = flow
    }

    var isClosed: Bool {
        associationSlot.isClosed
    }

    func waitForCurrent() async throws -> UDPAssociation? {
        try await associationSlot.waitForCurrent()
    }

    /// Publishes a ready association. Returns false once the flow has ended.
    func adopt(_ candidate: UDPAssociation) -> Bool {
        let result = associationSlot.adopt(candidate)
        guard result.accepted else {
            return false
        }
        if let previous = result.replaced, previous.id != candidate.id {
            previous.tearDown(with: AppProxyFlowCloseError.aborted)
        }
        return true
    }

    func release(
        _ candidate: UDPAssociation,
        with error: Error? = AppProxyFlowCloseError.aborted
    ) {
        associationSlot.release(candidate)
        candidate.tearDown(with: error)
    }

    /// Closes the application's flow exactly once. This is the only place a
    /// UDP flow dies, and it happens only when the flow itself failed or no
    /// engine generation can carry it any more.
    func close(with error: Error?) {
        let result = associationSlot.close()
        guard result.didClose else {
            return
        }

        result.current?.tearDown(
            with: error ?? AppProxyFlowCloseError.aborted
        )
        let sourceError = AppProxyFlowCloseError.normalize(error)
        flow.closeReadWithError(sourceError)
        flow.closeWriteWithError(sourceError)
    }
}

/// One-shot hand-off from the association's unstructured task to the
/// supervisor awaiting its outcome.
private final class UDPRelayOneShotBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Value?
    private var continuation: CheckedContinuation<Value, Never>?
    private var resolved = false

    func resolve(_ value: Value) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        let waiter = continuation
        continuation = nil
        if waiter == nil {
            pending = value
        }
        lock.unlock()
        waiter?.resume(returning: value)
    }

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let value = pending {
                pending = nil
                lock.unlock()
                continuation.resume(returning: value)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}
