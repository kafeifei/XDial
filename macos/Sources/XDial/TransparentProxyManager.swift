import AppKit
import Darwin
import Foundation
import Libbox
import Network
@preconcurrency import NetworkExtension
import SystemConfiguration
@preconcurrency import SystemExtensions

private func isNumericIPAddress(
    _ address: String,
    family: LineAddressFamily
) -> Bool {
    switch family {
    case .ipv4:
        var value = in_addr()
        return address.withCString {
            inet_pton(AF_INET, $0, &value)
        } == 1
    case .ipv6:
        var value = in6_addr()
        return address.withCString {
            inet_pton(AF_INET6, $0, &value)
        } == 1
    }
}

/// macOS 数据面的唯一宿主管理器。
///
/// Profile 只通过本次 `startVPNTunnel(options:)` 进入扩展内存；持久的
/// `providerConfiguration` 只保存定位 provider 所需的非敏感元数据。
final class TransparentProxyManager: NSObject, OSSystemExtensionRequestDelegate {
    static let shared = TransparentProxyManager()

    typealias StatusHandler = (_ status: String, _ error: String?) -> Void
    typealias ReportHandler = (_ report: ConnectionReport) -> Void
    typealias ScenarioSwitchHandler =
        (_ projection: HostScenarioSwitchProjection?) -> Void
    typealias ActivationStatusHandler =
        (_ event: SystemExtensionInstallationEvent) -> Void

    private let extensionIdentifier: String = {
        if let configured = Bundle.main.object(
            forInfoDictionaryKey: "XDialTransparentProxyBundleIdentifier"
        ) as? String,
           !configured.isEmpty {
            return configured
        }
        return XDialBuildIdentity.transparentProxyIdentifier
    }()
    private let configurationName =
        XDialBuildIdentity.providerConfigurationName

    var statusHandler: StatusHandler?
    var reportHandler: ReportHandler?
    /// 完整连接开始时读取一次；场景切换不读取，沿用已提交连接的入口。
    var connectionIngress: () -> ConnectionIngress = { .system }
    var scenarioSwitchHandler: ScenarioSwitchHandler?
    var activationStatusHandler: ActivationStatusHandler?
    var underlayChangeHandler: ((String, Bool) -> Void)?
    var automaticReconnectPreparationHandler:
        ((String, @escaping (AutomaticReconnectPreparation?) -> Void) -> Void)?
    var activeTransactionID: String? {
        TransparentProxyRuntimeGate.connectionProofTransactionID(
            currentTransactionID: currentTransactionID,
            automaticReconnectInProgress:
                automaticReconnectInProgress,
            attemptTransactionID:
                automaticReconnectTransactionID
        )
    }

    private var manager: NETransparentProxyManager?
    private var statusObserver: NSObjectProtocol?
    private var activationRequest: OSSystemExtensionRequest?
    private var activationCompletion: ((Result<Void, Error>) -> Void)?
    private var activationPurpose: ActivationPurpose?
    private var activationVerificationRequest:
        OSSystemExtensionRequest?
    private var activationVerificationPhase:
        SystemExtensionActivationVerifier.Phase?
    private var deactivationRequest: OSSystemExtensionRequest?
    private var deactivationCompletion:
        ((Result<Void, Error>) -> Void)?
    private var startAttempt: NetworkExtensionStartAttempt?
    private var startIntentID: UUID?
    private var currentTransactionID: String?
    /// Transactions this Host process began or adopted. Only transactions
    /// outside this set can be leftovers of an earlier Host process.
    private var hostOwnedTransactionIDs = Set<String>()
    private var currentTransactionSeedJSON: String?
    private var reportPollTimer: Timer?
    private var recoveringTransactionID: String?
    private var requestedProfileJSON: String?
    private var activeUnderlay: HostUnderlaySnapshot?
    private var latestCapturedUnderlay: HostUnderlaySnapshot?
    private var underlayMonitor: HostUnderlayMonitor?
    private var automaticReconnectInProgress = false
    private var automaticReconnectTrigger: AutomaticReconnectTrigger?
    private var pendingInitialRetryTrigger: AutomaticReconnectTrigger?
    /// The open recovery attempt's own transaction; nil while no attempt is
    /// open, and never the transaction which opened recovery.
    private var automaticReconnectTransactionID: String?
    /// The last transaction whose outcome a recovery step consumed.
    private var consumedRecoveryTransactionID: String?
    /// A transaction whose session the Host stopped for its start budget;
    /// its outcome is worded as a start timeout, while retry and incident
    /// classification still follow the code in its report.
    private var budgetStoppedTransactionID: String?
    private let automaticReconnectRetryPolicy =
        AutomaticReconnectRetryPolicy()
    /// Full-recovery budgets keyed by recovery epoch, parking, grants and
    /// the slow tail. The manager owns its timers and Underlay snapshots.
    private lazy var automaticRecoveryLedger = AutomaticRecoveryLedger(
        policy: AutomaticRecoveryLedger.Policy(
            maxAttempts: automaticReconnectRetryPolicy.maxAttempts
        )
    )
    private var automaticReconnectPreparationGate =
        AutomaticReconnectPreparationGate()
    private var automaticReconnectRetryWorkItem: DispatchWorkItem?
    private var automaticReconnectRetryToken: UUID?
    private var automaticReconnectRetryAt: Date?
    /// The scheduled (not yet started) attempt.
    private var automaticReconnectRetryKind: AutomaticRecoveryAttemptKind?
    /// The attempt whose connection transaction is running; nil while the
    /// failure that opened the recovery episode is being handled.
    private var automaticReconnectAttemptKind: AutomaticRecoveryAttemptKind?
    private var automaticReconnectRetryFailedTransactionID: String?
    /// Only the transaction the current recovery step waits for may decide
    /// it; stray status callbacks re-reading an older journal report cannot.
    private var automaticRecoveryOutcomeGate = AutomaticRecoveryOutcomeGate()
    /// Parked recovery keeps a read-only Underlay observer. It is separate
    /// from the committed session's monitor: Network Extension status
    /// callbacks stop that one, and XDial's own attempts stop this one.
    private var parkedUnderlayMonitor: HostUnderlayMonitor?
    /// The Underlay the parked epoch was decided on.
    private var parkedUnderlay: HostUnderlaySnapshot?
    private var parkedRecoveryTrigger: AutomaticReconnectTrigger?
    private var parkedUnderlayCaptureToken: UUID?
    private var parkedTailWorkItem: DispatchWorkItem?
    private var parkedTailAt: Date?
    private var deferredGrantWorkItem: DispatchWorkItem?
    private var powerLifecycleGate = SystemSleepNetworkEpochGate()
    private let lineRecoveryConditions = LineRecoveryConditionsPublisher()
    private var automaticReconnectUnderlayWaitEvidence:
        HostUnderlayCaptureEvidence?
    private var stableConnectionResetWorkItem: DispatchWorkItem?
    private var stableConnectionResetAt: Date?
    private var connectedSessionTransactionID: String?
    private var activeScenarioSwitch: HostScenarioSwitch? {
        didSet { publishScenarioSwitchProjection() }
    }
    private var lastScenarioSwitchProjection:
        HostScenarioSwitchProjection? {
        didSet { publishScenarioSwitchProjection() }
    }
    private var activeReconnectIncidentID: String?
    private var stableResetIncidentID: String?
    private var lastPublishedRuntimeStatus = "disconnected"
#if DEBUG
    private var debugFailureStage: String?
#endif

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate(_:)),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        lineRecoveryConditions.start { [weak self] conditions, completion in
            guard let self else { return completion(.providerNotConnected) }
            self.sendLineRecoveryConditions(conditions, completion: completion)
        }
    }

    var automaticReconnectState: AutomaticReconnectRuntimeState {
        let retryAttempt: Int?
        if case let .budget(number)? = automaticReconnectRetryKind {
            retryAttempt = number
        } else {
            retryAttempt = nil
        }
        return AutomaticReconnectRuntimeState(
            inProgress: automaticReconnectInProgress,
            trigger: automaticReconnectTrigger,
            attemptsUsed: automaticRecoveryLedger.attemptsUsed,
            maxAttempts: automaticReconnectRetryPolicy.maxAttempts,
            stableResetAt: stableConnectionResetAt,
            retryAt: automaticReconnectRetryAt,
            retryAttempt: retryAttempt,
            underlayWaitEvidence:
                automaticReconnectUnderlayWaitEvidence,
            parked: isAutomaticRecoveryParked,
            attemptKind: (
                automaticReconnectRetryKind
                    ?? automaticReconnectAttemptKind
            )?.name,
            tailAttemptAt: parkedTailAt,
            recovery: automaticRecoveryLedger.projection(at: Date())
        )
    }

    /// Recovery exhausted its budget with a network-related failure and is
    /// waiting for a settled network change, a wake, its slow tail or the
    /// user. The runtime is disconnected with takeover removed.
    var isAutomaticRecoveryParked: Bool {
        automaticRecoveryLedger.isParked && !automaticReconnectInProgress
    }

    var parkedRecoveryScenarioID: String? {
        guard automaticRecoveryLedger.isParked else { return nil }
        return automaticRecoveryLedger.parking?.epoch.scenarioID
    }

    var scenarioSwitchProjection: HostScenarioSwitchProjection? {
        guard let active = activeScenarioSwitch else {
            return lastScenarioSwitchProjection
        }
        let status: String
        if active.reconciling {
            status = "reconciling"
        } else if active.timedOut {
            status = "cancelling-after-timeout"
        } else if active.cancellationRequested {
            status = "cancelling"
        } else if active.requestSent {
            status = "preparing"
        } else {
            status = "capturing-underlay"
        }
        return makeScenarioSwitchProjection(
            active,
            status: status,
            // Once a sent request has an ambiguous response, the source is
            // only the last host-known commit. Do not label it active until a
            // read-only Provider reconciliation proves source or target.
            activeTransactionID: active.reconciling
                ? ""
                : currentTransactionID ?? active.sourceTransactionID,
            code: active.reconciling
                ? "switch-outcome-unknown"
                : nil,
            message: active.reconciling
                ? active.reconciliationError?.localizedDescription
                : nil,
            inFlight: true
        )
    }

    private func publishScenarioSwitchProjection() {
        scenarioSwitchHandler?(scenarioSwitchProjection)
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
        reportPollTimer?.invalidate()
        underlayMonitor?.cancel()
        parkedUnderlayMonitor?.cancel()
        parkedTailWorkItem?.cancel()
        deferredGrantWorkItem?.cancel()
        automaticReconnectRetryWorkItem?.cancel()
        stableConnectionResetWorkItem?.cancel()
        activeScenarioSwitch?.timeoutWorkItem?.cancel()
        activeScenarioSwitch?.reconciliationWorkItem?.cancel()
        activeScenarioSwitch?.progressWorkItem?.cancel()
    }

    func start(
        profileJSON: String,
        automaticRetryTrigger: AutomaticReconnectTrigger? = nil
    ) {
        guard !profileJSON.isEmpty else {
            publishFailure(ManagerError.missingProfile)
            return
        }
        lastScenarioSwitchProjection = nil
        let transactionID: String
        do {
            transactionID = try beginTransaction(profileJSON: profileJSON)
        } catch {
            publishFailure(error)
            return
        }
#if DEBUG
        let failureStage = debugFailureStage
        debugFailureStage = nil
#else
        let failureStage: String? = nil
#endif
        let intentID = UUID()
        // A new connection supersedes a parked recovery. A user connection is
        // also a new intent with a fresh budget; an automatic one keeps the
        // budget of whatever epoch its failure will be decided in.
        if let incidentID = activeReconnectIncidentID {
            ReconnectIncidentJournal.finish(
                incidentID: incidentID,
                outcome: "superseded",
                code: automaticRetryTrigger == nil
                    ? AutomaticRecoveryGrantReason.userConnect.rawValue
                    : AutomaticReconnectTrigger.automaticConnection.rawValue
            )
        }
        clearParkedRecovery()
        if automaticRetryTrigger == nil {
            automaticRecoveryLedger.noteUserConnection(at: Date())
        }
        startIntentID = intentID
        requestedProfileJSON = profileJSON
        automaticReconnectInProgress = false
        automaticReconnectTrigger = nil
        automaticReconnectAttemptKind = nil
        pendingInitialRetryTrigger = automaticRetryTrigger
        automaticReconnectTransactionID = nil
        automaticReconnectUnderlayWaitEvidence = nil
        connectedSessionTransactionID = nil
        activeReconnectIncidentID = nil
        stableResetIncidentID = nil
        cancelStableConnectionReset()
        cancelAutomaticReconnectRetry(resetAttempts: false)
        stopUnderlayMonitoring()
        withdrawPendingStart()
        publishRuntimeStatus("connecting", error: nil)
        updateReport(transactionID: transactionID) {
            $0.updateTask(id: "underlay:system", state: .running)
        }
        HostUnderlayCapture.start { [weak self] snapshotResult in
            guard let self else { return }
            guard self.startIntentID == intentID else { return }
            switch snapshotResult {
            case let .success(snapshot):
                self.latestCapturedUnderlay = snapshot
                self.updateReport(transactionID: transactionID) {
                    $0.updateTask(id: "underlay:system", state: .ready)
                    $0.setState(.preparing)
                }
                appLog(
                    "Transparent Proxy underlay default=\(snapshot.defaultInterface.name)"
                )
                self.checkExtensionReadiness(purpose: .connection) {
                    [weak self] result in
                    guard let self else { return }
                    guard self.startIntentID == intentID else { return }
                    switch result {
                    case .success:
                        self.configureAndStart(
                            profileJSON: profileJSON,
                            underlay: snapshot,
                            intentID: intentID,
                            debugFailureStage: failureStage
                        )
                    case let .failure(error):
                        self.publishFailure(error)
                    }
                }
            case let .failure(error):
                self.publishFailure(error)
            }
        }
    }

    /// Stage and atomically commit a new Scenario inside the already-running
    /// Provider session. The currently committed report remains authoritative
    /// until the Provider returns a committed target report; candidate state is
    /// never written into `ConnectionReportJournal`.
    func switchScenario(
        profileJSON: String,
        refreshLineRuntimes: Bool,
        networkEpochID: String? = nil,
        expectedUnderlayFingerprint: String? = nil,
        completion: @escaping (Result<ConnectionReport, Error>) -> Void
    ) {
        guard activeScenarioSwitch == nil else {
            completion(.failure(ManagerError.scenarioSwitchInProgress))
            return
        }
        guard
            let sourceReport = ConnectionReportJournal.read(),
            sourceReport.transactionID == currentTransactionID,
            sourceReport.state == .committed,
            !sourceReport.systemTakeoverRemoved,
            // Only a proven session is a switch source; during recovery the
            // attempt must prove its own transaction first.
            connectedSessionTransactionID == sourceReport.transactionID,
            manager?.connection.status == .connected
        else {
            completion(.failure(ManagerError.scenarioSwitchUnavailable))
            return
        }

        let plan: ConnectionPlan
        do {
            plan = try generateConnectionPlan(profileJSON: profileJSON)
        } catch {
            completion(.failure(error))
            return
        }
        guard
            plan.schemaVersion == 3,
            !plan.scenario.id.isEmpty,
            !plan.configurationFingerprint.isEmpty
        else {
            completion(.failure(ManagerError.invalidConnectionPlan))
            return
        }

        let requestID = UUID().uuidString
        let targetTransactionID = UUID().uuidString
        hostOwnedTransactionIDs.insert(targetTransactionID)
        let targetReport = ConnectionReport(
            transactionID: targetTransactionID,
            plan: plan,
            ingress: sourceReport.ingress
        )
        let targetReportJSON: String
        do {
            let data = try ConnectionReportCodec.encode(targetReport)
            guard let encoded = String(data: data, encoding: .utf8) else {
                throw ManagerError.invalidConnectionPlan
            }
            targetReportJSON = encoded
        } catch {
            completion(.failure(error))
            return
        }

        activeScenarioSwitch = HostScenarioSwitch(
            requestID: requestID,
            sourceTransactionID: sourceReport.transactionID,
            sourceReport: sourceReport,
            targetTransactionID: targetTransactionID,
            targetScenarioID: plan.scenario.id,
            targetConfigurationFingerprint:
                plan.configurationFingerprint,
            profileJSON: profileJSON,
            targetReportJSON: targetReportJSON,
            refreshLineRuntimes: refreshLineRuntimes,
            networkEpochID: networkEpochID,
            expectedUnderlayFingerprint: expectedUnderlayFingerprint,
            candidateReport: targetReport,
            completionGate: HostCompletionGate(completion),
            cancellationRequested: false,
            requestSent: false,
            timedOut: false,
            reconciling: false,
            reconciliationError: nil,
            reconciliationWorkItem: nil,
            progressWorkItem: nil,
            underlay: nil,
            timeoutWorkItem: nil
        )
        HostUnderlayCapture.start { [weak self] result in
            self?.continueScenarioSwitchAfterUnderlayCapture(
                requestID: requestID,
                result: result
            )
        }
    }

    /// Cancellation is scoped to the staged switch. It must not stop the
    /// Network Extension session or alter the source transaction.
    func cancelScenarioSwitch() {
        guard var active = activeScenarioSwitch,
              !active.cancellationRequested else {
            return
        }
        if !active.requestSent {
            activeScenarioSwitch = nil
            active.timeoutWorkItem?.cancel()
            recordScenarioSwitch(
                active,
                status: "cancelled",
                activeTransactionID: active.sourceTransactionID,
                code: "switch-cancelled",
                message: ManagerError.scenarioSwitchCancelled
                    .localizedDescription
            )
            active.completionGate.finish(.failure(
                ManagerError.scenarioSwitchCancelled
            ))
            return
        }
        active.cancellationRequested = true
        activeScenarioSwitch = active
        let request = ProviderScenarioSwitchRequest.cancelSwitch(
            requestID: active.requestID,
            expectedTransactionID: active.sourceTransactionID
        )
        sendScenarioSwitchMessage(request) { result in
            if case let .failure(error) = result {
                appLog(
                    "Scenario switch cancellation delivery failed: "
                        + error.localizedDescription
                )
            }
        }
        // A cancellation acknowledgement is not a terminal transaction fact:
        // settings may still be in flight, or commit may already have won.
        // Begin read-only reconciliation immediately because either the
        // original response or the cancellation acknowledgement can be lost.
        beginScenarioSwitchReconciliation(
            requestID: request.requestID,
            error: ManagerError.scenarioSwitchCancelled
        )
    }

    /// Re-sample the complete host Underlay at a network-epoch settle point.
    /// Only its opaque in-process identity crosses into AppState; the actual
    /// interfaces and DNS snapshot remain owned by this manager and are
    /// captured again for the eventual Provider Switch request.
    func captureCurrentUnderlayFingerprint(
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        HostUnderlayCapture.start { [weak self] result in
            if case let .success(snapshot) = result {
                self?.latestCapturedUnderlay = snapshot
            }
            completion(result.map(\.epochFingerprint))
        }
    }

    private func continueScenarioSwitchAfterUnderlayCapture(
        requestID: String,
        result: Result<HostUnderlaySnapshot, Error>
    ) {
        guard var active = activeScenarioSwitch,
              active.requestID == requestID else {
            // A newer desired generation cancelled this capture. It must not
            // leak an obsolete target into the Provider.
            return
        }
        guard !active.cancellationRequested else {
            activeScenarioSwitch = nil
            recordScenarioSwitch(
                active,
                status: "cancelled",
                activeTransactionID: active.sourceTransactionID,
                code: "switch-cancelled",
                message: ManagerError.scenarioSwitchCancelled
                    .localizedDescription
            )
            active.completionGate.finish(.failure(
                ManagerError.scenarioSwitchCancelled
            ))
            return
        }
        guard case let .success(underlay) = result else {
            activeScenarioSwitch = nil
            if case let .failure(error) = result {
                recordScenarioSwitch(
                    active,
                    status: "failed",
                    activeTransactionID: active.sourceTransactionID,
                    code: "underlay-capture-failed",
                    message: error.localizedDescription
                )
                active.completionGate.finish(.failure(error))
            }
            return
        }
        if let expected = active.expectedUnderlayFingerprint,
           expected != underlay.epochFingerprint {
            // A settled epoch is inseparable from its captured network facts.
            // A later capture cannot silently acquire that epoch's authority.
            let failure = ProviderScenarioSwitchRejectedError(
                code: "network-superseded",
                message: "网络仍在变化，等待新的稳定网络后切换"
            )
            finishSourceScenarioSwitchFailure(
                active,
                error: failure,
                code: failure.code,
                message: failure.localizedDescription
            )
            return
        }
        guard
            let liveSourceReport = ConnectionReportJournal.read(),
            liveSourceReport.transactionID == active.sourceTransactionID,
            liveSourceReport.transactionID == currentTransactionID,
            liveSourceReport.state == .committed,
            !liveSourceReport.systemTakeoverRemoved,
            manager?.connection.status == .connected
        else {
            activeScenarioSwitch = nil
            recordScenarioSwitch(
                active,
                status: "failed",
                activeTransactionID: currentTransactionID ??
                    active.sourceTransactionID,
                code: "switch-source-changed",
                message: ManagerError.scenarioSwitchUnavailable
                    .localizedDescription
            )
            active.completionGate.finish(.failure(
                ManagerError.scenarioSwitchUnavailable
            ))
            return
        }
        active.sourceReport = liveSourceReport

        if liveSourceReport.scenario.id == active.targetScenarioID,
           liveSourceReport.configurationFingerprint ==
            active.targetConfigurationFingerprint,
           activeUnderlay?.isEquivalent(to: underlay) == true,
           !active.refreshLineRuntimes {
            activeScenarioSwitch = nil
            recordScenarioSwitch(
                active,
                status: "no-op",
                activeTransactionID: liveSourceReport.transactionID,
                code: nil,
                message: nil
            )
            active.completionGate.finish(.success(liveSourceReport))
            return
        }

        active.underlay = underlay
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.timeOutScenarioSwitch(requestID: requestID)
        }
        active.timeoutWorkItem = timeoutWorkItem
        activeScenarioSwitch = active
        let request = ProviderScenarioSwitchRequest.switchScenario(
            requestID: active.requestID,
            expectedTransactionID: active.sourceTransactionID,
            targetTransactionID: active.targetTransactionID,
            profileJSON: active.profileJSON,
            connectionReportJSON: active.targetReportJSON,
            underlayInterfacesJSON: underlay.interfacesJSON,
            underlayDefaultName: underlay.defaultInterface.name,
            underlayDefaultIndex: underlay.defaultInterface.index,
            systemDNSJSON: underlay.systemDNSJSON,
            refreshLineRuntimes: active.refreshLineRuntimes,
            networkEpochID: active.networkEpochID,
            underlayPathIdentity: underlay.pathIdentity
        )
        sendScenarioSwitchMessage(request) { [weak self] switchResult in
            self?.finishScenarioSwitch(
                requestID: requestID,
                result: switchResult
            )
        }
        scheduleScenarioSwitchProgressPoll(
            requestID: requestID,
            delay: 0.1
        )
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 90,
            execute: timeoutWorkItem
        )
    }

    private func timeOutScenarioSwitch(requestID: String) {
        guard var active = activeScenarioSwitch,
              active.requestID == requestID else {
            return
        }
        active.timeoutWorkItem?.cancel()
        active.timeoutWorkItem = nil
        active.timedOut = true
        if !active.requestSent {
            activeScenarioSwitch = nil
            recordScenarioSwitch(
                active,
                status: "timed-out",
                activeTransactionID: active.sourceTransactionID,
                code: "switch-timeout",
                message: ManagerError.scenarioSwitchTimedOut
                    .localizedDescription
            )
            active.completionGate.finish(.failure(
                ManagerError.scenarioSwitchTimedOut
            ))
            return
        }
        active.cancellationRequested = true
        activeScenarioSwitch = active
        let cancelRequest = ProviderScenarioSwitchRequest.cancelSwitch(
            requestID: active.requestID,
            expectedTransactionID: active.sourceTransactionID
        )
        sendScenarioSwitchMessage(cancelRequest) { result in
            if case let .failure(error) = result {
                appLog(
                    "Timed-out Scenario switch cancellation delivery failed: "
                        + error.localizedDescription
                )
            }
            // Cancellation acknowledgement means only that cancellation was
            // accepted (or lost the commit race); reconciliation below reads
            // the live committed Provider transaction.
        }
        beginScenarioSwitchReconciliation(
            requestID: active.requestID,
            error: ManagerError.scenarioSwitchTimedOut
        )
    }

