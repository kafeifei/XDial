import Darwin
import Foundation
import Network
@preconcurrency import NetworkExtension
import OSLog

private struct ProviderRelayEndpoint: Sendable {
    let port: UInt16
    let credentials: SOCKSCredentials
    let applicationProcessCredentials: [ApplicationProcessCredential]
}

private final class ProviderApplicationAttributionLedger:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var activeSelectorKindCounts: [String: Int] = [:]
    private var matchedFlowCount = 0
    private var matchedSelectorKindCounts: [String: Int] = [:]
    private var matchedRuleSetIDCounts: [String: Int] = [:]
    private var matchedLineIDCounts: [String: Int] = [:]
    private var matchedSubscriptionIDCounts: [String: Int] = [:]
    private var baseFlowCount = 0
    private var baseMissingSourceIdentityCount = 0
    private var rejectedFlowCount = 0
    private var rejectedUnresolvedAuditTokenCount = 0

    func reset(credentials: [ApplicationProcessCredential]) {
        lock.lock()
        activeSelectorKindCounts = Dictionary(
            grouping: credentials,
            by: { $0.selector.kind.rawValue }
        ).mapValues(\.count)
        matchedFlowCount = 0
        matchedSelectorKindCounts = [:]
        matchedRuleSetIDCounts = [:]
        matchedLineIDCounts = [:]
        matchedSubscriptionIDCounts = [:]
        baseFlowCount = 0
        baseMissingSourceIdentityCount = 0
        rejectedFlowCount = 0
        rejectedUnresolvedAuditTokenCount = 0
        lock.unlock()
    }

    func recordMatched(_ credential: ApplicationProcessCredential) {
        lock.lock()
        matchedFlowCount += 1
        matchedSelectorKindCounts[
            credential.selector.kind.rawValue,
            default: 0
        ] += 1
        matchedRuleSetIDCounts[credential.ruleSetID, default: 0] += 1
        if let lineID = credential.lineID {
            matchedLineIDCounts[lineID, default: 0] += 1
        }
        if let subscriptionID = credential.subscriptionID {
            matchedSubscriptionIDCounts[subscriptionID, default: 0] += 1
        }
        lock.unlock()
    }

    func recordBase(
        signingIdentifierPresent: Bool,
        auditTokenPresent: Bool
    ) {
        lock.lock()
        baseFlowCount += 1
        if !signingIdentifierPresent && !auditTokenPresent {
            baseMissingSourceIdentityCount += 1
        }
        lock.unlock()
    }

    func recordRejectedUnresolvedAuditToken() {
        lock.lock()
        rejectedFlowCount += 1
        rejectedUnresolvedAuditTokenCount += 1
        lock.unlock()
    }

    func snapshot() -> ProviderApplicationAttributionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return ProviderApplicationAttributionSnapshot(
            activeSelectorKindCounts: activeSelectorKindCounts,
            matchedFlowCount: matchedFlowCount,
            matchedSelectorKindCounts: matchedSelectorKindCounts,
            matchedRuleSetIDCounts: matchedRuleSetIDCounts,
            matchedLineIDCounts: matchedLineIDCounts,
            matchedSubscriptionIDCounts: matchedSubscriptionIDCounts,
            baseFlowCount: baseFlowCount,
            baseMissingSourceIdentityCount:
                baseMissingSourceIdentityCount,
            rejectedFlowCount: rejectedFlowCount,
            rejectedUnresolvedAuditTokenCount:
                rejectedUnresolvedAuditTokenCount
        )
    }
}

final class TransparentProxyProvider: NETransparentProxyProvider {
    private static let profileOption = "profile"
    private static let underlayInterfacesOption = "underlay_interfaces"
    private static let underlayDefaultNameOption = "underlay_default_name"
    private static let underlayDefaultIndexOption = "underlay_default_index"
    private static let systemDNSOption = "system_dns"
    private static let transactionIDOption = "transaction_id"
    private static let connectionReportOption = "connection_report"
    private static let debugFailureStageOption = "debug_failure_stage"

    private let logger = Logger(
        subsystem: "com.kafeifei.xdial.transparent-proxy",
        category: "provider"
    )
    private let engineQueue = DispatchQueue(
        label: "com.kafeifei.xdial.transparent-proxy.engine",
        qos: .userInitiated
    )
    private let diagnosticsQueue = DispatchQueue(
        label: "com.kafeifei.xdial.transparent-proxy.diagnostics",
        qos: .utility,
        attributes: .concurrent
    )
    private let cancellationLock = NSLock()
    private let outboundProbeGate =
        ProviderDiagnosticsOperationGate()
    private let relayRegistry =
        ProviderRelayRegistry<ProviderRelayEndpoint>()
    private let applicationAttribution =
        ProviderApplicationAttributionLedger()

    private var runtime: EmbeddedSingBoxRuntime?
    private var session: EmbeddedSingBoxRuntime.Session?
    private var reporter: ConnectionTransactionReporter?
    private var settingsCommitted = false
    private var settingsCommitInFlight = false
    private var settingsCommitID: UUID?
    private var pendingCommitAbort: PendingCommitAbort?
    private var startCompletion: ((Error?) -> Void)?
    private var rollbackInProgress = false
    private var rollbackCompletions: [() -> Void] = []
    private var activeCancellation: ConnectionCancellation?
    private var generation = UUID().uuidString

