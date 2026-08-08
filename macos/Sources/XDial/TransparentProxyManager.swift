import AppKit
import Darwin
import Foundation
import Libbox
import Network
@preconcurrency import NetworkExtension
import SystemConfiguration
@preconcurrency import SystemExtensions

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
        return "com.kafeifei.xdial.transparent-proxy"
    }()
    private let configurationName = "XDial Transparent Proxy"

    var statusHandler: StatusHandler?
    var reportHandler: ReportHandler?
    var scenarioSwitchHandler: ScenarioSwitchHandler?
    var activationStatusHandler: ActivationStatusHandler?
    var underlayChangeHandler: ((String) -> Void)?
    var activeTransactionID: String? {
        TransparentProxyRuntimeGate.connectionProofTransactionID(
            currentTransactionID: currentTransactionID,
            automaticReconnectInProgress:
                automaticReconnectInProgress,
            reconnectTransactionID:
                automaticReconnectTransactionID,
            networkExtensionSessionTransactionID:
                networkExtensionSessionTransactionID
        )
    }

    private var manager: NETransparentProxyManager?
    private var statusObserver: NSObjectProtocol?
    private var activationRequest: OSSystemExtensionRequest?
    private var activationCompletion: ((Result<Void, Error>) -> Void)?
    private var activationPurpose: ActivationPurpose?
    private var activationVerificationRequest:
        OSSystemExtensionRequest?
    private var deactivationRequest: OSSystemExtensionRequest?
    private var deactivationCompletion:
        ((Result<Void, Error>) -> Void)?
    private var startAttemptID: UUID?
    private var startIntentID: UUID?
    private var currentTransactionID: String?
    private var currentTransactionSeedJSON: String?
    private var reportPollTimer: Timer?
    private var recoveringTransactionID: String?
    private var requestedProfileJSON: String?
    private var activeUnderlay: HostUnderlaySnapshot?
    private var underlayMonitor: HostUnderlayMonitor?
    private var automaticReconnectInProgress = false
    private var automaticReconnectTrigger: AutomaticReconnectTrigger?
    private var pendingInitialRetryTrigger: AutomaticReconnectTrigger?
    private var automaticReconnectTransactionID: String?
    private var networkExtensionSessionTransactionID: String?
    private let automaticReconnectRetryPolicy =
        AutomaticReconnectRetryPolicy()
    private var automaticReconnectAttemptsUsed = 0
    private var automaticReconnectRetryWorkItem: DispatchWorkItem?
    private var automaticReconnectRetryToken: UUID?
    private var automaticReconnectRetryAt: Date?
    private var automaticReconnectRetryAttempt: Int?
    private var automaticReconnectRetryFailedTransactionID: String?
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
    }

    var automaticReconnectState: AutomaticReconnectRuntimeState {
        AutomaticReconnectRuntimeState(
            inProgress: automaticReconnectInProgress,
            trigger: automaticReconnectTrigger,
            attemptsUsed: automaticReconnectAttemptsUsed,
            maxAttempts: automaticReconnectRetryPolicy.maxAttempts,
            stableResetAt: stableConnectionResetAt,
            retryAt: automaticReconnectRetryAt,
            retryAttempt: automaticReconnectRetryAttempt
        )
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
        startIntentID = intentID
        requestedProfileJSON = profileJSON
        automaticReconnectInProgress = false
        automaticReconnectTrigger = nil
        pendingInitialRetryTrigger = automaticRetryTrigger
        automaticReconnectTransactionID = nil
        networkExtensionSessionTransactionID = nil
        connectedSessionTransactionID = nil
        activeReconnectIncidentID = nil
        stableResetIncidentID = nil
        cancelStableConnectionReset()
        cancelAutomaticReconnectRetry(resetAttempts: false)
        stopUnderlayMonitoring()
        startAttemptID = nil
        publishRuntimeStatus("connecting", error: nil)
        updateReport(transactionID: transactionID) {
            $0.updateTask(id: "underlay:system", state: .running)
        }
        HostUnderlayCapture.start { [weak self] snapshotResult in
            guard let self else { return }
            guard self.startIntentID == intentID else { return }
            switch snapshotResult {
            case let .success(snapshot):
                self.updateReport(transactionID: transactionID) {
                    $0.updateTask(id: "underlay:system", state: .ready)
                    $0.setState(.preparing)
                }
                appLog(
                    "Transparent Proxy underlay default=\(snapshot.defaultInterface.name)"
                )
                self.activateExtension(purpose: .connection) {
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
        let targetReport = ConnectionReport(
            transactionID: targetTransactionID,
            plan: plan
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
        HostUnderlayCapture.start { result in
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
           activeUnderlay?.isEquivalent(to: underlay) == true {
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
            systemDNSJSON: underlay.systemDNSJSON
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
        activateExtension(
            purpose: .installation,
            completion: completion
        )
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

    func probeLineOutboundAddress(
        transactionID: String,
        lineID: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let request = ProviderDiagnosticsRequest(
            cmd: .probeLineOutboundAddress,
            transactionID: transactionID,
            lineID: lineID
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
                    !observation.address.isEmpty
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
        automaticReconnectInProgress = false
        automaticReconnectTrigger = nil
        pendingInitialRetryTrigger = nil
        automaticReconnectTransactionID = nil
        networkExtensionSessionTransactionID = nil
        connectedSessionTransactionID = nil
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
        startAttemptID = nil
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
                self.networkExtensionSessionTransactionID = nil
                self.finishOrphanedTransactionIfNeeded()
                self.publishRuntimeStatus("disconnected", error: nil)
            case let .success(manager?):
                self.stopLoadedManager(manager)
            }
        }
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
                self.publishFailure(error)
            case .success(nil):
                self.manager = nil
                self.networkExtensionSessionTransactionID = nil
                self.finishOrphanedTransactionIfNeeded()
                self.publishRuntimeStatus("disconnected", error: nil)
            case let .success(manager?):
                self.installStatusObserver(for: manager)
                if self.reconcileInterruptedTransactionIfNeeded(
                    manager
                ) {
                    return
                }
                self.publishStatus(for: manager)
            }
        }
    }

    private func activateExtension(
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
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        activationRequest = request
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func verifyActivatedExtension() {
        guard let expectedVersion = bundledExtensionVersion else {
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
            let attemptID = UUID()
            startAttemptID = attemptID
            activeUnderlay = underlay
            networkExtensionSessionTransactionID = transactionID
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
                monitorStartAttempt(
                    manager,
                    attemptID: attemptID,
                    checksRemaining: 90
                )
            } catch {
                if startAttemptID == attemptID {
                    startAttemptID = nil
                }
                if networkExtensionSessionTransactionID ==
                    transactionID {
                    networkExtensionSessionTransactionID = nil
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

        withExistingManager { result in
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
        networkExtensionSessionTransactionID = report.transactionID
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
        recordScenarioSwitch(
            active,
            status: "committed",
            activeTransactionID: report.transactionID,
            code: nil,
            message: nil,
            reusedLineIDs:
                ConnectionReportRuntimeFacts.reusedLineIDs(report: report)
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
            networkExtensionSessionTransactionID =
                sourceReport.transactionID
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

    /// 每次都从系统当前配置重新取得 connected manager/session。这里不缓存
    /// `NETunnelProviderSession`，避免重连后把请求发给上一笔事务的连接对象。
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
        withExistingManager(purpose: .diagnostics) { result in
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
        publishLatestReport()
        switch manager.connection.status {
        case .invalid, .disconnected:
            let disconnectedAt = Date()
            let reportBeforeRecovery = ConnectionReportJournal.read()
            let lostCommittedSession =
                startIntentID != nil
                && requestedProfileJSON != nil
                && connectedSessionTransactionID != nil
                && connectedSessionTransactionID ==
                    reportBeforeRecovery?.transactionID
                && !automaticReconnectInProgress
            networkExtensionSessionTransactionID = nil
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
                return
            }
            guard startAttemptID != nil else {
                publishRuntimeStatus("disconnected", error: nil)
                return
            }
            startAttemptID = nil
            manager.connection.fetchLastDisconnectError { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.publishLatestReport()
                    self.publishFailure(
                        error ?? ManagerError.providerStartFailed
                    )
                }
            }
        case .connecting:
            publishRuntimeStatus(
                automaticReconnectInProgress ? "reconnecting" : "connecting",
                error: nil
            )
        case .connected:
            startAttemptID = nil
            publishRuntimeStatus("connected", error: nil)
            publishLatestReport()
            if lastPublishedRuntimeStatus == "connected" {
                startUnderlayMonitoringIfNeeded()
            }
        case .reasserting:
            cancelStableConnectionReset()
            publishRuntimeStatus("reconnecting", error: nil)
        case .disconnecting:
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

    private func monitorStartAttempt(
        _ manager: NETransparentProxyManager,
        attemptID: UUID,
        checksRemaining: Int
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard self.startAttemptID == attemptID else {
                return
            }
            switch manager.connection.status {
            case .connected, .invalid, .disconnected:
                self.publishStatus(for: manager)
            case .connecting, .reasserting, .disconnecting:
                guard checksRemaining > 1 else {
                    self.startAttemptID = nil
                    manager.connection.stopVPNTunnel()
                    self.publishFailure(ManagerError.startTimedOut)
                    return
                }
                self.monitorStartAttempt(
                    manager,
                    attemptID: attemptID,
                    checksRemaining: checksRemaining - 1
                )
            @unknown default:
                self.startAttemptID = nil
                self.publishFailure(ManagerError.unknownStatus)
            }
        }
    }

    private func publishFailure(_ error: Error) {
        let wasAutomaticReconnect =
            automaticReconnectInProgress
                && automaticReconnectTrigger != nil
        networkExtensionSessionTransactionID = nil
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
                    code: "host-start-failed",
                    message: error.localizedDescription,
                    taskID: report.currentTask?.id ?? ""
                )
                report.rollbackSessionTasks(
                    systemTakeoverRemoved: true,
                    cleanupComplete: true,
                    finalState: .failed
                )
            }
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
        automaticReconnectTransactionID = report.transactionID
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
            "Transparent Proxy launch auto-connect failed; "
                + "entering bounded retry code=\(reasonCode)"
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
        automaticReconnectTransactionID = nil
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
            plan: plan
        )
        let seedData = try ConnectionReportCodec.encode(report)
        guard let seedJSON = String(data: seedData, encoding: .utf8) else {
            throw ManagerError.invalidConnectionPlan
        }
        try ConnectionReportJournal.write(report)
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

    private func publishLatestReport() {
        let localReport = ConnectionReportJournal.read()
        var candidate: ConnectionReport?
        var shouldMirrorProviderReport = false

        if let providerReport =
            PrivilegeManager.probeProviderConnectionReport(),
           currentTransactionID == nil ||
            providerReport.transactionID == currentTransactionID {
            if let localReport,
               localReport
                .isSystemDisconnectConfirmationSuccessor(
                    of: providerReport
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
            return
        }

        currentTransactionID = report.transactionID
        if shouldMirrorProviderReport {
            try? ConnectionReportJournal.write(report)
        }
        publishReport(report)
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
        pendingInitialRetryTrigger = nil
        automaticReconnectTransactionID = nil
        cancelAutomaticReconnectRetry(resetAttempts: false)
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
        guard automaticReconnectAttemptsUsed > 0 else {
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
            self.automaticReconnectAttemptsUsed = 0
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

    private func reconcileInterruptedTransactionIfNeeded(
        _ manager: NETransparentProxyManager
    ) -> Bool {
        guard let report = ConnectionReportJournal.read() else {
            return false
        }
        if report.state == .committed {
            switch manager.connection.status {
            case .invalid, .disconnected:
                currentTransactionID = report.transactionID
                finishInterruptedTransactionRecovery(
                    transactionID: report.transactionID,
                    error: .providerSessionLost,
                    code: "provider-session-lost",
                    taskID: "ingress:transparent-proxy"
                )
            default:
                break
            }
            return false
        }
        guard ![
            .failed,
            .cancelled,
        ].contains(report.state) else {
            return false
        }
        currentTransactionID = report.transactionID
        beginReportPolling(transactionID: report.transactionID)
        recoveringTransactionID = report.transactionID
        updateReport(transactionID: report.transactionID) {
            $0.setState(.rollingBack)
        }
        switch manager.connection.status {
        case .invalid, .disconnected:
            recoveringTransactionID = nil
            finishInterruptedTransactionRecovery(
                transactionID: report.transactionID
            )
            return false
        case .connected, .connecting, .reasserting, .disconnecting:
            publishRuntimeStatus(
                "disconnecting",
                error: ManagerError.interruptedTransactionRecovered
                    .localizedDescription
            )
            manager.connection.stopVPNTunnel()
            return true
        @unknown default:
            return false
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
        switch report.state {
        case .committed:
            finishInterruptedTransactionRecovery(
                transactionID: report.transactionID,
                error: .providerSessionLost,
                code: "provider-session-lost",
                taskID: "ingress:transparent-proxy"
            )
        case .failed, .cancelled:
            break
        default:
            finishInterruptedTransactionRecovery(
                transactionID: report.transactionID
            )
        }
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
        startUnderlayMonitoring(baseline: baseline)
    }

    private func startUnderlayMonitoring(
        baseline: HostUnderlaySnapshot
    ) {
        guard underlayMonitor == nil,
              requestedProfileJSON != nil,
              startIntentID != nil else {
            return
        }
        let monitor = HostUnderlayMonitor(baseline: baseline) {
            [weak self] snapshot in
            self?.handleUnderlayChange(snapshot)
        }
        underlayMonitor = monitor
        monitor.start()
    }

    private func stopUnderlayMonitoring() {
        underlayMonitor?.cancel()
        underlayMonitor = nil
    }

    private func handleUnderlayChange(
        _ underlay: HostUnderlaySnapshot
    ) {
        guard
            requestedProfileJSON != nil,
            startIntentID != nil,
            manager?.connection.status == .connected
        else {
            return
        }
        let changeKinds = activeUnderlay?
            .differenceKinds(comparedTo: underlay)
            .joined(separator: ",") ?? "unknown"
        appLog(
            "Transparent Proxy underlay changed "
                + "\(activeUnderlay?.defaultInterface.name ?? "unknown")"
                + " -> \(underlay.defaultInterface.name) "
                + "kinds=\(changeKinds); scheduling staged switch"
        )
        // HostUnderlayMonitor has already stopped itself at this point. Start
        // a fresh observer from the newest sample so another physical change
        // can supersede a candidate that is still preparing.
        underlayMonitor = nil
        startUnderlayMonitoring(baseline: underlay)
        underlayChangeHandler?(underlay.epochFingerprint)
    }

    private func handleAutomaticReconnectAfterDisconnect(
        report: ConnectionReport?
    ) {
        guard automaticReconnectInProgress else { return }
        guard
            let report,
            report.transactionID == currentTransactionID
        else {
            publishRuntimeStatus("reconnecting", error: nil)
            return
        }
        guard [.failed, .cancelled].contains(report.state) else {
            publishRuntimeStatus("reconnecting", error: nil)
            return
        }
        guard report.rollbackComplete,
              report.systemTakeoverRemoved else {
            publishRuntimeStatus("reconnecting", error: nil)
            return
        }
        guard let trigger = automaticReconnectTrigger else {
            finishAutomaticReconnect(
                report: report,
                message: report.error?.message
            )
            return
        }
        if let delay = automaticReconnectRetryPolicy.delay(
            after: report,
            attemptsUsed: automaticReconnectAttemptsUsed,
            trigger: trigger
        ) {
            scheduleAutomaticReconnectRetry(
                failedTransactionID: report.transactionID,
                delay: delay
            )
            publishRuntimeStatus("reconnecting", error: nil)
            return
        }

        finishAutomaticReconnect(
            report: report,
            message: report.error?.message
        )
    }

    private func scheduleAutomaticReconnectRetry(
        failedTransactionID: String,
        delay: TimeInterval
    ) {
        guard automaticReconnectRetryWorkItem == nil else {
            return
        }
        guard automaticReconnectAttemptsUsed
            < automaticReconnectRetryPolicy.maxAttempts else {
            finishAutomaticReconnect(
                report: ConnectionReportJournal.read(),
                message: ConnectionReportJournal.read()?.error?.message
            )
            return
        }
        let retryNumber = automaticReconnectAttemptsUsed + 1
        automaticReconnectAttemptsUsed = retryNumber
        if let incidentID = activeReconnectIncidentID {
            ReconnectIncidentJournal.append(
                incidentID: incidentID,
                type: "retry-scheduled",
                attempt: retryNumber,
                transactionID: failedTransactionID,
                message: "Retry scheduled after \(delay)s"
            )
        }
        appLog(
            "Transparent Proxy automatic reconnect retry "
                + "\(retryNumber) scheduled after \(delay)s"
        )
        let token = UUID()
        automaticReconnectRetryToken = token
        automaticReconnectRetryAt = Date().addingTimeInterval(delay)
        automaticReconnectRetryAttempt = retryNumber
        automaticReconnectRetryFailedTransactionID =
            failedTransactionID
        let work = DispatchWorkItem { [weak self] in
            self?.performScheduledAutomaticReconnectRetry(token: token)
        }
        automaticReconnectRetryWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: work
        )
    }

    @discardableResult
    func retryAutomaticReconnectNow() -> Bool {
        guard let token = automaticReconnectRetryToken else {
            return false
        }
        performScheduledAutomaticReconnectRetry(token: token)
        return true
    }

    private func performScheduledAutomaticReconnectRetry(
        token: UUID
    ) {
        guard
            automaticReconnectRetryToken == token,
            let failedTransactionID =
                automaticReconnectRetryFailedTransactionID,
            let retryNumber = automaticReconnectRetryAttempt
        else {
            return
        }
        automaticReconnectRetryWorkItem?.cancel()
        automaticReconnectRetryWorkItem = nil
        automaticReconnectRetryToken = nil
        automaticReconnectRetryAt = nil
        automaticReconnectRetryAttempt = nil
        automaticReconnectRetryFailedTransactionID = nil
        guard
            automaticReconnectInProgress,
            currentTransactionID == failedTransactionID,
            let profileJSON = requestedProfileJSON,
            let manager,
            startIntentID != nil
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
                self.automaticReconnectInProgress
            else {
                return
            }
            switch result {
            case let .success(snapshot):
                do {
                    let transactionID = try self.beginTransaction(
                        profileJSON: profileJSON
                    )
                    self.automaticReconnectTransactionID =
                        transactionID
                    if let incidentID = self.activeReconnectIncidentID {
                        ReconnectIncidentJournal.append(
                            incidentID: incidentID,
                            type: "retry-started",
                            attempt: retryNumber,
                            transactionID: transactionID
                        )
                    }
                    self.updateReport(transactionID: transactionID) {
                        $0.updateTask(
                            id: "underlay:system",
                            state: .ready
                        )
                        $0.setState(.preparing)
                    }
                } catch {
                    self.publishFailure(error)
                    return
                }
                appLog(
                    "Transparent Proxy automatic reconnect retry "
                        + "\(retryNumber) captured default="
                        + snapshot.defaultInterface.name
                )
                self.publishRuntimeStatus("reconnecting", error: nil)
                self.startConnection(
                    manager,
                    profileJSON: profileJSON,
                    underlay: snapshot,
                    intentID: intentID,
                    debugFailureStage: nil
                )
            case let .failure(error):
                guard let nextDelay =
                    self.automaticReconnectRetryPolicy
                    .delayForNextAttempt(
                        attemptsUsed: self.automaticReconnectAttemptsUsed
                    )
                else {
                    self.finishAutomaticReconnect(
                        report: ConnectionReportJournal.read(),
                        message: error.localizedDescription
                    )
                    return
                }
                self.scheduleAutomaticReconnectRetry(
                    failedTransactionID: failedTransactionID,
                    delay: nextDelay
                )
            }
        }
    }

    private func finishAutomaticReconnect(
        report: ConnectionReport?,
        message: String?
    ) {
        let exhausted =
            automaticReconnectAttemptsUsed
                >= automaticReconnectRetryPolicy.maxAttempts
        automaticReconnectInProgress = false
        automaticReconnectTrigger = nil
        automaticReconnectTransactionID = nil
        networkExtensionSessionTransactionID = nil
        cancelAutomaticReconnectRetry(resetAttempts: false)
        if let incidentID = activeReconnectIncidentID {
            ReconnectIncidentJournal.finish(
                incidentID: incidentID,
                outcome: exhausted ? "exhausted" : "failed",
                transactionID: report?.transactionID ?? "",
                code: report?.error?.code ?? "",
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
        automaticReconnectRetryWorkItem?.cancel()
        automaticReconnectRetryWorkItem = nil
        automaticReconnectRetryToken = nil
        automaticReconnectRetryAt = nil
        automaticReconnectRetryAttempt = nil
        automaticReconnectRetryFailedTransactionID = nil
        if resetAttempts {
            automaticReconnectAttemptsUsed = 0
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
        if activationPurpose == .installation {
            activationStatusHandler?(.waitingForApproval)
        } else {
            publishRuntimeStatus(
                "connecting",
                error: "请在系统设置的「登录项与扩展 → 网络扩展」中启用 XDial"
            )
        }
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
        if activationPurpose == .installation {
            verifyActivatedExtension()
            return
        }
        finishActivation(.success(()))
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
        let expectedVersion = bundledExtensionVersion ?? "unknown"
        guard
            SystemExtensionActivationVerifier
                .containsReadyCurrentVersion(
                    snapshots,
                    expectedIdentifier: extensionIdentifier,
                    expectedVersion: expectedVersion
                )
        else {
            finishActivation(
                .failure(
                    ManagerError.extensionVerificationFailed(
                        expectedVersion: expectedVersion
                    )
                )
            )
            return
        }
        finishActivation(.success(()))
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

    /// Exact canonical identity for coalescing host notifications. This value
    /// is never logged, persisted, sent to Provider, or exposed by Debug.
    var epochFingerprint: String {
        ([
            "\(defaultInterface.index):\(defaultInterface.name)",
            canonicalInterfaceKeys.joined(separator: ","),
            systemDNSJSON,
        ]).joined(separator: "\u{1F}")
    }

    func isEquivalent(to other: HostUnderlaySnapshot) -> Bool {
        defaultInterface.name == other.defaultInterface.name
            && defaultInterface.index == other.defaultInterface.index
            && canonicalInterfaceKeys == other.canonicalInterfaceKeys
            && systemDNSJSON == other.systemDNSJSON
    }

    func differenceKinds(
        comparedTo other: HostUnderlaySnapshot
    ) -> [String] {
        var kinds: [String] = []
        if defaultInterface.name != other.defaultInterface.name
            || defaultInterface.index != other.defaultInterface.index {
            kinds.append("default-interface")
        }
        if canonicalInterfaceKeys != other.canonicalInterfaceKeys {
            kinds.append("interface-set")
        }
        if systemDNSJSON != other.systemDNSJSON {
            kinds.append("system-dns")
        }
        return kinds
    }

    private var canonicalInterfaceKeys: [String] {
        interfaces.map {
            "\($0.index):\($0.name):\($0.type)"
        }.sorted()
    }
}

private final class HostUnderlayCapture {
    private let monitor = NWPathMonitor()
    private let completion: (Result<HostUnderlaySnapshot, Error>) -> Void
    private var finished = false

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
            finish(.failure(ManagerError.underlayUnavailable))
        }
    }

    private func consume(_ path: Network.NWPath) {
        guard let result = Self.snapshotResult(for: path) else { return }
        finish(result)
    }

    fileprivate static func snapshotResult(
        for path: Network.NWPath
    ) -> Result<HostUnderlaySnapshot, Error>? {
        guard path.status == .satisfied else { return nil }
        var routeError: NSError?
        let routeInterfaceName = LibboxDetectUnderlayInterface(&routeError)
        guard routeError == nil, !routeInterfaceName.isEmpty else {
            if let routeError {
                appLog(
                    "Transparent Proxy default route snapshot unavailable: "
                        + routeError.localizedDescription
                )
            }
            return nil
        }
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
        guard
            let defaultInterface = interfaces.first(where: {
                $0.name == routeInterfaceName
            }),
            let data = try? JSONEncoder().encode(interfaces),
            let interfacesJSON = String(data: data, encoding: .utf8)
        else {
            // 系统默认路由和 NWPath 可能正处在同一次切换的两个不同通知阶段。
            // 等下一份 path 或 3 秒总超时，不能退回 availableInterfaces.first。
            return nil
        }
        guard let systemDNSJSON = Self.captureSystemDNSJSON() else {
            return .failure(ManagerError.systemDNSUnavailable)
        }
        return .success(HostUnderlaySnapshot(
            defaultInterface: defaultInterface,
            interfaces: interfaces,
            interfacesJSON: interfacesJSON,
            systemDNSJSON: systemDNSJSON
        ))
    }

    private func finish(
        _ result: Result<HostUnderlaySnapshot, Error>
    ) {
        guard !finished else {
            return
        }
        finished = true
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
/// 短暂不可用不等于 Underlay 已变化。只有恢复后的接口 / DNS 事实与会话
/// 基线确实不同，才交给宿主做完整数据面重建。
private final class HostUnderlayMonitor {
    private let monitor = NWPathMonitor()
    private let baseline: HostUnderlaySnapshot
    private let onChange: (HostUnderlaySnapshot) -> Void
    private var pendingChange: DispatchWorkItem?
    private var cancelled = false

    init(
        baseline: HostUnderlaySnapshot,
        onChange: @escaping (HostUnderlaySnapshot) -> Void
    ) {
        self.baseline = baseline
        self.onChange = onChange
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.consume(path)
            }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    func cancel() {
        cancelled = true
        pendingChange?.cancel()
        pendingChange = nil
        monitor.pathUpdateHandler = nil
        monitor.cancel()
    }

    private func consume(_ path: Network.NWPath) {
        guard !cancelled else { return }
        guard path.status == .satisfied else {
            pendingChange?.cancel()
            pendingChange = nil
            return
        }
        guard
            let result = HostUnderlayCapture.snapshotResult(for: path),
            case let .success(snapshot) = result
        else {
            return
        }
        guard !snapshot.isEquivalent(to: baseline) else {
            pendingChange?.cancel()
            pendingChange = nil
            return
        }

        // 路由、NWPath 与 DNS 通知并非原子到达。短暂防抖后只使用最后一份
        // 三者一致的快照，避免在切换中间态连续重建。
        scheduleChange()
    }

    private func scheduleChange() {
        pendingChange?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.cancelled else { return }
            guard
                let result = HostUnderlayCapture.snapshotResult(
                    for: self.monitor.currentPath
                ),
                case let .success(snapshot) = result
            else {
                // DNS、默认路由和 NWPath 仍处于中间态；继续等待同一轮变化
                // 收敛，不拿旧快照启动，也不回落到任意接口。
                self.scheduleChange()
                return
            }
            guard !snapshot.isEquivalent(to: self.baseline) else {
                self.pendingChange = nil
                return
            }
            self.cancelled = true
            self.monitor.pathUpdateHandler = nil
            self.monitor.cancel()
            self.onChange(snapshot)
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

/// Separate host-side Switch fact projection. It deliberately does not replace
/// the authoritative committed ConnectionReport while a candidate is pending
/// or when that candidate fails.
struct HostScenarioSwitchProjection: Equatable {
    let status: String
    let fromScenarioID: String
    let toScenarioID: String
    let sourceCommittedTransactionID: String
    let candidateTransactionID: String
    let activeCommittedTransactionID: String
    let inFlight: Bool
    /// Credential-free task state for the candidate generation. It is a
    /// presentation sidecar, never the committed runtime fact.
    let candidateReport: ConnectionReport
    /// Public Line IDs only. Opaque runtime identities never leave Provider
    /// memory or enter this host/Debug projection.
    let reusedLineIDs: [String]
    let code: String?
    let message: String?
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

private struct ProviderScenarioSwitchRejectedError: LocalizedError {
    let code: String
    let message: String?

    var errorDescription: String? {
        if let message, !message.isEmpty {
            return message
        }
        return "场景切换失败（\(code)）"
    }
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
    case deactivationDeferredBySystem
    case rebootRequired
    case stopTimedOut
    case startTimedOut
    case unknownStatus

    var errorDescription: String? {
        switch self {
        case .activationInProgress:
            "XDial 网络扩展正在启用，请稍候"
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
            "macOS 未登记并启用当前 XDial 网络扩展（build \(expectedVersion)）"
        case .deactivationDeferredBySystem:
            "macOS 仍在占用 XDial 网络扩展；请退出其他正在运行的 XDial 后重试卸载"
        case .rebootRequired:
            "XDial 网络扩展需要重启 macOS 后才能启用"
        case .stopTimedOut:
            "旧的 XDial 网络会话未能在 10 秒内断开"
        case .startTimedOut:
            "XDial 数据面未能在 45 秒内启动"
        case .unknownStatus:
            "XDial 网络扩展返回了未知状态"
        }
    }
}
