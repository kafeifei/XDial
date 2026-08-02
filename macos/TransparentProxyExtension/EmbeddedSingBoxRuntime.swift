import Foundation
import Libbox
import OSLog

struct PathInterfaceSnapshot: Codable {
    let name: String
    let index: Int
    let type: String
}

struct InterfaceSnapshot {
    let defaultInterface: PathInterfaceSnapshot
    let interfacesJSON: String
    let systemDNSJSON: String
}

final class EmbeddedSingBoxRuntime {
    private static let networkStateGroup =
        "UVZM439VGU.com.kafeifei.xdial.network"

    struct Session {
        let port: UInt16
        let credentials: SOCKSCredentials
        /// Active application identities mapped to their per-session SOCKS
        /// usernames. The password stays the ordinary loopback session
        /// password; this map is never persisted or exposed in diagnostics.
        let applicationCredentials: [String: SOCKSCredentials]
        let lineOutbounds: [String: String]
        let ruleSetTags: Set<String>
        let dnsCaptureDomains: [String]
        let tailscaleDNSRecordCount: Int
    }

    private struct SessionEnvelope: Decodable {
        struct AnyConnect: Decodable {
            let server: String
            let username: String
            let password: String
            let allowInsecure: Bool

            enum CodingKeys: String, CodingKey {
                case server
                case username
                case password
                case allowInsecure = "allow_insecure"
            }
        }

        struct Tailscale: Decodable {
            let endpointTag: String
            let exitNode: String
            let magicDNSEnabled: Bool
            let dnsServerTag: String?

            enum CodingKeys: String, CodingKey {
                case endpointTag = "endpoint_tag"
                case exitNode = "exit_node"
                case magicDNSEnabled = "magic_dns_enabled"
                case dnsServerTag = "dns_server_tag"
            }
        }

        let configJSON: String
        let plan: ConnectionPlan
        let lineOutbounds: [String: String]
        let subscriptionOutbounds: [String: [String]]
        let ruleSetTags: [String]
        let applicationCredentials: [String: String]?
        let anyConnect: AnyConnect?
        let tailscale: Tailscale?

        enum CodingKeys: String, CodingKey {
            case configJSON = "config_json"
            case plan
            case lineOutbounds = "line_outbounds"
            case subscriptionOutbounds = "subscription_outbounds"
            case ruleSetTags = "rule_set_tags"
            case applicationCredentials = "application_credentials"
            case anyConnect = "anyconnect"
            case tailscale
        }
    }

    private struct TailscaleStatus: Decodable {
        struct Readiness: Decodable {
            struct DERP: Decodable {
                let observed: Bool
                let clientCount: Int
                let protocolReadyCount: Int
                let homeConfigured: Bool
                let homeState: String
                let homeKeyRelation: String
                let homeIdealKnown: Bool
                let homeIdeal: Bool
                let homeConnectionGeneration: UInt64
                let homeServerChangeSequence: UInt64

                enum CodingKeys: String, CodingKey {
                    case observed
                    case clientCount = "client_count"
                    case protocolReadyCount = "protocol_ready_count"
                    case homeConfigured = "home_configured"
                    case homeState = "home_state"
                    case homeKeyRelation = "home_key_relation"
                    case homeIdealKnown = "home_ideal_known"
                    case homeIdeal = "home_ideal"
                    case homeConnectionGeneration =
                        "home_connection_generation"
                    case homeServerChangeSequence =
                        "home_server_change_sequence"
                }
            }

            struct Control: Decodable {
                let generation: UInt64
                let observed: Bool
                let clientPresent: Bool
                let resetForCurrentClient: Bool
                let setForCurrentClient: Bool
                let preferredDERPRelation: String

                enum CodingKeys: String, CodingKey {
                    case generation
                    case observed
                    case clientPresent = "client_present"
                    case resetForCurrentClient =
                        "reset_for_current_client"
                    case setForCurrentClient = "set_for_current_client"
                    case preferredDERPRelation =
                        "preferred_derp_relation"
                }
            }

            let derp: DERP
            let control: Control
        }

        struct ExitNode: Decodable {
            let id: String
            let ip: String
            let online: Bool
            let selected: Bool
            let active: Bool
            let pathCandidate: String
            let txBytes: Int64
            let rxBytes: Int64
            let hasHandshake: Bool
            let inNetworkMap: Bool
            let inMagicSock: Bool
            let inEngine: Bool
            let controlHomeRelation: String
            let derpPath: TailscalePeerDERPPath

            enum CodingKeys: String, CodingKey {
                case id
                case ip
                case online
                case selected
                case active
                case pathCandidate = "path_candidate"
                case txBytes = "tx_bytes"
                case rxBytes = "rx_bytes"
                case hasHandshake = "has_handshake"
                case inNetworkMap = "in_network_map"
                case inMagicSock = "in_magic_sock"
                case inEngine = "in_engine"
                case controlHomeRelation = "control_home_relation"
                case derpPath = "derp_path"
            }
        }

        let backendState: String
        let authURL: String
        let healthCount: Int
        let controlSelfHomePresent: Bool
        let magicDNSReady: Bool
        let readiness: Readiness
        let exitNodes: [ExitNode]

        enum CodingKeys: String, CodingKey {
            case backendState = "backend_state"
            case authURL = "auth_url"
            case healthCount = "health_count"
            case controlSelfHomePresent = "control_self_home_present"
            case magicDNSReady = "magic_dns_ready"
            case readiness
            case exitNodes = "exit_nodes"
        }
    }