#if DEBUG
    func injectFailureOnNextStart(_ stage: String) -> Bool {
        guard [
            "rule-set",
            "line",
            "commit",
            "post-commit-fatal",
        ].contains(stage) else {
            return false
        }
        debugFailureStage = stage
        return true
    }
#endif

    /// Install or replace the bundled System Extension without creating a
    /// network configuration. Debug acceptance uses this to prove signing and
    /// embedding independently from live traffic takeover.
    func prepareSystemExtension(
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        checkExtensionReadiness(
            purpose: .installation,
            completion: completion
        )
    }

    /// Recovery entry point for an outgoing signed host identity. Network
    /// Extension preferences are owner-scoped, so the incoming Debug/Release
    /// identity cannot remove the previous identity's record on its behalf.
    func removeOwnedNetworkConfigurationsOnly(
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        removeOwnedNetworkConfigurations(completion: completion)
    }

    /// Explicit uninstall path. Upgrades never deactivate the current
    /// extension: an activation request replaces the same bundle identifier
    /// in place. Uninstall first removes this app's transparent-proxy
    /// configuration so the provider can exit, then deactivates the embedded
    /// extension without relying on an app deletion or a reboot.
    func uninstallSystemExtension(
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard
            activationCompletion == nil,
            activationVerificationRequest == nil,
            deactivationCompletion == nil
        else {
            completion(.failure(ManagerError.activationInProgress))
            return
        }
        removeOwnedNetworkConfigurations { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.submitDeactivation(completion: completion)
            case let .failure(error):
                completion(.failure(error))
            }
        }
    }

    func lineLatencies(transactionID: String, probeLineID: String? = nil, groupID: String? = nil,
                       completion: @escaping (Result<[ProviderLineLatency], Error>) -> Void) {
        let request = ProviderDiagnosticsRequest(
            cmd: probeLineID == nil ? .lineLatencySnapshot : .probeLineLatency,
            transactionID: transactionID, lineID: probeLineID, groupID: groupID)
        sendProviderDiagnostics(request, timeout: probeLineID == nil ? 5 : 12) { result in
            completion(result.flatMap { data in
                guard let facts = data.lineLatencies,
                      facts.allSatisfy({ ($0.milliseconds ?? 0) >= 0 && ($0.milliseconds ?? 0) <= 65_535 }),
                      probeLineID == nil || facts.contains(where: { $0.lineID == probeLineID }) else {
                    return .failure(ProviderDiagnosticsHostError.payloadMismatch)
                }
                return .success(facts)
            })
        }
    }

    func probeLineOutboundAddress(
        transactionID: String,
        lineID: String,
        addressFamily: LineAddressFamily = .ipv4,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let request = ProviderDiagnosticsRequest(
            cmd: .probeLineOutboundAddress,
            transactionID: transactionID,
            lineID: lineID,
            addressFamily: addressFamily
        )
        sendProviderDiagnostics(
            request,
            timeout: 12
        ) { result in
            switch result {
            case let .failure(error):
                completion(.failure(error))
            case let .success(data):
                guard
                    let observation = data.lineOutboundAddress,
                    observation.lineID == lineID,
                    isNumericIPAddress(
                        observation.address,
                        family: addressFamily
                    )
                else {
                    completion(.failure(
                        ProviderDiagnosticsHostError.payloadMismatch
                    ))
                    return
                }
                completion(.success(observation.address))
            }
        }
    }

    func trafficSnapshot(
        transactionID: String,
        completion: @escaping (
            Result<ProviderTrafficSnapshot, Error>
        ) -> Void
    ) {
        let request = ProviderDiagnosticsRequest(
            cmd: .trafficSnapshot,
            transactionID: transactionID
        )
        sendProviderDiagnostics(request, timeout: 3) { result in
            switch result {
            case let .failure(error):
                completion(.failure(error))
            case let .success(data):
                guard let snapshot = data.traffic else {
                    completion(.failure(
                        ProviderDiagnosticsHostError.payloadMismatch
                    ))
                    return
                }
                completion(.success(snapshot))
            }
        }
    }

    #if DEBUG
    func applicationAttributionSnapshot(
        transactionID: String,
        completion: @escaping (
            Result<ProviderApplicationAttributionSnapshot, Error>
        ) -> Void
    ) {
        let request = ProviderDiagnosticsRequest(
            cmd: .applicationAttributionSnapshot,
            transactionID: transactionID
        )
        sendProviderDiagnostics(request, timeout: 5) { result in
            switch result {
            case let .failure(error):
                completion(.failure(error))
            case let .success(data):
                guard let snapshot = data.applicationAttribution else {
                    completion(.failure(
                        ProviderDiagnosticsHostError.payloadMismatch
                    ))
                    return
                }
                completion(.success(snapshot))
            }
        }
    }

    func routingProbeSnapshot(
        transactionID: String,
        probeID: String,
        completion: @escaping (
            Result<ProviderRoutingProbeSnapshot, Error>
        ) -> Void
    ) {
        let request = ProviderDiagnosticsRequest(
            cmd: .routingProbeSnapshot,
            transactionID: transactionID,
            probeID: probeID
        )
        sendProviderDiagnostics(
            request,
            timeout: 5
        ) { result in
            switch result {
            case let .failure(error):
                completion(.failure(error))
            case let .success(data):
                guard
                    let snapshot = data.routingProbe,
                    snapshot.probeID == probeID
                else {
                    completion(.failure(
                        ProviderDiagnosticsHostError.payloadMismatch
                    ))
                    return
                }
                completion(.success(snapshot))
            }
        }
    }

    func beginRouteProbe(
        transactionID: String,
        host: String,
        timeoutMS: Int,
        completion: @escaping (
            Result<ProviderBegunRouteProbe, Error>
        ) -> Void
    ) {
        let request = ProviderDiagnosticsRequest(
            cmd: .beginRouteProbe,
            transactionID: transactionID,
            host: host,
            port: 443,
            timeoutMS: timeoutMS
        )
        sendProviderDiagnostics(
            request,
            timeout: TimeInterval(timeoutMS) / 1_000 + 2
        ) { result in
            switch result {
            case let .failure(error):
                completion(.failure(error))
            case let .success(data):
                guard let begun = data.begunRouteProbe else {
                    completion(.failure(
                        ProviderDiagnosticsHostError.payloadMismatch
                    ))
                    return
                }
                completion(.success(begun))
            }
        }
    }

    #endif

    func stop() {
        if activeScenarioSwitch != nil {
            cancelScenarioSwitch()
            if let active = activeScenarioSwitch {
                activeScenarioSwitch = nil
                active.timeoutWorkItem?.cancel()
                active.reconciliationWorkItem?.cancel()
                recordScenarioSwitch(
                    active, status: "interrupted", activeTransactionID: "",
                    code: "user-disconnected", message: nil
                )
                active.completionGate.finish(.failure(
                    ManagerError.scenarioSwitchCancelled
                ))
            }
        }
        if let transactionID = currentTransactionID {
            updateReport(transactionID: transactionID) { report in
                guard report.state != .committed else { return }
                report.setState(.rollingBack)
            }
        }
        startIntentID = nil
        requestedProfileJSON = nil
        activeUnderlay = nil
        latestCapturedUnderlay = nil
        automaticReconnectInProgress = false
        automaticReconnectTrigger = nil
        automaticReconnectAttemptKind = nil
        pendingInitialRetryTrigger = nil
        automaticReconnectTransactionID = nil
        automaticReconnectUnderlayWaitEvidence = nil
        connectedSessionTransactionID = nil
        // Explicit disconnect (and quit, which stops through here) ends a
        // parked recovery immediately together with its observer and timers.
        clearParkedRecovery()
        if let incidentID = activeReconnectIncidentID {
            ReconnectIncidentJournal.finish(
                incidentID: incidentID,
                outcome: "cancelled",
                code: "user-disconnected",
                message: "User explicitly disconnected XDial"
            )
        }
        activeReconnectIncidentID = nil
        stableResetIncidentID = nil
        cancelStableConnectionReset()
        cancelAutomaticReconnectRetry(resetAttempts: false)
        stopUnderlayMonitoring()
        withdrawPendingStart()
        publishRuntimeStatus("disconnecting", error: nil)
        if let manager {
            // 正常退出发生在 NSApplication 的嵌套 RunLoop 中。此时再调用
            // loadAllFromPreferences 会把真正的 stopVPNTunnel 延后到一个无法
            // 执行的 completion。运行期已经持有精确 manager，必须直接停止。
            stopLoadedManager(manager)
            return
        }
        withExistingManager { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error):
                self.publishFailure(error)
            case .success(nil):
                self.manager = nil
                self.finishOrphanedTransactionIfNeeded()
                self.publishRuntimeStatus("disconnected", error: nil)
            case let .success(manager?):
                self.stopLoadedManager(manager)
            }
        }
    }

    /// Closes an open start attempt. Its session may still read inactive
    /// because the system has not acted on the start yet, so the start is
    /// withdrawn with a stop as well; stopping an inactive session is a no-op
    /// otherwise.
    private func withdrawPendingStart() {
        guard startAttempt != nil else { return }
        startAttempt = nil
        manager?.connection.stopVPNTunnel()
    }

    private func stopLoadedManager(
        _ manager: NETransparentProxyManager
    ) {
        installStatusObserver(for: manager)
        if manager.connection.status == .disconnected
            || manager.connection.status == .invalid {
            publishStatus(for: manager)
            return
        }
        manager.connection.stopVPNTunnel()
        // stopVPNTunnel() 同步改变系统 session 的阶段；立即投影一次，避免
        // 退出嵌套 RunLoop 期间只依赖异步 NEVPNStatusDidChange。
        publishStatus(for: manager)
    }

    /// 退出的 Timer 必须直接读取系统 session 与 journal。GoEngine 的
    /// @Published 投影通过 MainActor Task 更新，在 AppKit 的嵌套退出 RunLoop
    /// 中可能暂时不推进，不能作为是否允许进程退出的唯一事实。
    func terminationDrainSnapshot() -> (
        runtimeStatus: String,
        report: ConnectionReport?
    ) {
        if let manager {
            switch manager.connection.status {
            case .invalid, .disconnected:
                publishStatus(for: manager)
                return ("disconnected", ConnectionReportJournal.read())
            case .disconnecting:
                return ("disconnecting", ConnectionReportJournal.read())
            case .connecting:
                return ("connecting", ConnectionReportJournal.read())
            case .connected:
                return ("connected", ConnectionReportJournal.read())
            case .reasserting:
                return ("reconnecting", ConnectionReportJournal.read())
            @unknown default:
                return (lastPublishedRuntimeStatus, ConnectionReportJournal.read())
            }
        }
        return (lastPublishedRuntimeStatus, ConnectionReportJournal.read())
    }

    func syncStatus() {
        withExistingManager { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error):
                // A failed preferences read says nothing about the session
                // of an open start attempt; its own checks bound it.
                guard self.startAttempt == nil else {
                    self.publishRuntimeStatus(
                        self.lastPublishedRuntimeStatus,
                        error: nil
                    )
                    return
                }
                self.publishFailure(error)
            case .success(nil):
                self.manager = nil
                self.finishOrphanedTransactionIfNeeded()
                self.publishRuntimeStatus("disconnected", error: nil)
            case let .success(loaded?):
                // An open start attempt is judged through the instance that
                // started it. Nothing guarantees that separately loaded
                // instances see the same session's changes at the same time.
                let manager = self.startAttempt == nil
                    ? loaded
                    : self.manager ?? loaded
                self.installStatusObserver(for: manager)
                if self.reconcilePersistedTransactionIfNeeded(
                    manager
                ) {
                    return
                }
                self.publishStatus(for: manager)
            }
        }
    }

    func noteSystemWake() {
        powerLifecycleGate.noteSystemDidWake()
        lineRecoveryConditions.noteSystemDidWake()
        underlayMonitor?.noteSystemWake()
        parkedUnderlayMonitor?.noteSystemWake()
        resumeAutomaticReconnectRetryAfterWake()
        armParkedTailTimer()
        scheduleDeferredGrantIfNeeded()
    }

    func noteSystemSleep() {
        powerLifecycleGate.noteSystemWillSleep()
        lineRecoveryConditions.noteSystemWillSleep()
        underlayMonitor?.noteSystemSleep()
        parkedUnderlayMonitor?.noteSystemSleep()
        automaticReconnectRetryWorkItem?.cancel()
        automaticReconnectRetryWorkItem = nil
        // Parked timers keep their due dates; no grant or attempt is made
        // while asleep, and the full wake re-arms them.
        parkedTailWorkItem?.cancel()
        parkedTailWorkItem = nil
        deferredGrantWorkItem?.cancel()
        deferredGrantWorkItem = nil
    }

    private func checkExtensionReadiness(
        purpose: ActivationPurpose,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard
            activationCompletion == nil,
            activationVerificationRequest == nil,
            deactivationCompletion == nil
        else {
            completion(.failure(ManagerError.activationInProgress))
            return
        }
        activationCompletion = completion
        activationPurpose = purpose
        if purpose == .installation {
            activationStatusHandler?(.submitted)
        }
        verifyActivatedExtension(
            phase: purpose == .installation
                ? .installationPreflight : .connection
        )
    }

    private func submitExtensionActivation() {
        guard activationPurpose == .installation else { return }
        activationVerificationRequest = nil
        activationVerificationPhase = nil
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        activationRequest = request
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func verifyActivatedExtension(
        phase: SystemExtensionActivationVerifier.Phase
    ) {
        guard bundledExtensionVersion != nil else {
            finishActivation(
                .failure(
                    ManagerError.extensionVerificationFailed(
                        expectedVersion: "unknown"
                    )
                )
            )
            return
        }
        activationRequest = nil
        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        activationVerificationRequest = request
        activationVerificationPhase = phase
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private var bundledExtensionVersion: String? {
        let extensionURL = Bundle.main.bundleURL
            .appendingPathComponent(
                "Contents/Library/SystemExtensions",
                isDirectory: true
            )
            .appendingPathComponent(
                "\(extensionIdentifier).systemextension",
                isDirectory: true
            )
        return Bundle(url: extensionURL)?.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String
    }

    private func removeOwnedNetworkConfigurations(
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        NETransparentProxyManager.loadAllFromPreferences {
            [weak self] managers, error in
            guard let self else { return }
            if let error {
                completion(.failure(error))
                return
            }
            let owned = (managers ?? []).filter {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == self.extensionIdentifier
            }
            self.removeOwnedNetworkConfigurations(
                ArraySlice(owned),
                completion: completion
            )
        }
    }

    private func removeOwnedNetworkConfigurations(
        _ managers: ArraySlice<NETransparentProxyManager>,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let manager = managers.first else {
            self.manager = nil
            completion(.success(()))
            return
        }
        manager.connection.stopVPNTunnel()
        waitForManagerToStop(
            manager,
            attemptsRemaining: 100
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error):
                completion(.failure(error))
            case .success:
                manager.removeFromPreferences { [weak self] error in
                    guard let self else { return }
                    if let error {
                        completion(.failure(error))
                        return
                    }
                    self.removeOwnedNetworkConfigurations(
                        managers.dropFirst(),
                        completion: completion
                    )
                }
            }
        }
    }

    private func waitForManagerToStop(
        _ manager: NETransparentProxyManager,
        attemptsRemaining: Int,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        switch manager.connection.status {
        case .disconnected, .invalid:
            completion(.success(()))
        default:
            guard attemptsRemaining > 0 else {
                completion(.failure(ManagerError.stopTimedOut))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                [weak self] in
                self?.waitForManagerToStop(
                    manager,
                    attemptsRemaining: attemptsRemaining - 1,
                    completion: completion
                )
            }
        }
    }

    private func submitDeactivation(
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        deactivationCompletion = completion
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        deactivationRequest = request
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func finishDeactivation(
        _ result: Result<Void, Error>
    ) {
        let completion = deactivationCompletion
        deactivationCompletion = nil
        deactivationRequest = nil
        completion?(result)
    }

    private func finishActivation(_ result: Result<Void, Error>) {
        let purpose = activationPurpose
        let completion = activationCompletion
        activationCompletion = nil
        activationPurpose = nil
        activationRequest = nil
        activationVerificationRequest = nil
        activationVerificationPhase = nil
        if purpose == .installation {
            switch result {
            case .success:
                activationStatusHandler?(.completed)
            case let .failure(error):
                activationStatusHandler?(
                    .failed(error.localizedDescription)
                )
            }
        }
        completion?(result)
    }

    private func configureAndStart(
        profileJSON: String,
        underlay: HostUnderlaySnapshot,
        intentID: UUID,
        debugFailureStage: String?
    ) {
        loadManager { [weak self] result in
            guard let self else { return }
            guard self.startIntentID == intentID else { return }
            switch result {
            case let .failure(error):
                self.publishFailure(error)
            case let .success(manager):
                let providerProtocol = NETunnelProviderProtocol()
                providerProtocol.providerBundleIdentifier =
                    self.extensionIdentifier
                providerProtocol.providerConfiguration = [
                    "schema_version": 1,
                ]
                providerProtocol.serverAddress = self.configurationName

                manager.protocolConfiguration = providerProtocol
                manager.localizedDescription = self.configurationName
                manager.isEnabled = true
                manager.saveToPreferences { [weak self] error in
                    guard let self else { return }
                    guard self.startIntentID == intentID else { return }
                    if let error {
                        self.publishFailure(error)
                        return
                    }
                    manager.loadFromPreferences { [weak self] error in
                        guard let self else { return }
                        guard self.startIntentID == intentID else { return }
                        if let error {
                            self.publishFailure(error)
                            return
                        }
                        self.installStatusObserver(for: manager)
                        self.startConnection(
                            manager,
                            profileJSON: profileJSON,
                            underlay: underlay,
                            intentID: intentID,
                            debugFailureStage: debugFailureStage
                        )
                    }
                }
            }
        }
    }

    private func startConnection(
        _ manager: NETransparentProxyManager,
        profileJSON: String,
        underlay: HostUnderlaySnapshot,
        intentID: UUID,
        debugFailureStage: String?
    ) {
        guard startIntentID == intentID else { return }
        switch manager.connection.status {
        case .connected, .connecting, .reasserting, .disconnecting:
            manager.connection.stopVPNTunnel()
            waitUntilStopped(
                manager,
                attemptsRemaining: 100,
                profileJSON: profileJSON,
                underlay: underlay,
                intentID: intentID,
                debugFailureStage: debugFailureStage
            )
        case .invalid, .disconnected:
            guard let transactionID = currentTransactionID else {
                publishFailure(ManagerError.missingTransaction)
                return
            }
            guard let connectionReport = currentTransactionSeedJSON else {
                publishFailure(ManagerError.missingTransaction)
                return
            }
            // The attempt is judged through the instance that starts it; the
            // status observer and later syncs follow the same one.
            if self.manager !== manager {
                installStatusObserver(for: manager)
            }
            let attempt = NetworkExtensionStartAttempt(
                intentID: intentID,
                transactionID: transactionID,
                isRecoveryAttempt: automaticReconnectInProgress
                    && automaticReconnectTransactionID == transactionID
            )
            startAttempt = attempt
            activeUnderlay = underlay
            do {
                var options: [String: NSObject] = [
                    "profile": profileJSON as NSString,
                    "underlay_interfaces":
                        underlay.interfacesJSON as NSString,
                    "underlay_default_name":
                        underlay.defaultInterface.name as NSString,
                    "underlay_default_index":
                        NSNumber(value: underlay.defaultInterface.index),
                    "system_dns": underlay.systemDNSJSON as NSString,
                    "underlay_path_identity":
                        underlay.pathIdentity as NSString,
                    "transaction_id": transactionID as NSString,
                    "connection_report": connectionReport as NSString,
                ]
#if DEBUG
                if let debugFailureStage {
                    options["debug_failure_stage"] =
                        debugFailureStage as NSString
                }
#endif
                try manager.connection.startVPNTunnel(options: options)
                monitorStartAttempt(manager, attemptID: attempt.id)
            } catch {
                if startAttempt?.id == attempt.id {
                    startAttempt = nil
                }
                publishFailure(error)
            }
        @unknown default:
            publishFailure(ManagerError.unknownStatus)
        }
    }

    private func waitUntilStopped(
        _ manager: NETransparentProxyManager,
        attemptsRemaining: Int,
        profileJSON: String,
        underlay: HostUnderlaySnapshot,
        intentID: UUID,
        debugFailureStage: String?
    ) {
        guard startIntentID == intentID else { return }
        guard attemptsRemaining > 0 else {
            publishFailure(ManagerError.stopTimedOut)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard self.startIntentID == intentID else { return }
            switch manager.connection.status {
            case .invalid, .disconnected:
                self.startConnection(
                    manager,
                    profileJSON: profileJSON,
                    underlay: underlay,
                    intentID: intentID,
                    debugFailureStage: debugFailureStage
                )
            default:
                self.waitUntilStopped(
                    manager,
                    attemptsRemaining: attemptsRemaining - 1,
                    profileJSON: profileJSON,
                    underlay: underlay,
                    intentID: intentID,
                    debugFailureStage: debugFailureStage
                )
            }
        }
    }

    private func loadManager(
        completion: @escaping (
            Result<NETransparentProxyManager, Error>
        ) -> Void
    ) {
        withExistingManager { result in
            switch result {
            case let .failure(error):
                completion(.failure(error))
            case let .success(manager):
                completion(.success(manager ?? NETransparentProxyManager()))
            }
        }
    }

    /// Provider messages go through the manager this Host already holds.
    /// Every `loadAllFromPreferences` returns new manager instances whose
    /// `NETunnelProviderSession` outlives them and keeps receiving every change
    /// of the same system session; loading once per message left about 5,000
    /// of them in one Host process (2026-10-22), each change of the session's
    /// last disconnect error then costing the main thread several seconds.
    /// The session belongs to the configuration, not to one tunnel run;
    /// requests that belong to a transaction name it and are checked against
    /// the current one. Only a Host without a manager for this Provider loads
    /// one.
    private func withProviderMessageManager(
        purpose: TransparentProxyManagerSelectionPurpose,
        completion: @escaping (
            Result<NETransparentProxyManager?, Error>
        ) -> Void
    ) {
        guard
            let manager,
            (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier == extensionIdentifier
        else {
            withExistingManager(purpose: purpose, completion: completion)
            return
        }
        // Delivered later, like a preferences load, so callers keep their
        // ordering against cancellation and timeouts.
        DispatchQueue.main.async {
            completion(.success(manager))
        }
    }

    private func withExistingManager(
        purpose: TransparentProxyManagerSelectionPurpose = .runtime,
        completion: @escaping (
            Result<NETransparentProxyManager?, Error>
        ) -> Void
    ) {
        NETransparentProxyManager.loadAllFromPreferences {
            [weak self] managers, error in
            guard let self else { return }
            if let error {
                completion(.failure(error))
                return
            }
            let candidates = managers ?? []
            let descriptors = candidates.map {
                TransparentProxyManagerCandidate(
                    providerBundleIdentifier:
                        ($0.protocolConfiguration as?
                            NETunnelProviderProtocol)?
                        .providerBundleIdentifier,
                    localizedDescription: $0.localizedDescription,
                    state: Self.managerCandidateState(
                        $0.connection.status
                    ),
                    isCurrentManager: self.manager === $0
                )
            }
            let selectedIndex =
                TransparentProxyManagerSelector.selectIndex(
                    from: descriptors,
                    expectedBundleIdentifier:
                        self.extensionIdentifier,
                    configurationName: self.configurationName,
                    purpose: purpose
                )
            completion(.success(
                selectedIndex.map { candidates[$0] }
            ))
        }
    }

    private static func managerCandidateState(
        _ status: NEVPNStatus
    ) -> TransparentProxyManagerCandidateState {
        switch status {
        case .connected:
            .connected
        case .reasserting:
            .reasserting
        case .connecting:
            .connecting
        case .disconnecting:
            .disconnecting
        case .disconnected:
            .disconnected
        case .invalid:
            .invalid
        @unknown default:
            .unknown
        }
    }

    private func sendScenarioSwitchMessage(
        _ request: ProviderScenarioSwitchRequest,
        completion: @escaping (
            Result<ProviderScenarioSwitchResponse, Error>
        ) -> Void
    ) {
        let requestData: Data
        do {
            requestData = try ProviderScenarioSwitchCodec.encodeRequest(
                request
            )
        } catch {
            completion(.failure(error))
            return
        }

        withProviderMessageManager(purpose: .runtime) { result in
            switch result {
            case .failure:
                completion(.failure(
                    ManagerError.scenarioSwitchUnavailable
                ))
            case .success(nil):
                completion(.failure(
                    ManagerError.scenarioSwitchUnavailable
                ))
            case let .success(manager?):
                guard manager.connection.status == .connected,
                      let session = manager.connection
                        as? NETunnelProviderSession else {
                    completion(.failure(
                        ManagerError.scenarioSwitchUnavailable
                    ))
                    return
                }
                if request.cmd == .switchScenario {
                    guard var active = self.activeScenarioSwitch,
                          active.requestID == request.requestID,
                          !active.cancellationRequested,
                          !active.requestSent else {
                        completion(.failure(
                            ManagerError.scenarioSwitchCancelled
                        ))
                        return
                    }
                    // `requestSent` means sendProviderMessage is about to be
                    // invoked, not merely that manager lookup started. A cancel
                    // racing the lookup can therefore remove the candidate and
                    // prevent an obsolete Switch from being delivered later.
                    active.requestSent = true
                    self.activeScenarioSwitch = active
                }
                do {
                    try session.sendProviderMessage(requestData) {
                        responseData in
                        DispatchQueue.main.async {
                            guard let responseData else {
                                completion(.failure(
                                    ManagerError
                                        .scenarioSwitchInvalidResponse
                                ))
                                return
                            }
                            do {
                                let response = try
                                    ProviderScenarioSwitchCodec
                                    .decodeResponse(responseData)
                                guard
                                    response.cmd == request.cmd,
                                    response.requestID == request.requestID,
                                    response.sourceTransactionID ==
                                        request.expectedTransactionID
                                else {
                                    throw ManagerError
                                        .scenarioSwitchInvalidResponse
                                }
                                completion(.success(response))
                            } catch {
                                completion(.failure(error))
                            }
                        }
                    }
                } catch {
                    completion(.failure(
                        ManagerError.scenarioSwitchSendFailed
                    ))
                }
            }
        }
    }

    private func finishScenarioSwitch(
        requestID: String,
        result: Result<ProviderScenarioSwitchResponse, Error>
    ) {
        guard
            let active = activeScenarioSwitch,
            active.requestID == requestID
        else {
            return
        }

        switch result {
        case let .failure(error):
            guard active.requestSent else {
                finishSourceScenarioSwitchFailure(
                    active,
                    error: error,
                    code: "switch-host-failed",
                    message: error.localizedDescription
                )
                return
            }
            beginScenarioSwitchReconciliation(
                requestID: requestID,
                error: active.timedOut
                    ? ManagerError.scenarioSwitchTimedOut
                    : error
            )
        case let .success(response):
            guard response.ok else {
                finishSourceScenarioSwitchFailure(
                    active,
                    error: active.timedOut
                        ? ManagerError.scenarioSwitchTimedOut
                        : ProviderScenarioSwitchRejectedError(
                            code: response.code ?? "switch-failed",
                            message: response.message
                        ),
                    code: active.timedOut
                        ? "switch-timeout"
                        : response.code ?? "switch-failed",
                    message: response.message
                )
                return
            }
            guard
                let (report, reportJSON) = committedReport(
                    from: response
                ),
                response.activeTransactionID == active.targetTransactionID,
                report.transactionID == active.targetTransactionID,
                report.scenario.id == active.targetScenarioID,
                report.configurationFingerprint ==
                    active.targetConfigurationFingerprint
            else {
                beginScenarioSwitchReconciliation(
                    requestID: requestID,
                    error: ManagerError.scenarioSwitchInvalidResponse
                )
                return
            }
            adoptCommittedScenarioSwitch(
                active,
                report: report,
                reportJSON: reportJSON
            )
        }
    }

    private func beginScenarioSwitchReconciliation(
        requestID: String,
        error: Error
    ) {
        guard var active = activeScenarioSwitch,
              active.requestID == requestID,
              active.requestSent else {
            return
        }
        active.timeoutWorkItem?.cancel()
        active.timeoutWorkItem = nil
        active.progressWorkItem?.cancel()
        active.progressWorkItem = nil
        active.reconciling = true
        if active.reconciliationError == nil {
            active.reconciliationError = error
        }
        activeScenarioSwitch = active
        scheduleScenarioSwitchReconciliation(
            requestID: requestID,
            delay: 0
        )
    }

    /// Polls only the Provider's in-memory candidate sidecar. The committed
    /// source report remains authoritative until the original Switch response
    /// publishes the target transaction.
    private func scheduleScenarioSwitchProgressPoll(
        requestID: String,
        delay: TimeInterval
    ) {
        guard var active = activeScenarioSwitch,
              active.requestID == requestID,
              !active.reconciling,
              active.progressWorkItem == nil else {
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.performScenarioSwitchProgressPoll(
                requestID: requestID
            )
        }
        active.progressWorkItem = workItem
        activeScenarioSwitch = active
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }

    private func performScenarioSwitchProgressPoll(
        requestID: String
    ) {
        guard var active = activeScenarioSwitch,
              active.requestID == requestID,
              !active.reconciling else {
            return
        }
        active.progressWorkItem = nil
        activeScenarioSwitch = active
        guard active.requestSent else {
            scheduleScenarioSwitchProgressPoll(
                requestID: requestID,
                delay: 0.1
            )
            return
        }
        let request = ProviderScenarioSwitchRequest.reconcileSwitch(
            requestID: active.requestID,
            expectedTransactionID: active.sourceTransactionID,
            targetTransactionID: active.targetTransactionID
        )
        sendScenarioSwitchMessage(request) { [weak self] result in
            self?.finishScenarioSwitchProgressPoll(
                requestID: requestID,
                result: result
            )
        }
    }

    private func finishScenarioSwitchProgressPoll(
        requestID: String,
        result: Result<ProviderScenarioSwitchResponse, Error>
    ) {
        guard var active = activeScenarioSwitch,
              active.requestID == requestID,
              !active.reconciling else {
            return
        }
        if
            case let .success(response) = result,
            response.ok,
            response.switchInProgress == true,
            let reportJSON = response.candidateReportJSON,
            let reportData = reportJSON.data(using: .utf8),
            let report = try? ConnectionReportCodec.decode(reportData),
            report.transactionID == active.targetTransactionID,
            report.scenario.id == active.targetScenarioID,
            report.configurationFingerprint ==
                active.targetConfigurationFingerprint
        {
            active.candidateReport = report
        }
        activeScenarioSwitch = active
        scheduleScenarioSwitchProgressPoll(
            requestID: requestID,
            delay: 0.15
        )
    }

    private func scheduleScenarioSwitchReconciliation(
        requestID: String,
        delay: TimeInterval
    ) {
        guard var active = activeScenarioSwitch,
              active.requestID == requestID,
              active.reconciling,
              active.reconciliationWorkItem == nil else {
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.performScenarioSwitchReconciliation(
                requestID: requestID
            )
        }
        active.reconciliationWorkItem = workItem
        activeScenarioSwitch = active
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }

    private func performScenarioSwitchReconciliation(
        requestID: String
    ) {
        guard let active = activeScenarioSwitch,
              active.requestID == requestID,
              active.reconciling else {
            return
        }
        let request = ProviderScenarioSwitchRequest.reconcileSwitch(
            requestID: active.requestID,
            expectedTransactionID: active.sourceTransactionID,
            targetTransactionID: active.targetTransactionID
        )
        sendScenarioSwitchMessage(request) { [weak self] result in
            self?.finishScenarioSwitchReconciliation(
                requestID: requestID,
                result: result
            )
        }
    }

    private func finishScenarioSwitchReconciliation(
        requestID: String,
        result: Result<ProviderScenarioSwitchResponse, Error>
    ) {
        guard var active = activeScenarioSwitch,
              active.requestID == requestID,
              active.reconciling else {
            return
        }
        active.reconciliationWorkItem = nil
        activeScenarioSwitch = active

        guard case let .success(response) = result,
              response.ok,
              let switchInProgress = response.switchInProgress,
              let (report, reportJSON) = committedReport(from: response),
              report.transactionID == response.activeTransactionID else {
            if case let .failure(error) = result,
               active.reconciliationError == nil {
                active.reconciliationError = error
                activeScenarioSwitch = active
            }
            scheduleScenarioSwitchReconciliation(
                requestID: requestID,
                delay: 0.5
            )
            return
        }

        switch ProviderScenarioSwitchReconciliation.resolve(
            sourceTransactionID: active.sourceTransactionID,
            targetTransactionID: active.targetTransactionID,
            activeTransactionID: report.transactionID,
            switchInProgress: switchInProgress
        ) {
        case .targetCommitted:
            guard report.scenario.id == active.targetScenarioID,
                  report.configurationFingerprint ==
                    active.targetConfigurationFingerprint else {
                scheduleScenarioSwitchReconciliation(
                    requestID: requestID,
                    delay: 0.5
                )
                return
            }
            adoptCommittedScenarioSwitch(
                active,
                report: report,
                reportJSON: reportJSON
            )
        case .sourceInProgress:
            guard report.scenario.id == active.sourceReport.scenario.id,
                  report.configurationFingerprint ==
                    active.sourceReport.configurationFingerprint else {
                scheduleScenarioSwitchReconciliation(
                    requestID: requestID,
                    delay: 0.5
                )
                return
            }
            scheduleScenarioSwitchReconciliation(
                requestID: requestID,
                delay: 0.25
            )
        case .sourceRestored:
            guard report.scenario.id == active.sourceReport.scenario.id,
                  report.configurationFingerprint ==
                    active.sourceReport.configurationFingerprint else {
                scheduleScenarioSwitchReconciliation(
                    requestID: requestID,
                    delay: 0.5
                )
                return
            }
            let terminalError: Error
            let code: String
            if active.timedOut {
                terminalError = ManagerError.scenarioSwitchTimedOut
                code = "switch-timeout"
            } else if active.cancellationRequested {
                terminalError = ManagerError.scenarioSwitchCancelled
                code = "switch-cancelled"
            } else {
                terminalError = active.reconciliationError
                    ?? ManagerError.scenarioSwitchInvalidResponse
                code = "switch-not-committed"
            }
            finishSourceScenarioSwitchFailure(
                active,
                error: terminalError,
                code: code,
                message: terminalError.localizedDescription,
                sourceReport: report,
                sourceReportJSON: reportJSON
            )
        case .unrelatedTransaction:
            // A transaction outside this host's source/target pair is still an
            // explicit Provider fact, but this request cannot safely attach
            // the missing Profile snapshot to it. Keep the outcome uncertain
            // instead of silently relabelling the old source as active.
            scheduleScenarioSwitchReconciliation(
                requestID: requestID,
                delay: 0.5
            )
        }
    }

    private func committedReport(
        from response: ProviderScenarioSwitchResponse
    ) -> (ConnectionReport, String)? {
        guard
            let reportJSON = response.reportJSON,
            let reportData = reportJSON.data(using: .utf8),
            let report = try? ConnectionReportCodec.decode(reportData),
            report.state == .committed,
            !report.systemTakeoverRemoved,
            report.tasks.contains(where: {
                $0.id == "ingress:transparent-proxy"
                    && $0.kind == "ingress"
                    && $0.state == .committed
            })
        else {
            return nil
        }
        return (report, reportJSON)
    }

    private func adoptCommittedScenarioSwitch(
        _ active: HostScenarioSwitch,
        report: ConnectionReport,
        reportJSON: String
    ) {
        activeScenarioSwitch = nil
        active.timeoutWorkItem?.cancel()
        active.reconciliationWorkItem?.cancel()
        stopUnderlayMonitoring()
        activeUnderlay = active.underlay
        requestedProfileJSON = active.profileJSON
        currentTransactionID = report.transactionID
        currentTransactionSeedJSON = reportJSON
        connectedSessionTransactionID = report.transactionID
        do {
            try ConnectionReportJournal.write(report)
        } catch {
            appLog(
                "Scenario switch committed report journal write failed: "
                    + error.localizedDescription
            )
        }
        publishReport(report)
        lastScenarioSwitchProjection = .committed(
            sourceReport: active.sourceReport,
            report: report
        )
        active.completionGate.finish(.success(report))
    }

    private func finishSourceScenarioSwitchFailure(
        _ active: HostScenarioSwitch,
        error: Error,
        code: String,
        message: String?,
        sourceReport: ConnectionReport? = nil,
        sourceReportJSON: String? = nil
    ) {
        activeScenarioSwitch = nil
        active.timeoutWorkItem?.cancel()
        active.reconciliationWorkItem?.cancel()
        if let sourceReport {
            currentTransactionID = sourceReport.transactionID
            currentTransactionSeedJSON = sourceReportJSON
            connectedSessionTransactionID = sourceReport.transactionID
            try? ConnectionReportJournal.write(sourceReport)
            publishReport(sourceReport)
        }
        recordScenarioSwitch(
            active,
            status: active.timedOut ? "timed-out" : "failed",
            activeTransactionID: active.sourceTransactionID,
            code: code,
            message: message
        )
        active.completionGate.finish(.failure(error))
    }

    private func makeScenarioSwitchProjection(
        _ active: HostScenarioSwitch,
        status: String,
        activeTransactionID: String,
        code: String?,
        message: String?,
        inFlight: Bool,
        reusedLineIDs: [String] = []
    ) -> HostScenarioSwitchProjection {
        HostScenarioSwitchProjection(
            status: status,
            fromScenarioID: active.sourceReport.scenario.id,
            toScenarioID: active.targetScenarioID,
            sourceCommittedTransactionID: active.sourceTransactionID,
            candidateTransactionID: active.targetTransactionID,
            activeCommittedTransactionID: activeTransactionID,
            inFlight: inFlight,
            candidateReport: active.candidateReport,
            reusedLineIDs: reusedLineIDs,
            code: code,
            message: message
        )
    }

    private func recordScenarioSwitch(
        _ active: HostScenarioSwitch,
        status: String,
        activeTransactionID: String,
        code: String?,
        message: String?,
        reusedLineIDs: [String] = []
    ) {
        lastScenarioSwitchProjection = makeScenarioSwitchProjection(
            active,
            status: status,
            activeTransactionID: activeTransactionID,
            code: code,
            message: message,
            inFlight: false,
            reusedLineIDs: reusedLineIDs
        )
    }

    /// 经已持有的 manager 发送（见 `withProviderMessageManager`）。请求与响应
    /// 都带事务 ID，发给上一笔事务的请求由 `diagnosticsTransactionIsCurrent`
    /// 和回包校验拒绝，不靠每次重新取得连接对象。
    func sendTailscaleControl(_ request: TailscaleControlRequest,
        completion: @escaping (Result<TailscaleControlResponse, Error>) -> Void) {
        let gate = HostCompletionGate(completion)
        guard request.isValid, diagnosticsTransactionIsCurrent(request.transactionID),
              let data = try? JSONEncoder().encode(request) else {
            gate.finish(.failure(ProviderDiagnosticsHostError.transactionMismatch)); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            gate.finish(.failure(ProviderDiagnosticsHostError.timedOut))
        }
        withProviderMessageManager(purpose: .diagnostics) { result in
            guard case let .success(manager?) = result,
                  manager.connection.status == .connected,
                  self.diagnosticsTransactionIsCurrent(request.transactionID),
                  let session = manager.connection as? NETunnelProviderSession else {
                gate.finish(.failure(ProviderDiagnosticsHostError.notConnected)); return
            }
            do {
                try session.sendProviderMessage(data) { raw in
                    guard self.diagnosticsTransactionIsCurrent(request.transactionID),
                          let raw, raw.count <= 1_048_576,
                          let response = try? JSONDecoder().decode(TailscaleControlResponse.self, from: raw),
                          response.requestID == request.requestID,
                          response.transactionID == request.transactionID else {
                        gate.finish(.failure(ProviderDiagnosticsHostError.invalidResponse)); return
                    }
                    gate.finish(.success(response))
                }
            } catch { gate.finish(.failure(ProviderDiagnosticsHostError.sendFailed)) }
        }
    }

    /// 本机 SOCKS5 共享只改变 Provider 持有的回环监听，不改变当前事务的
    /// 规则、出口或系统接管；响应携带 Provider 的实际监听结果。
    func sendLocalSOCKSShare(_ request: LocalSOCKSShareRequest,
        completion: @escaping (Result<LocalSOCKSShareResponse, Error>) -> Void) {
        let gate = HostCompletionGate(completion)
        guard request.isValid, diagnosticsTransactionIsCurrent(request.transactionID),
              let data = try? JSONEncoder().encode(request) else {
            gate.finish(.failure(ProviderDiagnosticsHostError.transactionMismatch)); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            gate.finish(.failure(ProviderDiagnosticsHostError.timedOut))
        }
        withProviderMessageManager(purpose: .diagnostics) { result in
            guard case let .success(manager?) = result,
                  manager.connection.status == .connected,
                  self.diagnosticsTransactionIsCurrent(request.transactionID),
                  let session = manager.connection as? NETunnelProviderSession else {
                gate.finish(.failure(ProviderDiagnosticsHostError.notConnected)); return
            }
            do {
                try session.sendProviderMessage(data) { raw in
                    guard let raw, raw.count <= 4096,
                          let response = try? JSONDecoder().decode(LocalSOCKSShareResponse.self, from: raw),
                          response.requestID == request.requestID,
                          response.transactionID == request.transactionID else {
                        gate.finish(.failure(ProviderDiagnosticsHostError.invalidResponse)); return
                    }
                    gate.finish(.success(response))
                }
            } catch { gate.finish(.failure(ProviderDiagnosticsHostError.sendFailed)) }
        }
    }

    /// 电源与 Underlay 条件不属于某笔事务，只发给当前已连接的 Provider；结果区分未连接
    /// 与未确认，由发布者重发或续约。Provider 据此决定 Line 局部恢复能否消耗预算。
    private func sendLineRecoveryConditions(
        _ conditions: ProviderLineRecoveryConditions,
        completion: @escaping (LineRecoveryConditionsDeliveryResult) -> Void
    ) {
        guard conditions.isValid,
              let data = try? JSONEncoder().encode(conditions) else {
            completion(.unacknowledged); return
        }
        if let manager, manager.connection.status != .connected {
            completion(.providerNotConnected); return
        }
        let gate = HostCompletionGate<LineRecoveryConditionsDeliveryResult> { result in
            completion((try? result.get()) ?? .unacknowledged)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            gate.finish(.success(.unacknowledged))
        }
        withProviderMessageManager(purpose: .diagnostics) { result in
            guard case let .success(manager?) = result,
                  manager.connection.status == .connected,
                  let session = manager.connection as? NETunnelProviderSession else {
                gate.finish(.success(.providerNotConnected)); return
            }
            do {
                try session.sendProviderMessage(data) { raw in
                    guard let raw,
                          raw.count <= ProviderLineRecoveryConditions.maxMessageBytes,
                          let response = try? JSONDecoder().decode(
                            ProviderLineRecoveryConditionsResponse.self, from: raw),
                          response.source == conditions.source,
                          response.sequence == conditions.sequence,
                          response.delivered else {
                        gate.finish(.success(.unacknowledged)); return
                    }
                    gate.finish(.success(.acknowledged))
                }
            } catch { gate.finish(.success(.unacknowledged)) }
        }
    }

    private func sendProviderDiagnostics(
        _ request: ProviderDiagnosticsRequest,
        timeout: TimeInterval,
        completion: @escaping (
            Result<ProviderDiagnosticsData, Error>
        ) -> Void
    ) {
        guard
            request.v == ProviderDiagnosticsCodec.version,
            !request.transactionID.isEmpty
        else {
            completion(.failure(
                ProviderDiagnosticsHostError.invalidRequest
            ))
            return
        }
        guard diagnosticsTransactionIsCurrent(
            request.transactionID
        ) else {
            completion(.failure(
                ProviderDiagnosticsHostError.transactionMismatch
            ))
            return
        }
        guard
            let requestData =
                try? ProviderDiagnosticsCodec.encodeRequest(request)
        else {
            completion(.failure(
                ProviderDiagnosticsHostError.invalidRequest
            ))
            return
        }

        let gate = HostCompletionGate(completion)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(1, timeout)
        ) {
            gate.finish(.failure(
                ProviderDiagnosticsHostError.timedOut
            ))
        }
        withProviderMessageManager(purpose: .diagnostics) { result in
            switch result {
            case .failure:
                gate.finish(.failure(
                    ProviderDiagnosticsHostError.managerUnavailable
                ))
            case .success(nil):
                gate.finish(.failure(
                    ProviderDiagnosticsHostError.managerUnavailable
                ))
            case let .success(manager?):
                guard self.diagnosticsTransactionIsCurrent(
                    request.transactionID
                ) else {
                    gate.finish(.failure(
                        ProviderDiagnosticsHostError.transactionMismatch
                    ))
                    return
                }
                guard manager.connection.status == .connected else {
                    gate.finish(.failure(
                        ProviderDiagnosticsHostError.notConnected
                    ))
                    return
                }
                guard
                    let session =
                        manager.connection as? NETunnelProviderSession
                else {
                    gate.finish(.failure(
                        ProviderDiagnosticsHostError.sessionUnavailable
                    ))
                    return
                }
                do {
                    try session.sendProviderMessage(
                        requestData
                    ) { responseData in
                        guard
                            let responseData,
                            let response =
                                try? ProviderDiagnosticsCodec
                                .decodeResponse(responseData),
                            response.v ==
                                ProviderDiagnosticsCodec.version
                        else {
                            gate.finish(.failure(
                                ProviderDiagnosticsHostError
                                    .invalidResponse
                            ))
                            return
                        }
                        guard
                            response.transactionID ==
                                request.transactionID
                        else {
                            gate.finish(.failure(
                                ProviderDiagnosticsHostError
                                    .transactionMismatch
                            ))
                            return
                        }
                        guard self.diagnosticsTransactionIsCurrent(
                            request.transactionID
                        ) else {
                            gate.finish(.failure(
                                ProviderDiagnosticsHostError
                                    .transactionMismatch
                            ))
                            return
                        }
                        guard response.ok else {
                            gate.finish(.failure(
                                ProviderDiagnosticsHostError
                                    .providerRejected(
                                        response.code ??
                                            "provider-request-failed"
                                    )
                            ))
                            return
                        }
                        guard let data = response.data else {
                            gate.finish(.failure(
                                ProviderDiagnosticsHostError
                                    .payloadMismatch
                            ))
                            return
                        }
                        gate.finish(.success(data))
                    }
                } catch {
                    gate.finish(.failure(
                        ProviderDiagnosticsHostError.sendFailed
                    ))
                }
            }
        }
    }

    private func diagnosticsTransactionIsCurrent(
        _ transactionID: String
    ) -> Bool {
        guard
            currentTransactionID == transactionID,
            let report = ConnectionReportJournal.read(),
            report.transactionID == transactionID,
            report.state == .committed,
            !report.systemTakeoverRemoved,
            report.tasks.contains(where: {
                $0.id == "ingress:transparent-proxy"
                    && $0.kind == "ingress"
                    && $0.state == .committed
            })
        else {
            return false
        }
        return true
    }

    private func installStatusObserver(
        for manager: NETransparentProxyManager
    ) {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
        self.manager = manager
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager.connection,
            queue: .main
        ) { [weak self, weak manager] _ in
            guard let self, let manager else { return }
            self.publishStatus(for: manager)
        }
    }

    private func publishStatus(for manager: NETransparentProxyManager) {
        lineRecoveryConditions.noteProviderConnected(
            manager.connection.status == .connected
        )
        publishLatestReport()
        switch manager.connection.status {
        case .invalid, .disconnected:
            if startAttempt?.inactiveSession == .beforeStart {
                // The Host has not read the Provider's copy of this start and
                // has no evidence it was rejected (no active session seen, or
                // no answer from the Provider journal): the read may be the
                // session before it and decides nothing. The attempt's own
                // checks bound the wait.
                publishRuntimeStatus(
                    automaticReconnectInProgress
                        ? "reconnecting"
                        : "connecting",
                    error: nil
                )
                return
            }
            let disconnectedAt = Date()
            let reportBeforeRecovery = ConnectionReportJournal.read()
            // Only an attempt the Host saw acted on gets here.
            let endedAttempt = startAttempt
            startAttempt = nil
            let lostCommittedSession =
                startIntentID != nil
                && requestedProfileJSON != nil
                && connectedSessionTransactionID != nil
                && connectedSessionTransactionID ==
                    reportBeforeRecovery?.transactionID
                && !automaticReconnectInProgress
            connectedSessionTransactionID = nil
            cancelStableConnectionReset()
            stopUnderlayMonitoring()
            finishSystemDisconnectRollbackIfNeeded()
            if let report = ConnectionReportJournal.read(),
               report.state == .committed {
                currentTransactionID = report.transactionID
                finishInterruptedTransactionRecovery(
                    transactionID: report.transactionID,
                    error: .providerSessionLost,
                    code: "provider-session-lost",
                    taskID: "ingress:transparent-proxy"
                )
            }
            if let report = ConnectionReportJournal.read(),
               PersistedTransactionReconciliation.decide(
                   report: report,
                   ownership: ownership(of: report),
                   systemSession: .inactive,
                   hostIntentActive: hostIntentActive
               ) == .finishWithdrawnTransaction {
                finishWithdrawnTransaction(
                    transactionID: report.transactionID
                )
            }
            if let transactionID = recoveringTransactionID {
                recoveringTransactionID = nil
                finishInterruptedTransactionRecovery(
                    transactionID: transactionID
                )
                publishRuntimeStatus(
                    "disconnected",
                    error: ManagerError.interruptedTransactionRecovered
                        .localizedDescription
                )
                return
            }
            if lostCommittedSession {
                beginUnexpectedDisconnectRecovery(
                    manager: manager,
                    disconnectedAt: disconnectedAt,
                    report: ConnectionReportJournal.read()
                )
                return
            }
            if automaticReconnectInProgress {
                handleAutomaticReconnectAfterDisconnect(
                    report: ConnectionReportJournal.read()
                )
            }
            guard let endedAttempt else {
                if !automaticReconnectInProgress {
                    publishRuntimeStatus("disconnected", error: nil)
                }
                return
            }
            settleEndedStartAttempt(endedAttempt, manager: manager)
        case .connecting:
            startAttempt?.noteSystemActive()
            publishRuntimeStatus(
                automaticReconnectInProgress ? "reconnecting" : "connecting",
                error: nil
            )
        case .connected:
            // A connected session alone does not end the attempt; the
            // committed report of its transaction does.
            startAttempt?.noteSystemActive()
            publishRuntimeStatus("connected", error: nil)
            publishLatestReport()
            if lastPublishedRuntimeStatus == "connected" {
                startUnderlayMonitoringIfNeeded()
            }
        case .reasserting:
            startAttempt?.noteSystemActive()
            cancelStableConnectionReset()
            publishRuntimeStatus("reconnecting", error: nil)
        case .disconnecting:
            startAttempt?.noteSystemActive()
            cancelStableConnectionReset()
            publishRuntimeStatus(
                automaticReconnectInProgress ? "reconnecting" : "disconnecting",
                error: nil
            )
        @unknown default:
            publishRuntimeStatus(
                "disconnected",
                error: ManagerError.unknownStatus.localizedDescription
            )
        }
    }

    /// The session of an attempt the Host saw acted on is inactive now. The
    /// Provider's terminal report is written before its session ends, so it
    /// is read again first; the disconnect error only words the failure and
    /// is not waited for beyond a short deadline (its callback was seen to
    /// arrive minutes late). What remains unsettled is settled from what the
    /// Host saw, see `NetworkExtensionStartAttempt.settlement`.
    private func settleEndedStartAttempt(
        _ attempt: NetworkExtensionStartAttempt,
        manager: NETransparentProxyManager
    ) {
        let scope = attempt.scope
        var done = false
        let settle: (Error?) -> Void = { [weak self] error in
            guard
                !done,
                let self,
                scope.matches(
                    currentIntentID: self.startIntentID,
                    currentTransactionID: self.currentTransactionID
                )
            else {
                return
            }
            done = true
            let probed = self.publishLatestReport()
            // A terminal report first read here may still need the Host's
            // confirmation of the system teardown it already observed.
            if Self.systemSessionState(self.manager) != .active {
                self.finishSystemDisconnectRollbackIfNeeded()
            }
            guard scope.matches(
                currentIntentID: self.startIntentID,
                currentTransactionID: self.currentTransactionID
            ) else {
                return
            }
            let settled = ConnectionReportJournal.read().map {
                $0.transactionID == scope.transactionID
                    && [.failed, .cancelled].contains($0.state)
            } ?? false
            let settlement = NetworkExtensionStartAttempt.settlement(
                isRecoveryAttempt: attempt.isRecoveryAttempt,
                recoveryAwaitsTransaction:
                    self.automaticReconnectInProgress
                        && self.automaticRecoveryOutcomeGate
                            .awaitedTransactionID == scope.transactionID,
                recoveryConsumedTransaction:
                    self.consumedRecoveryTransactionID == scope.transactionID,
                stopRequested: attempt.stopRequested,
                settled: settled,
                providerTookTransaction:
                    attempt.providerTookTransaction
                        || probed?.transactionID == scope.transactionID
            )
            switch settlement {
            case .alreadyDecided:
                return
            case let .recoveryStep(markSessionLost):
                if markSessionLost {
                    self.finishProviderSessionLost(scope.transactionID)
                }
                self.handleAutomaticReconnectAfterDisconnect(
                    report: ConnectionReportJournal.read()
                )
            case let .fail(markSessionLost, cause):
                if markSessionLost {
                    self.finishProviderSessionLost(scope.transactionID)
                }
                switch cause {
                case .startTimedOut:
                    self.publishFailure(ManagerError.startTimedOut)
                case .providerSessionLost:
                    self.publishFailure(
                        error ?? ManagerError.providerSessionLost
                    )
                case .providerStartFailed:
                    self.publishFailure(
                        error ?? ManagerError.providerStartFailed
                    )
                }
            }
        }
        manager.connection.fetchLastDisconnectError { error in
            DispatchQueue.main.async {
                settle(error)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            settle(nil)
        }
    }

    private func recoveryOutcomeMessage(
        _ report: ConnectionReport?
    ) -> String? {
        guard let report else { return nil }
        return report.transactionID == budgetStoppedTransactionID
            ? ManagerError.startTimedOut.localizedDescription
            : report.error?.message
    }

    private func finishProviderSessionLost(_ transactionID: String) {
        finishInterruptedTransactionRecovery(
            transactionID: transactionID,
            error: .providerSessionLost,
            code: ConnectionFailureCode.providerSessionLost
        )
    }

    /// Re-evaluates the attempt every check until it is proven or settled, so
    /// a state change that was missed or read before the session acted on the
    /// start never leaves it open without a bound.
    private func monitorStartAttempt(
        _ manager: NETransparentProxyManager,
        attemptID: UUID
    ) {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + NetworkExtensionStartAttempt.checkInterval
        ) {
            guard self.startAttempt?.id == attemptID else {
                return
            }
            let status = manager.connection.status
            switch status {
            case .connected, .invalid, .disconnected:
                self.publishStatus(for: manager)
            case .connecting, .reasserting, .disconnecting:
                self.startAttempt?.noteSystemActive()
            @unknown default:
                self.startAttempt = nil
                self.publishFailure(ManagerError.unknownStatus)
                return
            }
            guard self.startAttempt?.id == attemptID else {
                return
            }
            let sessionActive = status != .invalid && status != .disconnected
            switch self.startAttempt?.recordCheck(
                sessionActive: sessionActive
            ) {
            case .keepWaiting?:
                self.monitorStartAttempt(manager, attemptID: attemptID)
            case .stopSession?:
                appLog(
                    "Transparent Proxy start attempt unproven after "
                        + Self.elapsedSeconds(since: self.startAttempt?.startedAt)
                        + "s; stopping its session transaction="
                        + (self.currentTransactionID ?? "")
                )
                self.budgetStoppedTransactionID =
                    self.startAttempt?.transactionID
                manager.connection.stopVPNTunnel()
                self.monitorStartAttempt(manager, attemptID: attemptID)
            case .timedOut?:
                appLog(
                    "Transparent Proxy start attempt timed out after "
                        + Self.elapsedSeconds(since: self.startAttempt?.startedAt)
                        + "s session-active=\(sessionActive) transaction="
                        + (self.currentTransactionID ?? "")
                )
                self.startAttempt = nil
                // Also withdraws a start the system has not acted on yet.
                manager.connection.stopVPNTunnel()
                self.publishFailure(ManagerError.startTimedOut)
            case nil:
                return
            }
        }
    }

    private static func elapsedSeconds(since start: Date?) -> String {
        String(Int((-(start?.timeIntervalSinceNow ?? 0)).rounded()))
    }

    private func publishFailure(_ error: Error) {
        let underlayCaptureError = error as? HostUnderlayCaptureError
        let wasAutomaticReconnect =
            automaticReconnectInProgress
                && automaticReconnectTrigger != nil
        // The transaction is decided; no start attempt for it stays open,
        // and a start the system has not acted on yet is withdrawn.
        withdrawPendingStart()
        connectedSessionTransactionID = nil
        cancelStableConnectionReset()
        stopUnderlayMonitoring()
        if let transactionID = currentTransactionID {
            updateReport(transactionID: transactionID) { report in
                guard ![
                    ConnectionTransactionState.failed,
                    .cancelled,
                ].contains(report.state) else {
                    return
                }
                report.setState(.rollingBack)
                report.fail(
                    code: underlayCaptureError?.evidence.reason.rawValue
                        ?? "host-start-failed",
                    message: error.localizedDescription,
                    taskID: report.currentTask?.id ?? "",
                    evidence: underlayCaptureError.map {
                        ConnectionFailureEvidence(
                            underlayCapture: $0.evidence
                        )
                    }
                )
                report.rollbackSessionTasks(
                    systemTakeoverRemoved: true,
                    cleanupComplete: true,
                    finalState: .failed
                )
            }
        }
        if AutomaticRecoveryOutcomeGate.failureContinuation(
            wasRecovering: wasAutomaticReconnect,
            stillRecovering: automaticReconnectInProgress
        ) == .alreadyDecided {
            return
        }
        let report = ConnectionReportJournal.read()
        let shouldContinueAutomaticReconnect =
            wasAutomaticReconnect
                || beginInitialFailureRecoveryIfEligible(report: report)
        if !shouldContinueAutomaticReconnect {
            automaticReconnectInProgress = false
            automaticReconnectTrigger = nil
            pendingInitialRetryTrigger = nil
            automaticReconnectTransactionID = nil
            cancelAutomaticReconnectRetry(resetAttempts: false)
        }
        if shouldContinueAutomaticReconnect {
            publishRuntimeStatus("reconnecting", error: nil)
            handleAutomaticReconnectAfterDisconnect(
                report: report
            )
            return
        }
        publishRuntimeStatus(
            "disconnected",
            error: error.localizedDescription
        )
    }

    private func beginInitialFailureRecoveryIfEligible(
        report: ConnectionReport?
    ) -> Bool {
        guard
            pendingInitialRetryTrigger == .automaticConnection,
            let report,
            report.transactionID == currentTransactionID,
            report.state == .failed,
            report.rollbackComplete,
            report.systemTakeoverRemoved,
            requestedProfileJSON != nil,
            startIntentID != nil
        else {
            return false
        }
        pendingInitialRetryTrigger = nil
        automaticReconnectInProgress = true
        automaticReconnectTrigger = .automaticConnection
        automaticReconnectAttemptKind = nil
        // The failed launch transaction opens the episode and is awaited as
        // its first outcome, but it is no attempt: it can never prove recovery.
        automaticReconnectTransactionID = nil
        automaticRecoveryOutcomeGate.await(report.transactionID)
        automaticRecoveryLedger.beginEpisode(
            in: recoveryEpoch(
                scenarioID: report.scenario.id,
                underlay: latestCapturedUnderlay ?? activeUnderlay
            ),
            at: Date()
        )
        let reasonCode = report.error?.code ?? "launch-auto-connect-failed"
        let reasonMessage = report.error?.message
            ?? "Launch auto-connect failed"
        let incidentID = ReconnectIncidentJournal.begin(
            at: Date(),
            trigger: .automaticConnection,
            report: report,
            reasonCode: reasonCode,
            reasonMessage: reasonMessage
        )
        activeReconnectIncidentID = incidentID.isEmpty
            ? nil
            : incidentID
        appLog(
            "Transparent Proxy launch auto-connect failed "
                + "transaction=\(report.transactionID) code="
                + ReconnectIncidentFailureCode.recordable(reasonCode)
        )
        return true
    }

    private func beginUnexpectedDisconnectRecovery(
        manager: NETransparentProxyManager,
        disconnectedAt: Date,
        report: ConnectionReport?
    ) {
        automaticReconnectInProgress = true
        automaticReconnectTrigger = .unexpectedDisconnect
        automaticReconnectAttemptKind = nil
        automaticReconnectTransactionID = nil
        // The lost committed transaction's settled report opens the episode.
        automaticRecoveryOutcomeGate.await(
            report?.transactionID ?? currentTransactionID
        )
        automaticRecoveryLedger.beginEpisode(
            in: recoveryEpoch(
                scenarioID: report?.scenario.id ?? "",
                underlay: activeUnderlay
            ),
            at: disconnectedAt
        )
        let reasonCode = report?.error?.code
            ?? ConnectionFailureCode.providerSessionLost
        let reasonMessage = report?.error?.message
            ?? ManagerError.providerSessionLost.localizedDescription
        let incidentID = ReconnectIncidentJournal.begin(
            at: disconnectedAt,
            trigger: .unexpectedDisconnect,
            report: report,
            reasonCode: reasonCode,
            reasonMessage: reasonMessage
        )
        activeReconnectIncidentID = incidentID.isEmpty
            ? nil
            : incidentID
        appLog(
            "Transparent Proxy disconnected unexpectedly "
                + "at=\(ISO8601DateFormatter().string(from: disconnectedAt)) "
                + "code=\(reasonCode)"
        )
        manager.connection.fetchLastDisconnectError { [weak self] error in
            DispatchQueue.main.async {
                guard
                    let self,
                    let incidentID = self.activeReconnectIncidentID,
                    let error
                else {
                    return
                }
                let nsError = error as NSError
                ReconnectIncidentJournal.updateReason(
                    incidentID: incidentID,
                    code:
                        "\(nsError.domain):\(nsError.code)",
                    message: error.localizedDescription
                )
            }
        }
        publishRuntimeStatus("reconnecting", error: nil)
        handleAutomaticReconnectAfterDisconnect(report: report)
    }

    func runtimeConfigurationFingerprint(
        profileJSON: String
    ) -> Result<String, Error> {
        do {
            let plan = try generateConnectionPlan(profileJSON: profileJSON)
            guard !plan.configurationFingerprint.isEmpty else {
                throw ManagerError.invalidConnectionPlan
            }
            return .success(plan.configurationFingerprint)
        } catch {
            return .failure(error)
        }
    }

    private func generateConnectionPlan(
        profileJSON: String
    ) throws -> ConnectionPlan {
        var planError: NSError?
        let planJSON = LibboxGenerateConnectionPlan(
            profileJSON,
            &planError
        )
        if let planError {
            throw planError
        }
        guard
            let data = planJSON.data(using: .utf8),
            let plan = try? JSONDecoder().decode(
                ConnectionPlan.self,
                from: data
            )
        else {
            throw ManagerError.invalidConnectionPlan
        }
        return plan
    }

    private func beginTransaction(profileJSON: String) throws -> String {
        let plan = try generateConnectionPlan(profileJSON: profileJSON)
        let transactionID = UUID().uuidString
        let report = ConnectionReport(
            transactionID: transactionID,
            plan: plan,
            ingress: connectionIngress()
        )
        let seedData = try ConnectionReportCodec.encode(report)
        guard let seedJSON = String(data: seedData, encoding: .utf8) else {
            throw ManagerError.invalidConnectionPlan
        }
        hostOwnedTransactionIDs.insert(transactionID)
        try ConnectionReportJournal.write(report)
        budgetStoppedTransactionID = nil
        currentTransactionID = transactionID
        currentTransactionSeedJSON = seedJSON
        beginReportPolling(transactionID: transactionID)
        publishReport(report)
        return transactionID
    }

    private func updateReport(
        transactionID: String,
        _ mutation: (inout ConnectionReport) -> Void
    ) {
        guard let report = ConnectionReportJournal.update(
            transactionID: transactionID,
            mutation
        ) else {
            return
        }
        if let seedData = try? ConnectionReportCodec.encode(report) {
            currentTransactionSeedJSON = String(
                data: seedData,
                encoding: .utf8
            )
        }
        publishReport(report)
    }

    private func beginReportPolling(transactionID: String) {
        reportPollTimer?.invalidate()
        reportPollTimer = Timer.scheduledTimer(
            withTimeInterval: 0.2,
            repeats: true
        ) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard self.currentTransactionID == transactionID else {
                timer.invalidate()
                return
            }
            self.publishLatestReport()
            if let report = ConnectionReportJournal.read(),
               report.transactionID == transactionID,
               [.committed, .failed, .cancelled].contains(report.state) {
                timer.invalidate()
                self.reportPollTimer = nil
            }
        }
    }

    /// Returns the daemon's read of the Provider journal, nil when the probe
    /// got no report.
    @discardableResult
    private func publishLatestReport() -> ConnectionReport? {
        let localReport = ConnectionReportJournal.read()
        var candidate: ConnectionReport?
        var shouldMirrorProviderReport = false

        let probedProviderReport =
            PrivilegeManager.probeProviderConnectionReport()
        startAttempt?.noteProviderReport(probedProviderReport)
        if let providerReport = probedProviderReport,
           currentTransactionID == nil ||
            providerReport.transactionID == currentTransactionID {
            if let localReport,
               localReport
                .isSystemDisconnectConfirmationSuccessor(
                    of: providerReport
                ) || (
                    Self.systemSessionState(manager) != .active
                        && localReport.isHostSettlementSuccessor(
                            of: providerReport
                        )
                ) {
                candidate = localReport
            } else {
                candidate = providerReport
                shouldMirrorProviderReport = true
            }
        } else if let localReport,
                  currentTransactionID == nil ||
                    localReport.transactionID == currentTransactionID {
            candidate = localReport
        }

        guard
            let report = candidate,
            ConnectionReportLiveProjection.shouldAdoptPersisted(
                report,
                currentTransactionID: currentTransactionID
            )
        else {
            return probedProviderReport
        }

        currentTransactionID = report.transactionID
        if shouldMirrorProviderReport {
            try? ConnectionReportJournal.write(report)
        }
        publishReport(report)
        return probedProviderReport
    }

    private func finishSystemDisconnectRollbackIfNeeded() {
        guard
            let report = ConnectionReportJournal.read(),
            [.failed, .cancelled].contains(report.state),
            !report.rollbackComplete ||
                !report.systemTakeoverRemoved
        else {
            return
        }
        currentTransactionID = report.transactionID
        updateReport(transactionID: report.transactionID) {
            $0.confirmSystemDisconnectRollback()
        }
    }

    private func publishReport(_ report: ConnectionReport) {
        reportHandler?(report)
        if automaticReconnectInProgress,
           let manager,
           manager.connection.status == .disconnected
            || manager.connection.status == .invalid {
            handleAutomaticReconnectAfterDisconnect(report: report)
            return
        }
        guard manager?.connection.status == .connected else {
            return
        }
        let runtimeStatus = publishRuntimeStatus(
            "connected",
            error: nil,
            report: report
        )
        if runtimeStatus == "connected" {
            handleCommittedRuntimeConnected(report)
        } else {
            stopUnderlayMonitoring()
        }
    }

    private func handleCommittedRuntimeConnected(
        _ report: ConnectionReport
    ) {
        let isNewSession =
            connectedSessionTransactionID != report.transactionID
        connectedSessionTransactionID = report.transactionID
        if startAttempt?.transactionID == report.transactionID {
            startAttempt = nil
        }
        if automaticReconnectInProgress {
            if let incidentID = activeReconnectIncidentID {
                ReconnectIncidentJournal.finish(
                    incidentID: incidentID,
                    outcome: "recovered",
                    transactionID: report.transactionID
                )
                stableResetIncidentID = incidentID
            }
            activeReconnectIncidentID = nil
        }
        automaticReconnectInProgress = false
        automaticReconnectTrigger = nil
        automaticReconnectAttemptKind = nil
        pendingInitialRetryTrigger = nil
        automaticReconnectTransactionID = nil
        automaticReconnectUnderlayWaitEvidence = nil
        cancelAutomaticReconnectRetry(resetAttempts: false)
        // A wake or slow-tail attempt that connected ends the parked epoch;
        // its budget still needs five stable minutes to reset.
        clearParkedRecovery()
        if isNewSession || stableConnectionResetWorkItem == nil {
            scheduleStableConnectionReset(
                transactionID: report.transactionID
            )
        }
        startUnderlayMonitoringIfNeeded()
    }

    private func scheduleStableConnectionReset(
        transactionID: String
    ) {
        cancelStableConnectionReset(clearIncident: false)
        guard automaticRecoveryLedger.attemptsUsed > 0 else {
            stableResetIncidentID = nil
            return
        }
        let resetAt = Date().addingTimeInterval(
            automaticReconnectRetryPolicy.stableResetInterval
        )
        stableConnectionResetAt = resetAt
        let incidentID = stableResetIncidentID
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stableConnectionResetWorkItem = nil
            self.stableConnectionResetAt = nil
            guard
                self.connectedSessionTransactionID == transactionID,
                self.currentTransactionID == transactionID,
                self.lastPublishedRuntimeStatus == "connected",
                self.manager?.connection.status == .connected
            else {
                return
            }
            self.automaticRecoveryLedger.stableReset()
            if let incidentID {
                ReconnectIncidentJournal.append(
                    incidentID: incidentID,
                    type: "retry-budget-reset",
                    transactionID: transactionID,
                    message:
                        "Connection remained stable for five minutes"
                )
            }
            self.stableResetIncidentID = nil
            appLog(
                "Transparent Proxy automatic reconnect budget reset "
                    + "after 300s stable transaction=\(transactionID)"
            )
        }
        stableConnectionResetWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now()
                + automaticReconnectRetryPolicy.stableResetInterval,
            execute: work
        )
    }

    private func cancelStableConnectionReset(
        clearIncident: Bool = true
    ) {
        stableConnectionResetWorkItem?.cancel()
        stableConnectionResetWorkItem = nil
        stableConnectionResetAt = nil
        if clearIncident {
            stableResetIncidentID = nil
        }
    }

    /// Network Extension 的 `connected` 只是一条系统事实。对外状态必须再经过
    /// 当前 transaction 的 committed report 与 ingress takeover 门禁。
    @discardableResult
    private func publishRuntimeStatus(
        _ systemStatus: String,
        error: String?,
        report explicitReport: ConnectionReport? = nil
    ) -> String {
        let report = explicitReport ?? ConnectionReportJournal.read()
        let runtimeStatus = TransparentProxyRuntimeGate.resolve(
            systemStatus: systemStatus,
            report: report,
            activeTransactionID: activeTransactionID,
            previousStatus: lastPublishedRuntimeStatus
        )
        lastPublishedRuntimeStatus = runtimeStatus
        statusHandler?(runtimeStatus, error)
        return runtimeStatus
    }

    private var hostIntentActive: Bool {
        startIntentID != nil
            || automaticReconnectInProgress
            || activeScenarioSwitch != nil
    }

    private func ownership(
        of report: ConnectionReport
    ) -> TransactionOwnership {
        hostOwnedTransactionIDs.contains(report.transactionID)
            ? .thisHost
            : .inherited
    }

    private static func systemSessionState(
        _ manager: NETransparentProxyManager?
    ) -> SystemProxySessionState {
        guard let manager else { return .absent }
        switch manager.connection.status {
        case .invalid, .disconnected:
            return .inactive
        default:
            return .active
        }
    }

    /// Status synchronization may arrive late (for example a wake sync whose
    /// preferences load stalls). It reads the journal at callback time and may
    /// only act on facts: a takeover macOS no longer has, a session this Host
    /// stopped, or a transaction an earlier Host process left unfinished.
    /// Anything this Host is still starting, reconnecting or switching belongs
    /// to the live state machine.
    @discardableResult
    private func reconcilePersistedTransactionIfNeeded(
        _ manager: NETransparentProxyManager?
    ) -> Bool {
        guard let report = ConnectionReportJournal.read() else {
            return false
        }
        let disposition = PersistedTransactionReconciliation.decide(
            report: report,
            ownership: ownership(of: report),
            systemSession: Self.systemSessionState(manager),
            hostIntentActive: hostIntentActive
        )
        switch disposition {
        case .none:
            return false
        case .adoptCommittedSession:
            hostOwnedTransactionIDs.insert(report.transactionID)
            return false
        case .markProviderSessionLost:
            currentTransactionID = report.transactionID
            finishInterruptedTransactionRecovery(
                transactionID: report.transactionID,
                error: .providerSessionLost,
                code: "provider-session-lost",
                taskID: "ingress:transparent-proxy"
            )
            return false
        case .finishWithdrawnTransaction:
            finishWithdrawnTransaction(
                transactionID: report.transactionID
            )
            return false
        case let .recoverInterrupted(stopSystemSession):
            currentTransactionID = report.transactionID
            guard stopSystemSession, let manager else {
                finishInterruptedTransactionRecovery(
                    transactionID: report.transactionID
                )
                return false
            }
            beginReportPolling(transactionID: report.transactionID)
            recoveringTransactionID = report.transactionID
            updateReport(transactionID: report.transactionID) {
                $0.setState(.rollingBack)
            }
            publishRuntimeStatus(
                "disconnecting",
                error: ManagerError.interruptedTransactionRecovered
                    .localizedDescription
            )
            manager.connection.stopVPNTunnel()
            return true
        }
    }

    /// Completes a transaction this Host stopped before its Provider finished
    /// the report. macOS has confirmed that no session remains, so no other
    /// writer can complete it.
    private func finishWithdrawnTransaction(transactionID: String) {
        updateReport(transactionID: transactionID) { report in
            if ![.rollingBack, .rolledBack].contains(report.state) {
                report.setState(.rollingBack)
            }
            report.rollbackSessionTasks(
                systemTakeoverRemoved: true,
                cleanupComplete: true,
                finalState: report.error == nil ? .cancelled : .failed
            )
        }
    }

    private func finishInterruptedTransactionRecovery(
        transactionID: String,
        error: ManagerError = .interruptedTransactionRecovered,
        code: String = "interrupted-transaction-recovered",
        taskID: String = ""
    ) {
        updateReport(transactionID: transactionID) { report in
            report.setState(.rollingBack)
            report.fail(
                code: code,
                message: error.localizedDescription,
                taskID: taskID.isEmpty
                    ? report.currentTask?.id ?? ""
                    : taskID
            )
            report.rollbackSessionTasks(
                systemTakeoverRemoved: true,
                cleanupComplete: true,
                finalState: .failed
            )
        }
    }

    private func finishOrphanedTransactionIfNeeded() {
        guard
            let report = ConnectionReportJournal.read(),
            ConnectionReportLiveProjection.shouldAdoptPersisted(
                report,
                currentTransactionID: currentTransactionID
            )
        else {
            return
        }
        currentTransactionID = report.transactionID
        reconcilePersistedTransactionIfNeeded(nil)
    }

    private func startUnderlayMonitoringIfNeeded() {
        guard
            underlayMonitor == nil,
            let baseline = activeUnderlay,
            requestedProfileJSON != nil,
            startIntentID != nil
        else {
            return
        }
        startUnderlayMonitoring(
            baseline: baseline,
            committedBaseline: baseline
        )
    }

    /// `baseline` is the newest snapshot already handed to the epoch
    /// pipeline, so the same sample is not reported twice. `committedBaseline`
    /// is what the committed generation actually runs on; only it may prove
    /// after a wake that the running state is still current. The two differ
    /// while a candidate prepares and after an epoch failed to commit.
    private func startUnderlayMonitoring(
        baseline: HostUnderlaySnapshot,
        committedBaseline: HostUnderlaySnapshot
    ) {
        guard underlayMonitor == nil,
              requestedProfileJSON != nil,
              startIntentID != nil else {
            return
        }
        let monitor = HostUnderlayMonitor(
            baseline: baseline,
            committedBaseline: committedBaseline
        ) {
            [weak self] snapshot, connectivityRestored in
            self?.handleUnderlayChange(
                snapshot,
                connectivityRestored: connectivityRestored
            )
        }
        underlayMonitor = monitor
        monitor.start()
    }

    private func stopUnderlayMonitoring() {
        underlayMonitor?.cancel()
        underlayMonitor = nil
    }

    private func handleUnderlayChange(
        _ underlay: HostUnderlaySnapshot,
        connectivityRestored: Bool
    ) {
        guard
            requestedProfileJSON != nil,
            startIntentID != nil,
            manager?.connection.status == .connected
        else {
            return
        }
        latestCapturedUnderlay = underlay
        var changeKinds = activeUnderlay?
            .differenceKinds(comparedTo: underlay)
            ?? []
        if connectivityRestored {
            changeKinds.append("connectivity-restored")
        }
        appLog(
            "Transparent Proxy underlay changed "
                + "\(activeUnderlay?.defaultInterface.name ?? "unknown")"
                + " -> \(underlay.defaultInterface.name) "
                + "kinds=\(changeKinds.joined(separator: ",")); "
                + "scheduling network epoch"
        )
        // HostUnderlayMonitor has already stopped itself at this point. Start
        // a fresh observer from the newest sample so another physical change
        // can supersede a candidate that is still preparing. The committed
        // generation keeps its own Underlay until a Switch commits; if this
        // epoch fails, a full wake must not mistake the uncommitted sample
        // for proof that the committed generation is current.
        underlayMonitor = nil
        startUnderlayMonitoring(
            baseline: underlay,
            committedBaseline: activeUnderlay ?? underlay
        )
        underlayChangeHandler?(
            underlay.epochFingerprint,
            connectivityRestored
        )
    }

    // MARK: - Parked automatic recovery

    private func recoveryEpoch(
        scenarioID: String,
        underlay: HostUnderlaySnapshot?
    ) -> AutomaticRecoveryEpoch {
        AutomaticRecoveryEpoch(
            scenarioID: scenarioID,
            underlayFingerprint: underlay?.epochFingerprint ?? "",
            connectivityGeneration:
                automaticRecoveryLedger.connectivityGeneration
        )
    }

    private var hostHoldsConnectionIntent: Bool {
        requestedProfileJSON != nil && startIntentID != nil
    }

    /// The budget of this epoch ended with a network-related failure, or a
    /// wake / slow-tail attempt inside the parked epoch failed again. The
    /// runtime stays disconnected with takeover removed; the connection
    /// intent and the open incident are kept.
    private func enterParkedRecovery(
        report: ConnectionReport,
        failedAttempt: AutomaticRecoveryAttemptKind?,
        originalTrigger: AutomaticReconnectTrigger?,
        message: String?
    ) -> Bool {
        let now = Date()
        let fallbackUnderlay = latestCapturedUnderlay ?? activeUnderlay
        let singleAttempt = failedAttempt?.isSingleParkedAttempt == true
        let epoch = singleAttempt
            ? automaticRecoveryLedger.parking?.epoch
                ?? recoveryEpoch(
                    scenarioID: report.scenario.id,
                    underlay: fallbackUnderlay
                )
            : recoveryEpoch(
                scenarioID: report.scenario.id,
                underlay: fallbackUnderlay
            )
        guard automaticRecoveryLedger.park(
            epoch: epoch,
            failure: report.error,
            at: now
        ) else {
            return false
        }
        if !singleAttempt {
            parkedRecoveryTrigger = originalTrigger ?? .automaticConnection
            parkedUnderlay = fallbackUnderlay
        }
        if let incidentID = activeReconnectIncidentID {
            switch failedAttempt {
            case .wake?, .tail?:
                let attempt: Int
                if case let .tail(number)? = failedAttempt {
                    attempt = number
                } else {
                    attempt = 0
                }
                ReconnectIncidentJournal.recordAttemptFailed(
                    incidentID: incidentID,
                    attempt: attempt,
                    transactionID: report.transactionID,
                    failureCode: report.error?.code
                )
            case .budget?, nil:
                ReconnectIncidentJournal.recordParked(
                    incidentID: incidentID,
                    attemptsUsed: automaticRecoveryLedger.attemptsUsed,
                    transactionID: report.transactionID,
                    failureCode: report.error?.code
                )
            }
        }
        appLog(
            "Transparent Proxy automatic reconnect parked "
                + "after=\(failedAttempt?.name ?? "budget") "
                + "attempts=\(automaticRecoveryLedger.attemptsUsed) "
                + "tail=\(automaticRecoveryLedger.parking?.tailAttemptsUsed ?? 0) "
                + "transaction=\(report.transactionID) code="
                + ReconnectIncidentFailureCode.recordable(report.error?.code)
        )
        publishRuntimeStatus("disconnected", error: message)
        captureParkedUnderlay(fallback: fallbackUnderlay)
        return true
    }

    /// Re-sample after XDial's own attempt has rolled back, so the observer
    /// and the parked epoch start from facts the attempt can no longer touch.
    private func captureParkedUnderlay(
        fallback: HostUnderlaySnapshot?
    ) {
        let token = UUID()
        parkedUnderlayCaptureToken = token
        HostUnderlayCapture.start { [weak self] result in
            guard let self,
                  self.parkedUnderlayCaptureToken == token,
                  self.isAutomaticRecoveryParked else {
                return
            }
            self.parkedUnderlayCaptureToken = nil
            var baseline = fallback
            if case let .success(snapshot) = result {
                self.latestCapturedUnderlay = snapshot
                self.automaticRecoveryLedger.absorbParkedUnderlay(
                    fingerprint: snapshot.epochFingerprint
                )
                baseline = snapshot
            }
            if let baseline {
                self.parkedUnderlay = baseline
                self.startParkedUnderlayMonitoring(baseline: baseline)
            }
            self.scheduleParkedTail()
            self.scheduleDeferredGrantIfNeeded()
        }
    }

    private func startParkedUnderlayMonitoring(
        baseline: HostUnderlaySnapshot
    ) {
        stopParkedUnderlayMonitoring()
        guard isAutomaticRecoveryParked, hostHoldsConnectionIntent else {
            return
        }
        let monitor = HostUnderlayMonitor(
            baseline: baseline,
            committedBaseline: parkedUnderlay ?? baseline
        ) { [weak self] snapshot, connectivityRestored in
            self?.handleParkedUnderlayChange(
                snapshot,
                connectivityRestored: connectivityRestored
            )
        }
        parkedUnderlayMonitor = monitor
        if powerLifecycleGate.defersNetworkWork {
            monitor.noteSystemSleep()
        }
        monitor.start()
    }

    private func stopParkedUnderlayMonitoring() {
        parkedUnderlayMonitor?.cancel()
        parkedUnderlayMonitor = nil
    }

    /// The parked observer only reports host facts. AppState settles them in
    /// the same quiet window as SSID and hands the epoch back through
    /// `resumeParkedRecovery`, where the ledger decides.
    private func handleParkedUnderlayChange(
        _ underlay: HostUnderlaySnapshot,
        connectivityRestored: Bool
    ) {
        guard isAutomaticRecoveryParked, hostHoldsConnectionIntent else {
            return
        }
        latestCapturedUnderlay = underlay
        var changeKinds = parkedUnderlay?
            .differenceKinds(comparedTo: underlay)
            ?? []
        if connectivityRestored {
            changeKinds.append("connectivity-restored")
        }
        appLog(
            "Transparent Proxy underlay changed while automatic reconnect "
                + "is parked "
                + "\(parkedUnderlay?.defaultInterface.name ?? "unknown")"
                + " -> \(underlay.defaultInterface.name) "
                + "kinds=\(changeKinds.joined(separator: ",")); "
                + "scheduling network epoch"
        )
        parkedUnderlayMonitor = nil
        startParkedUnderlayMonitoring(baseline: underlay)
        underlayChangeHandler?(
            underlay.epochFingerprint,
            connectivityRestored
        )
    }

    /// A settled host network epoch while parked. Returns false when there
    /// is no parked recovery to hand it to.
    @discardableResult
    func resumeParkedRecovery(
        scenarioID: String,
        underlayFingerprint: String,
        connectivityRestored: Bool
    ) -> Bool {
        guard isAutomaticRecoveryParked else { return false }
        let decision = automaticRecoveryLedger.resume(
            .networkEpoch(connectivityRestored: connectivityRestored),
            observed: AutomaticRecoveryObservation(
                scenarioID: scenarioID,
                underlayFingerprint: underlayFingerprint
            ),
            systemAsleep: powerLifecycleGate.defersNetworkWork,
            at: Date()
        )
        applyParkedRecoveryDecision(decision, source: "network-epoch")
        return true
    }

    /// A wake keeps exactly one attempt for an unchanged parked epoch; the
    /// attempt's preparation upgrades it to a full budget when the settled
    /// network turns out to have changed.
    @discardableResult
    func resumeParkedRecoveryAfterWake() -> Bool {
        startParkedSingleAttempt(.wake)
    }

    /// Ends parking without an attempt, e.g. when the target Scenario was
    /// removed from the Profile.
    func endParkedRecovery(code: String) {
        guard automaticRecoveryLedger.isParked else { return }
        let wasAttempting = automaticReconnectInProgress
        if wasAttempting {
            automaticReconnectInProgress = false
            automaticReconnectTrigger = nil
            automaticReconnectAttemptKind = nil
            automaticReconnectTransactionID = nil
            automaticReconnectUnderlayWaitEvidence = nil
            cancelAutomaticReconnectRetry(resetAttempts: false)
        }
        clearParkedRecovery()
        if let incidentID = activeReconnectIncidentID {
            ReconnectIncidentJournal.finish(
                incidentID: incidentID,
                outcome: "cancelled",
                code: code
            )
        }
        activeReconnectIncidentID = nil
        appLog("Transparent Proxy parked automatic reconnect ended code=\(code)")
        if wasAttempting || lastPublishedRuntimeStatus != "disconnected" {
            publishRuntimeStatus("disconnected", error: nil)
        }
    }

    private func applyParkedRecoveryDecision(
        _ decision: AutomaticRecoveryDecision,
        source: String
    ) {
        switch decision {
        case let .grant(reason):
            beginGrantedRecovery(reason)
        case let .deferred(reason, notBefore):
            if let incidentID = activeReconnectIncidentID {
                ReconnectIncidentJournal.recordGrantDeferred(
                    incidentID: incidentID,
                    reason: reason,
                    until: notBefore
                )
            }
            appLog(
                "Transparent Proxy parked reconnect grant deferred "
                    + "source=\(source) reason=\(reason.rawValue) "
                    + "until=\(ISO8601DateFormatter().string(from: notBefore))"
            )
            scheduleDeferredGrantIfNeeded()
        case let .singleAttempt(kind):
            appLog(
                "Transparent Proxy parked reconnect ignored single "
                    + "\(kind.name) attempt from source=\(source)"
            )
        case let .rejected(rejection):
            appLog(
                "Transparent Proxy parked reconnect not resumed "
                    + "source=\(source) reason=\(rejection.rawValue)"
            )
        }
    }

    /// Leaves parking with a fresh budget. The attempts reuse the ordinary
    /// retry path, including its Underlay wait and settled preparation.
    private func beginGrantedRecovery(
        _ reason: AutomaticRecoveryGrantReason
    ) {
        stopParkedUnderlayMonitoring()
        cancelParkedTimers()
        parkedUnderlayCaptureToken = nil
        guard let failedTransactionID = currentTransactionID,
              hostHoldsConnectionIntent,
              manager != nil else {
            appLog(
                "Transparent Proxy granted reconnect budget has no "
                    + "recoverable transaction reason=\(reason.rawValue)"
            )
            return
        }
        automaticReconnectInProgress = true
        automaticReconnectTrigger = reason == .userRetry
            ? parkedRecoveryTrigger ?? .automaticConnection
            : .underlayChange
        automaticReconnectAttemptKind = nil
        parkedUnderlay = nil
        if let incidentID = activeReconnectIncidentID {
            ReconnectIncidentJournal.recordBudgetGranted(
                incidentID: incidentID,
                reason: reason
            )
        }
        appLog(
            "Transparent Proxy automatic reconnect budget granted "
                + "reason=\(reason.rawValue) "
                + "automatic-grants-last-hour="
                + "\(automaticRecoveryLedger.rateLimitedGrantCount(at: Date()))"
        )
        publishRuntimeStatus("reconnecting", error: nil)
        scheduleAutomaticReconnectRetry(
            failedTransactionID: failedTransactionID,
            failureCode: ConnectionReportJournal.read()?.error?.code,
            delay: reason == .userRetry
                ? 0
                : automaticReconnectRetryPolicy.delayForNextAttempt(
                    attemptsUsed: 0
                ) ?? automaticReconnectRetryPolicy.underlayWaitRetryDelay
        )
    }

    /// Starts a wake or slow-tail attempt inside the parked epoch. Its kind
    /// is provisional until preparation compares the settled facts with the
    /// parked epoch.
    @discardableResult
    private func startParkedSingleAttempt(
        _ trigger: AutomaticRecoveryResumeTrigger
    ) -> Bool {
        guard isAutomaticRecoveryParked,
              !powerLifecycleGate.defersNetworkWork,
              automaticReconnectRetryToken == nil,
              automaticReconnectPreparationGate.token == nil,
              let failedTransactionID = currentTransactionID,
              hostHoldsConnectionIntent,
              manager != nil else {
            return false
        }
        let kind: AutomaticRecoveryAttemptKind
        switch trigger {
        case .wake:
            kind = .wake
        case .slowTail:
            guard automaticRecoveryLedger.nextTailDelay != nil else {
                return false
            }
            kind = .tail(
                (automaticRecoveryLedger.parking?.tailAttemptsUsed ?? 0) + 1
            )
        case .networkEpoch:
            return false
        }
        stopParkedUnderlayMonitoring()
        parkedTailWorkItem?.cancel()
        parkedTailWorkItem = nil
        parkedTailAt = nil
        parkedUnderlayCaptureToken = nil
        automaticReconnectInProgress = true
        automaticReconnectTrigger =
            parkedRecoveryTrigger ?? .automaticConnection
        automaticReconnectAttemptKind = nil
        appLog(
            "Transparent Proxy parked automatic reconnect "
                + "\(kind.name) attempt preparing"
        )
        publishRuntimeStatus("reconnecting", error: nil)
        scheduleAutomaticReconnectRetry(
            failedTransactionID: failedTransactionID,
            delay: 0,
            recordSchedule: false,
            kind: kind
        )
        return true
    }

    /// Resolves the attempt kind once its preparation settled. A changed
    /// epoch upgrades a wake / tail attempt to budget attempt 1; a rejected
    /// one returns to parking without starting a transaction.
    private func resolvePreparedAttemptKind(
        _ kind: AutomaticRecoveryAttemptKind,
        prepared: AutomaticReconnectPreparation
    ) -> AutomaticRecoveryAttemptKind? {
        guard kind.isSingleParkedAttempt else { return kind }
        let deferredBefore = automaticRecoveryLedger.parking?.deferredGrant
        let decision = automaticRecoveryLedger.resume(
            kind == .wake ? .wake : .slowTail,
            observed: AutomaticRecoveryObservation(
                scenarioID: prepared.scenarioID,
                underlayFingerprint: prepared.underlayFingerprint
            ),
            systemAsleep: powerLifecycleGate.defersNetworkWork,
            at: Date()
        )
        switch decision {
        case let .grant(reason):
            cancelParkedTimers()
            automaticReconnectTrigger = .underlayChange
            parkedUnderlay = nil
            if let incidentID = activeReconnectIncidentID {
                ReconnectIncidentJournal.recordBudgetGranted(
                    incidentID: incidentID,
                    reason: reason
                )
            }
            appLog(
                "Transparent Proxy parked \(kind.name) attempt found a new "
                    + "epoch; budget granted reason=\(reason.rawValue)"
            )
            return automaticRecoveryLedger.nextAttempt.map {
                AutomaticRecoveryAttemptKind.budget($0)
            }
        case let .singleAttempt(resolved):
            if let deferred = automaticRecoveryLedger.parking?.deferredGrant,
               deferred != deferredBefore {
                if let incidentID = activeReconnectIncidentID {
                    ReconnectIncidentJournal.recordGrantDeferred(
                        incidentID: incidentID,
                        reason: deferred.reason,
                        until: deferred.notBefore
                    )
                }
            }
            return resolved
        case .deferred:
            return kind
        case let .rejected(rejection):
            appLog(
                "Transparent Proxy parked \(kind.name) attempt not started "
                    + "reason=\(rejection.rawValue)"
            )
            returnToParkingWithoutAttempt()
            return nil
        }
    }

    /// A scheduled attempt cannot start because the host's current
    /// transaction is no longer the one it was scheduled after. A wake /
    /// tail attempt simply returns to parking; a budget step is decided by
    /// the transaction that is current now, so recovery cannot hang waiting
    /// for an attempt that never gets its own transaction.
    private func abandonScheduledAttempt(
        _ kind: AutomaticRecoveryAttemptKind
    ) {
        guard automaticReconnectInProgress else { return }
        appLog(
            "Transparent Proxy automatic reconnect \(kind.name) attempt "
                + "abandoned before its transaction; current="
                + (currentTransactionID ?? "none")
        )
        if kind.isSingleParkedAttempt, automaticRecoveryLedger.isParked {
            returnToParkingWithoutAttempt()
            return
        }
        automaticRecoveryOutcomeGate.await(currentTransactionID)
        handleAutomaticReconnectAfterDisconnect(
            report: ConnectionReportJournal.read()
        )
    }

    /// The attempt failed on the host before its transaction existed (its
    /// plan or journal could not be created). No report describes it, so
    /// the previous attempt's failed report must not decide; a plan that
    /// cannot be built is a configuration-class stop.
    private func failAutomaticRecoveryBeforeTransaction(
        _ error: Error,
        attempt: AutomaticRecoveryAttemptKind
    ) {
        appLog(
            "Transparent Proxy automatic reconnect \(attempt.name) attempt "
                + "could not create its transaction: "
                + error.localizedDescription
        )
        automaticReconnectInProgress = false
        automaticReconnectTrigger = nil
        automaticReconnectAttemptKind = nil
        automaticReconnectTransactionID = nil
        automaticReconnectUnderlayWaitEvidence = nil
        cancelAutomaticReconnectRetry(resetAttempts: false)
        clearParkedRecovery()
        if let incidentID = activeReconnectIncidentID {
            ReconnectIncidentJournal.finish(
                incidentID: incidentID,
                outcome: "failed",
                code: "host-start-failed",
                message: error.localizedDescription
            )
        }
        activeReconnectIncidentID = nil
        publishRuntimeStatus(
            "disconnected",
            error: error.localizedDescription
        )
    }

    private func returnToParkingWithoutAttempt() {
        automaticReconnectInProgress = false
        automaticReconnectTrigger = nil
        automaticReconnectAttemptKind = nil
        automaticReconnectTransactionID = nil
        automaticReconnectUnderlayWaitEvidence = nil
        cancelAutomaticReconnectRetry(resetAttempts: false)
        guard automaticRecoveryLedger.isParked else {
            publishRuntimeStatus("disconnected", error: nil)
            return
        }
        publishRuntimeStatus(
            "disconnected",
            error: ConnectionReportJournal.read()?.error?.message
        )
        // No transaction ran, so there is nothing of XDial's to absorb.
        // Resume observing from the parked epoch's own Underlay: a network
        // that changed meanwhile (for example across sleep) is then reported
        // as a host epoch and earns its full budget.
        guard let parkedUnderlay else {
            captureParkedUnderlay(fallback: nil)
            return
        }
        startParkedUnderlayMonitoring(baseline: parkedUnderlay)
        scheduleParkedTail()
        scheduleDeferredGrantIfNeeded()
    }

    private func scheduleParkedTail() {
        parkedTailWorkItem?.cancel()
        parkedTailWorkItem = nil
        guard isAutomaticRecoveryParked,
              let delay = automaticRecoveryLedger.nextTailDelay else {
            parkedTailAt = nil
            return
        }
        parkedTailAt = Date().addingTimeInterval(delay)
        armParkedTailTimer()
    }

    private func armParkedTailTimer() {
        parkedTailWorkItem?.cancel()
        parkedTailWorkItem = nil
        guard let parkedTailAt,
              isAutomaticRecoveryParked,
              !powerLifecycleGate.defersNetworkWork else {
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.parkedTailWorkItem = nil
            guard self.parkedTailAt == parkedTailAt else { return }
            if !self.startParkedSingleAttempt(.slowTail) {
                // Busy with another attempt; re-parking reschedules.
                self.parkedTailAt = nil
            }
        }
        parkedTailWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, parkedTailAt.timeIntervalSinceNow),
            execute: work
        )
    }

    private func scheduleDeferredGrantIfNeeded() {
        deferredGrantWorkItem?.cancel()
        deferredGrantWorkItem = nil
        guard isAutomaticRecoveryParked,
              !powerLifecycleGate.defersNetworkWork,
              let deferred = automaticRecoveryLedger.parking?.deferredGrant
        else {
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.deferredGrantWorkItem = nil
            guard self.isAutomaticRecoveryParked else { return }
            self.applyParkedRecoveryDecision(
                self.automaticRecoveryLedger.reevaluateDeferredGrant(
                    systemAsleep: self.powerLifecycleGate.defersNetworkWork,
                    at: Date()
                ),
                source: "deferred-grant"
            )
        }
        deferredGrantWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now()
                + max(0, deferred.notBefore.timeIntervalSinceNow),
            execute: work
        )
    }

    private func cancelParkedTimers() {
        parkedTailWorkItem?.cancel()
        parkedTailWorkItem = nil
        parkedTailAt = nil
        deferredGrantWorkItem?.cancel()
        deferredGrantWorkItem = nil
    }

    private func clearParkedRecovery() {
        stopParkedUnderlayMonitoring()
        cancelParkedTimers()
        parkedUnderlayCaptureToken = nil
        parkedUnderlay = nil
        parkedRecoveryTrigger = nil
        automaticRecoveryLedger.endParking()
    }

    /// Quitting ends a parked recovery; close its incident so the journal
    /// does not keep an open "parked" record for a process that is gone.
    @objc private func applicationWillTerminate(_ notification: Notification) {
        guard automaticRecoveryLedger.isParked else { return }
        clearParkedRecovery()
        if let incidentID = activeReconnectIncidentID {
            ReconnectIncidentJournal.finish(
                incidentID: incidentID,
                outcome: "cancelled",
                code: "application-quit"
            )
        }
        activeReconnectIncidentID = nil
    }

    // MARK: - Stale committed generation

    /// After an automatic network epoch's Switch finally failed, reports
    /// whether the still-committed generation's default interface is absent
    /// from the current Underlay. Only a successful capture of the same
    /// settled epoch counts as evidence.
    func committedDefaultInterfaceIsAbsent(
        expectedUnderlayFingerprint: String,
        completion: @escaping (Bool) -> Void
    ) {
        guard manager?.connection.status == .connected,
              let committed = activeUnderlay,
              let transactionID = currentTransactionID,
              activeScenarioSwitch == nil,
              !automaticReconnectInProgress else {
            completion(false)
            return
        }
        HostUnderlayCapture.start { [weak self] result in
            guard let self,
                  case let .success(snapshot) = result,
                  snapshot.epochFingerprint == expectedUnderlayFingerprint,
                  self.currentTransactionID == transactionID,
                  self.manager?.connection.status == .connected,
                  self.activeScenarioSwitch == nil,
                  !self.automaticReconnectInProgress else {
                completion(false)
                return
            }
            self.latestCapturedUnderlay = snapshot
            let absent = StaleCommittedGenerationPolicy.shouldEscalate(
                switchFinallyFailed: true,
                automaticEpoch: true,
                committedDefaultInterface: .init(
                    name: committed.defaultInterface.name,
                    index: committed.defaultInterface.index
                ),
                currentInterfaces: snapshot.interfaces.map {
                    .init(name: $0.name, index: $0.index)
                }
            )
            if absent {
                appLog(
                    "Transparent Proxy committed generation default "
                        + committed.defaultInterface.name
                        + " is absent from the current Underlay "
                        + "(default \(snapshot.defaultInterface.name)) "
                        + "transaction=\(transactionID)"
                )
            }
            completion(absent)
        }
    }

    /// An attempt is scheduled (possibly held across sleep) or its Underlay
    /// capture / settled preparation is running; it has no transaction yet.
    private var automaticRecoveryAttemptPending: Bool {
        automaticReconnectRetryToken != nil
            || automaticReconnectPreparationGate.token != nil
    }

    private func handleAutomaticReconnectAfterDisconnect(
        report: ConnectionReport?
    ) {
        switch automaticRecoveryOutcomeGate.decide(
            recoveryInProgress: automaticReconnectInProgress,
            attemptPending: automaticRecoveryAttemptPending,
            report: report,
            currentTransactionID: currentTransactionID,
            systemSessionInactive:
                Self.systemSessionState(manager) != .active
        ) {
        case .notRecovering:
            return
        case .awaitOutcome:
            publishRuntimeStatus("reconnecting", error: nil)
            return
        case .attemptOutcome:
            break
        }
        guard let report else { return }
        // Consumed: a duplicate of this report decides nothing further, and
        // the decided attempt's transaction can no longer prove recovery.
        automaticRecoveryOutcomeGate.reset()
        automaticReconnectTransactionID = nil
        consumedRecoveryTransactionID = report.transactionID
        let outcomeMessage = recoveryOutcomeMessage(report)
        guard let trigger = automaticReconnectTrigger else {
            finishAutomaticReconnect(
                report: report,
                message: outcomeMessage
            )
            return
        }
        // A wake or slow-tail attempt is a single attempt inside the parked
        // epoch; its failure re-parks instead of opening budget retries.
        if automaticReconnectAttemptKind?.isSingleParkedAttempt != true,
           let delay = automaticReconnectRetryPolicy.delay(
            after: report,
            attemptsUsed: automaticRecoveryLedger.attemptsUsed,
            trigger: trigger
        ) {
            scheduleAutomaticReconnectRetry(
                failedTransactionID: report.transactionID,
                failureCode: report.error?.code,
                delay: delay,
                outcomeReport: report
            )
            publishRuntimeStatus("reconnecting", error: nil)
            return
        }

        finishAutomaticReconnect(
            report: report,
            message: outcomeMessage
        )
    }

    /// Schedules the next attempt. Without an explicit `kind` it is the next
    /// budget attempt; an Underlay wait reschedules the same kind, so waiting
    /// never consumes budget nor turns a wake / tail attempt into a budget one.
    private func scheduleAutomaticReconnectRetry(
        failedTransactionID: String,
        failureCode: String? = nil,
        delay: TimeInterval,
        recordSchedule: Bool = true,
        kind requestedKind: AutomaticRecoveryAttemptKind? = nil,
        outcomeReport: ConnectionReport? = nil
    ) {
        guard automaticReconnectRetryWorkItem == nil,
              automaticReconnectRetryToken == nil,
              automaticReconnectPreparationGate.token == nil else {
            return
        }
        let kind: AutomaticRecoveryAttemptKind
        if let requestedKind {
            kind = requestedKind
        } else {
            guard let retryNumber =
                automaticRecoveryLedger.nextAttempt else {
                // No budget left for the failure just decided (or for the
                // episode that just opened in an exhausted epoch).
                let report = outcomeReport ?? ConnectionReportJournal.read()
                finishAutomaticReconnect(
                    report: report,
                    message: recoveryOutcomeMessage(report)
                )
                return
            }
            kind = .budget(retryNumber)
        }
        automaticRecoveryOutcomeGate.attemptScheduled()
        if recordSchedule,
           case let .budget(retryNumber) = kind {
            if let incidentID = activeReconnectIncidentID {
                ReconnectIncidentJournal.recordRetryScheduled(
                    incidentID: incidentID,
                    attempt: retryNumber,
                    failedTransactionID: failedTransactionID,
                    failureCode: failureCode,
                    delay: delay
                )
            }
            appLog(
                "Transparent Proxy automatic reconnect retry "
                    + "\(retryNumber) scheduled after \(delay)s "
                    + "failed-transaction=\(failedTransactionID) code="
                    + ReconnectIncidentFailureCode.recordable(failureCode)
            )
        }
        let token = UUID()
        automaticReconnectRetryToken = token
        automaticReconnectRetryAt = Date().addingTimeInterval(delay)
        automaticReconnectRetryKind = kind
        automaticReconnectRetryFailedTransactionID =
            failedTransactionID
        let work = DispatchWorkItem { [weak self] in
            self?.performScheduledAutomaticReconnectRetry(token: token)
        }
        guard !powerLifecycleGate.defersNetworkWork else {
            return
        }
        automaticReconnectRetryWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: work
        )
    }

    /// "Retry now": runs a scheduled retry immediately, or — while parked —
    /// grants a fresh user budget and starts its first attempt at once.
    @discardableResult
    func retryAutomaticReconnectNow() -> Bool {
        guard !powerLifecycleGate.defersNetworkWork else { return false }
        if let token = automaticReconnectRetryToken {
            performScheduledAutomaticReconnectRetry(token: token)
            return true
        }
        guard isAutomaticRecoveryParked else { return false }
        applyParkedRecoveryDecision(
            automaticRecoveryLedger.userRetry(at: Date()),
            source: "user"
        )
        return true
    }

    private func performScheduledAutomaticReconnectRetry(
        token: UUID
    ) {
        guard
            automaticReconnectRetryToken == token,
            let failedTransactionID =
                automaticReconnectRetryFailedTransactionID,
            let scheduledKind = automaticReconnectRetryKind
        else {
            return
        }
        automaticReconnectRetryWorkItem?.cancel()
        automaticReconnectRetryWorkItem = nil
        guard !powerLifecycleGate.defersNetworkWork else {
            return
        }
        automaticReconnectRetryToken = nil
        automaticReconnectRetryAt = nil
        automaticReconnectRetryKind = nil
        automaticReconnectRetryFailedTransactionID = nil
        guard automaticReconnectInProgress else { return }
        guard
            currentTransactionID == failedTransactionID,
            requestedProfileJSON != nil,
            let manager,
            startIntentID != nil
        else {
            abandonScheduledAttempt(scheduledKind)
            return
        }
        guard let preparationID = automaticReconnectPreparationGate.begin()
        else {
            return
        }
        publishRuntimeStatus("reconnecting", error: nil)
        let intentID = UUID()
        startIntentID = intentID
        HostUnderlayCapture.start { [weak self] result in
            guard let self else { return }
            guard
                self.startIntentID == intentID,
                self.automaticReconnectInProgress,
                self.automaticReconnectPreparationGate.isCurrent(preparationID)
            else {
                return
            }
            switch result {
            case let .success(snapshot):
                self.latestCapturedUnderlay = snapshot
                guard !self.powerLifecycleGate.defersNetworkWork,
                      let handler = self.automaticReconnectPreparationHandler else {
                    self.rescheduleAutomaticReconnectPreparation(
                        preparationID: preparationID,
                        failedTransactionID: failedTransactionID,
                        kind: scheduledKind
                    )
                    return
                }
                self.retireScenarioSwitchForAutomaticRecovery()
                handler(snapshot.epochFingerprint) { [weak self] prepared in
                    guard let self,
                          self.automaticReconnectPreparationGate
                            .isCurrent(preparationID),
                          self.startIntentID == intentID,
                          self.automaticReconnectInProgress else {
                        return
                    }
                    guard self.currentTransactionID == failedTransactionID
                    else {
                        _ = self.automaticReconnectPreparationGate
                            .finish(preparationID)
                        self.abandonScheduledAttempt(scheduledKind)
                        return
                    }
                    guard !self.powerLifecycleGate.defersNetworkWork,
                          let prepared,
                          let stableSnapshot = self.latestCapturedUnderlay,
                          stableSnapshot.epochFingerprint
                            == prepared.underlayFingerprint else {
                        self.rescheduleAutomaticReconnectPreparation(
                            preparationID: preparationID,
                            failedTransactionID: failedTransactionID,
                            kind: scheduledKind
                        )
                        return
                    }
                    // Consume once before publishing a new transaction; a
                    // duplicate or cancelled preparation cannot start again.
                    guard self.automaticReconnectPreparationGate
                        .finish(preparationID) else { return }
                    self.automaticReconnectUnderlayWaitEvidence = nil
                    guard let attemptKind = self.resolvePreparedAttemptKind(
                        scheduledKind,
                        prepared: prepared
                    ) else {
                        return
                    }
                    self.requestedProfileJSON = prepared.profileJSON
                    switch attemptKind {
                    case let .budget(retryNumber):
                        guard self.automaticRecoveryLedger.recordStarted(
                            retryNumber
                        ) else {
                            self.abandonScheduledAttempt(attemptKind)
                            return
                        }
                    case .tail:
                        self.automaticRecoveryLedger
                            .recordTailAttemptStarted()
                    case .wake:
                        break
                    }
                    do {
                        let transactionID = try self.beginTransaction(
                            profileJSON: prepared.profileJSON
                        )
                        self.automaticReconnectTransactionID =
                            transactionID
                        self.automaticReconnectAttemptKind = attemptKind
                        // From here only this transaction's settled report
                        // is the attempt's outcome.
                        self.automaticRecoveryOutcomeGate.await(transactionID)
                        if let incidentID = self.activeReconnectIncidentID {
                            if case let .budget(retryNumber) = attemptKind {
                                ReconnectIncidentJournal.append(
                                    incidentID: incidentID,
                                    type: "retry-started",
                                    attempt: retryNumber,
                                    transactionID: transactionID
                                )
                            } else {
                                ReconnectIncidentJournal
                                    .recordSingleAttemptStarted(
                                        incidentID: incidentID,
                                        kind: attemptKind,
                                        transactionID: transactionID
                                    )
                            }
                        }
                        self.updateReport(transactionID: transactionID) {
                            $0.updateTask(
                                id: "underlay:system",
                                state: .ready
                            )
                            $0.setState(.preparing)
                        }
                    } catch {
                        self.failAutomaticRecoveryBeforeTransaction(
                            error,
                            attempt: attemptKind
                        )
                        return
                    }
                    appLog(
                        "Transparent Proxy automatic reconnect "
                            + "\(attemptKind.name) attempt "
                            + "\(Self.attemptNumber(attemptKind)) captured default="
                            + stableSnapshot.defaultInterface.name
                    )
                    self.publishRuntimeStatus("reconnecting", error: nil)
                    self.startConnection(
                        manager,
                        profileJSON: prepared.profileJSON,
                        underlay: stableSnapshot,
                        intentID: intentID,
                        debugFailureStage: nil
                    )
                }
            case let .failure(error):
                guard self.automaticReconnectPreparationGate
                    .finish(preparationID) else { return }
                let captureError = error as? HostUnderlayCaptureError
                self.automaticReconnectUnderlayWaitEvidence =
                    captureError?.evidence
                appLog(
                    "Transparent Proxy automatic reconnect waiting for "
                        + "usable Underlay: \(error.localizedDescription) "
                        + (captureError?.evidence.logSummary ?? "")
                )
                self.scheduleAutomaticReconnectRetry(
                    failedTransactionID: failedTransactionID,
                    delay: self.automaticReconnectRetryPolicy
                        .underlayWaitRetryDelay,
                    recordSchedule: false,
                    kind: scheduledKind
                )
            }
        }
    }

    private static func attemptNumber(
        _ kind: AutomaticRecoveryAttemptKind
    ) -> Int {
        switch kind {
        case let .budget(number), let .tail(number): number
        case .wake: 0
        }
    }

    private func retireScenarioSwitchForAutomaticRecovery() {
        guard let active = activeScenarioSwitch else { return }
        // Recovery is allowed only after the failed Provider rolled back and
        // removed takeover. Its old source/target pair can never reconcile
        // against the new recovery transaction, so retire it locally.
        activeScenarioSwitch = nil
        active.timeoutWorkItem?.cancel()
        active.reconciliationWorkItem?.cancel()
        active.progressWorkItem?.cancel()
        recordScenarioSwitch(
            active,
            status: "failed",
            activeTransactionID: "",
            code: "provider-session-lost",
            message: ManagerError.providerSessionLost.localizedDescription
        )
        active.completionGate.finish(.failure(ManagerError.providerSessionLost))
    }

    private func rescheduleAutomaticReconnectPreparation(
        preparationID: UUID,
        failedTransactionID: String,
        kind: AutomaticRecoveryAttemptKind
    ) {
        guard automaticReconnectPreparationGate.finish(preparationID) else {
            return
        }
        scheduleAutomaticReconnectRetry(
            failedTransactionID: failedTransactionID,
            delay: automaticReconnectRetryPolicy.underlayWaitRetryDelay,
            recordSchedule: false,
            kind: kind
        )
    }

    private func resumeAutomaticReconnectRetryAfterWake() {
        guard automaticReconnectRetryWorkItem == nil,
              let token = automaticReconnectRetryToken,
              automaticReconnectRetryKind != nil,
              automaticReconnectRetryFailedTransactionID != nil else {
            return
        }
        let delay = max(
            0,
            automaticReconnectRetryAt?.timeIntervalSinceNow ?? 0
        )
        let work = DispatchWorkItem { [weak self] in
            self?.performScheduledAutomaticReconnectRetry(token: token)
        }
        automaticReconnectRetryWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: work
        )
    }

    private func finishAutomaticReconnect(
        report: ConnectionReport?,
        message: String?
    ) {
        // Exhausted only when the last failure would still have qualified; a
        // terminal or unknown code stops the recovery even on the last attempt.
        let failureQualified = report.map { report in
            automaticReconnectTrigger.map {
                automaticReconnectRetryPolicy.qualifies(report, trigger: $0)
            } ?? false
        } ?? true
        let failedAttempt = automaticReconnectAttemptKind
        let singleParkedAttempt =
            failedAttempt?.isSingleParkedAttempt == true
        let exhausted =
            automaticRecoveryLedger.isExhausted
                && failureQualified
                && !singleParkedAttempt
        let originalTrigger = automaticReconnectTrigger
        let failureCode = report?.error?.code ?? ""
        appLog(
            "Transparent Proxy automatic reconnect "
                + (exhausted
                    ? "exhausted"
                    : singleParkedAttempt
                        ? "\(failedAttempt?.name ?? "single") attempt failed"
                        : "stopped")
                + " attempts=\(automaticRecoveryLedger.attemptsUsed)"
                + " transaction=\(report?.transactionID ?? "")"
                + " code="
                + ReconnectIncidentFailureCode.recordable(failureCode)
        )
        automaticReconnectInProgress = false
        automaticReconnectTrigger = nil
        automaticReconnectAttemptKind = nil
        automaticReconnectTransactionID = nil
        automaticReconnectUnderlayWaitEvidence = nil
        cancelAutomaticReconnectRetry(resetAttempts: false)
        // A network-related failure that used up the epoch's budget, or that
        // ended a wake / tail attempt inside the parked epoch, parks with the
        // intent kept. Identity, configuration and unclassified failures stop
        // here with their own error and end any parking.
        if failureQualified,
           exhausted || singleParkedAttempt,
           hostHoldsConnectionIntent,
           let report,
           enterParkedRecovery(
               report: report,
               failedAttempt: failedAttempt,
               originalTrigger: originalTrigger,
               message: message
           ) {
            return
        }
        clearParkedRecovery()
        if let incidentID = activeReconnectIncidentID {
            ReconnectIncidentJournal.finish(
                incidentID: incidentID,
                outcome: exhausted ? "exhausted" : "failed",
                transactionID: report?.transactionID ?? "",
                code: failureCode,
                message: message ?? ""
            )
        }
        activeReconnectIncidentID = nil
        publishRuntimeStatus(
            "disconnected",
            error: message
        )
    }

    private func cancelAutomaticReconnectRetry(
        resetAttempts: Bool
    ) {
        automaticReconnectPreparationGate.cancel()
        automaticReconnectRetryWorkItem?.cancel()
        automaticReconnectRetryWorkItem = nil
        automaticReconnectRetryToken = nil
        automaticReconnectRetryAt = nil
        automaticReconnectRetryKind = nil
        automaticReconnectRetryFailedTransactionID = nil
        automaticRecoveryOutcomeGate.reset()
        if resetAttempts {
            automaticRecoveryLedger.stableReset()
        }
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension extension: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        guard request === activationRequest,
              activationPurpose == .installation else { return }
        activationStatusHandler?(.waitingForApproval)
        Self.openExtensionApprovalSettings()
    }

    static func openExtensionApprovalSettings() {
        if let url = URL(
            string:
                "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        if request === deactivationRequest {
            guard result == .completed else {
                finishDeactivation(
                    .failure(ManagerError.deactivationDeferredBySystem)
                )
                return
            }
            finishDeactivation(.success(()))
            return
        }
        guard request === activationRequest else { return }
        guard result == .completed else {
            finishActivation(.failure(ManagerError.rebootRequired))
            return
        }
        verifyActivatedExtension(phase: .installationCompletion)
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFailWithError error: Error
    ) {
        if request === deactivationRequest {
            let nsError = error as NSError
            if nsError.domain == OSSystemExtensionErrorDomain,
               nsError.code
                == OSSystemExtensionError.Code.extensionNotFound.rawValue {
                finishDeactivation(.success(()))
            } else {
                finishDeactivation(.failure(error))
            }
            return
        }
        if request === activationVerificationRequest {
            let nsError = error as NSError
            if nsError.domain == OSSystemExtensionErrorDomain,
               nsError.code
                == OSSystemExtensionError.Code.extensionNotFound.rawValue {
                resolveExtensionProperties([])
                return
            }
            finishActivation(.failure(error))
            return
        }
        guard request === activationRequest else { return }
        finishActivation(.failure(error))
    }

    func request(
        _ request: OSSystemExtensionRequest,
        foundProperties properties: [OSSystemExtensionProperties]
    ) {
        guard request === activationVerificationRequest else {
            return
        }
        let snapshots = properties.map {
            SystemExtensionPropertySnapshot(
                bundleIdentifier: $0.bundleIdentifier,
                bundleVersion: $0.bundleVersion,
                isEnabled: $0.isEnabled,
                isAwaitingUserApproval:
                    $0.isAwaitingUserApproval,
                isUninstalling: $0.isUninstalling
            )
        }
        resolveExtensionProperties(snapshots)
    }

    private func resolveExtensionProperties(
        _ snapshots: [SystemExtensionPropertySnapshot]
    ) {
        guard let phase = activationVerificationPhase else { return }
        let expectedVersion = bundledExtensionVersion ?? "unknown"
        switch SystemExtensionActivationVerifier.action(
            for: snapshots,
            expectedIdentifier: extensionIdentifier,
            expectedVersion: expectedVersion,
            phase: phase
        ) {
        case .ready:
            finishActivation(.success(()))
        case .activate:
            submitExtensionActivation()
        case let .newerActive(activeVersion):
            // Installing an older host over a newer one, by any route, leaves
            // the newer extension in place; only an uninstall clears it.
            let error = ManagerError.newerExtensionActive(
                activeVersion: activeVersion,
                bundledVersion: expectedVersion
            )
            if phase == .connection {
                activationStatusHandler?(.failed(error.localizedDescription))
            }
            finishActivation(.failure(error))
        case .unavailable:
            let error = ManagerError.extensionVerificationFailed(
                expectedVersion: expectedVersion
            )
            if phase == .connection {
                // A user may disable/remove the extension after installation.
                // Invalidate the shared gate without repairing it from connect.
                activationStatusHandler?(.failed(error.localizedDescription))
            }
            finishActivation(.failure(error))
        }
    }
}