    override func startProxy(
        options: [String: Any]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard
            let profileJSON = options?[Self.profileOption] as? String,
            !profileJSON.isEmpty
        else {
            completionHandler(ProviderError.missingProfile)
            return
        }
        guard
            let transactionID =
                options?[Self.transactionIDOption] as? String,
            !transactionID.isEmpty,
            let reportJSON =
                options?[Self.connectionReportOption] as? String,
            let reportData = reportJSON.data(using: .utf8),
            let initialReport =
                try? ConnectionReportCodec.decode(reportData),
            initialReport.transactionID == transactionID
        else {
            completionHandler(ProviderError.missingTransaction)
            return
        }
        guard
            let interfacesJSON =
                options?[Self.underlayInterfacesOption] as? String,
            let defaultName =
                options?[Self.underlayDefaultNameOption] as? String,
            let defaultIndex =
                options?[Self.underlayDefaultIndexOption] as? NSNumber,
            let systemDNSJSON =
                options?[Self.systemDNSOption] as? String,
            let interfacesData = interfacesJSON.data(using: .utf8),
            let interfaces = try? JSONDecoder().decode(
                [PathInterfaceSnapshot].self,
                from: interfacesData
            ),
            let defaultInterface = interfaces.first(where: {
                $0.name == defaultName
                    && $0.index == defaultIndex.intValue
            }),
            Self.isValidSystemDNSJSON(systemDNSJSON)
        else {
            completionHandler(ProviderError.invalidUnderlaySnapshot)
            return
        }
        let networkSnapshot = InterfaceSnapshot(
            defaultInterface: defaultInterface,
            interfacesJSON: interfacesJSON,
            systemDNSJSON: systemDNSJSON
        )
#if DEBUG
        let debugFailureStage =
            options?[Self.debugFailureStageOption] as? String
#endif
        let cancellation = ConnectionCancellation()
        cancellationLock.lock()
        activeCancellation = cancellation
        cancellationLock.unlock()
        outboundProbeGate.invalidate()
        generation = transactionID
        let generation = generation
        engineQueue.async { [weak self] in
            guard let self else {
                completionHandler(ProviderError.deallocated)
                return
            }
            self.startCompletion = completionHandler
            let reporter: ConnectionTransactionReporter
            do {
                // System Extension 由 root 运行；它的 App Group 容器与宿主用户的
                // 同名容器不是同一目录。宿主只把无凭据的计划种子带进来，此后
                // 扩展侧日志是连接事务的权威副本。
                try ConnectionReportJournal.write(initialReport)
                reporter = try ConnectionTransactionReporter(
                    transactionID: transactionID
                )
            } catch {
                self.clearCancellation(cancellation)
                self.finishStart(error)
                return
            }
            let runtime = EmbeddedSingBoxRuntime(
                logger: self.logger,
                onFatalError: { [weak self] error in
                    self?.handleFatalError(error)
                }
            )
            self.reporter = reporter
            self.runtime = runtime
            self.session = nil
            self.settingsCommitted = false
            self.settingsCommitInFlight = false
            self.settingsCommitID = nil
            self.pendingCommitAbort = nil
            do {
#if DEBUG
                if debugFailureStage == "rule-set" {
                    let injected = ProviderError.debugInjected(
                        "rule-set"
                    )
                    let taskID =
                        reporter.firstTaskID(kind: "rule_set") ?? ""
                    if !taskID.isEmpty {
                        reporter.setTask(id: taskID, state: .running)
                    }
                    reporter.fail(
                        injected,
                        code: "debug-rule-set-failure",
                        taskID: taskID
                    )
                    throw injected
                }
#endif
                let session = try runtime.start(
                    profileJSON: profileJSON,
                    networkSnapshot: networkSnapshot,
                    reporter: reporter,
                    cancellation: cancellation
                )
                self.applicationAttribution.reset(
                    credentials: session.applicationProcessCredentials
                )
                self.logger.notice(
                    "application-attribution active-selectors=\(session.applicationProcessCredentials.count, privacy: .public) bundle-identifiers=\(session.applicationProcessCredentials.filter { $0.selector.kind == .bundleIdentifier }.count, privacy: .public)"
                )
                guard !cancellation.isCancelled else {
                    throw ProviderError.cancelledBeforeCommit
                }
#if DEBUG
                if debugFailureStage == "line" {
                    let injected = ProviderError.debugInjected("line")
                    let taskID =
                        reporter.firstTaskID(kind: "line") ?? ""
                    reporter.fail(
                        injected,
                        code: "debug-line-failure",
                        taskID: taskID
                    )
                    throw injected
                }
#endif
                try reporter.ensureReadyForCommit()
                reporter.setState(.readyToCommit)
                reporter.setTask(
                    id: "ingress:transparent-proxy",
                    state: .committing
                )
                reporter.setState(.committing)
                try reporter.ensureHealthy()
#if DEBUG
                if debugFailureStage == "commit" {
                    let injected = ProviderError.debugInjected("commit")
                    reporter.fail(
                        injected,
                        code: "debug-commit-failure",
                        taskID: "ingress:transparent-proxy"
                    )
                    throw injected
                }
#endif
                let settings = NETransparentProxyNetworkSettings(
                    tunnelRemoteAddress: "127.0.0.1"
                )
                settings.includedNetworkRules = session.dnsCaptureDomains.map {
                    domain in
                    NENetworkRule(
                        destinationHostEndpoint: .hostPort(
                            host: NWEndpoint.Host(domain),
                            port: NWEndpoint.Port(rawValue: 53)!
                        ),
                        protocol: .any
                    )
                } + [
                    NENetworkRule(
                        remoteNetworkEndpoint: nil,
                        remotePrefix: 0,
                        localNetworkEndpoint: nil,
                        localPrefix: 0,
                        protocol: .any,
                        direction: .outbound
                    ),
                ]
                self.logger.notice(
                    "dns-capture-rules count=\(session.dnsCaptureDomains.count, privacy: .public) tailscale-records=\(session.tailscaleDNSRecordCount, privacy: .public)"
                )
                let commitID = UUID()
                let replacedRelays = self.relayRegistry.activate(
                    generation: generation,
                    endpoint: ProviderRelayEndpoint(
                        port: session.port,
                        credentials: session.credentials,
                        applicationProcessCredentials:
                            session.applicationProcessCredentials
                    )
                )
                if replacedRelays.count > 0 {
                    self.logger.error(
                        "replaced-stale-relays generation=\(generation, privacy: .public) count=\(replacedRelays.count)"
                    )
                    guard replacedRelays.wait(timeout: 1) else {
                        throw ProviderError.relayDrainTimedOut(
                            replacedRelays.count
                        )
                    }
                }
                self.settingsCommitID = commitID
                self.settingsCommitInFlight = true
                self.scheduleCommitTimeout(
                    id: commitID,
                    runtime: runtime,
                    reporter: reporter
                )
                self.setTunnelNetworkSettings(settings) { error in
                    self.engineQueue.async {
                        guard self.settingsCommitID == commitID else {
                            return
                        }
                        self.settingsCommitID = nil
                        self.settingsCommitInFlight = false
                        let pendingAbort =
                            self.takePendingCommitAbort()
                        if let error {
                            reporter.fail(
                                error,
                                code: "commit-failed",
                                taskID: "ingress:transparent-proxy"
                            )
                            self.rollback(
                                runtime: runtime,
                                reporter: reporter,
                                error: pendingAbort?.error ?? error,
                                code: pendingAbort?.code ??
                                    "commit-failed",
                                finalState: pendingAbort?.finalState ??
                                    .failed,
                                // Commit 已经发给系统；即使回调报错，也要显式撤销，
                                // 不能假设系统一定没有应用其中任何一部分。
                                networkSettings: .removeExplicitly,
                                relayDrain: pendingAbort?.relayDrain
                            ) {
                                self.finishStart(
                                    Self.providerNSError(
                                        pendingAbort?.error ?? error
                                    )
                                )
                                self.finishPendingCommitAbort(
                                    pendingAbort
                                )
                            }
                            return
                        }
                        self.settingsCommitted = true
                        if let pendingAbort {
                            self.session = nil
                            self.rollback(
                                runtime: runtime,
                                reporter: reporter,
                                error: pendingAbort.error,
                                code: pendingAbort.code,
                                finalState: pendingAbort.finalState,
                                networkSettings: .removeExplicitly,
                                relayDrain: pendingAbort.relayDrain
                            ) {
                                self.finishStart(
                                    Self.providerNSError(
                                        pendingAbort.error ??
                                            ProviderError
                                            .cancelledDuringCommit
                                    )
                                )
                                self.finishPendingCommitAbort(
                                    pendingAbort
                                )
                            }
                            return
                        }
                        if cancellation.isCancelled ||
                            self.rollbackInProgress {
                            self.session = nil
                            let cancelled =
                                ProviderError.cancelledDuringCommit
                            self.rollback(
                                runtime: runtime,
                                reporter: reporter,
                                error: cancelled,
                                code: "commit-cancelled",
                                finalState: .cancelled,
                                networkSettings: .removeExplicitly
                            ) {
                                self.finishStart(
                                    Self.providerNSError(cancelled)
                                )
                            }
                            return
                        }
                        self.session = session
                        do {
                            try reporter.markCommitted()
                        } catch {
                            self.session = nil
                            self.rollback(
                                runtime: runtime,
                                reporter: reporter,
                                error: error,
                                code: "report-commit-failed",
                                finalState: .failed,
                                networkSettings: .removeExplicitly
                            ) {
                                self.finishStart(
                                    Self.providerNSError(error)
                                )
                            }
                            return
                        }
                        self.logger.notice(
                            "started generation=\(generation, privacy: .public)"
                        )
                        self.finishStart(nil)
#if DEBUG
                        if debugFailureStage == "post-commit-fatal" {
                            self.engineQueue.asyncAfter(
                                deadline: .now() + 0.5
                            ) {
                                self.handleFatalError(
                                    ProviderError.debugInjected(
                                        "post-commit-fatal"
                                    )
                                )
                            }
                        }
#endif
                    }
                }
            } catch {
                let runtimeFailure =
                    error as? ConnectionRuntimeFailure
                if let runtimeFailure {
                    reporter.fail(runtimeFailure)
                } else {
                    reporter.fail(error, code: "prepare-failed")
                }
                self.logger.error(
                    "start-failed generation=\(generation, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                let providerError = Self.providerNSError(error)
                let finalState: ConnectionTransactionState =
                    cancellation.isCancelled ? .cancelled : .failed
                self.rollback(
                    runtime: runtime,
                    reporter: reporter,
                    error: error,
                    code:
                        runtimeFailure?.code ?? "prepare-failed",
                    finalState: finalState,
                    networkSettings: .alreadyAbsent
                ) {
                    self.finishStart(providerError)
                }
            }
        }
    }

    override func stopProxy(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        outboundProbeGate.invalidate()
        let relayDrain = relayRegistry.deactivateCurrent()
        cancellationLock.lock()
        activeCancellation?.cancel()
        cancellationLock.unlock()
        engineQueue.async {
            let runtime = self.runtime
            let reporter = self.reporter
            self.session = nil
            guard let runtime, let reporter else {
                _ = relayDrain.wait(timeout: 1)
                try? runtime?.stop()
                self.runtime = nil
                self.reporter = nil
                self.logger.notice("stopped reason=\(reason.rawValue)")
                completionHandler()
                return
            }
            let finalState: ConnectionTransactionState =
                reason == .userInitiated ? .cancelled : .failed
            if self.settingsCommitInFlight {
                self.deferCommitAbort(
                    error: nil,
                    code: "provider-stopped",
                    finalState: finalState,
                    relayDrain: relayDrain
                ) {
                    self.logger.notice(
                        "stopped reason=\(reason.rawValue)"
                    )
                    completionHandler()
                }
                return
            }
            self.rollback(
                runtime: runtime,
                reporter: reporter,
                error: nil,
                code: "provider-stopped",
                finalState: finalState,
                networkSettings: .providerStop(
                    settingsCommitted: self.settingsCommitted
                ),
                relayDrain: relayDrain
            ) {
                self.logger.notice("stopped reason=\(reason.rawValue)")
                completionHandler()
            }
        }
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)?
    ) {
        guard let completionHandler else { return }
        let request: ProviderDiagnosticsRequest
        do {
            request = try ProviderDiagnosticsCodec.decodeRequest(
                messageData
            )
        } catch {
            let code =
                (error as? ProviderDiagnosticsCodecError)?
                .responseCode ?? "invalid-request"
            completionHandler(
                Self.encodeDiagnosticsResponse(
                    .failure(transactionID: "", code: code)
                )
            )
            return
        }

        engineQueue.async { [weak self] in
            guard let self else {
                completionHandler(
                    Self.encodeDiagnosticsResponse(
                        .failure(
                            transactionID: request.transactionID,
                            code: "provider-unavailable"
                        )
                    )
                )
                return
            }
            let runtime = self.runtime
            let session = self.session
            let state = ProviderDiagnosticsSessionState(
                transactionID: self.generation,
                hasRuntime: runtime != nil,
                hasSession: session != nil,
                hasReporter: self.reporter != nil,
                settingsCommitted: self.settingsCommitted,
                settingsCommitInFlight:
                    self.settingsCommitInFlight,
                rollbackInProgress: self.rollbackInProgress
            )
            if let rejectionCode =
                ProviderDiagnosticsGate.rejectionCode(
                    requestTransactionID: request.transactionID,
                    state: state
                )
            {
                completionHandler(
                    Self.encodeDiagnosticsResponse(
                        .failure(
                            transactionID: request.transactionID,
                            code: rejectionCode
                        )
                    )
                )
                return
            }
#if DEBUG
            let debugCommandsEnabled = true
#else
            let debugCommandsEnabled = false
#endif
            if let rejectionCode =
                ProviderDiagnosticsGate.commandRejectionCode(
                    request.cmd,
                    debugCommandsEnabled: debugCommandsEnabled
                )
            {
                completionHandler(
                    Self.encodeDiagnosticsResponse(
                        .failure(
                            transactionID: request.transactionID,
                            code: rejectionCode
                        )
                    )
                )
                return
            }
            guard
                let runtime,
                let session
            else {
                completionHandler(
                    Self.encodeDiagnosticsResponse(
                        .failure(
                            transactionID: request.transactionID,
                            code: "session-not-committed"
                        )
                    )
                )
                return
            }

            let response: ProviderDiagnosticsResponse
            switch request.cmd {
            case .applicationAttributionSnapshot:
                response = .success(
                    transactionID: request.transactionID,
                    data: ProviderDiagnosticsData(
                        applicationAttribution:
                            self.applicationAttribution.snapshot()
                    )
                )
            case .routingProbeSnapshot:
                guard let expectedProbeID = request.probeID else {
                    completionHandler(
                        Self.encodeDiagnosticsResponse(
                            .failure(
                                transactionID: request.transactionID,
                                code: "invalid-request"
                            )
                        )
                    )
                    return
                }
                do {
                    let rawSnapshot =
                        try runtime.routingProbeSnapshot()
                    if let rejectionCode =
                        ProviderDiagnosticsGate
                        .routeProbeSnapshotRejectionCode(
                            expectedProbeID: expectedProbeID,
                            actualProbeID: rawSnapshot.probeID
                        )
                    {
                        response = .failure(
                            transactionID: request.transactionID,
                            code: rejectionCode
                        )
                        break
                    }
                    let snapshot =
                        rawSnapshot.restrictedToActiveCapabilities(
                            lineOutbounds: session.lineOutbounds,
                            ruleSetTags: session.ruleSetTags
                        )
                    response = .success(
                        transactionID: request.transactionID,
                        data: ProviderDiagnosticsData(
                            routingProbe: snapshot
                        )
                    )
                } catch {
                    response = .failure(
                        transactionID: request.transactionID,
                        code: "snapshot-unavailable"
                    )
                }
            case .probeLineOutboundAddress:
                self.beginLineOutboundAddressProbe(
                    request: request,
                    runtime: runtime,
                    session: session,
                    completionHandler: completionHandler
                )
                return
            case .beginRouteProbe:
#if DEBUG
                guard
                    let hostname = request.host,
                    let timeoutMS = request.timeoutMS
                else {
                    completionHandler(
                        Self.encodeDiagnosticsResponse(
                            .failure(
                                transactionID: request.transactionID,
                                code: "invalid-request"
                            )
                        )
                    )
                    return
                }
                do {
                    let begun = try runtime.beginRouteProbe(
                        hostname: hostname,
                        timeoutMS: timeoutMS
                    )
                    response = .success(
                        transactionID: request.transactionID,
                        data: ProviderDiagnosticsData(
                            begunRouteProbe: begun
                        )
                    )
                } catch {
                    response = .failure(
                        transactionID: request.transactionID,
                        code: "begin-probe-failed"
                    )
                }
#else
                response = .failure(
                    transactionID: request.transactionID,
                    code: "debug-command-unavailable"
                )
#endif
            }
            completionHandler(
                Self.encodeDiagnosticsResponse(response)
            )
        }
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        // Transparent Proxy 返回 false 会让系统按原网络路径放行。只允许在启动前或显式
        // 停止后的无会话窗口这样做；active 会话内的 TCP/UDP 转发失败必须由 relay 关流。
        let reservation: ProviderRelayRegistry<
            ProviderRelayEndpoint
        >.Reservation
        switch relayRegistry.claim() {
        case let .relay(currentReservation):
            reservation = currentReservation
        case .reject:
            Self.reject(flow)
            return true
        case .passThrough:
            return false
        }
        guard let credentials = credentials(
            for: flow,
            endpoint: reservation.endpoint
        ) else {
            relayRegistry.finish(reservation)
            Self.reject(flow)
            return true
        }
        let handle: ProviderRelayHandle
        if let tcpFlow = flow as? NEAppProxyTCPFlow {
            handle = TCPFlowSOCKSRelay.makeHandle(
                flow: tcpFlow,
                socksPort: reservation.endpoint.port,
                credentials: credentials,
                trialID: reservation.generation,
                logger: logger
            )
        } else if let udpFlow = flow as? NEAppProxyUDPFlow {
            handle = UDPFlowSOCKSRelay.makeHandle(
                flow: udpFlow,
                socksPort: reservation.endpoint.port,
                credentials: credentials,
                trialID: reservation.generation,
                logger: logger
            )
        } else {
            relayRegistry.finish(reservation)
            Self.reject(flow)
            return true
        }
        guard relayRegistry.attach(handle, to: reservation) else {
            // The transaction stopped after this flow was reserved. It has
            // already been claimed by XDial, so fail it closed rather than
            // returning false and leaking it to the Underlay.
            handle.cancel(with: AppProxyFlowCloseError.aborted)
            return true
        }
        if !handle.start(onFinish: { [weak self] in
            self?.relayRegistry.finish(reservation)
        }) {
            relayRegistry.finish(reservation)
            handle.cancel(with: AppProxyFlowCloseError.aborted)
        }
        return true
    }