    private struct RuntimeDiagnostics: Decodable {
        let handshakeCompleted: Bool

        enum CodingKeys: String, CodingKey {
            case handshakeCompleted = "handshake_completed"
        }
    }

    private struct TailscalePeerDERPPathObservation {
        let nodeID: String
        let path: TailscalePeerDERPPath
    }

    private let logger: Logger
    private let callback: EngineCallback
    private let engineLock = NSLock()
    private var engine: LibboxLibbox?

    init(
        logger: Logger,
        onFatalError:
            @escaping @Sendable (ConnectionRuntimeFailure) -> Void
    ) {
        self.logger = logger
        callback = EngineCallback(
            logger: logger,
            onFatalError: onFatalError
        )
    }

    func start(
        profileJSON: String,
        networkSnapshot: InterfaceSnapshot,
        reporter: ConnectionTransactionReporter,
        cancellation: ConnectionCancellation
    ) throws -> Session {
        try checkCancellation(cancellation)
        guard currentEngine() == nil else {
            throw RuntimeError.alreadyRunning
        }

        let port = UInt16.random(in: 20_000 ... 60_000)
        let credentials = SOCKSCredentials(
            username: UUID().uuidString,
            password: UUID().uuidString + UUID().uuidString
        )
        let basePath = try runtimeDirectory()

        try checkCancellation(cancellation)
        reporter.setState(.preparing)
        reporter.setTask(id: "dns:mode", state: .running)
        let preparationCallback = PreparationCallback(
            reporter: reporter
        )
        var generationError: NSError?
        let envelopeJSON =
            LibboxGenerateTransparentProxySessionWithCallback(
            profileJSON,
            basePath.path,
            Int(port),
            credentials.username,
            credentials.password,
            networkSnapshot.defaultInterface.name,
            networkSnapshot.systemDNSJSON,
            preparationCallback,
            &generationError
        )
        if let generationError {
            throw generationError
        }
        try checkCancellation(cancellation)
        guard
            let envelopeData = envelopeJSON.data(using: .utf8),
            let envelope = try? JSONDecoder().decode(
                SessionEnvelope.self,
                from: envelopeData
            )
        else {
            throw RuntimeError.invalidSessionEnvelope
        }
        let plannedLineIDs = Set(
            envelope.plan.tasks
                .filter { $0.kind == "line" }
                .map(\.resourceID)
        )
        let plannedSubscriptionIDs = Set(
            envelope.plan.tasks
                .filter { $0.kind == "subscription" }
                .map(\.resourceID)
        )
        guard
            !plannedLineIDs.contains(""),
            Set(envelope.lineOutbounds.keys) == plannedLineIDs,
            envelope.lineOutbounds.values.allSatisfy({ !$0.isEmpty }),
            !plannedSubscriptionIDs.contains(""),
            Set(envelope.subscriptionOutbounds.keys) ==
                plannedSubscriptionIDs,
            envelope.subscriptionOutbounds.values.allSatisfy({ tags in
                !tags.isEmpty &&
                    tags.allSatisfy({ !$0.isEmpty }) &&
                    Set(tags).count == tags.count
            }),
            !envelope.ruleSetTags.contains(""),
            Set(envelope.ruleSetTags).count ==
                envelope.ruleSetTags.count,
            (envelope.applicationCredentials ?? [:]).allSatisfy({ entry in
                !entry.key.isEmpty &&
                    !entry.value.isEmpty &&
                    entry.value.utf8.count <= 255
            }),
            envelope.tailscale.map({ tailscale in
                !tailscale.magicDNSEnabled ||
                    !(tailscale.dnsServerTag ?? "").isEmpty
            }) ?? true
        else {
            throw RuntimeError.invalidSessionEnvelope
        }
        try reporter.validate(plan: envelope.plan)
        reporter.setPendingTasks(kind: "rule_set", state: .ready)
        reporter.setTasks(kind: "line", state: .running)
        reporter.setTasks(kind: "subscription", state: .running)
        reporter.setTask(id: "data-plane:sing-box", state: .running)
        try checkCancellation(cancellation)
        guard let instance = LibboxNew(callback) else {
            throw RuntimeError.unavailable
        }
        let anyConnectTaskID = envelope.plan.tasks.first {
            $0.kind == "line" && $0.resourceType == "vpn"
        }?.id
        callback.attach(
            engine: instance,
            taskID: anyConnectTaskID ?? "data-plane:sing-box",
            reporter: reporter
        )
#if DEBUG
        instance.setDebugRoutingProbeEnabled(true)
#endif
        instance.setUnderlayInterfaceBinding(true)
        try instance.setNetworkInterfaces(networkSnapshot.interfacesJSON)
        instance.setDefaultInterface(
            networkSnapshot.defaultInterface.name,
            index: networkSnapshot.defaultInterface.index
        )
        logger.notice(
            "platform-interface name=\(networkSnapshot.defaultInterface.name, privacy: .public) socketBinding=true"
        )

        do {
            if let anyConnect = envelope.anyConnect {
                try checkCancellation(cancellation)
                var resolveError: NSError?
                let dialAddress = LibboxResolveServerIPv4(
                    anyConnect.server,
                    &resolveError
                )
                if let resolveError {
                    throw resolveError
                }
                try instance.startResolved(
                    withInsecure: anyConnect.server,
                    dialAddress: dialAddress,
                    username: anyConnect.username,
                    password: anyConnect.password,
                    allowInsecure: anyConnect.allowInsecure,
                    configJSON: envelope.configJSON
                )
            } else {
                try instance.startStandalone(envelope.configJSON)
            }
            try checkCancellation(cancellation)
            reporter.setTasks(
                kind: "line",
                state: .ready,
                matchingResourceType: "direct"
            )
            let proxyTargets = try ProxyResourceReadiness.targets(
                plan: envelope.plan,
                lineOutbounds: envelope.lineOutbounds,
                subscriptionOutbounds:
                    envelope.subscriptionOutbounds
            )
            try ProxyResourceReadiness.verifyConcurrently(
                proxyTargets,
                probe: { target, outboundTag in
                    do {
                        try self.checkCancellation(cancellation)
                        var probeError: NSError?
                        let address = instance.probeOutboundIP(
                            outboundTag,
                            timeoutMS: 8_000,
                            error: &probeError
                        )
                        try self.checkCancellation(cancellation)
                        guard probeError == nil, !address.isEmpty else {
                            throw ProxyResourceReadiness.failure(
                                target: target,
                                reason:
                                    probeError?.localizedDescription
                                        ?? "exact outbound probe returned no address"
                            )
                        }
                    } catch {
                        if cancellation.isCancelled ||
                            error is ConnectionRuntimeFailure
                        {
                            throw error
                        }
                        throw ProxyResourceReadiness.failure(
                            target: target,
                            reason: error.localizedDescription
                        )
                    }
                    self.logger.notice(
                        "proxy-resource-outbound-ready kind=\(target.taskKind, privacy: .public) type=\(target.resourceType, privacy: .public) resource=\(target.resourceID, privacy: .public)"
                    )
                },
                markReady: { target in
                    logger.notice(
                        "proxy-resource-egress-ready kind=\(target.taskKind, privacy: .public) type=\(target.resourceType, privacy: .public) resource=\(target.resourceID, privacy: .public)"
                    )
                    reporter.note(
                        code: target.readyCode,
                        message: target.readyMessage,
                        taskID: target.taskID
                    )
                    reporter.setTask(
                        id: target.taskID,
                        state: .ready
                    )
                }
            )
            var preparedTailscaleDNS:
                TransparentProxyPreparedTailscaleDNS?
            if let tailscale = envelope.tailscale {
                let taskID = envelope.plan.tasks.first {
                    $0.kind == "line" &&
                        $0.resourceType == "tailscale"
                }?.id ?? "data-plane:sing-box"
                do {
                    preparedTailscaleDNS = try waitForTailscale(
                        instance,
                        target: tailscale,
                        reporter: reporter,
                        taskID: taskID,
                        cancellation: cancellation
                    )
                } catch {
                    if let failure =
                        error as? ConnectionRuntimeFailure
                    {
                        reporter.fail(failure)
                        throw failure
                    }
                    let reportCode =
                        (error as? RuntimeError)?.reportCode
                            ?? "tailscale-readiness-failed"
                    let failureTaskID =
                        reportCode ==
                            ConnectionFailureCode
                            .underlayEgressUnavailable
                            ? "underlay:system"
                            : taskID
                    reporter.fail(
                        error,
                        code: reportCode,
                        taskID: failureTaskID
                    )
                    throw error
                }
                reporter.setTasks(
                    kind: "line",
                    state: .ready,
                    matchingResourceType: "tailscale"
                )
            }
            if envelope.anyConnect != nil {
                try waitForAnyConnectRecovery(
                    instance,
                    cancellation: cancellation
                )
                reporter.setTasks(
                    kind: "line",
                    state: .ready,
                    matchingResourceType: "vpn"
                )
            }
            reporter.setTask(id: "dns:mode", state: .ready)
            try checkCancellation(cancellation)
            engineLock.lock()
            engine = instance
            engineLock.unlock()
            reporter.setTask(
                id: "data-plane:sing-box",
                state: .ready
            )
            logger.notice("sing-box-started port=\(port)")
            return Session(
                port: port,
                credentials: credentials,
                applicationCredentials: Dictionary(
                    uniqueKeysWithValues: (envelope.applicationCredentials ?? [:])
                        .map { identity, username in
                            (
                                identity,
                                SOCKSCredentials(
                                    username: username,
                                    password: credentials.password
                                )
                            )
                        }
                ),
                lineOutbounds: envelope.lineOutbounds,
                ruleSetTags: Set(envelope.ruleSetTags),
                dnsCaptureDomains:
                    preparedTailscaleDNS?.captureDomains ?? [],
                tailscaleDNSRecordCount:
                    preparedTailscaleDNS?.recordCount ?? 0
            )
        } catch {
            callback.markStopped()
            try? instance.stop()
            throw error
        }
    }