private enum ActivationPurpose {
    case installation
    case connection
}

private struct HostPathInterfaceSnapshot: Encodable {
    let name: String
    let index: Int
    let type: String
}

private struct HostUnderlaySnapshot {
    let defaultInterface: HostPathInterfaceSnapshot
    let interfaces: [HostPathInterfaceSnapshot]
    let interfacesJSON: String
    let systemDNSJSON: String
    /// Comparison facts sampled together with the snapshot above. The
    /// Provider receives only the opaque `pathIdentity`, never these facts.
    let identity: HostUnderlayIdentity

    /// Exact canonical identity for coalescing host notifications. This value
    /// is never logged, persisted, sent to Provider, or exposed by Debug.
    var epochFingerprint: String {
        identity.epochFingerprint
    }

    /// Opaque equality token for the default path (interface, its IPv4
    /// addresses, default routers). The Provider compares it across
    /// generations to decide whether established TCP flows remain valid.
    var pathIdentity: String {
        identity.pathIdentity
    }

    func isEquivalent(to other: HostUnderlaySnapshot) -> Bool {
        identity == other.identity
    }

    func differenceKinds(
        comparedTo other: HostUnderlaySnapshot
    ) -> [String] {
        identity.differenceKinds(comparedTo: other.identity)
    }
}

