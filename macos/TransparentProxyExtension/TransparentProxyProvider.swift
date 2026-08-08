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
    private var transactionID = ""
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

    func reset(
        transactionID: String,
        credentials: [ApplicationProcessCredential]
    ) {
        lock.lock()
        self.transactionID = transactionID
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

    func recordMatched(
        _ credential: ApplicationProcessCredential,
        transactionID: String
    ) {
        lock.lock()
        guard self.transactionID == transactionID else {
            lock.unlock()
            return
        }
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
        auditTokenPresent: Bool,
        transactionID: String
    ) {
        lock.lock()
        guard self.transactionID == transactionID else {
            lock.unlock()
            return
        }
        baseFlowCount += 1
        if !signingIdentifierPresent && !auditTokenPresent {
            baseMissingSourceIdentityCount += 1
        }
        lock.unlock()
    }

    func recordRejectedUnresolvedAuditToken(
        transactionID: String
    ) {
        lock.lock()
        guard self.transactionID == transactionID else {
            lock.unlock()
            return
        }
        rejectedFlowCount += 1
        rejectedUnresolvedAuditTokenCount += 1
        lock.unlock()
    }

    func snapshot(
        transactionID: String
    ) -> ProviderApplicationAttributionSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard self.transactionID == transactionID else { return nil }
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
    /// Candidate construction may enter an uninterruptible third-party
    /// AnyConnect dial. It must never occupy the queue which owns Provider
    /// stop, fatal teardown and system-settings rollback.
    private let scenarioSwitchPreparationQueue = DispatchQueue(
        label: "com.kafeifei.xdial.transparent-proxy.switch-preparation",
        qos: .userInitiated
    )
    private let scenarioSwitchCancellationQueue = DispatchQueue(
        label: "com.kafeifei.xdial.transparent-proxy.switch-cancellation",
        qos: .userInitiated
    )
    private let diagnosticsQueue = DispatchQueue(
        label: "com.kafeifei.xdial.transparent-proxy.diagnostics",
        qos: .utility,
        attributes: .concurrent
    )
    private let cancellationLock = NSLock()
    private let scenarioSwitchLock = NSLock()
    private let outboundProbeGate =
        ProviderDiagnosticsOperationGate()
    private let relayRegistry =
        ProviderRelayRegistry<ProviderRelayEndpoint>()
    private let applicationAttribution =
        ProviderApplicationAttributionLedger()
    private let traffic = ProviderTrafficLedger()

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
    private var activeScenarioSwitch:
        ProviderScenarioSwitchOperation?
    private var generation = UUID().uuidString
    /// A committed target remains authoritative even if releasing its retained
    /// source fails. Block the next Prepare until the two-lease pool proves the
    /// source lease is gone, so a third generation can never accumulate.
    private var retainedSourceRetirementPending = false
    private var retainedSourceRetirementRetryCount = 0

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
        traffic.reset(transactionID: transactionID)
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
            self.retainedSourceRetirementPending = false
            self.retainedSourceRetirementRetryCount = 0
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
                    transactionID: generation,
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
                        runtime.beginRuleSetRefreshes()
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
        cancelActiveScenarioSwitch(force: true)
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
        if Self.isScenarioSwitchMessage(messageData) {
            handleScenarioSwitchMessage(
                messageData,
                completionHandler: completionHandler
            )
            return
        }
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
            case .trafficSnapshot:
                guard let snapshot = self.traffic.snapshot(
                    transactionID: request.transactionID
                ) else {
                    response = .failure(
                        transactionID: request.transactionID,
                        code: "stale-session"
                    )
                    break
                }
                response = .success(
                    transactionID: request.transactionID,
                    data: ProviderDiagnosticsData(traffic: snapshot)
                )
            case .applicationAttributionSnapshot:
                guard let snapshot = self.applicationAttribution.snapshot(
                    transactionID: request.transactionID
                ) else {
                    response = .failure(
                        transactionID: request.transactionID,
                        code: "stale-session"
                    )
                    break
                }
                response = .success(
                    transactionID: request.transactionID,
                    data: ProviderDiagnosticsData(
                        applicationAttribution: snapshot
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

    private static func isScenarioSwitchMessage(_ data: Data) -> Bool {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any],
            let command = dictionary["cmd"] as? String
        else {
            return false
        }
        return ProviderScenarioSwitchCommand(rawValue: command) != nil
    }

    private func handleScenarioSwitchMessage(
        _ messageData: Data,
        completionHandler: @escaping (Data?) -> Void
    ) {
        let request: ProviderScenarioSwitchRequest
        do {
            request = try ProviderScenarioSwitchCodec.decodeRequest(
                messageData
            )
        } catch {
            completionHandler(
                Self.encodeScenarioSwitchResponse(
                    ProviderScenarioSwitchResponse(
                        v: ProviderScenarioSwitchCodec.version,
                        cmd: .switchScenario,
                        requestID: "invalid-request",
                        ok: false,
                        sourceTransactionID:
                            Self.safeTransactionID(generation),
                        activeTransactionID:
                            Self.safeTransactionID(generation),
                        code: "invalid-request",
                        message: error.localizedDescription,
                        reportJSON: nil
                    )
                )
            )
            return
        }

        if request.cmd == .cancelSwitch {
            handleScenarioSwitchCancellation(
                request,
                completionHandler: completionHandler
            )
            return
        }
        if request.cmd == .reconcileSwitch {
            handleScenarioSwitchReconciliation(
                request,
                completionHandler: completionHandler
            )
            return
        }

        let operation = ProviderScenarioSwitchOperation(
            request: request,
            completionHandler: completionHandler
        )
        scenarioSwitchLock.lock()
        if activeScenarioSwitch != nil {
            scenarioSwitchLock.unlock()
            let failure = ProviderError.scenarioSwitchInProgress
            completionHandler(
                Self.encodeScenarioSwitchResponse(
                    scenarioSwitchFailureResponse(
                        request: request,
                        error: failure,
                        code: "switch-in-progress"
                    )
                )
            )
            return
        }
        activeScenarioSwitch = operation
        scenarioSwitchLock.unlock()

        engineQueue.async { [weak self] in
            guard let self else {
                completionHandler(nil)
                return
            }
            self.performScenarioSwitch(
                operation,
                completionHandler: completionHandler
            )
        }
    }

    private func handleScenarioSwitchCancellation(
        _ request: ProviderScenarioSwitchRequest,
        completionHandler: @escaping (Data?) -> Void
    ) {
        scenarioSwitchLock.lock()
        let operation = activeScenarioSwitch
        scenarioSwitchLock.unlock()
        guard
            let operation,
            operation.request.requestID == request.requestID,
            operation.request.expectedTransactionID ==
                request.expectedTransactionID
        else {
            completionHandler(
                Self.encodeScenarioSwitchResponse(
                    scenarioSwitchFailureResponse(
                        request: request,
                        error: ProviderError.scenarioSwitchSourceChanged,
                        code: "switch-not-active"
                    )
                )
            )
            return
        }
        let outcome = operation.cancel()
        if outcome.completesSwitchImmediately {
            finishScenarioSwitch(
                operation,
                response: scenarioSwitchFailureResponse(
                    request: operation.request,
                    error: ProviderError.scenarioSwitchCancelled,
                    code: "switch-cancelled"
                ),
                completionHandler: completionHandler
            )
        }
        if let runtime = outcome.runtimeToAbort {
            scenarioSwitchCancellationQueue.async {
                runtime.abortPreparedSwitch()
            }
        }
        if outcome.accepted {
            completionHandler(
                Self.encodeScenarioSwitchResponse(
                    ProviderScenarioSwitchResponse(
                        v: ProviderScenarioSwitchCodec.version,
                        cmd: .cancelSwitch,
                        requestID: request.requestID,
                        ok: true,
                        sourceTransactionID:
                            request.expectedTransactionID,
                        activeTransactionID:
                            request.expectedTransactionID,
                        code: nil,
                        message: nil,
                        reportJSON: nil
                    )
                )
            )
        } else {
            completionHandler(
                Self.encodeScenarioSwitchResponse(
                    ProviderScenarioSwitchResponse(
                        v: ProviderScenarioSwitchCodec.version,
                        cmd: .cancelSwitch,
                        requestID: request.requestID,
                        ok: false,
                        sourceTransactionID:
                            request.expectedTransactionID,
                        activeTransactionID:
                            operation.request.targetTransactionID ??
                            request.expectedTransactionID,
                        code: "switch-already-committed",
                        message: ProviderError
                            .scenarioSwitchSourceChanged
                            .localizedDescription,
                        reportJSON: nil
                    )
                )
            )
        }
    }

    /// Resolves an ambiguous host-side Switch result from live Provider facts.
    /// This path is intentionally journal-independent: promotion may be the
    /// operation whose result was lost. It never starts, cancels, commits or
    /// retires a generation.
    private func handleScenarioSwitchReconciliation(
        _ request: ProviderScenarioSwitchRequest,
        completionHandler: @escaping (Data?) -> Void
    ) {
        engineQueue.async {
            let activeTransactionID = Self.safeTransactionID(
                self.generation
            )
            guard
                let activeReporter = self.reporter,
                let activeReport = activeReporter.currentReport(),
                activeReport.transactionID == self.generation,
                activeReport.state == .committed,
                !activeReport.systemTakeoverRemoved,
                self.settingsCommitted,
                !self.rollbackInProgress,
                let reportData = try? ConnectionReportCodec.encode(
                    activeReport
                ),
                let reportJSON = String(
                    data: reportData,
                    encoding: .utf8
                )
            else {
                completionHandler(Self.encodeScenarioSwitchResponse(
                    ProviderScenarioSwitchResponse(
                        v: ProviderScenarioSwitchCodec.version,
                        cmd: .reconcileSwitch,
                        requestID: request.requestID,
                        ok: false,
                        sourceTransactionID:
                            request.expectedTransactionID,
                        activeTransactionID: activeTransactionID,
                        code: "switch-reconcile-unavailable",
                        message: ProviderError
                            .scenarioSwitchSourceChanged
                            .localizedDescription,
                        reportJSON: nil
                    )
                ))
                return
            }

            self.scenarioSwitchLock.lock()
            let activeSwitch = self.activeScenarioSwitch
            self.scenarioSwitchLock.unlock()
            let switchInProgress = activeSwitch?.request.requestID
                == request.requestID
                && activeSwitch?.request.expectedTransactionID
                    == request.expectedTransactionID
                && activeSwitch?.request.targetTransactionID
                    == request.targetTransactionID
                && activeSwitch?.isPreCommit == true
            completionHandler(Self.encodeScenarioSwitchResponse(
                ProviderScenarioSwitchResponse(
                    v: ProviderScenarioSwitchCodec.version,
                    cmd: .reconcileSwitch,
                    requestID: request.requestID,
                    ok: true,
                    sourceTransactionID: request.expectedTransactionID,
                    activeTransactionID: activeReport.transactionID,
                    code: nil,
                    message: nil,
                    reportJSON: reportJSON,
                    switchInProgress: switchInProgress
                )
            ))
        }
    }

    private func performScenarioSwitch(
        _ operation: ProviderScenarioSwitchOperation,
        completionHandler: @escaping (Data?) -> Void
    ) {
        let request = operation.request
        var candidateReporter: ConnectionTransactionReporter?
        guard
            request.expectedTransactionID == generation,
            let targetTransactionID = request.targetTransactionID,
            targetTransactionID != request.expectedTransactionID,
            let profileJSON = request.profileJSON,
            let reportJSON = request.connectionReportJSON,
            let reportData = reportJSON.data(using: .utf8),
            let initialCandidate = try? ConnectionReportCodec.decode(
                reportData
            ),
            initialCandidate.transactionID == targetTransactionID,
            initialCandidate.state == .planning,
            let networkSnapshot = switchNetworkSnapshot(from: request),
            let runtime,
            let sourceSession = session,
            let sourceReporter = reporter,
            let sourceReport = sourceReporter.currentReport(),
            sourceReport.transactionID == request.expectedTransactionID,
            sourceReport.state == .committed,
            settingsCommitted,
            !settingsCommitInFlight,
            !rollbackInProgress
        else {
            finishScenarioSwitch(
                operation,
                response: scenarioSwitchFailureResponse(
                    request: request,
                    error: ProviderError.scenarioSwitchSourceChanged,
                    code: "switch-source-changed"
                ),
                completionHandler: completionHandler
            )
            return
        }
        guard retireRetainedSourceIfNeeded(
            runtime,
            scheduleRetry: false
        ) else {
            finishScenarioSwitch(
                operation,
                response: scenarioSwitchFailureResponse(
                    request: request,
                    error: ProviderError
                        .scenarioSwitchRetirementPending,
                    code: "switch-retire-pending"
                ),
                completionHandler: completionHandler
            )
            return
        }
        guard operation.beginPreparing(runtime: runtime) else {
            finishScenarioSwitch(
                operation,
                response: scenarioSwitchFailureResponse(
                    request: request,
                    error: ProviderError.scenarioSwitchCancelled,
                    code: "switch-cancelled"
                ),
                completionHandler: completionHandler
            )
            return
        }

        do {
            candidateReporter = try ConnectionTransactionReporter(
                candidate: initialCandidate
            )
        } catch {
            finishScenarioSwitch(
                operation,
                response: scenarioSwitchFailureResponse(
                    request: request,
                    error: error,
                    code: "scenario-switch-prepare-failed"
                ),
                completionHandler: completionHandler
            )
            return
        }
        guard let candidateReporter else { return }

        scenarioSwitchPreparationQueue.async { [weak self] in
            let result: Result<EmbeddedSingBoxRuntime.PreparedSwitch, Error>
            do {
                let prepared = try runtime.prepareSwitch(
                    profileJSON: profileJSON,
                    networkSnapshot: networkSnapshot,
                    sourceSession: sourceSession,
                    reporter: candidateReporter,
                    cancellation: operation.cancellation
                )
                try candidateReporter.ensureReadyForCommit()
                candidateReporter.setState(.readyToCommit)
                candidateReporter.setTask(
                    id: "ingress:transparent-proxy",
                    state: .committing
                )
                candidateReporter.setState(.committing)
                try candidateReporter.ensureHealthy()
                result = .success(prepared)
            } catch {
                result = .failure(error)
            }

            guard let self else {
                runtime.abortPreparedSwitch()
                candidateReporter.discardStagedCandidate()
                operation.finish()?(nil)
                return
            }
            // The preparation queue is serial. Resolve (and, on cancellation,
            // abort) this candidate before allowing a newer desired Scenario
            // to enter Libbox, otherwise a late prepared candidate could make
            // latest-wins fail spuriously with "already preparing".
            self.engineQueue.sync {
                self.finishScenarioSwitchPreparation(
                    operation: operation,
                    runtime: runtime,
                    sourceSession: sourceSession,
                    sourceReporter: sourceReporter,
                    candidateReporter: candidateReporter,
                    targetTransactionID: targetTransactionID,
                    result: result,
                    completionHandler: completionHandler
                )
            }
        }
    }

    private func finishScenarioSwitchPreparation(
        operation: ProviderScenarioSwitchOperation,
        runtime: EmbeddedSingBoxRuntime,
        sourceSession: EmbeddedSingBoxRuntime.Session,
        sourceReporter: ConnectionTransactionReporter,
        candidateReporter: ConnectionTransactionReporter,
        targetTransactionID: String,
        result: Result<EmbeddedSingBoxRuntime.PreparedSwitch, Error>,
        completionHandler: @escaping (Data?) -> Void
    ) {
        let prepared: EmbeddedSingBoxRuntime.PreparedSwitch
        switch result {
        case let .success(candidate):
            prepared = candidate
        case let .failure(error):
            abortScenarioSwitchCandidate(runtime)
            candidateReporter.fail(
                error,
                code: EmbeddedSingBoxRuntime.switchFailureCode(
                    for: error
                )
            )
            candidateReporter.discardStagedCandidate()
            finishScenarioSwitch(
                operation,
                response: scenarioSwitchFailureResponse(
                    request: operation.request,
                    error: error,
                    code: operation.isCancelled
                        ? "switch-cancelled"
                        : EmbeddedSingBoxRuntime.switchFailureCode(
                            for: error
                        )
                ),
                completionHandler: completionHandler
            )
            return
        }

        guard
            self.runtime === runtime,
            reporter === sourceReporter,
            generation == operation.request.expectedTransactionID,
            settingsCommitted,
            !settingsCommitInFlight,
            !rollbackInProgress
        else {
            abortScenarioSwitchCandidate(runtime)
            candidateReporter.discardStagedCandidate()
            finishScenarioSwitch(
                operation,
                response: scenarioSwitchFailureResponse(
                    request: operation.request,
                    error: ProviderError.scenarioSwitchSourceChanged,
                    code: "switch-source-changed"
                ),
                completionHandler: completionHandler
            )
            return
        }

        do {
            // Prove the candidate journal path is writable before touching
            // either system settings or the relay generation.
            try candidateReporter.stageCandidate()
            guard operation.beginSettingsCommit() else {
                throw ProviderError.scenarioSwitchCancelled
            }
        } catch {
            abortScenarioSwitchCandidate(runtime)
            candidateReporter.fail(
                error,
                code: operation.isCancelled
                    ? "switch-cancelled"
                    : "scenario-switch-prepare-failed"
            )
            candidateReporter.discardStagedCandidate()
            finishScenarioSwitch(
                operation,
                response: scenarioSwitchFailureResponse(
                    request: operation.request,
                    error: error,
                    code: operation.isCancelled
                        ? "switch-cancelled"
                        : "scenario-switch-prepare-failed"
                ),
                completionHandler: completionHandler
            )
            return
        }

        let candidateSession = prepared.session
        let candidateEndpoint = ProviderRelayEndpoint(
            port: candidateSession.port,
            credentials: candidateSession.credentials,
            applicationProcessCredentials:
                candidateSession.applicationProcessCredentials
        )
        let sourceSettings = networkSettings(for: sourceSession)
        let candidateSettings = networkSettings(for: candidateSession)
        let commitID = UUID()
        settingsCommitID = commitID
        settingsCommitInFlight = true
        setTunnelNetworkSettings(candidateSettings) { error in
            self.engineQueue.async {
                self.resolveScenarioSwitchSettingsCommit(
                    id: commitID,
                    operation: operation,
                    runtime: runtime,
                    sourceReporter: sourceReporter,
                    sourceSettings: sourceSettings,
                    prepared: prepared,
                    candidateEndpoint: candidateEndpoint,
                    candidateReporter: candidateReporter,
                    targetTransactionID: targetTransactionID,
                    error: error,
                    completionHandler: completionHandler
                )
            }
        }
        engineQueue.asyncAfter(deadline: .now() + 5) {
            self.resolveScenarioSwitchSettingsCommit(
                id: commitID,
                operation: operation,
                runtime: runtime,
                sourceReporter: sourceReporter,
                sourceSettings: sourceSettings,
                prepared: prepared,
                candidateEndpoint: candidateEndpoint,
                candidateReporter: candidateReporter,
                targetTransactionID: targetTransactionID,
                error: ProviderError.scenarioSwitchCommitTimedOut,
                completionHandler: completionHandler
            )
        }
    }

    private func resolveScenarioSwitchSettingsCommit(
        id: UUID,
        operation: ProviderScenarioSwitchOperation,
        runtime: EmbeddedSingBoxRuntime,
        sourceReporter: ConnectionTransactionReporter,
        sourceSettings: NETransparentProxyNetworkSettings,
        prepared: EmbeddedSingBoxRuntime.PreparedSwitch,
        candidateEndpoint: ProviderRelayEndpoint,
        candidateReporter: ConnectionTransactionReporter,
        targetTransactionID: String,
        error: Error?,
        completionHandler: @escaping (Data?) -> Void
    ) {
        guard settingsCommitID == id else { return }
        settingsCommitID = nil
        settingsCommitInFlight = false
        let pendingAbort = takePendingCommitAbort()
        if let pendingAbort {
            abortScenarioSwitchCandidate(runtime)
            candidateReporter.discardStagedCandidate()
            finishScenarioSwitch(
                operation,
                response: scenarioSwitchFailureResponse(
                    request: operation.request,
                    error: pendingAbort.error ??
                        ProviderError.scenarioSwitchCancelled,
                    code: pendingAbort.code
                ),
                completionHandler: completionHandler
            )
            rollback(
                runtime: runtime,
                reporter: sourceReporter,
                error: pendingAbort.error,
                code: pendingAbort.code,
                finalState: pendingAbort.finalState,
                networkSettings: .removeExplicitly,
                relayDrain: pendingAbort.relayDrain
            ) {
                self.finishPendingCommitAbort(pendingAbort)
            }
            return
        }
        if let error {
            let failureCode: String
            if let providerError = error as? ProviderError,
               case .scenarioSwitchCommitTimedOut = providerError {
                failureCode = "switch-settings-timeout"
            } else {
                failureCode = "switch-settings-failed"
            }
            restoreSourceSettingsAfterScenarioSwitchFailure(
                operation: operation,
                runtime: runtime,
                sourceReporter: sourceReporter,
                sourceSettings: sourceSettings,
                candidateReporter: candidateReporter,
                failure: error,
                code: failureCode,
                completionHandler: completionHandler
            )
            return
        }
        guard !operation.isCancelled else {
            restoreSourceSettingsAfterScenarioSwitchFailure(
                operation: operation,
                runtime: runtime,
                sourceReporter: sourceReporter,
                sourceSettings: sourceSettings,
                candidateReporter: candidateReporter,
                failure: ProviderError.scenarioSwitchCancelled,
                code: "switch-cancelled",
                completionHandler: completionHandler
            )
            return
        }

        let committedReport: ConnectionReport
        let reportJSON: String
        do {
            // Every fallible report transformation happens before either the
            // Libbox generation or the relay generation changes. This sidecar
            // remains non-authoritative while A still carries every flow.
            try candidateReporter.markCommitted()
            guard let report = candidateReporter.currentReport() else {
                throw ProviderError.invalidScenarioSwitch
            }
            let reportData = try ConnectionReportCodec.encode(report)
            guard let encoded = String(
                data: reportData,
                encoding: .utf8
            ) else {
                throw ProviderError.invalidScenarioSwitch
            }
            try candidateReporter.stageCandidate()
            committedReport = report
            reportJSON = encoded
        } catch {
            restoreSourceSettingsAfterScenarioSwitchFailure(
                operation: operation,
                runtime: runtime,
                sourceReporter: sourceReporter,
                sourceSettings: sourceSettings,
                candidateReporter: candidateReporter,
                failure: error,
                code: "switch-report-stage-failed",
                completionHandler: completionHandler
            )
            return
        }

        let sourceDrain: ProviderRelayDrain?
        do {
            sourceDrain = try operation.commitRuntime(
                {
                    try runtime.commitPreparedSwitch(
                        prepared,
                        reporter: candidateReporter
                    )
                },
                publish: {
                    relayRegistry.handoff(
                        generation: targetTransactionID,
                        endpoint: candidateEndpoint
                    )
                }
            )
        } catch {
            restoreSourceSettingsAfterScenarioSwitchFailure(
                operation: operation,
                runtime: runtime,
                sourceReporter: sourceReporter,
                sourceSettings: sourceSettings,
                candidateReporter: candidateReporter,
                failure: error,
                code: "switch-runtime-commit-failed",
                completionHandler: completionHandler
            )
            return
        }
        guard let sourceDrain else {
            restoreSourceSettingsAfterScenarioSwitchFailure(
                operation: operation,
                runtime: runtime,
                sourceReporter: sourceReporter,
                sourceSettings: sourceSettings,
                candidateReporter: candidateReporter,
                failure: ProviderError.scenarioSwitchCancelled,
                code: "switch-cancelled",
                completionHandler: completionHandler
            )
            return
        }

        // CommitPreparedSwitch atomically adopted B while retaining A, then
        // the operation gate published B before a terminal stop/fatal could
        // deactivate the relay registry. A now exists only for this drain.
        session = prepared.session
        reporter = candidateReporter
        generation = candidateReporter.transactionID
        settingsCommitted = true
        outboundProbeGate.invalidate()
        traffic.reset(transactionID: generation)
        applicationAttribution.reset(
            transactionID: generation,
            credentials:
                prepared.session.applicationProcessCredentials
        )
        cancellationLock.lock()
        activeCancellation = operation.cancellation
        cancellationLock.unlock()

        if !sourceDrain.wait(timeout: 1) {
            sourceDrain.cancel()
            if !sourceDrain.wait(timeout: 1) {
                logger.error(
                    "scenario-switch-source-drain-timeout generation=\(self.generation, privacy: .public) flows=\(sourceDrain.count)"
                )
            }
        }
        retainedSourceRetirementPending = true
        retainedSourceRetirementRetryCount = 0
        _ = retireRetainedSourceIfNeeded(runtime, scheduleRetry: true)

        do {
            _ = try candidateReporter.persistCommittedCandidate()
        } catch {
            logger.error(
                "scenario-switch-journal-promote-failed generation=\(self.generation, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            do {
                try ConnectionReportJournal.write(committedReport)
                candidateReporter.discardStagedCandidate()
                logger.notice(
                    "scenario-switch-journal-repaired generation=\(self.generation, privacy: .public)"
                )
            } catch {
                // The host receives the complete committed report below and
                // performs the same authoritative write. Runtime truth stays
                // on B even if local storage is temporarily unavailable.
                logger.error(
                    "scenario-switch-journal-repair-failed generation=\(self.generation, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }

        runtime.beginRuleSetRefreshes()
        finishScenarioSwitch(
            operation,
            response: ProviderScenarioSwitchResponse(
                v: ProviderScenarioSwitchCodec.version,
                cmd: .switchScenario,
                requestID: operation.request.requestID,
                ok: true,
                sourceTransactionID:
                    operation.request.expectedTransactionID,
                activeTransactionID:
                    candidateReporter.transactionID,
                code: nil,
                message: nil,
                reportJSON: reportJSON
            ),
            completionHandler: completionHandler
        )
        logger.notice(
            "scenario-switch-committed generation=\(self.generation, privacy: .public)"
        )
    }

    /// Restores only the source system settings. The relay registry still
    /// publishes A here, so no candidate flow exists and no relay is closed.
    private func restoreSourceSettingsAfterScenarioSwitchFailure(
        operation: ProviderScenarioSwitchOperation,
        runtime: EmbeddedSingBoxRuntime,
        sourceReporter: ConnectionTransactionReporter,
        sourceSettings: NETransparentProxyNetworkSettings,
        candidateReporter: ConnectionTransactionReporter,
        failure: Error,
        code: String,
        completionHandler: @escaping (Data?) -> Void
    ) {
        abortScenarioSwitchCandidate(runtime)
        candidateReporter.fail(failure, code: code)
        candidateReporter.discardStagedCandidate()

        let restoreID = UUID()
        settingsCommitID = restoreID
        settingsCommitInFlight = true
        setTunnelNetworkSettings(sourceSettings) { restoreError in
            self.engineQueue.async {
                self.resolveScenarioSwitchRestore(
                    id: restoreID,
                    operation: operation,
                    runtime: runtime,
                    sourceReporter: sourceReporter,
                    sourceDrain: .empty,
                    originalFailure: failure,
                    originalCode: code,
                    restoreError: restoreError,
                    completionHandler: completionHandler
                )
            }
        }
        engineQueue.asyncAfter(deadline: .now() + 5) {
            self.resolveScenarioSwitchRestore(
                id: restoreID,
                operation: operation,
                runtime: runtime,
                sourceReporter: sourceReporter,
                sourceDrain: .empty,
                originalFailure: failure,
                originalCode: code,
                restoreError:
                    ProviderError.scenarioSwitchRestoreTimedOut,
                completionHandler: completionHandler
            )
        }
    }

    private func resolveScenarioSwitchRestore(
        id: UUID,
        operation: ProviderScenarioSwitchOperation,
        runtime: EmbeddedSingBoxRuntime,
        sourceReporter: ConnectionTransactionReporter,
        sourceDrain: ProviderRelayDrain,
        originalFailure: Error,
        originalCode: String,
        restoreError: Error?,
        completionHandler: @escaping (Data?) -> Void
    ) {
        guard settingsCommitID == id else { return }
        settingsCommitID = nil
        settingsCommitInFlight = false
        let pendingAbort = takePendingCommitAbort()
        if restoreError == nil, pendingAbort == nil {
            settingsCommitted = true
            finishScenarioSwitch(
                operation,
                response: scenarioSwitchFailureResponse(
                    request: operation.request,
                    error: originalFailure,
                    code: originalCode
                ),
                completionHandler: completionHandler
            )
            return
        }

        let finalError = pendingAbort?.error ?? restoreError ??
            ProviderError.scenarioSwitchRestoreFailed
        let finalCode = pendingAbort?.code ??
            "switch-restore-failed"
        let relayDrain = ProviderRelayDrain.merged([
            sourceDrain,
            pendingAbort?.relayDrain ??
                relayRegistry.deactivateCurrent(),
        ])
        finishScenarioSwitch(
            operation,
            response: scenarioSwitchFailureResponse(
                request: operation.request,
                error: finalError,
                code: finalCode
            ),
            completionHandler: completionHandler
        )
        rollback(
            runtime: runtime,
            reporter: sourceReporter,
            error: finalError,
            code: finalCode,
            finalState: pendingAbort?.finalState ?? .failed,
            networkSettings: .removeExplicitly,
            relayDrain: relayDrain
        ) {
            self.finishPendingCommitAbort(pendingAbort)
            if pendingAbort == nil {
                self.cancelProxyWithError(
                    Self.providerNSError(finalError)
                )
            }
        }
    }

    private func switchNetworkSnapshot(
        from request: ProviderScenarioSwitchRequest
    ) -> InterfaceSnapshot? {
        guard
            let interfacesJSON = request.underlayInterfacesJSON,
            let defaultName = request.underlayDefaultName,
            let defaultIndex = request.underlayDefaultIndex,
            let systemDNSJSON = request.systemDNSJSON,
            let interfacesData = interfacesJSON.data(using: .utf8),
            let interfaces = try? JSONDecoder().decode(
                [PathInterfaceSnapshot].self,
                from: interfacesData
            ),
            let defaultInterface = interfaces.first(where: {
                $0.name == defaultName && $0.index == defaultIndex
            }),
            Self.isValidSystemDNSJSON(systemDNSJSON)
        else {
            return nil
        }
        return InterfaceSnapshot(
            defaultInterface: defaultInterface,
            interfacesJSON: interfacesJSON,
            systemDNSJSON: systemDNSJSON
        )
    }

    private func networkSettings(
        for session: EmbeddedSingBoxRuntime.Session
    ) -> NETransparentProxyNetworkSettings {
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
        return settings
    }

    private func abortScenarioSwitchCandidate(
        _ runtime: EmbeddedSingBoxRuntime
    ) {
        // Wait for any out-of-band token invalidation to finish closing its
        // candidate before the serial preparation queue admits a successor.
        scenarioSwitchCancellationQueue.sync {
            runtime.abortPreparedSwitch()
        }
    }

    /// Retire is cleanup after B's irreversible commit, not part of deciding
    /// whether A or B is active. A failure therefore keeps B authoritative but
    /// holds the pool at two leases and prevents another Prepare until cleanup
    /// succeeds. Stop/fatal teardown remains the final idempotent reclamation.
    @discardableResult
    private func retireRetainedSourceIfNeeded(
        _ runtime: EmbeddedSingBoxRuntime,
        scheduleRetry: Bool
    ) -> Bool {
        guard retainedSourceRetirementPending else { return true }
        guard self.runtime === runtime else {
            retainedSourceRetirementPending = false
            retainedSourceRetirementRetryCount = 0
            return true
        }
        do {
            try runtime.retireCommittedSwitch()
            retainedSourceRetirementPending = false
            retainedSourceRetirementRetryCount = 0
            logger.notice(
                "scenario-switch-source-retired generation=\(self.generation, privacy: .public)"
            )
            return true
        } catch {
            retainedSourceRetirementRetryCount += 1
            let attempt = retainedSourceRetirementRetryCount
            logger.error(
                "scenario-switch-retire-failed generation=\(self.generation, privacy: .public) attempt=\(attempt, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            if scheduleRetry, attempt < 3 {
                engineQueue.asyncAfter(deadline: .now() + 0.25) {
                    guard self.runtime === runtime else { return }
                    _ = self.retireRetainedSourceIfNeeded(
                        runtime,
                        scheduleRetry: true
                    )
                }
            }
            return false
        }
    }

    private func cancelActiveScenarioSwitch(force: Bool = false) {
        scenarioSwitchLock.lock()
        let operation = activeScenarioSwitch
        scenarioSwitchLock.unlock()
        let outcome = force
            ? operation?.forceCancel()
            : operation?.cancel()
        if let operation,
           outcome?.completesSwitchImmediately == true {
            finishScenarioSwitch(
                operation,
                response: scenarioSwitchFailureResponse(
                    request: operation.request,
                    error: ProviderError.scenarioSwitchCancelled,
                    code: "switch-cancelled"
                ),
                completionHandler: { _ in }
            )
        }
        if let runtime = outcome?.runtimeToAbort {
            scenarioSwitchCancellationQueue.async {
                runtime.abortPreparedSwitch()
            }
        }
    }

    private func finishScenarioSwitch(
        _ operation: ProviderScenarioSwitchOperation,
        response: ProviderScenarioSwitchResponse,
        completionHandler: @escaping (Data?) -> Void
    ) {
        guard let originalCompletion = operation.finish() else {
            return
        }
        scenarioSwitchLock.lock()
        if activeScenarioSwitch === operation {
            activeScenarioSwitch = nil
        }
        scenarioSwitchLock.unlock()
        originalCompletion(Self.encodeScenarioSwitchResponse(response))
    }

    private func scenarioSwitchFailureResponse(
        request: ProviderScenarioSwitchRequest,
        error: Error,
        code: String
    ) -> ProviderScenarioSwitchResponse {
        ProviderScenarioSwitchResponse(
            v: ProviderScenarioSwitchCodec.version,
            cmd: request.cmd,
            requestID: request.requestID,
            ok: false,
            sourceTransactionID: request.expectedTransactionID,
            activeTransactionID: request.expectedTransactionID,
            code: code,
            message: error.localizedDescription,
            reportJSON: nil
        )
    }

    private static func encodeScenarioSwitchResponse(
        _ response: ProviderScenarioSwitchResponse
    ) -> Data? {
        try? ProviderScenarioSwitchCodec.encodeResponse(response)
    }

    private static func safeTransactionID(_ value: String) -> String {
        value.isEmpty ? "unknown" : value
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
            endpoint: reservation.endpoint,
            transactionID: reservation.generation
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
                traffic: traffic,
                logger: logger
            )
        } else if let udpFlow = flow as? NEAppProxyUDPFlow {
            handle = UDPFlowSOCKSRelay.makeHandle(
                flow: udpFlow,
                socksPort: reservation.endpoint.port,
                credentials: credentials,
                trialID: reservation.generation,
                traffic: traffic,
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
    /// first matching process selector in Scenario order.
    /// A raw metadata signing identifier is intentionally insufficient: it
    /// loses the path ancestry that keeps bundled helpers scoped to their app.
    private func credentials(
        for flow: NEAppProxyFlow,
        endpoint: ProviderRelayEndpoint,
        transactionID: String
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
                auditTokenPresent: auditTokenPresent,
                transactionID: transactionID
            )
            return endpoint.credentials
        case let .application(selector):
            guard let index = endpoint.applicationProcessCredentials
                .firstIndex(where: { $0.selector == selector })
            else { return nil }
            let credential = endpoint.applicationProcessCredentials[index]
            applicationAttribution.recordMatched(
                credential,
                transactionID: transactionID
            )
            let processName = executablePath.map {
                URL(fileURLWithPath: $0).lastPathComponent
            } ?? ""
            logger.debug(
                "application-attribution result=matched selector-index=\(index, privacy: .public) kind=\(selector.kind.rawValue, privacy: .public) rule-set=\(credential.ruleSetID, privacy: .public) line=\(credential.lineID ?? "", privacy: .public) process=\(processName, privacy: .public)"
            )
            return credential.credentials
        case .reject:
            applicationAttribution.recordRejectedUnresolvedAuditToken(
                transactionID: transactionID
            )
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
        cancelActiveScenarioSwitch(force: true)
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
        retainedSourceRetirementPending = false
        retainedSourceRetirementRetryCount = 0
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

private final class ProviderScenarioSwitchOperation:
    @unchecked Sendable
{
    enum Phase: Equatable {
        case queued
        case preparing
        case settingsInFlight
        case committed
        case finished
    }

    let request: ProviderScenarioSwitchRequest
    let cancellation = ConnectionCancellation()
    private let switchCompletionHandler: (Data?) -> Void

    struct CancellationOutcome {
        let accepted: Bool
        let runtimeToAbort: EmbeddedSingBoxRuntime?
        let completesSwitchImmediately: Bool
    }

    private let lock = NSLock()
    private var phase: Phase = .queued
    private weak var runtime: EmbeddedSingBoxRuntime?

    init(
        request: ProviderScenarioSwitchRequest,
        completionHandler: @escaping (Data?) -> Void
    ) {
        self.request = request
        switchCompletionHandler = completionHandler
    }

    func beginPreparing(
        runtime: EmbeddedSingBoxRuntime
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .queued, !cancellation.isCancelled else {
            return false
        }
        self.runtime = runtime
        phase = .preparing
        return true
    }

    /// Returns the runtime only while Go Prepare can still be blocked. The
    /// caller invokes Abort outside the Provider engine queue in that phase.
    func cancel() -> CancellationOutcome {
        lock.lock()
        let outcome: CancellationOutcome
        switch phase {
        case .queued, .preparing:
            cancellation.cancel()
            outcome = CancellationOutcome(
                accepted: true,
                runtimeToAbort: runtime,
                completesSwitchImmediately: true
            )
        case .settingsInFlight:
            cancellation.cancel()
            outcome = CancellationOutcome(
                accepted: true,
                runtimeToAbort: nil,
                completesSwitchImmediately: false
            )
        case .committed, .finished:
            outcome = CancellationOutcome(
                accepted: false,
                runtimeToAbort: nil,
                completesSwitchImmediately: false
            )
        }
        lock.unlock()
        return outcome
    }

    func forceCancel() -> CancellationOutcome {
        lock.lock()
        guard phase != .finished else {
            lock.unlock()
            return CancellationOutcome(
                accepted: false,
                runtimeToAbort: nil,
                completesSwitchImmediately: false
            )
        }
        cancellation.cancel()
        let runtimeToAbort: EmbeddedSingBoxRuntime?
        let completesSwitchImmediately: Bool
        switch phase {
        case .queued, .preparing:
            runtimeToAbort = runtime
            completesSwitchImmediately = true
        case .settingsInFlight, .committed, .finished:
            runtimeToAbort = nil
            completesSwitchImmediately = false
        }
        lock.unlock()
        return CancellationOutcome(
            accepted: true,
            runtimeToAbort: runtimeToAbort,
            completesSwitchImmediately: completesSwitchImmediately
        )
    }

    func beginSettingsCommit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .preparing, !cancellation.isCancelled else {
            return false
        }
        phase = .settingsInFlight
        return true
    }

    /// Serializes cancellation against the only irreversible Switch step.
    /// Libbox validates before adopting B, so a thrown commit leaves this
    /// operation cancellable and A authoritative. A successful return makes
    /// every later user cancellation observably too late.
    func commitRuntime(
        _ commit: () throws -> Void,
        publish: () -> ProviderRelayDrain
    ) throws -> ProviderRelayDrain? {
        lock.lock()
        guard phase == .settingsInFlight,
              !cancellation.isCancelled else {
            lock.unlock()
            return nil
        }
        do {
            try commit()
            phase = .committed
            let drain = publish()
            lock.unlock()
            return drain
        } catch {
            lock.unlock()
            throw error
        }
    }

    func finish() -> ((Data?) -> Void)? {
        lock.lock()
        guard phase != .finished else {
            lock.unlock()
            return nil
        }
        phase = .finished
        runtime = nil
        lock.unlock()
        return switchCompletionHandler
    }

    var isCancelled: Bool {
        cancellation.isCancelled
    }

    var isPreCommit: Bool {
        lock.lock()
        defer { lock.unlock() }
        switch phase {
        case .queued, .preparing, .settingsInFlight:
            return true
        case .committed, .finished:
            return false
        }
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
    case scenarioSwitchInProgress
    case scenarioSwitchSourceChanged
    case invalidScenarioSwitch
    case scenarioSwitchCancelled
    case scenarioSwitchCommitTimedOut
    case scenarioSwitchRestoreTimedOut
    case scenarioSwitchRestoreFailed
    case scenarioSwitchRetirementPending
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
        case .scenarioSwitchInProgress:
            "已有场景切换正在进行"
        case .scenarioSwitchSourceChanged:
            "当前连接已经变化，场景切换已取消"
        case .invalidScenarioSwitch:
            "场景切换请求无效"
        case .scenarioSwitchCancelled:
            "场景切换已取消，原场景保持连接"
        case .scenarioSwitchCommitTimedOut:
            "场景切换的系统网络设置提交超时"
        case .scenarioSwitchRestoreTimedOut:
            "恢复原场景的系统网络设置超时"
        case .scenarioSwitchRestoreFailed:
            "无法恢复原场景的系统网络设置"
        case .scenarioSwitchRetirementPending:
            "上一场景仍在释放，暂不能准备下一次切换"
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