    /// Resolve the real executable path from the kernel-provided audit token
    /// with the same process-path primitive used by Surge, then apply the
    /// first matching process selector in Mode order.
    /// A raw metadata signing identifier is intentionally insufficient: it
    /// loses the path ancestry that keeps bundled helpers scoped to their app.
    private func credentials(
        for flow: NEAppProxyFlow,
        endpoint: ProviderRelayEndpoint
    ) -> SOCKSCredentials? {
        let auditToken = flow.metaData.sourceAppAuditToken
        let auditTokenPresent = auditToken?.isEmpty == false
        let signingIdentifier = flow.metaData.sourceAppSigningIdentifier
        let executablePath = Self.applicationExecutablePath(
            auditToken: auditToken
        )
        switch TransparentProxyApplicationCredentialDecision.select(
            sourceAppSigningIdentifier: signingIdentifier,
            auditTokenPresent: auditTokenPresent,
            auditExecutablePath: executablePath,
            activeSelectors: endpoint.applicationProcessCredentials.map(
                \.selector
            )
        ) {
        case .base:
            applicationAttribution.recordBase(
                signingIdentifierPresent: !signingIdentifier.isEmpty,
                auditTokenPresent: auditTokenPresent
            )
            return endpoint.credentials
        case let .application(selector):
            guard let index = endpoint.applicationProcessCredentials
                .firstIndex(where: { $0.selector == selector })
            else { return nil }
            let credential = endpoint.applicationProcessCredentials[index]
            applicationAttribution.recordMatched(credential)
            let processName = executablePath.map {
                URL(fileURLWithPath: $0).lastPathComponent
            } ?? ""
            logger.debug(
                "application-attribution result=matched selector-index=\(index, privacy: .public) kind=\(selector.kind.rawValue, privacy: .public) rule-set=\(credential.ruleSetID, privacy: .public) line=\(credential.lineID ?? "", privacy: .public) process=\(processName, privacy: .public)"
            )
            return credential.credentials
        case .reject:
            applicationAttribution.recordRejectedUnresolvedAuditToken()
            logger.error(
                "application-attribution result=rejected reason=unresolved-audit-token"
            )
            return nil
        }
    }