private struct HostUnderlaySnapshotEvaluation {
    let result: Result<HostUnderlaySnapshot, Error>?
    let evidence: HostUnderlayCaptureEvidence?
}

private struct HostUnderlayCaptureError: LocalizedError {
    let evidence: HostUnderlayCaptureEvidence

    var errorDescription: String? {
        ManagerError.underlayUnavailable.localizedDescription
    }
}

private final class HostUnderlayCapture {
    private let monitor = NWPathMonitor()
    private let completion: (Result<HostUnderlaySnapshot, Error>) -> Void
    private var resolution = HostUnderlayCaptureResolution()

    private init(
        completion: @escaping (
            Result<HostUnderlaySnapshot, Error>
        ) -> Void
    ) {
        self.completion = completion
    }

    static func start(
        completion: @escaping (
            Result<HostUnderlaySnapshot, Error>
        ) -> Void
    ) {
        let capture = HostUnderlayCapture(completion: completion)
        capture.start()
    }

    private func start() {
        monitor.pathUpdateHandler = { [self] path in
            DispatchQueue.main.async {
                self.consume(path)
            }
        }
        monitor.start(queue: .global(qos: .userInitiated))
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            guard let evidence = resolution.expire() else { return }
            appLog(
                "Transparent Proxy host Underlay capture timed out "
                    + evidence.logSummary
            )
            deliver(.failure(HostUnderlayCaptureError(
                evidence: evidence
            )))
        }
    }

    private func consume(_ path: Network.NWPath) {
        let evaluation = Self.evaluateSnapshot(for: path)
        if let evidence = evaluation.evidence {
            resolution.observe(evidence)
        }
        guard let result = evaluation.result else { return }
        finish(result)
    }

    fileprivate static func snapshotResult(
        for path: Network.NWPath
    ) -> Result<HostUnderlaySnapshot, Error>? {
        evaluateSnapshot(for: path).result
    }

    private static func evaluateSnapshot(
        for path: Network.NWPath
    ) -> HostUnderlaySnapshotEvaluation {
        let pathStatus = pathStatusName(path.status)
        var candidateNamesSeen = Set<String>()
        let candidateNames = path.availableInterfaces.compactMap {
            candidateNamesSeen.insert($0.name).inserted
                ? $0.name
                : nil
        }
        guard path.status == .satisfied else {
            return HostUnderlaySnapshotEvaluation(
                result: nil,
                evidence: HostUnderlayCaptureDiagnosticClassifier.classify(
                    pathStatus: pathStatus,
                    routeInterface: "",
                    routeError: "",
                    candidateInterfaces: candidateNames,
                    indexedInterfaces: candidateNames.filter {
                        if_nametoindex($0) > 0
                    }
                )
            )
        }
        var routeError: NSError?
        let routeInterfaceName = LibboxDetectUnderlayInterface(&routeError)
        var seenNames = Set<String>()
        let interfaces = path.availableInterfaces.compactMap {
            networkInterface -> HostPathInterfaceSnapshot? in
            guard seenNames.insert(networkInterface.name).inserted else {
                return nil
            }
            let index = Int(if_nametoindex(networkInterface.name))
            guard index > 0 else {
                return nil
            }
            return HostPathInterfaceSnapshot(
                name: networkInterface.name,
                index: index,
                type: Self.networkTypeName(networkInterface.type)
            )
        }
        if let evidence = HostUnderlayCaptureDiagnosticClassifier.classify(
            pathStatus: pathStatus,
            routeInterface: routeInterfaceName,
            routeError: routeError?.localizedDescription ?? "",
            candidateInterfaces: candidateNames,
            indexedInterfaces: interfaces.map(\.name)
        ) {
            return HostUnderlaySnapshotEvaluation(
                result: nil,
                evidence: evidence
            )
        }
        guard
            let defaultInterface = interfaces.first(where: {
                $0.name == routeInterfaceName
            }),
            let data = try? JSONEncoder().encode(interfaces),
            let interfacesJSON = String(data: data, encoding: .utf8)
        else {
            // 系统默认路由和 NWPath 可能正处在同一次切换的两个不同通知阶段。
            // 等下一份 path 或 3 秒总超时，不能退回 availableInterfaces.first。
            return HostUnderlaySnapshotEvaluation(
                result: nil,
                evidence: HostUnderlayCaptureEvidence(
                    schemaVersion: 1,
                    reason: .snapshotEncodingFailed,
                    pathStatus: pathStatus,
                    routeInterface: routeInterfaceName,
                    candidateInterfaces: candidateNames,
                    invalidCandidateInterfaces: [],
                    routeError: "interface snapshot encoding failed"
                )
            )
        }
        guard let interfaceAddresses = Self.captureInterfaceAddresses() else {
            // 地址快照缺失不能当作“默认接口没有地址”，否则会伪造一次换网。
            return HostUnderlaySnapshotEvaluation(
                result: nil,
                evidence: HostUnderlayCaptureEvidence(
                    schemaVersion: 1,
                    reason: .snapshotEncodingFailed,
                    pathStatus: pathStatus,
                    routeInterface: routeInterfaceName,
                    candidateInterfaces: candidateNames,
                    invalidCandidateInterfaces: [],
                    routeError: "interface address snapshot failed"
                )
            )
        }
        guard let systemDNSJSON = Self.captureSystemDNSJSON() else {
            return HostUnderlaySnapshotEvaluation(
                result: .failure(ManagerError.systemDNSUnavailable),
                evidence: nil
            )
        }
        let identity = HostUnderlayIdentity(
            defaultInterface: HostUnderlayIdentity.Interface(
                name: defaultInterface.name,
                index: defaultInterface.index,
                type: defaultInterface.type
            ),
            interfaces: interfaces.map {
                HostUnderlayIdentity.Interface(
                    name: $0.name,
                    index: $0.index,
                    type: $0.type
                )
            },
            systemDNSJSON: systemDNSJSON,
            interfaceAddresses: interfaceAddresses,
            routers: Self.captureDefaultRouters()
        )
        return HostUnderlaySnapshotEvaluation(
            result: .success(HostUnderlaySnapshot(
                defaultInterface: defaultInterface,
                interfaces: interfaces,
                interfacesJSON: interfacesJSON,
                systemDNSJSON: systemDNSJSON,
                identity: identity
            )),
            evidence: nil
        )
    }

    /// Kernel interface addresses at the same sampling point as the default
    /// route and NWPath. `HostUnderlayIdentity` keeps only what identifies the
    /// default path; this reader does not filter by interface name or type.
    private static func captureInterfaceAddresses()
        -> [HostInterfaceAddressFact]?
    {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else {
            return nil
        }
        guard let first = head else {
            return []
        }
        defer { freeifaddrs(head) }
        var facts: [HostInterfaceAddressFact] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let socketAddress = entry.pointee.ifa_addr else {
                continue
            }
            let name = String(cString: entry.pointee.ifa_name)
            switch Int32(socketAddress.pointee.sa_family) {
            case AF_INET:
                var buffer = [CChar](
                    repeating: 0,
                    count: Int(INET_ADDRSTRLEN)
                )
                let rendered = socketAddress.withMemoryRebound(
                    to: sockaddr_in.self,
                    capacity: 1
                ) { pointer -> Bool in
                    var address = pointer.pointee.sin_addr
                    return inet_ntop(
                        AF_INET,
                        &address,
                        &buffer,
                        socklen_t(buffer.count)
                    ) != nil
                }
                if rendered {
                    facts.append(HostInterfaceAddressFact(
                        interfaceName: name,
                        family: .ipv4,
                        address: String(cString: buffer)
                    ))
                }
            case AF_INET6:
                var buffer = [CChar](
                    repeating: 0,
                    count: Int(INET6_ADDRSTRLEN)
                )
                let rendered = socketAddress.withMemoryRebound(
                    to: sockaddr_in6.self,
                    capacity: 1
                ) { pointer -> Bool in
                    var address = pointer.pointee.sin6_addr
                    return inet_ntop(
                        AF_INET6,
                        &address,
                        &buffer,
                        socklen_t(buffer.count)
                    ) != nil
                }
                if rendered {
                    facts.append(HostInterfaceAddressFact(
                        interfaceName: name,
                        family: .ipv6,
                        address: String(cString: buffer)
                    ))
                }
            default:
                continue
            }
        }
        return facts
    }

    /// The primary service's default routers as configd publishes them. A
    /// missing key is a fact (for example an IPv6-only or link-local network),
    /// not a failed capture.
    private static func captureDefaultRouters() -> HostDefaultRouterFacts {
        func router(_ key: String, _ property: CFString) -> String? {
            guard let state = SCDynamicStoreCopyValue(
                nil,
                key as CFString
            ) as? [String: Any] else {
                return nil
            }
            return state[property as String] as? String
        }
        return HostDefaultRouterFacts(
            ipv4: router(
                "State:/Network/Global/IPv4",
                kSCPropNetIPv4Router
            ),
            ipv6: router(
                "State:/Network/Global/IPv6",
                kSCPropNetIPv6Router
            )
        )
    }

    private static func pathStatusName(
        _ status: Network.NWPath.Status
    ) -> String {
        switch status {
        case .satisfied:
            "satisfied"
        case .unsatisfied:
            "unsatisfied"
        case .requiresConnection:
            "requires-connection"
        @unknown default:
            "unknown"
        }
    }

    private func finish(
        _ result: Result<HostUnderlaySnapshot, Error>
    ) {
        guard resolution.resolve() else {
            return
        }
        deliver(result)
    }

    private func deliver(
        _ result: Result<HostUnderlaySnapshot, Error>
    ) {
        monitor.pathUpdateHandler = nil
        monitor.cancel()
        completion(result)
    }

    private static func networkTypeName(
        _ type: Network.NWInterface.InterfaceType
    ) -> String {
        switch type {
        case .wifi:
            "wifi"
        case .cellular:
            "cellular"
        case .wiredEthernet:
            "ethernet"
        default:
            "other"
        }
    }

    fileprivate static func captureSystemDNSJSON() -> String? {
        guard
            let state = SCDynamicStoreCopyValue(
                nil,
                "State:/Network/Global/DNS" as CFString
            ) as? [String: Any],
            let rawAddresses =
                state[kSCPropNetDNSServerAddresses as String] as? [String]
        else {
            return nil
        }

        var seen = Set<String>()
        var addresses: [String] = []
        for rawAddress in rawAddresses {
            let address = rawAddress.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard isNumericIPAddress(address) else {
                return nil
            }
            if seen.insert(address).inserted {
                addresses.append(address)
            }
        }
        guard
            !addresses.isEmpty,
            let data = try? JSONEncoder().encode(addresses),
            let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return json
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

/// 只观察 macOS 已经裁决完成的网络事实。它不识别接口类型或产品；
/// 真正的路径恢复是新的 network epoch，即使接口 / DNS 快照未变也要交给
/// 宿主刷新运行时。唯一例外是紧邻系统唤醒且快照完全等价的电源生命周期
/// 抖动；该情况继续由已提交事务及 Line 局部恢复负责。
private final class HostUnderlayMonitor {
    private let monitor = NWPathMonitor()
    /// The newest snapshot already reported; equivalent samples are not
    /// reported again.
    private let baseline: HostUnderlaySnapshot
    /// What the running state was decided on: the committed generation's
    /// Underlay, or the parked epoch's. Only this proves after a wake that
    /// nothing changed.
    private let committedBaseline: HostUnderlaySnapshot
    private let onChange: (HostUnderlaySnapshot, Bool) -> Void
    private var pathTransition = UnderlayPathTransitionState()
    private var pendingChange: DispatchWorkItem?
    private var lastSystemWakeAt: Date?
    private var systemSleepGate = SystemSleepNetworkEpochGate()
    private var cancelled = false
    private var factStore: SCDynamicStore?

    /// Weak bridge for configd's C callback; owned by the store's context.
    private final class FactObserver {
        weak var monitor: HostUnderlayMonitor?

        init(_ monitor: HostUnderlayMonitor) {
            self.monitor = monitor
        }
    }

    init(
        baseline: HostUnderlaySnapshot,
        committedBaseline: HostUnderlaySnapshot,
        onChange: @escaping (HostUnderlaySnapshot, Bool) -> Void
    ) {
        self.baseline = baseline
        self.committedBaseline = committedBaseline
        self.onChange = onChange
    }

    deinit {
        stopFactNotifications()
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.consume(path)
            }
        }
        monitor.start(queue: .global(qos: .utility))
        startFactNotifications()
    }

    func cancel() {
        cancelled = true
        pendingChange?.cancel()
        pendingChange = nil
        monitor.pathUpdateHandler = nil
        monitor.cancel()
        stopFactNotifications()
    }

    /// NWPath does not promise a callback when only the default router, the
    /// system resolvers or a configd-managed interface address change on an
    /// unchanged interface. configd publishes each of those facts; watching
    /// the same keys the snapshot reads gives every fingerprint fact a change
    /// source. Read-only: nothing is written to the dynamic store.
    private func startFactNotifications() {
        guard factStore == nil, !cancelled else { return }
        let observer = Unmanaged.passRetained(FactObserver(self))
        var context = SCDynamicStoreContext(
            version: 0,
            info: observer.toOpaque(),
            retain: nil,
            release: { info in
                Unmanaged<FactObserver>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        guard let store = SCDynamicStoreCreate(
            nil,
            "XDial host Underlay" as CFString,
            { _, _, info in
                guard let info else { return }
                Unmanaged<FactObserver>.fromOpaque(info)
                    .takeUnretainedValue()
                    .monitor?
                    .factsChanged()
            },
            &context
        ) else {
            observer.release()
            return
        }
        let keys = [
            "State:/Network/Global/IPv4",
            "State:/Network/Global/IPv6",
            "State:/Network/Global/DNS",
        ] as CFArray
        let patterns = ["State:/Network/Interface/[^/]+/IPv4"] as CFArray
        guard
            SCDynamicStoreSetNotificationKeys(store, keys, patterns),
            SCDynamicStoreSetDispatchQueue(store, .main)
        else {
            return
        }
        factStore = store
    }

    private func stopFactNotifications() {
        if let factStore {
            SCDynamicStoreSetDispatchQueue(factStore, nil)
        }
        factStore = nil
    }

    /// Only re-samples. It never cancels a pending change and never feeds the
    /// path transition state, so NWPath edges (unsatisfied / restored) keep
    /// their meaning; an equivalent snapshot is ignored here.
    private func factsChanged() {
        guard
            !cancelled,
            pendingChange == nil,
            systemSleepGate.observeNetworkSignal() == .evaluateCurrentPath
        else {
            return
        }
        let path = monitor.currentPath
        guard
            path.status == .satisfied,
            let result = HostUnderlayCapture.snapshotResult(for: path),
            case let .success(snapshot) = result,
            !snapshot.isEquivalent(to: baseline)
        else {
            return
        }
        scheduleChange(allowEquivalentSnapshot: false)
    }

    func noteSystemWake(at date: Date = Date()) {
        guard !cancelled else { return }
        systemSleepGate.noteSystemDidWake()
        lastSystemWakeAt = date
        // The process can miss intermediate NWPath callbacks while suspended.
        // Always re-sample after the full wake; an equivalent snapshot is
        // suppressed below, while a real move emits exactly one epoch.
        scheduleChange(allowEquivalentSnapshot: true)
    }

    func noteSystemSleep() {
        guard !cancelled else { return }
        systemSleepGate.noteSystemWillSleep()
        lastSystemWakeAt = nil
        pendingChange?.cancel()
        pendingChange = nil
        pathTransition = UnderlayPathTransitionState()
    }

    private func consume(_ path: Network.NWPath) {
        guard !cancelled else { return }
        guard systemSleepGate.observeNetworkSignal()
            == .evaluateCurrentPath else {
            return
        }
        let snapshot: HostUnderlaySnapshot?
        if path.status == .satisfied,
            let result = HostUnderlayCapture.snapshotResult(for: path),
            case let .success(value) = result
        {
            snapshot = value
        } else {
            snapshot = nil
        }
        let action = pathTransition.observe(
            isSatisfied: path.status == .satisfied,
            hasCompleteSnapshot: snapshot != nil,
            snapshotMatchesBaseline:
                snapshot?.isEquivalent(to: baseline) == true
        )
        switch action {
        case .none:
            return
        case .cancelPending:
            pendingChange?.cancel()
            pendingChange = nil
            return
        case let .scheduleRefresh(allowEquivalentSnapshot):
            scheduleChange(
                allowEquivalentSnapshot: allowEquivalentSnapshot
            )
        }
    }

    private func scheduleChange(
        allowEquivalentSnapshot: Bool
    ) {
        pendingChange?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.cancelled else { return }
            guard self.systemSleepGate.observeNetworkSignal()
                == .evaluateCurrentPath else {
                self.pendingChange = nil
                return
            }
            guard self.monitor.currentPath.status == .satisfied else {
                _ = self.pathTransition.observe(
                    isSatisfied: false,
                    hasCompleteSnapshot: false,
                    snapshotMatchesBaseline: false
                )
                self.pendingChange = nil
                return
            }
            guard
                let result = HostUnderlayCapture.snapshotResult(
                    for: self.monitor.currentPath
                ),
                case let .success(snapshot) = result
            else {
                // DNS、默认路由和 NWPath 仍处于中间态；继续等待同一轮变化
                // 收敛，不拿旧快照启动，也不回落到任意接口。
                self.scheduleChange(
                    allowEquivalentSnapshot: allowEquivalentSnapshot
                )
                return
            }
            let snapshotMatchesBaseline = snapshot.isEquivalent(
                to: self.baseline
            )
            let secondsSinceSystemWake = self.lastSystemWakeAt.map {
                Date().timeIntervalSince($0)
            }
            if SystemWakeUnderlayPolicy.suppressesEquivalentRestoration(
                connectivityRestored: allowEquivalentSnapshot,
                snapshotMatchesBaseline: snapshot.isEquivalent(
                    to: self.committedBaseline
                ),
                secondsSinceSystemWake: secondsSinceSystemWake
            ) {
                self.lastSystemWakeAt = nil
                self.pendingChange = nil
                appLog(
                    "Transparent Proxy equivalent Underlay restoration "
                        + "suppressed after system wake; committed runtime "
                        + "remains authoritative"
                )
                return
            }
            guard allowEquivalentSnapshot || !snapshotMatchesBaseline else {
                self.pendingChange = nil
                return
            }
            self.cancelled = true
            self.monitor.pathUpdateHandler = nil
            self.monitor.cancel()
            self.stopFactNotifications()
            self.onChange(snapshot, allowEquivalentSnapshot)
        }
        pendingChange = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.8,
            execute: work
        )
    }
}