    func probeLineOutboundAddress(
        lineID: String,
        session: Session
    ) throws -> ProviderLineOutboundAddress {
        guard
            let engine = currentEngine(),
            let outboundTag = session.lineOutbounds[lineID],
            !outboundTag.isEmpty
        else {
            throw RuntimeError.lineCapabilityUnavailable
        }
        var probeError: NSError?
        let address = engine.probeOutboundIP(
            outboundTag,
            timeoutMS: 3_000,
            error: &probeError
        )
        guard probeError == nil, !address.isEmpty else {
            throw RuntimeError.diagnosticsUnavailable
        }
        return ProviderLineOutboundAddress(
            lineID: lineID,
            address: address
        )
    }

    func routingProbeSnapshot() throws
        -> ProviderRoutingProbeSnapshot
    {
        guard let engine = currentEngine() else {
            throw RuntimeError.diagnosticsUnavailable
        }
        let raw = engine.routingProbeSnapshot()
        guard
            let data = raw.data(using: .utf8),
            let snapshot = try? JSONDecoder().decode(
                ProviderRoutingProbeSnapshot.self,
                from: data
            )
        else {
            throw RuntimeError.diagnosticsUnavailable
        }
        return snapshot
    }

    func beginRouteProbe(
        hostname: String,
        timeoutMS: Int
    ) throws -> ProviderBegunRouteProbe {
        guard let engine = currentEngine() else {
            throw RuntimeError.diagnosticsUnavailable
        }
        var probeError: NSError?
        let probeID = engine.beginRoutingProbe(
            hostname,
            timeoutMS: timeoutMS,
            error: &probeError
        )
        guard probeError == nil, !probeID.isEmpty else {
            throw RuntimeError.diagnosticsUnavailable
        }
        return ProviderBegunRouteProbe(probeID: probeID)
    }