    private static func applicationExecutablePath(
        auditToken: Data?
    ) -> String? {
        guard
            let auditToken,
            auditToken.count == MemoryLayout<audit_token_t>.size
        else {
            return nil
        }

        var token = audit_token_t()
        _ = withUnsafeMutableBytes(of: &token) { destination in
            auditToken.copyBytes(to: destination)
        }

        // Use the audit-token form directly so PID reuse cannot redirect the
        // lookup between attribution and proc_pidpath(). Four MAXPATHLEN units
        // matches PROC_PIDPATHINFO_MAXSIZE, whose macro Swift cannot import.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath_audittoken(
            &token,
            &path,
            UInt32(path.count)
        )
        guard length > 0, length < path.count else {
            return nil
        }

        let executablePath = String(cString: path)
        guard executablePath.hasPrefix("/") else {
            return nil
        }
        return (executablePath as NSString).standardizingPath
    }

    private static func reject(_ flow: NEAppProxyFlow) {
        let error = AppProxyFlowCloseError.aborted
        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
    }

    private func beginLineOutboundAddressProbe(
        request: ProviderDiagnosticsRequest,
        runtime: EmbeddedSingBoxRuntime,
        session: EmbeddedSingBoxRuntime.Session,
        completionHandler: @escaping (Data?) -> Void
    ) {
        guard
            let lineID = request.lineID,
            session.lineOutbounds[lineID] != nil
        else {
            completionHandler(
                Self.encodeDiagnosticsResponse(
                    .failure(
                        transactionID: request.transactionID,
                        code: "line-unavailable"
                    )
                )
            )
            return
        }
        guard
            let token = outboundProbeGate.begin(
                transactionID: request.transactionID
            )
        else {
            completionHandler(
                Self.encodeDiagnosticsResponse(
                    .failure(
                        transactionID: request.transactionID,
                        code: "probe-busy"
                    )
                )
            )
            return
        }

        let gate = outboundProbeGate
        diagnosticsQueue.async { [weak self] in
            let result = Result {
                try runtime.probeLineOutboundAddress(
                    lineID: lineID,
                    session: session
                )
            }
            guard let self else {
                gate.finish(token)
                completionHandler(
                    Self.encodeDiagnosticsResponse(
                        .failure(
                            transactionID: request.transactionID,
                            code: "provider-unavailable"
                        )
                    )
                )
                return
            }
            self.engineQueue.async { [weak self] in
                guard let self else {
                    gate.finish(token)
                    completionHandler(
                        Self.encodeDiagnosticsResponse(
                            .failure(
                                transactionID:
                                    request.transactionID,
                                code: "provider-unavailable"
                            )
                        )
                    )
                    return
                }
                defer { gate.finish(token) }
                guard gate.isCurrent(token) else {
                    completionHandler(
                        Self.encodeDiagnosticsResponse(
                            .failure(
                                transactionID:
                                    request.transactionID,
                                code: "probe-cancelled"
                            )
                        )
                    )
                    return
                }

                let currentSession = self.session
                let currentState =
                    ProviderDiagnosticsSessionState(
                        transactionID: self.generation,
                        hasRuntime: self.runtime != nil,
                        hasSession: currentSession != nil,
                        hasReporter: self.reporter != nil,
                        settingsCommitted:
                            self.settingsCommitted,
                        settingsCommitInFlight:
                            self.settingsCommitInFlight,
                        rollbackInProgress:
                            self.rollbackInProgress
                    )
                if let rejectionCode =
                    ProviderDiagnosticsGate.rejectionCode(
                        requestTransactionID:
                            request.transactionID,
                        state: currentState
                    )
                {
                    completionHandler(
                        Self.encodeDiagnosticsResponse(
                            .failure(
                                transactionID:
                                    request.transactionID,
                                code: rejectionCode ==
                                    "stale-session"
                                    ? rejectionCode
                                    : "probe-cancelled"
                            )
                        )
                    )
                    return
                }
                guard
                    self.runtime === runtime,
                    currentSession?.lineOutbounds[lineID] ==
                        session.lineOutbounds[lineID]
                else {
                    completionHandler(
                        Self.encodeDiagnosticsResponse(
                            .failure(
                                transactionID:
                                    request.transactionID,
                                code: "probe-cancelled"
                            )
                        )
                    )
                    return
                }

                let response: ProviderDiagnosticsResponse
                switch result {
                case let .success(address):
                    response = .success(
                        transactionID: request.transactionID,
                        data: ProviderDiagnosticsData(
                            lineOutboundAddress: address
                        )
                    )
                case .failure:
                    response = .failure(
                        transactionID: request.transactionID,
                        code: "probe-failed"
                    )
                }
                completionHandler(
                    Self.encodeDiagnosticsResponse(response)
                )
            }
        }
    }

    private static func encodeDiagnosticsResponse(
        _ response: ProviderDiagnosticsResponse
    ) -> Data? {
        try? ProviderDiagnosticsCodec.encodeResponse(response)
    }

    private func handleFatalError(_ error: Error) {
        outboundProbeGate.invalidate()
        let relayDrain = relayRegistry.deactivateCurrent()
        engineQueue.async { [weak self] in
            guard
                let self,
                let runtime = self.runtime,
                let reporter = self.reporter
            else {
                return
            }
            let failure =
                error as? ConnectionRuntimeFailure ??
                ConnectionRuntimeFailure(
                    code: "data-plane-failed",
                    message: error.localizedDescription,
                    taskID: "data-plane:sing-box",
                    evidence: nil
                )
            self.session = nil
            reporter.fail(failure)
            if self.settingsCommitInFlight {
                self.deferCommitAbort(
                    error: failure,
                    code: failure.code,
                    finalState: .failed,
                    relayDrain: relayDrain
                ) {
                    self.cancelProxyWithError(failure)
                }
                return
            }
            self.rollback(
                runtime: runtime,
                reporter: reporter,
                error: failure,
                code: failure.code,
                finalState: .failed,
                networkSettings: self.settingsCommitted
                    ? .removeExplicitly
                    : .alreadyAbsent,
                relayDrain: relayDrain
            ) {
                self.cancelProxyWithError(failure)
            }
        }
    }

    private func scheduleCommitTimeout(
        id: UUID,
        runtime: EmbeddedSingBoxRuntime,
        reporter: ConnectionTransactionReporter
    ) {
        engineQueue.asyncAfter(deadline: .now() + 5) {
            guard
                self.settingsCommitInFlight,
                self.settingsCommitID == id
            else {
                return
            }
            self.settingsCommitID = nil
            self.settingsCommitInFlight = false
            let timeout = ProviderError.commitTimedOut
            reporter.fail(
                timeout,
                code: "commit-timeout",
                taskID: "ingress:transparent-proxy"
            )
            let pendingAbort = self.takePendingCommitAbort()
            self.rollback(
                runtime: runtime,
                reporter: reporter,
                error: pendingAbort?.error ?? timeout,
                code: pendingAbort?.code ?? "commit-timeout",
                finalState: pendingAbort?.finalState ?? .failed,
                // 超时意味着提交结果未知；等满边界后必须显式撤销。
                networkSettings: .removeExplicitly,
                relayDrain: pendingAbort?.relayDrain
            ) {
                self.finishStart(
                    Self.providerNSError(
                        pendingAbort?.error ?? timeout
                    )
                )
                self.finishPendingCommitAbort(pendingAbort)
            }
        }
    }

    private func deferCommitAbort(
        error: Error?,
        code: String,
        finalState: ConnectionTransactionState,
        relayDrain: ProviderRelayDrain = .empty,
        completion: @escaping () -> Void
    ) {
        if var pending = pendingCommitAbort {
            if finalState == .failed &&
                pending.finalState != .failed {
                pending.error = error
                pending.code = code
                pending.finalState = .failed
            } else if pending.error == nil, let error {
                pending.error = error
                pending.code = code
            }
            if relayDrain.generation != nil {
                pending.relayDrains.append(relayDrain)
            }
            pending.completions.append(completion)
            pendingCommitAbort = pending
            return
        }
        pendingCommitAbort = PendingCommitAbort(
            error: error,
            code: code,
            finalState: finalState,
            relayDrains: relayDrain.generation != nil
                ? [relayDrain]
                : [],
            completions: [completion]
        )
    }

    private func takePendingCommitAbort() -> PendingCommitAbort? {
        let pending = pendingCommitAbort
        pendingCommitAbort = nil
        return pending
    }

    private func finishPendingCommitAbort(
        _ pending: PendingCommitAbort?
    ) {
        for completion in pending?.completions ?? [] {
            completion()
        }
    }

    private func finishStart(_ error: Error?) {
        let completion = startCompletion
        startCompletion = nil
        completion?(error)
    }

    private func clearCancellation(
        _ cancellation: ConnectionCancellation
    ) {
        cancellationLock.lock()
        if activeCancellation === cancellation {
            activeCancellation = nil
        }
        cancellationLock.unlock()
    }

    private func rollback(
        runtime: EmbeddedSingBoxRuntime,
        reporter: ConnectionTransactionReporter,
        error: Error?,
        code: String,
        finalState: ConnectionTransactionState,
        networkSettings:
            TransparentProxyNetworkSettingsRollbackAction,
        relayDrain initialRelayDrain: ProviderRelayDrain? = nil,
        completion: @escaping () -> Void
    ) {
        outboundProbeGate.invalidate()
        let relayDrain =
            initialRelayDrain ?? relayRegistry.deactivateCurrent()
        guard !rollbackInProgress else {
            rollbackCompletions.append(completion)
            return
        }
        rollbackInProgress = true
        rollbackCompletions = [completion]
        reporter.beginRollback(error, code: code)

        let finish: (Bool) -> Void = { [weak self] takeoverRemoved in
            guard let self else {
                completion()
                return
            }
            if takeoverRemoved,
               let relayGeneration = relayDrain.generation {
                self.relayRegistry.markInactive(
                    generation: relayGeneration
                )
            }
            var cleanupResolved = false
            let resolveCleanup: (Error?) -> Void = {
                [weak self] cleanupError in
                guard let self else {
                    return
                }
                self.engineQueue.async {
                    guard !cleanupResolved else { return }
                    cleanupResolved = true
                    if let cleanupError {
                        let failureCode: String
                        let failureTaskID: String
                        if let providerError =
                            cleanupError as? ProviderError,
                           case .rollbackTimedOut = providerError {
                            failureCode = "rollback-runtime-timeout"
                            failureTaskID = "data-plane:sing-box"
                        } else if let providerError =
                            cleanupError as? ProviderError,
                            case .relayDrainTimedOut = providerError {
                            failureCode = "rollback-relay-timeout"
                            failureTaskID = "ingress:transparent-proxy"
                        } else {
                            failureCode = "rollback-runtime-failed"
                            failureTaskID = "data-plane:sing-box"
                        }
                        reporter.failRollback(
                            cleanupError,
                            code: failureCode,
                            taskID: failureTaskID
                        )
                    }
                    self.runtime = nil
                    self.reporter = nil
                    self.session = nil
                    self.settingsCommitted = !takeoverRemoved
                    self.settingsCommitInFlight = false
                    self.cancellationLock.lock()
                    self.activeCancellation = nil
                    self.cancellationLock.unlock()
                    reporter.rollbackSessionTasks(
                        systemTakeoverRemoved: takeoverRemoved,
                        cleanupComplete: cleanupError == nil,
                        finalState: finalState
                    )
                    self.rollbackInProgress = false
                    let completions = self.rollbackCompletions
                    self.rollbackCompletions = []
                    for completion in completions {
                        completion()
                    }
                }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let relaysDrained = relayDrain.wait(timeout: 1)
                let relayDrainError: Error? =
                    relaysDrained
                    ? nil
                    : ProviderError.relayDrainTimedOut(
                        relayDrain.count
                    )
                do {
                    try runtime.stop()
                    resolveCleanup(relayDrainError)
                } catch {
                    resolveCleanup(error)
                }
            }
            self.engineQueue.asyncAfter(deadline: .now() + 5) {
                resolveCleanup(ProviderError.rollbackTimedOut)
            }
        }

        switch networkSettings {
        case .alreadyAbsent:
            finish(true)
            return
        case .awaitSystemDisconnect:
            // `stopProxy` is already inside the system-owned teardown. The
            // host completes this transaction only after the manager reports
            // disconnected, which is the authoritative removal fact.
            finish(false)
            return
        case .removeExplicitly:
            break
        }
        var removalResolved = false
        let resolveRemoval: (Error?) -> Void = {
            [weak self] removalError in
            guard let self else {
                completion()
                return
            }
            self.engineQueue.async {
                guard !removalResolved else { return }
                removalResolved = true
                if let removalError {
                    reporter.failRollback(
                        removalError,
                        code: "rollback-network-settings-failed",
                        taskID: "ingress:transparent-proxy"
                    )
                }
                finish(removalError == nil)
            }
        }
        setTunnelNetworkSettings(nil) { removalError in
            resolveRemoval(removalError)
        }
        engineQueue.asyncAfter(deadline: .now() + 5) {
            resolveRemoval(ProviderError.rollbackTimedOut)
        }
    }

    private static func providerNSError(_ error: Error) -> NSError {
        NSError(
            domain: "com.kafeifei.xdial.transparent-proxy.start",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    error.localizedDescription,
            ]
        )
    }

    private static func isValidSystemDNSJSON(_ json: String) -> Bool {
        guard
            let data = json.data(using: .utf8),
            let addresses = try? JSONDecoder().decode(
                [String].self,
                from: data
            ),
            !addresses.isEmpty
        else {
            return false
        }

        var seen = Set<String>()
        for address in addresses {
            guard
                address == address.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                isNumericIPAddress(address),
                seen.insert(address).inserted
            else {
                return false
            }
        }
        return true
    }

    private static func isNumericIPAddress(_ address: String) -> Bool {
        var ipv4 = in_addr()
        if address.withCString({
            inet_pton(AF_INET, $0, &ipv4)
        }) == 1 {
            return true
        }
        var ipv6 = in6_addr()
        return address.withCString({
            inet_pton(AF_INET6, $0, &ipv6)
        }) == 1
    }
}