enum ProviderDiagnosticsHostError: LocalizedError {
    case invalidRequest
    case transactionMismatch
    case managerUnavailable
    case notConnected
    case sessionUnavailable
    case sendFailed
    case timedOut
    case invalidResponse
    case providerRejected(String)
    case payloadMismatch

    var code: String {
        switch self {
        case .invalidRequest:
            "invalid-provider-diagnostics-request"
        case .transactionMismatch:
            "provider-diagnostics-transaction-mismatch"
        case .managerUnavailable:
            "transparent-proxy-manager-unavailable"
        case .notConnected:
            "transparent-proxy-not-connected"
        case .sessionUnavailable:
            "provider-session-unavailable"
        case .sendFailed:
            "provider-message-send-failed"
        case .timedOut:
            "provider-message-timeout"
        case .invalidResponse:
            "invalid-provider-diagnostics-response"
        case let .providerRejected(code):
            code
        case .payloadMismatch:
            "provider-diagnostics-payload-mismatch"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "Provider 诊断请求无效"
        case .transactionMismatch:
            "Provider 诊断请求不属于当前连接事务"
        case .managerUnavailable:
            "找不到当前 XDial Transparent Proxy 配置"
        case .notConnected:
            "XDial Transparent Proxy 当前未连接"
        case .sessionUnavailable:
            "当前网络配置没有可用的 Provider 会话"
        case .sendFailed:
            "无法向 XDial Provider 发送诊断请求"
        case .timedOut:
            "XDial Provider 诊断请求超时"
        case .invalidResponse:
            "XDial Provider 返回了无效诊断响应"
        case let .providerRejected(code):
            "XDial Provider 拒绝诊断请求（\(code)）"
        case .payloadMismatch:
            "XDial Provider 返回的诊断数据与请求不匹配"
        }
    }
}