    func stop() throws {
        callback.markStopped()
        engineLock.lock()
        let current = engine
        engine = nil
        engineLock.unlock()
        guard let current else {
            return
        }
        try current.stop()
        logger.notice("sing-box-stopped")
    }

    private func currentEngine() -> LibboxLibbox? {
        engineLock.lock()
        let current = engine
        engineLock.unlock()
        return current
    }

    private func runtimeDirectory() throws -> URL {
        guard let groupContainer = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier:
                Self.networkStateGroup
        ) else {
            throw RuntimeError.storageUnavailable
        }
        let directory = groupContainer.appendingPathComponent(
            "NetworkExtension",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        logger.notice(
            "runtime-directory path=\(directory.path, privacy: .public)"
        )
        return directory
    }

    private func waitForTailscale(
        _ instance: LibboxLibbox,
        target: SessionEnvelope.Tailscale,
        reporter: ConnectionTransactionReporter,
        taskID: String,
        cancellation: ConnectionCancellation
    ) throws -> TransparentProxyPreparedTailscaleDNS? {
        try checkCancellation(cancellation)
        var underlayProbeError: NSError?
        let underlayAddress = instance.probeOutboundIP(
            "direct",
            timeoutMS: 5_000,
            error: &underlayProbeError
        )
        guard underlayProbeError == nil, !underlayAddress.isEmpty else {
            throw RuntimeError.underlayEgressUnavailable(
                underlayProbeError?.localizedDescription
                    ?? "direct outbound address probe returned no address"
            )
        }
        logger.notice("underlay-egress-ready")

        let deadline = Date().addingTimeInterval(30)
        var lastState = "NoState"
        var lastProbeError: Error?
        var lastObservedExitNode: TailscaleStatus.ExitNode?
        var lastMagicDNSReady = false
        var lastPostProbeSample:
            (status: TailscaleStatus, node: TailscaleStatus.ExitNode)?
        var lastReadinessSummary = ""
        var firstDERPPathObservation:
            TailscalePeerDERPPathObservation?
        var finalDERPPathObservation:
            TailscalePeerDERPPathObservation?
        while Date() < deadline {
            try checkCancellation(cancellation)
            var statusError: NSError?
            let statusJSON = instance.tailscaleStatus(
                target.endpointTag,
                error: &statusError
            )
            if let statusError {
                throw statusError
            }
            guard
                let data = statusJSON.data(using: String.Encoding.utf8),
                let status = try? JSONDecoder().decode(
                    TailscaleStatus.self,
                    from: data
                )
            else {
                throw RuntimeError.invalidTailscaleStatus
            }
            lastState = status.backendState
            lastMagicDNSReady =
                status.backendState == "Running" && status.magicDNSReady
            let readinessSummary =
                "controlGeneration=\(status.readiness.control.generation) " +
                "controlClient=\(status.readiness.control.clientPresent) " +
                "controlObserved=\(status.readiness.control.observed) " +
                "netInfoReset=\(status.readiness.control.resetForCurrentClient) " +
                "netInfoSet=\(status.readiness.control.setForCurrentClient) " +
                "preferredRelation=\(status.readiness.control.preferredDERPRelation) " +
                "derpClients=\(status.readiness.derp.clientCount) " +
                "derpObserved=\(status.readiness.derp.observed) " +
                "derpReady=\(status.readiness.derp.protocolReadyCount) " +
                "homeConfigured=\(status.readiness.derp.homeConfigured) " +
                "homeState=\(status.readiness.derp.homeState) " +
                "homeKeyRelation=\(status.readiness.derp.homeKeyRelation) " +
                "homeIdealKnown=\(status.readiness.derp.homeIdealKnown) " +
                "homeIdeal=\(status.readiness.derp.homeIdeal) " +
                "homeGeneration=\(status.readiness.derp.homeConnectionGeneration) " +
                "homeServerChangeSeq=\(status.readiness.derp.homeServerChangeSequence)"
            if readinessSummary != lastReadinessSummary {
                lastReadinessSummary = readinessSummary
                logger.notice(
                    "tailscale-bootstrap \(readinessSummary, privacy: .public)"
                )
            }
            if !status.authURL.isEmpty {
                throw RuntimeError.tailscaleLoginRequired
            }
            if status.backendState == "Running" {
                if target.magicDNSEnabled && !status.magicDNSReady {
                    Thread.sleep(forTimeInterval: 0.2)
                    continue
                }
                let selected = status.exitNodes.first {
                    $0.id == target.exitNode || $0.ip == target.exitNode
                }
                lastObservedExitNode = selected
                if selected?.online != true ||
                    selected?.selected != true {
                    lastPostProbeSample = nil
                    firstDERPPathObservation = nil
                    finalDERPPathObservation = nil
                }
                if let selected, selected.online, selected.selected {
                    try checkCancellation(cancellation)
                    let remainingMS = Int(
                        deadline.timeIntervalSinceNow * 1_000
                    )
                    if remainingMS < 500 {
                        break
                    }
                    var probeError: NSError?
                    let publicAddress = instance.probeOutboundIP(
                        target.endpointTag,
                        timeoutMS: min(5_000, remainingMS),
                        error: &probeError
                    )
                    if probeError == nil && !publicAddress.isEmpty {
                        logger.notice(
                            "tailscale-ready endpoint=\(target.endpointTag, privacy: .public)"
                        )
                        if !target.magicDNSEnabled {
                            return nil
                        }
                        guard let dnsServerTag = target.dnsServerTag else {
                            throw RuntimeError.invalidSessionEnvelope
                        }
                        try checkCancellation(cancellation)
                        var preparationError: NSError?
                        // Snapshot and replace happen atomically in Libbox.
                        // Only bounded ingress metadata crosses into Swift so
                        // member address mappings cannot reach reports or
                        // Provider configuration.
                        let metadataJSON =
                            instance.prepareTailscaleDNS(
                                target.endpointTag,
                                dnsServerTag: dnsServerTag,
                                error: &preparationError
                            )
                        if preparationError != nil {
                            throw ConnectionRuntimeFailure(
                                code:
                                    "tailscale-dns-preparation-failed",
                                message:
                                    "无法准备当前 Tailnet 的内存 DNS 记录",
                                taskID: "dns:mode",
                                evidence: nil
                            )
                        }
                        let prepared:
                            TransparentProxyPreparedTailscaleDNS
                        do {
                            prepared = try
                                TransparentProxyDNSCapturePlan
                                .decodePreparedTailscaleDNS(
                                    metadataJSON
                                )
                        } catch {
                            throw ConnectionRuntimeFailure(
                                code:
                                    "tailscale-dns-preparation-failed",
                                message: error.localizedDescription,
                                taskID: "dns:mode",
                                evidence: nil
                            )
                        }
                        try checkCancellation(cancellation)
                        logger.notice(
                            "tailscale-dns-prepared records=\(prepared.recordCount) capture-domains=\(prepared.captureDomains.count)"
                        )
                        return prepared
                    }
                    if let latest = latestSelectedExitNode(
                            instance,
                            target: target
                        )
                    {
                        lastPostProbeSample = latest
                        let observation =
                            TailscalePeerDERPPathObservation(
                                nodeID: latest.node.id,
                                path: latest.node.derpPath
                            )
                        if firstDERPPathObservation == nil {
                            firstDERPPathObservation = observation
                        }
                        finalDERPPathObservation = observation
                        logger.notice(
                            "tailscale-egress-probe-failed sample=post-probe active=\(latest.node.active) pathCandidate=\(latest.node.pathCandidate, privacy: .public) tx=\(latest.node.txBytes) rx=\(latest.node.rxBytes) handshake=\(latest.node.hasHandshake) map=\(latest.node.inNetworkMap) magic=\(latest.node.inMagicSock) engine=\(latest.node.inEngine) controlGeneration=\(latest.status.readiness.control.generation) derpClients=\(latest.status.readiness.derp.clientCount) derpReady=\(latest.status.readiness.derp.protocolReadyCount) homeState=\(latest.status.readiness.derp.homeState, privacy: .public) netInfoSet=\(latest.status.readiness.control.setForCurrentClient) preferredRelation=\(latest.status.readiness.control.preferredDERPRelation, privacy: .public) health=\(latest.status.healthCount) controlSelfHome=\(latest.status.controlSelfHomePresent) controlHomeRelation=\(latest.node.controlHomeRelation, privacy: .public) derpPath=\(latest.node.derpPath.logSummary, privacy: .public)"
                        )
                    } else {
                        // The post-probe sample is the chronology authority.
                        // Do not classify from the pre-probe snapshot if the
                        // node disappeared or status became unreadable.
                        lastPostProbeSample = nil
                        firstDERPPathObservation = nil
                        finalDERPPathObservation = nil
                    }
                    lastProbeError = probeError
                }
            } else {
                lastObservedExitNode = nil
                lastPostProbeSample = nil
                firstDERPPathObservation = nil
                finalDERPPathObservation = nil
                if ![
                    "NoState",
                    "Starting",
                    "NeedsLogin",
                ].contains(status.backendState) {
                    throw RuntimeError.tailscaleUnavailable(
                        status.backendState
                    )
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        try checkCancellation(cancellation)
        if target.magicDNSEnabled, !lastMagicDNSReady {
            throw RuntimeError.tailscaleMagicDNSUnavailable
        }
        if let selected = lastObservedExitNode,
            (!selected.online || !selected.selected)
        {
            throw RuntimeError.tailscaleExitNodeUnavailable
        }
        if let sample = lastPostProbeSample {
            let readiness = sample.status.readiness
            let selected = sample.node
            let failure = classifyTailscaleReadinessFailure(
                TailscaleReadinessFacts(
                    pathCandidate: selected.pathCandidate,
                    exitNodeOnline: selected.online,
                    exitNodeSelected: selected.selected,
                    controlGeneration:
                        readiness.control.generation,
                    controlObserved: readiness.control.observed,
                    controlClientPresent:
                        readiness.control.clientPresent,
                    netInfoResetForCurrentClient:
                        readiness.control.resetForCurrentClient,
                    netInfoSetForCurrentClient:
                        readiness.control.setForCurrentClient,
                    preferredDERPRelation:
                        readiness.control.preferredDERPRelation,
                    derpObserved: readiness.derp.observed,
                    homeDERPState: readiness.derp.homeState,
                    homeDERPKeyRelation:
                        readiness.derp.homeKeyRelation
                )
            )
            switch failure {
            case .controlClientMissing:
                throw RuntimeError.tailscaleControlClientMissing
            case .netInfoResetMissing:
                throw RuntimeError.tailscaleNetInfoResetMissing
            case .netInfoSetMissing:
                throw RuntimeError.tailscaleNetInfoSetMissing
            case .homeDERPReportMismatch:
                throw RuntimeError.tailscaleHomeDERPReportMismatch
            case .derpIdentityMismatch:
                throw RuntimeError.tailscaleDERPIdentityMismatch
            case let .homeDERPNotReady(state):
                throw RuntimeError.tailscaleHomeDERPNotReady(state)
            case nil:
                break
            }
        }
        if let sample = lastPostProbeSample {
            let node = sample.node
            if node.online,
                node.selected,
                node.inNetworkMap,
                node.inMagicSock,
                node.inEngine,
                node.txBytes > 0,
                node.rxBytes == 0,
                !node.hasHandshake
            {
                let initialObservation =
                    firstDERPPathObservation ??
                    TailscalePeerDERPPathObservation(
                        nodeID: node.id,
                        path: node.derpPath
                    )
                let finalObservation =
                    finalDERPPathObservation ??
                    TailscalePeerDERPPathObservation(
                        nodeID: node.id,
                        path: node.derpPath
                    )
                let comparison = TailscalePeerDERPPathComparison(
                    initial: initialObservation.path,
                    final: finalObservation.path,
                    sameExitNode:
                        initialObservation.nodeID ==
                        finalObservation.nodeID
                )
                var facts = comparison.reportFacts
                facts["final_control_observed"] =
                    sample.status.readiness.control.observed
                facts["final_control_client_present"] =
                    sample.status.readiness.control.clientPresent
                facts["final_netinfo_reset_for_current_client"] =
                    sample.status.readiness.control
                    .resetForCurrentClient
                facts["final_netinfo_set_for_current_client"] =
                    sample.status.readiness.control
                    .setForCurrentClient
                facts["final_preferred_derp_matches"] =
                    sample.status.readiness.control
                    .preferredDERPRelation == "match"
                facts["final_derp_observed"] =
                    sample.status.readiness.derp.observed
                facts["final_home_derp_configured"] =
                    sample.status.readiness.derp.homeConfigured
                facts["final_home_derp_protocol_ready"] =
                    sample.status.readiness.derp.homeState ==
                    "protocol_ready"
                facts["final_home_derp_key_matches"] =
                    sample.status.readiness.derp.homeKeyRelation ==
                    "match"
                facts["final_home_derp_ideal_known"] =
                    sample.status.readiness.derp.homeIdealKnown
                facts["final_home_derp_ideal"] =
                    sample.status.readiness.derp.homeIdeal
                facts["final_home_derp_connection_established"] =
                    sample.status.readiness.derp
                    .homeConnectionGeneration > 0
                facts["final_home_derp_server_changed"] =
                    sample.status.readiness.derp
                    .homeServerChangeSequence > 0
                facts["final_control_self_home_present"] =
                    sample.status.controlSelfHomePresent
                facts["final_peer_control_home_matches"] =
                    tailscaleControlHomeRelationIsSame(
                        node.controlHomeRelation
                    )
                facts["final_path_candidate_relay"] =
                    node.pathCandidate == "relay"
                reporter.note(
                    code: "tailscale-peer-derp-path-observation",
                    message:
                        "DERP 路径首尾观察：\(comparison.logSummary)",
                    taskID: taskID,
                    facts: facts
                )
                logger.notice(
                    "tailscale-peer-derp-path-final \(comparison.logSummary, privacy: .public)"
                )
                throw RuntimeError.tailscalePeerHandshakeUnavailable
            }
        }
        if let lastProbeError {
            throw RuntimeError.tailscaleEgressUnavailable(
                lastProbeError.localizedDescription
            )
        }
        throw RuntimeError.tailscaleReadinessTimedOut(lastState)
    }

    private func latestSelectedExitNode(
        _ instance: LibboxLibbox,
        target: SessionEnvelope.Tailscale
    ) -> (status: TailscaleStatus, node: TailscaleStatus.ExitNode)? {
        var statusError: NSError?
        let statusJSON = instance.tailscaleStatus(
            target.endpointTag,
            error: &statusError
        )
        guard
            statusError == nil,
            let data = statusJSON.data(using: .utf8),
            let status = try? JSONDecoder().decode(
                TailscaleStatus.self,
                from: data
            ),
            let selected = status.exitNodes.first(where: {
                $0.id == target.exitNode || $0.ip == target.exitNode
            })
        else {
            return nil
        }
        return (status, selected)
    }

    private func waitForAnyConnectRecovery(
        _ instance: LibboxLibbox,
        cancellation: ConnectionCancellation
    ) throws {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            try checkCancellation(cancellation)
            let diagnosticsJSON = instance.diagnostics()
            if let data = diagnosticsJSON.data(using: .utf8),
               let diagnostics = try? JSONDecoder().decode(
                    RuntimeDiagnostics.self,
                    from: data
               ),
               diagnostics.handshakeCompleted {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw RuntimeError.anyConnectRecoveryTimedOut
    }

    private func checkCancellation(
        _ cancellation: ConnectionCancellation
    ) throws {
        try callback.throwIfFailed()
        if cancellation.isCancelled {
            throw RuntimeError.cancelled
        }
    }

}

private final class PreparationCallback:
    NSObject,
    LibboxConnectionPreparationCallbackProtocol
{
    private let reporter: ConnectionTransactionReporter

    init(reporter: ConnectionTransactionReporter) {
        self.reporter = reporter
    }

    func onPreparationEvent(_ eventJSON: String?) {
        guard let eventJSON else { return }
        reporter.consumePreparationEvent(eventJSON)
    }
}

private final class EngineCallback: NSObject, LibboxCallbackProtocol {
    private struct DiagnosticsEnvelope: Decodable {
        let anyConnect: AnyConnectFailureEvidence?

        enum CodingKeys: String, CodingKey {
            case anyConnect = "anyconnect"
        }
    }

    private let logger: Logger
    private let onFatalError:
        @Sendable (ConnectionRuntimeFailure) -> Void
    private let lock = NSLock()
    private var gate = EngineCallbackRuntimeGate()
    private weak var engine: LibboxLibbox?
    private weak var reporter: ConnectionTransactionReporter?
    private var taskID = "data-plane:sing-box"
    private var fatalFailure: ConnectionRuntimeFailure?

    init(
        logger: Logger,
        onFatalError:
            @escaping @Sendable (ConnectionRuntimeFailure) -> Void
    ) {
        self.logger = logger
        self.onFatalError = onFatalError
    }

    func attach(
        engine: LibboxLibbox,
        taskID: String,
        reporter: ConnectionTransactionReporter
    ) {
        lock.lock()
        self.engine = engine
        self.reporter = reporter
        self.taskID = taskID
        fatalFailure = nil
        gate.beginStart()
        lock.unlock()
    }

    func markStopped() {
        lock.lock()
        gate.stop()
        engine = nil
        reporter = nil
        lock.unlock()
    }

    func onStatusChanged(_ statusJSON: String?) {
        let lineStatus: AnyConnectLineRuntimeStatus?
        if let statusJSON,
           let data = statusJSON.data(using: .utf8) {
            lineStatus = try? JSONDecoder().decode(
                AnyConnectLineRuntimeStatus.self,
                from: data
            )
        } else {
            lineStatus = nil
        }
        lock.lock()
        gate.consumeStatus(statusJSON)
        let currentReporter = reporter
        let currentTaskID = taskID
        lock.unlock()
        if let lineStatus,
           lineStatus.isAnyConnect,
           let currentReporter {
            switch lineStatus.state {
            case .reconnecting:
                currentReporter.setTask(
                    id: currentTaskID,
                    state: .running
                )
                currentReporter.note(
                    code: "anyconnect-line-reconnecting",
                    message:
                        "AnyConnect 线路正在局部重连（\(lineStatus.attempt)/\(lineStatus.maxAttempts)）",
                    taskID: currentTaskID
                )
            case .connected:
                currentReporter.setTask(
                    id: currentTaskID,
                    state: .ready
                )
                currentReporter.note(
                    code: "anyconnect-line-reconnected",
                    message: "AnyConnect 线路已恢复，其他线路未重启",
                    taskID: currentTaskID
                )
            }
        }
        logger.notice(
            "engine-status value=\(statusJSON ?? "-", privacy: .private)"
        )
    }

    func onError(_ code: Int, message: String?) {
        lock.lock()
        let shouldCancel = gate.consumeFatalError()
        let currentEngine = engine
        let failureTaskID = taskID
        guard shouldCancel else {
            lock.unlock()
            logger.error(
                "engine-error ignored phase=not-running code=\(code)"
            )
            return
        }

        let anyConnect: AnyConnectFailureEvidence?
        if let diagnosticsJSON = currentEngine?.diagnostics(),
           let data = diagnosticsJSON.data(using: .utf8) {
            anyConnect = try? JSONDecoder().decode(
                DiagnosticsEnvelope.self,
                from: data
            ).anyConnect
        } else {
            anyConnect = nil
        }
        let anyConnectReportCode = anyConnect?.reportCode
        let reportCode =
            anyConnectReportCode ?? "data-plane-failed"
        let reportMessage: String
        if anyConnectReportCode != nil {
            reportMessage =
                anyConnect?.publicFailureMessage ??
                "AnyConnect 会话意外结束"
        } else {
            reportMessage =
                message ?? "sing-box data plane failed"
        }
        let evidence = anyConnect.map {
            ConnectionFailureEvidence(anyConnect: $0)
        }
        let failure = ConnectionRuntimeFailure(
            code: reportCode,
            message: reportMessage,
            taskID: anyConnectReportCode == nil
                ? "data-plane:sing-box"
                : failureTaskID,
            evidence: evidence
        )
        fatalFailure = failure
        engine = nil
        lock.unlock()
        logger.error(
            "engine-error code=\(code) report-code=\(reportCode, privacy: .public)"
        )
        onFatalError(failure)
    }

    func throwIfFailed() throws {
        lock.lock()
        let failure = fatalFailure
        lock.unlock()
        if let failure {
            throw failure
        }
    }
}

private enum RuntimeError: Error {
    case alreadyRunning
    case unavailable
    case invalidSessionEnvelope
    case storageUnavailable
    case invalidTailscaleStatus
    case underlayEgressUnavailable(String)
    case tailscaleLoginRequired
    case tailscaleReadinessTimedOut(String)
    case tailscaleMagicDNSUnavailable
    case tailscaleExitNodeUnavailable
    case tailscaleControlClientMissing
    case tailscaleNetInfoResetMissing
    case tailscaleNetInfoSetMissing
    case tailscaleHomeDERPReportMismatch
    case tailscaleDERPIdentityMismatch
    case tailscaleHomeDERPNotReady(String)
    case tailscalePeerHandshakeUnavailable
    case tailscaleEgressUnavailable(String)
    case tailscaleUnavailable(String)
    case anyConnectRecoveryTimedOut
    case lineCapabilityUnavailable
    case diagnosticsUnavailable
    case cancelled
}

extension RuntimeError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "sing-box 已经在运行"
        case .unavailable:
            "无法创建 sing-box 数据面"
        case .invalidSessionEnvelope:
            "Transparent Proxy 会话配置无效"
        case .storageUnavailable:
            "XDial 运行目录不可用"
        case .invalidTailscaleStatus:
            "内置 Tailscale 返回了无效状态"
        case let .underlayEgressUnavailable(reason):
            "启动前的系统网络无法承载 sing-box 真实流量（\(reason)）"
        case .tailscaleLoginRequired:
            "内置 Tailscale 需要重新登录"
        case let .tailscaleReadinessTimedOut(state):
            "内置 Tailscale 出口未在 30 秒内就绪（\(state)）"
        case .tailscaleMagicDNSUnavailable:
            "当前 Tailnet 未启用或尚未发布可用的 MagicDNS 配置"
        case .tailscaleExitNodeUnavailable:
            "所选 Tailscale Exit Node 已离线或未被当前运行时选中"
        case .tailscaleControlClientMissing:
            "内置 Tailscale 当前没有可用的控制连接"
        case .tailscaleNetInfoResetMissing:
            "当前 Tailscale 控制连接建立后，NetInfo 缓存没有完成重置"
        case .tailscaleNetInfoSetMissing:
            "当前 Tailscale 控制连接没有收到本轮 NetInfo"
        case .tailscaleHomeDERPReportMismatch:
            "本轮 NetInfo 上报的 Home DERP 与运行时裁决不一致"
        case .tailscaleDERPIdentityMismatch:
            "Home DERP 客户端使用的节点身份与当前运行时不一致"
        case let .tailscaleHomeDERPNotReady(state):
            "Home DERP 尚未完成本代协议注册（\(state)）"
        case .tailscalePeerHandshakeUnavailable:
            "所选 Tailscale Exit Node 已在线并进入节点地图，但没有完成握手（已发送数据，未收到回包）"
        case let .tailscaleEgressUnavailable(reason):
            "内置 Tailscale 出口无法承载真实流量（\(reason)）"
        case let .tailscaleUnavailable(state):
            "内置 Tailscale 不可用（\(state)）"
        case .anyConnectRecoveryTimedOut:
            "AnyConnect 线路未能在 60 秒内完成局部重连"
        case .lineCapabilityUnavailable:
            "所选线路不属于当前连接计划"
        case .diagnosticsUnavailable:
            "当前数据面诊断不可用"
        case .cancelled:
            "XDial 连接已取消"
        }
    }

    var reportCode: String {
        switch self {
        case .underlayEgressUnavailable:
            ConnectionFailureCode.underlayEgressUnavailable
        case .tailscaleExitNodeUnavailable:
            "tailscale-exit-node-unavailable"
        case .tailscaleMagicDNSUnavailable:
            "tailscale-magic-dns-unavailable"
        case .tailscaleControlClientMissing:
            "tailscale-control-client-missing"
        case .tailscaleNetInfoResetMissing:
            "tailscale-netinfo-reset-missing"
        case .tailscaleNetInfoSetMissing:
            "tailscale-netinfo-set-missing"
        case .tailscaleHomeDERPReportMismatch:
            "tailscale-home-derp-report-mismatch"
        case .tailscaleDERPIdentityMismatch:
            "tailscale-derp-key-mismatch"
        case .tailscaleHomeDERPNotReady:
            "tailscale-home-derp-not-ready"
        case .tailscalePeerHandshakeUnavailable:
            "tailscale-peer-handshake-failed"
        case .anyConnectRecoveryTimedOut:
            "anyconnect-line-reconnect-timeout"
        default:
            "tailscale-readiness-failed"
        }
    }
}