private enum ProviderError: Error {
    case missingProfile
    case missingTransaction
    case invalidUnderlaySnapshot
    case deallocated
    case rollbackTimedOut
    case relayDrainTimedOut(Int)
    case commitTimedOut
    case cancelledBeforeCommit
    case cancelledDuringCommit
#if DEBUG
    case debugInjected(String)
#endif
}

extension ProviderError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingProfile:
            "XDial 配置为空"
        case .missingTransaction:
            "XDial 连接事务为空"
        case .invalidUnderlaySnapshot:
            "XDial 启动前的系统网络快照无效"
        case .deallocated:
            "XDial 网络扩展已经退出"
        case .rollbackTimedOut:
            "XDial 回滚未能在 5 秒内完成"
        case let .relayDrainTimedOut(count):
            "XDial 有 \(count) 条旧网络流未能在 1 秒内结束"
        case .commitTimedOut:
            "XDial 系统网络接管提交未能在 5 秒内完成"
        case .cancelledBeforeCommit:
            "XDial 在系统网络接管提交前被取消"
        case .cancelledDuringCommit:
            "XDial 在系统网络接管提交期间被取消"
#if DEBUG
        case let .debugInjected(stage):
            "Debug 注入失败（\(stage)）"
#endif
        }
    }
}

private struct PendingCommitAbort {
    var error: Error?
    var code: String
    var finalState: ConnectionTransactionState
    var relayDrains: [ProviderRelayDrain]
    var completions: [() -> Void]

    var relayDrain: ProviderRelayDrain {
        .merged(relayDrains)
    }
}