private final class HostCompletionGate<Value> {
    private let lock = NSLock()
    private var completion: ((Result<Value, Error>) -> Void)?

    init(
        _ completion: @escaping (Result<Value, Error>) -> Void
    ) {
        self.completion = completion
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let completion = completion
        self.completion = nil
        lock.unlock()
        guard let completion else { return }
        DispatchQueue.main.async {
            completion(result)
        }
    }
}

private struct HostScenarioSwitch {
    let requestID: String
    let sourceTransactionID: String
    var sourceReport: ConnectionReport
    let targetTransactionID: String
    let targetScenarioID: String
    let targetConfigurationFingerprint: String
    let profileJSON: String
    let targetReportJSON: String
    let refreshLineRuntimes: Bool
    let networkEpochID: String?
    let expectedUnderlayFingerprint: String?
    var candidateReport: ConnectionReport
    let completionGate: HostCompletionGate<ConnectionReport>
    var cancellationRequested: Bool
    var requestSent: Bool
    var timedOut: Bool
    var reconciling: Bool
    var reconciliationError: Error?
    var reconciliationWorkItem: DispatchWorkItem?
    var progressWorkItem: DispatchWorkItem?
    var underlay: HostUnderlaySnapshot?
    var timeoutWorkItem: DispatchWorkItem?
}

private enum ManagerError: LocalizedError {
    case activationInProgress
    case missingProfile
    case missingTransaction
    case invalidConnectionPlan
    case scenarioSwitchInProgress
    case scenarioSwitchUnavailable
    case scenarioSwitchInvalidResponse
    case scenarioSwitchSendFailed
    case scenarioSwitchCancelled
    case scenarioSwitchTimedOut
    case interruptedTransactionRecovered
    case providerSessionLost
    case providerStartFailed
    case underlayUnavailable
    case systemDNSUnavailable
    case extensionVerificationFailed(expectedVersion: String)
    case newerExtensionActive(activeVersion: String, bundledVersion: String)
    case deactivationDeferredBySystem
    case rebootRequired
    case stopTimedOut
    case startTimedOut
    case unknownStatus

    var errorDescription: String? {
        switch self {
        case .activationInProgress:
            "\(XDialBuildIdentity.transparentProxyDisplayName) 正在启用，请稍候"
        case .missingProfile:
            "当前配置为空，无法启动"
        case .missingTransaction:
            "XDial 连接事务不存在"
        case .invalidConnectionPlan:
            "当前场景无法生成有效的连接计划"
        case .scenarioSwitchInProgress:
            "已有一笔场景切换正在进行"
        case .scenarioSwitchUnavailable:
            "当前连接尚未进入可切换状态"
        case .scenarioSwitchInvalidResponse:
            "XDial Provider 返回了无效的场景切换结果"
        case .scenarioSwitchSendFailed:
            "无法向 XDial Provider 发送场景切换请求"
        case .scenarioSwitchCancelled:
            "场景切换已取消"
        case .scenarioSwitchTimedOut:
            "场景切换准备超时，当前场景保持连接"
        case .interruptedTransactionRecovered:
            "检测到上一次连接事务未完成，已撤销系统网络接管"
        case .providerSessionLost:
            "XDial 数据面意外退出，系统网络接管已移除"
        case .providerStartFailed:
            "XDial 数据面启动失败"
        case .underlayUnavailable:
            "无法读取 XDial 启动前的系统网络接口"
        case .systemDNSUnavailable:
            "无法读取 XDial 启动前的系统 DNS"
        case let .extensionVerificationFailed(expectedVersion):
            "macOS 未登记并启用当前 \(XDialBuildIdentity.transparentProxyDisplayName)（build \(expectedVersion)）；请先完成 XDial 安装"
        case let .newerExtensionActive(activeVersion, bundledVersion):
            "macOS 中已有构建号更高的 \(XDialBuildIdentity.transparentProxyDisplayName)（build \(activeVersion)，可能来自 beta），"
                + "不会换成当前 App 带的 build \(bundledVersion)；请先在 \(XDialBuildIdentity.applicationDisplayName) 内卸载（不勾选删除数据），再安装这个版本"
        case .deactivationDeferredBySystem:
            "macOS 仍在占用 \(XDialBuildIdentity.transparentProxyDisplayName)；请退出其他正在运行的 XDial 后重试卸载"
        case .rebootRequired:
            "\(XDialBuildIdentity.transparentProxyDisplayName) 需要重启 macOS 后才能启用"
        case .stopTimedOut:
            "旧的 XDial 网络会话未能在 10 秒内断开"
        case .startTimedOut:
            "XDial 数据面未能在 45 秒内启动"
        case .unknownStatus:
            "\(XDialBuildIdentity.transparentProxyDisplayName) 返回了未知状态"
        }
    }
}
