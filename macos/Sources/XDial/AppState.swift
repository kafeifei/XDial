import AppKit
import Combine
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    #if DEBUG
    static private(set) weak var current: AppState?
    #endif

    @Published var profile: Profile

    @Published var helperInstalled: Bool = false
    /// SMAppService 已注册但等用户在系统设置「登录项」里批准
    @Published var helperNeedsApproval: Bool = false

    /// 配置已改但尚未下发引擎。
    ///
    /// 引擎只在 start 时拿一次 profile 快照，之后 UI 的编辑只落盘、不下发；
    /// 若不显式暴露这个差异，用户切了模式却发现行为没变，只能怀疑是 bug。
    /// v1 的语义是「提示 + 一键重连」：绝不在用户没点的时候自动重启数据面，
    /// 那会造成连接期间无提示断流。
    ///
    /// 这里刻意用「存储位 AND 引擎仍攥着快照」而不是只靠存储位：引擎自己掉线
    /// （链路断了、daemon 重启）时旧快照已经不存在，提示必须立刻消失，而
    /// objectWillChange 是变更前触发的，靠事件回调去清位会慢一拍。
    @Published private var configDirtyFlag = false
    private var configurationChanges =
        ConfigurationDirtyTracker<Profile>()

    var configDirty: Bool { configDirtyFlag && engineHoldsSnapshot }

    @Published var language: Lang {
        didSet {
            xdialDefaults.set(language.rawValue, forKey: "xdial.language")
        }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            xdialDefaults.set(launchAtLogin, forKey: "xdial.launchAtLogin")
            updateLaunchAtLogin()
        }
    }
    @Published var autoConnect: Bool {
        didSet {
            xdialDefaults.set(autoConnect, forKey: "xdial.autoConnect")
            if !autoConnect {
                launchAutoConnectPending = false
            }
        }
    }

    let engine = GoEngine.shared
    let installation = InstallationCoordinator.shared
    private var engineSubs = Set<AnyCancellable>()
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var screenWakeObserver: NSObjectProtocol?
    private var sessionActiveObserver: NSObjectProtocol?
    private var connectionDesired = ConnectionDesiredState()
    private var wakeReconnectGeneration = 0
    private var wakeReconnectTask: Task<Void, Never>?
    @Published private(set) var wakeReconnectPhase:
        WakeReconnectPhase?
    private var systemIsSleeping = false
    private var initialStatusSynchronized = false
    private var launchAutoConnectPending = false
    private var connectionAttempts = ConnectionAttemptGate()

    private let profileKey = "xdial.profile"
    private let keychainPrefix = "xdial-line-"
    private let subKeychainPrefix = "xdial-sub-"
    private var cachedVault: [String: String] = [:]

    /// Tailscale 的登录/节点发现属于配置态，不是 LineRow 的视图状态。
    ///
    /// 关闭设置窗口不能丢掉刚读取的状态；浏览器登录轮询也不能因为卡片被收起而停止。
    /// 这里不持久化 auth URL 或节点列表，App 重启后由显式配置操作重新读取；运行中的
    /// Line 是否已连接则始终由 committed ConnectionReport 决定。
    @Published private var tailscaleConfigurationStatuses:
        [String: TailscaleRuntimeStatus] = [:]
    @Published private var tailscaleConfigurationErrors:
        [String: String] = [:]
    @Published private var tailscaleConfigurationBusyLineIDs:
        Set<String> = []
    private var tailscaleConfigurationPollGenerations:
        [String: Int] = [:]

    func tr(_ zh: String, _ en: String) -> String {
        language == .zh ? zh : en
    }

    var isConnected: Bool { engine.isConnected }
    var isBusy: Bool {
        engine.isBusy || wakeReconnectPhase != nil
    }
    var automaticReconnectState: AutomaticReconnectRuntimeState {
        engine.automaticReconnectState
    }

    var presentedConnectionReport: ConnectionReport? {
        if let wakeReconnectPhase,
           !wakeReconnectPhase.presentsConnectionReport {
            return nil
        }
        return engine.presentedConnectionReport
    }

    func tailscaleConfigurationStatus(
        for lineID: String
    ) -> TailscaleRuntimeStatus? {
        tailscaleConfigurationStatuses[lineID]
    }

    func tailscaleConfigurationError(
        for lineID: String
    ) -> String? {
        tailscaleConfigurationErrors[lineID]
    }

    func isTailscaleConfigurationBusy(
        for lineID: String
    ) -> Bool {
        tailscaleConfigurationBusyLineIDs.contains(lineID)
    }

    func setTailscaleConfigurationStatus(
        _ status: TailscaleRuntimeStatus,
        for lineID: String
    ) {
        tailscaleConfigurationStatuses[lineID] = status
        tailscaleConfigurationErrors.removeValue(forKey: lineID)
    }

    func setTailscaleConfigurationError(
        _ error: String?,
        for lineID: String
    ) {
        if let error, !error.isEmpty {
            tailscaleConfigurationErrors[lineID] = error
        } else {
            tailscaleConfigurationErrors.removeValue(forKey: lineID)
        }
    }

    func setTailscaleConfigurationBusy(
        _ busy: Bool,
        for lineID: String
    ) {
        if busy {
            tailscaleConfigurationBusyLineIDs.insert(lineID)
        } else {
            tailscaleConfigurationBusyLineIDs.remove(lineID)
        }
    }

    func startTailscaleConfigurationPolling(
        lineID: String,
        attempts: Int = 90
    ) {
        let generation =
            (tailscaleConfigurationPollGenerations[lineID] ?? 0) + 1
        tailscaleConfigurationPollGenerations[lineID] = generation
        scheduleTailscaleConfigurationPoll(
            lineID: lineID,
            generation: generation,
            remaining: attempts
        )
    }

    func cancelTailscaleConfigurationPolling(
        lineID: String
    ) {
        tailscaleConfigurationPollGenerations[lineID] =
            (tailscaleConfigurationPollGenerations[lineID] ?? 0) + 1
        tailscaleConfigurationBusyLineIDs.remove(lineID)
    }

    private func scheduleTailscaleConfigurationPoll(
        lineID: String,
        generation: Int,
        remaining: Int
    ) {
        guard remaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            [weak self] in
            guard let self else { return }
            guard
                self.tailscaleConfigurationPollGenerations[lineID]
                    == generation
            else {
                return
            }
            self.engine.tailscaleStatus(lineID: lineID) {
                [weak self] result in
                guard let self else { return }
                guard
                    self.tailscaleConfigurationPollGenerations[lineID]
                        == generation
                else {
                    return
                }
                switch result {
                case let .success(status):
                    self.setTailscaleConfigurationStatus(
                        status,
                        for: lineID
                    )
                    if status.isRunning {
                        self.setTailscaleConfigurationBusy(
                            false,
                            for: lineID
                        )
                        return
                    }
                    self.scheduleTailscaleConfigurationPoll(
                        lineID: lineID,
                        generation: generation,
                        remaining: remaining - 1
                    )
                case let .failure(error):
                    self.setTailscaleConfigurationBusy(
                        false,
                        for: lineID
                    )
                    self.setTailscaleConfigurationError(
                        error.localizedDescription,
                        for: lineID
                    )
                }
            }
        }
    }

    /// 引擎手里是否攥着一份 profile 快照。攥着的时候改配置才产生「双头真相」，
    /// 未连接时改配置下次 connect 自然生效，不需要提示。
    private var engineHoldsSnapshot: Bool {
        switch engine.status {
        case "connected", "connecting", "reconnecting": return true
        default: return false
        }
    }

    var canConnect: Bool {
        // 宿主的唤醒恢复态会让 UI 显示忙碌，但它最终仍要进入这里发起连接。
        // 真正阻止新事务的只能是引擎自身的连接/断开状态。
        guard !engine.isBusy else { return false }
        guard installation.isReady else { return false }
        guard let s = activeMode else { return false }
        // 必须有效的 VPN 凭据（如果模式用到 VPN）
        for binding in s.bindings {
            if let line = profile.lines.first(where: { $0.id == binding.lineID }),
               line.type == "vpn",
               (line.vpnServer.isEmpty || line.vpnUsername.isEmpty || line.vpnPassword.isEmpty) {
                return false
            }
        }
        if let line = profile.lines.first(where: { $0.id == s.defaultLineID }),
           line.type == "vpn",
           (line.vpnServer.isEmpty || line.vpnUsername.isEmpty || line.vpnPassword.isEmpty) {
            return false
        }
        return true
    }

    var statusText: String {
        if let wakeReconnectPhase {
            return tr(
                wakeReconnectPhase.zhStatusText,
                wakeReconnectPhase.enStatusText
            )
        }
        switch engine.status {
        case "connected": return tr("已连接", "Connected")
        case "connecting":
            if let task = engine.presentedConnectionReport?.currentTask {
                return task.name
            }
            return tr("正在连接…", "Connecting…")
        case "disconnecting": return tr("正在断开…", "Disconnecting…")
        case "reconnecting":
            if let task = engine.presentedConnectionReport?.currentTask {
                return task.name
            }
            return tr("正在重连…", "Reconnecting…")
        default:
            if let report = presentedConnectionReport,
               let failure = report.error,
               !failure.message.isEmpty {
                return failure.message
            }
            if let err = engine.lastError { return err }
            return tr("未连接", "Not Connected")
        }
    }

    var activeMode: Mode? {
        profile.modes.first { $0.id == profile.activeModeID }
    }

    var activeSubscriptions: [Subscription] {
        guard let mode = activeMode else { return [] }
        var ids = Set(mode.bindings.compactMap {
            $0.subscriptionID.isEmpty ? nil : $0.subscriptionID
        })
        if !mode.defaultSubscriptionID.isEmpty {
            ids.insert(mode.defaultSubscriptionID)
        }
        return profile.subscriptions.filter { ids.contains($0.id) && $0.enabled }
    }

    /// macOS Packet Tunnel 试验版启用了 App Sandbox，配置因此落在容器目录。
    /// 桌面端回到 root helper 后，进程重新使用正常用户目录；这里做一次有界迁移，
    /// 只搬 XDial 自己的 profile/语言/登录项开关，不触碰任何系统网络配置。
    private static func importSandboxPreferencesIfNeeded() {
        let marker = "xdial.migratedFromSandboxProfileV1"
        let defaults = xdialDefaults
        guard !defaults.bool(forKey: marker) else { return }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let source = home.appendingPathComponent(
            "Library/Containers/com.kafeifei.xdial/Data/Library/Preferences/com.kafeifei.xdial.plist"
        )
        guard let values = NSDictionary(contentsOf: source),
              let profileData = values["xdial.profile"] as? Data else { return }

        let destination = home.appendingPathComponent(
            "Library/Preferences/com.kafeifei.xdial.plist"
        )
        let sourceValues = try? source.resourceValues(forKeys: [.contentModificationDateKey])
        let destinationValues = try? destination.resourceValues(
            forKeys: [.contentModificationDateKey]
        )
        let sourceDate = sourceValues?.contentModificationDate ?? .distantPast
        let destinationDate = destinationValues?.contentModificationDate ?? .distantPast

        // 已经在非沙盒版本里改过更新配置时，不用更旧的试验版快照覆盖它。
        if defaults.data(forKey: "xdial.profile") == nil || sourceDate > destinationDate {
            defaults.set(profileData, forKey: "xdial.profile")
            if let language = values["xdial.language"] as? String {
                defaults.set(language, forKey: "xdial.language")
            }
            if let launchAtLogin = values["xdial.launchAtLogin"] as? Bool {
                defaults.set(launchAtLogin, forKey: "xdial.launchAtLogin")
            }
            KeychainStore.importSandboxVaultIfNeeded()
            appLog("migrated Packet Tunnel sandbox profile into desktop helper app")
        }
        defaults.set(true, forKey: marker)
    }

    init() {
        // 先用 bootstrap 初始化，loadSaved 后会被覆盖
        self.profile = Profile.bootstrap()

        Self.importSandboxPreferencesIfNeeded()

        // 语言：先读已保存，没有则用系统语言
        if let savedLang = xdialDefaults.string(forKey: "xdial.language"),
           let lang = Lang(rawValue: savedLang) {
            self.language = lang
        } else {
            self.language = .system
        }
        self.launchAtLogin = xdialDefaults.bool(forKey: "xdial.launchAtLogin")
        if let savedAutoConnect = xdialDefaults.object(
            forKey: "xdial.autoConnect"
        ) as? Bool {
            self.autoConnect = savedAutoConnect
        } else {
            self.autoConnect = AutomaticConnectionPolicy.defaultEnabled
            xdialDefaults.set(
                self.autoConnect,
                forKey: "xdial.autoConnect"
            )
        }

        engine.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &engineSubs)
        installation.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &engineSubs)
        installation.$report
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.checkHelper()
                    self.runLaunchAutoConnectIfNeeded()
                }
            }
            .store(in: &engineSubs)
        engine.$status
            .combineLatest(engine.$connectionReport)
            .sink { [weak self] _, _ in
                // @Published 在 willSet 时发送。延后一轮再读取两份属性，避免把
                // “旧 status + 新 report”或“新 status + 旧 report”拼成假事实。
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let status = self.engine.status
                    let report = self.engine.connectionReport
                    if self.initialStatusSynchronized {
                        self.synchronizeConnectionDesiredState(
                            runtimeStatus: status,
                            report: report
                        )
                    }
                    if self.wakeReconnectPhase == .startingConnection,
                       AutomaticConnectionPolicy.holdsConnectionIntent(
                           runtimeStatus: status
                       ) {
                        self.wakeReconnectPhase = nil
                    }
                    if status == "connected", let report {
                        self.markUsedLinesVerified(report: report)
                    }
                    self.synchronizeLineObservations(
                        status: status,
                        report: report
                    )
                    self.runLaunchAutoConnectIfNeeded()
                    self.restoreAdoptedRuntimeIfNeeded(
                        runtimeStatus: status
                    )
                }
            }
            .store(in: &engineSubs)
        loadSaved()
        configurationChanges.load(
            Self.runtimeConfigurationSnapshot(profile)
        )
        checkHelper()
        installation.start()
        launchAutoConnectPending = autoConnect
        registerSleepWakeObservers()
        engine.syncStatus { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.initialStatusSynchronized = true
                self.synchronizeConnectionDesiredState(
                    runtimeStatus: self.engine.status,
                    report: self.engine.connectionReport
                )
                self.runLaunchAutoConnectIfNeeded()
            }
        }
        #if DEBUG
        Self.current = self
        Self.debugServer.start()
        #endif
    }

    deinit {
        wakeReconnectTask?.cancel()
        let notificationCenter = NSWorkspace.shared.notificationCenter
        if let sleepObserver {
            notificationCenter.removeObserver(sleepObserver)
        }
        if let wakeObserver {
            notificationCenter.removeObserver(wakeObserver)
        }
        if let screenWakeObserver {
            notificationCenter.removeObserver(screenWakeObserver)
        }
        if let sessionActiveObserver {
            notificationCenter.removeObserver(sessionActiveObserver)
        }
    }

    #if DEBUG
    private static let debugServer = DebugServer()
    #endif

    /// 出口观察只能跟随 Provider 已提交的 ConnectionReport。
    /// 当前正在编辑的 Profile、设置页生命周期和旧 helper 都不是运行事实来源。
    private func synchronizeLineObservations(
        status: String,
        report: ConnectionReport?
    ) {
        guard let runtime = ConnectionReportRuntimeFacts.committedLines(
            status: status,
            report: report
        ) else {
            NetworkInfo.shared.clear()
            return
        }
        let pending = NetworkInfo.shared.begin(
            transactionID: runtime.transactionID,
            lineIDs: runtime.lineIDs
        )
        probeLineObservationsSequentially(
            pending[...],
            transactionID: runtime.transactionID
        )
    }

    /// Provider 只允许一个出口探测租约。宿主按 ConnectionPlan 顺序串行发送，
    /// 既保持报告顺序稳定，也避免把并发拒绝误显示为 Line 故障。
    private func probeLineObservationsSequentially(
        _ pending: ArraySlice<String>,
        transactionID: String
    ) {
        guard let lineID = pending.first else { return }
        guard isCurrentObservationTransaction(transactionID) else {
            return
        }
        engine.probeLineOutboundAddress(
            transactionID: transactionID,
            lineID: lineID
        ) { [weak self] result in
            guard let self else { return }
            guard self.isCurrentObservationTransaction(
                transactionID
            ) else {
                return
            }
            switch result {
            case let .success(address):
                NetworkInfo.shared.recordAddress(
                    address,
                    lineID: lineID,
                    transactionID: transactionID
                )
            case let .failure(error):
                let errorCode =
                    (error as? ProviderDiagnosticsHostError)?.code
                        ?? "provider-line-probe-failed"
                NetworkInfo.shared.recordFailure(
                    code: errorCode,
                    lineID: lineID,
                    transactionID: transactionID
                )
            }
            self.probeLineObservationsSequentially(
                pending.dropFirst(),
                transactionID: transactionID
            )
        }
    }

    private func isCurrentObservationTransaction(
        _ transactionID: String
    ) -> Bool {
        guard
            let report = engine.connectionReport,
            report.transactionID == transactionID,
            ConnectionReportRuntimeFacts.committedLines(
                status: engine.status,
                report: report
            )?.transactionID == transactionID
        else {
            return false
        }
        return true
    }

    private func updateLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                engine.lastError = tr("设置开机启动失败: \(error.localizedDescription)",
                                      "Failed to update login item: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Automatic connection and sleep / wake

    var desiredConnectionStateForDiagnostics: String {
        switch connectionDesired.value {
        case .unresolved:
            return "unresolved"
        case .disconnected(explicit: true):
            return "disconnected_explicit"
        case .disconnected(explicit: false):
            return "disconnected"
        case .connected:
            return "connected"
        }
    }

    var desiredConnectionModeIDForDiagnostics: String {
        connectionDesired.modeID ?? ""
    }

    var desiredConnectionOwnershipForDiagnostics: String {
        connectionDesired.runtimeOwnership?.rawValue ?? ""
    }

    var systemIsSleepingForDiagnostics: Bool { systemIsSleeping }

    private func synchronizeConnectionDesiredState(
        runtimeStatus: String,
        report: ConnectionReport?
    ) {
        if AutomaticConnectionPolicy.holdsConnectionIntent(
            runtimeStatus: runtimeStatus
        ) {
            let modeID = report?.mode.id ?? activeMode?.id ?? ""
            if !modeID.isEmpty {
                connectionDesired.observeExistingConnection(modeID: modeID)
            }
            return
        }

        if runtimeStatus == "disconnected", !launchAutoConnectPending {
            connectionDesired.settleInitialDisconnection()
        }
    }

    private func runLaunchAutoConnectIfNeeded() {
        guard initialStatusSynchronized, !systemIsSleeping else { return }
        synchronizeConnectionDesiredState(
            runtimeStatus: engine.status,
            report: engine.connectionReport
        )
        guard launchAutoConnectPending else { return }

        if AutomaticConnectionPolicy.holdsConnectionIntent(
            runtimeStatus: engine.status
        ) {
            // 冷启动时系统里已经有一笔有效事务，不能再创建第二笔；但这份
            // 自动连接请求也不能在这里被消费。安装事务可能紧接着替换
            // System Extension，使旧 Provider 会话掉线。请求要一直保留到
            // 真正发起新连接，或用户明确断开。
            return
        }
        guard installation.isReady else { return }
        guard engine.status == "disconnected" else { return }
        guard canConnect else {
            launchAutoConnectPending = false
            connectionDesired.settleInitialDisconnection()
            appLog(
                "launch auto-connect skipped: active Mode is not ready"
            )
            return
        }
        guard AutomaticConnectionPolicy.shouldConnectOnLaunch(
            enabled: autoConnect,
            initialStatusSynchronized: initialStatusSynchronized,
            installationReady: installation.isReady,
            runtimeStatus: engine.status,
            canConnect: canConnect
        ) else {
            launchAutoConnectPending = false
            connectionDesired.settleInitialDisconnection()
            return
        }

        launchAutoConnectPending = false
        appLog("launch auto-connect started")
        connectAutomatically()
    }

    private func registerSleepWakeObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        sleepObserver = notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWillSleep()
            }
        }
        wakeObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWakeSignal(trigger: "workspace_did_wake")
            }
        }
        screenWakeObserver = notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWakeSignal(trigger: "screens_did_wake")
            }
        }
        sessionActiveObserver = notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWakeSignal(trigger: "session_did_become_active")
            }
        }
    }

    private func handleWillSleep() {
        systemIsSleeping = true
        cancelWakeReconnectTask()
        synchronizeConnectionDesiredState(
            runtimeStatus: engine.status,
            report: engine.connectionReport
        )
        connectionAttempts.cancel()
        let action = DesiredConnectionReconcilePolicy.decide(
            desired: connectionDesired,
            activeModeID: activeMode?.id ?? "",
            systemIsSleeping: systemIsSleeping,
            runtimeStatus: engine.status,
            canConnect: canConnect,
            networkWaitCompleted: false
        )
        guard action == .stopRuntime else { return }

        appLog("system will sleep: stopping active connection transaction")
        NetworkInfo.shared.clear()
        configDirtyFlag = false
        configurationChanges.clear()
        reconnectGeneration += 1
        reconnecting = false
        engine.stop()
    }

    private func handleWakeSignal(trigger: String) {
        systemIsSleeping = false
        synchronizeConnectionDesiredState(
            runtimeStatus: engine.status,
            report: engine.connectionReport
        )
        reconcileDesiredConnection(trigger: trigger)
    }

    private func restoreAdoptedRuntimeIfNeeded(
        runtimeStatus: String
    ) {
        guard initialStatusSynchronized,
              installation.isReady,
              !systemIsSleeping,
              runtimeStatus == "disconnected",
              connectionDesired.beginRestoringAdoptedRuntime()
        else {
            return
        }
        appLog(
            "adopted runtime disconnected: current host claimed recovery"
        )
        reconcileDesiredConnection(trigger: "adopted_runtime_lost")
    }

    private func reconcileDesiredConnection(trigger: String) {
        guard connectionDesired.wantsConnection else {
            let action = DesiredConnectionReconcilePolicy.decide(
                desired: connectionDesired,
                activeModeID: activeMode?.id ?? "",
                systemIsSleeping: systemIsSleeping,
                runtimeStatus: engine.status,
                canConnect: canConnect,
                networkWaitCompleted: false
            )
            if action == .stopRuntime {
                cancelWakeReconnectTask()
                engine.stop(userInitiated: true)
            }
            runLaunchAutoConnectIfNeeded()
            return
        }
        if wakeReconnectTask != nil
            || wakeReconnectPhase == .startingConnection {
            appLog("wake signal \(trigger): reconcile already in progress")
            return
        }

        let action = DesiredConnectionReconcilePolicy.decide(
            desired: connectionDesired,
            activeModeID: activeMode?.id ?? "",
            systemIsSleeping: systemIsSleeping,
            runtimeStatus: engine.status,
            canConnect: canConnect,
            networkWaitCompleted: false
        )
        switch action {
        case .none:
            cancelWakeReconnectTask()
        case .waitForRuntime, .waitForNetwork:
            scheduleDesiredConnectionReconcile(trigger: trigger)
        case .stopRuntime:
            cancelWakeReconnectTask()
            engine.stop(userInitiated: true)
        case .waitForWake:
            cancelWakeReconnectTask()
        case let .modeChanged(expectedModeID, activeModeID):
            failDesiredConnectionReconcile(
                message: tr(
                    "无法恢复连接：当前模式已变化，请手动连接",
                    "Could not restore the connection because the active Mode changed"
                ),
                log: "connection restore blocked: desired Mode \(expectedModeID), active Mode \(activeModeID)"
            )
        case .configurationUnavailable:
            failDesiredConnectionReconcile(
                message: tr(
                    "无法自动恢复连接，请检查当前模式配置",
                    "Could not restore the connection; check the active Mode configuration"
                ),
                log: "connection restore blocked: active Mode is not ready"
            )
        case .startAutomatically:
            // networkWaitCompleted 为 false 时不会直接进入 start。
            scheduleDesiredConnectionReconcile(trigger: trigger)
        }
    }

    private func scheduleDesiredConnectionReconcile(trigger: String) {
        wakeReconnectGeneration += 1
        let generation = wakeReconnectGeneration
        wakeReconnectTask?.cancel()
        wakeReconnectPhase = engine.status == "disconnected"
            ? .waitingForNetwork
            : .finishingDisconnect
        appLog(
            "connection reconcile trigger \(trigger)"
        )
        wakeReconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == self.wakeReconnectGeneration {
                    self.wakeReconnectTask = nil
                }
            }
            let disconnected = await self.waitForEngineToDisconnect(
                generation: generation,
                timeout: 12
            )
            guard
                disconnected,
                generation == self.wakeReconnectGeneration,
                !self.systemIsSleeping,
                !Task.isCancelled
            else {
                if generation == self.wakeReconnectGeneration,
                   !self.systemIsSleeping,
                   !Task.isCancelled {
                    self.wakeReconnectPhase = nil
                    self.engine.lastError = self.tr(
                        "唤醒后无法完成断开，请手动重连",
                        "Could not finish disconnecting after wake; reconnect manually"
                    )
                }
                return
            }

            self.wakeReconnectPhase = .waitingForNetwork
            let networkReady = await NetworkAvailabilityWaiter.wait(
                timeout: 8
            )
            guard generation == self.wakeReconnectGeneration,
                  !self.systemIsSleeping,
                  !Task.isCancelled else {
                return
            }
            if !networkReady {
                // 与 XDVPN 一致：等待有上限；超时后仍进入正常连接事务，
                // 由 Underlay 捕获与结构化报告 fail-closed，而不是无限挂起。
                appLog(
                    "wake reconnect network wait timed out; "
                        + "starting bounded connection transaction"
                )
            }
            let action = DesiredConnectionReconcilePolicy.decide(
                desired: self.connectionDesired,
                activeModeID: self.activeMode?.id ?? "",
                systemIsSleeping: self.systemIsSleeping,
                runtimeStatus: self.engine.status,
                canConnect: self.canConnect,
                networkWaitCompleted: true
            )
            switch action {
            case let .startAutomatically(modeID):
                appLog("wake reconnect started for Mode \(modeID)")
                self.wakeReconnectPhase = .startingConnection
                if !self.connectAutomatically(expectedModeID: modeID) {
                    self.wakeReconnectPhase = nil
                }
            case .none:
                self.wakeReconnectPhase = nil
            case let .modeChanged(expectedModeID, activeModeID):
                self.failDesiredConnectionReconcile(
                    message: self.tr(
                        "无法恢复连接：当前模式已变化，请手动连接",
                        "Could not restore the connection because the active Mode changed"
                    ),
                    log: "connection restore blocked: desired Mode \(expectedModeID), active Mode \(activeModeID)"
                )
            case .configurationUnavailable:
                self.failDesiredConnectionReconcile(
                    message: self.tr(
                        "无法自动恢复连接，请检查当前模式配置",
                        "Could not restore the connection; check the active Mode configuration"
                    ),
                    log: "connection restore blocked: active Mode is not ready"
                )
            case .stopRuntime:
                self.wakeReconnectPhase = nil
                self.engine.stop(userInitiated: true)
            case .waitForWake, .waitForRuntime, .waitForNetwork:
                self.wakeReconnectPhase = nil
            }
        }
    }

    private func failDesiredConnectionReconcile(
        message: String,
        log: String
    ) {
        cancelWakeReconnectTask()
        engine.lastError = message
        appLog(log)
    }

    private func waitForEngineToDisconnect(
        generation: Int,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if engine.status == "disconnected" { return true }
            if generation != wakeReconnectGeneration { return false }
            if systemIsSleeping || Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return engine.status == "disconnected"
    }

    private func cancelWakeReconnectTask() {
        wakeReconnectGeneration += 1
        wakeReconnectTask?.cancel()
        wakeReconnectTask = nil
        wakeReconnectPhase = nil
    }

    func uninstall(deleteData: Bool, completion: @escaping (Bool, String?) -> Void) {
        connectionDesired.userRequestedDisconnection()
        connectionAttempts.cancel()
        launchAutoConnectPending = false
        cancelWakeReconnectTask()
        if launchAtLogin { launchAtLogin = false }
        ApplicationUninstaller.run(
            deleteData: deleteData
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.helperInstalled = false
                completion(true, nil)
            case let .failure(error):
                completion(false, error.localizedDescription)
            }
        }
    }

    private var lastVerifiedTransactionID = ""

    private func markUsedLinesVerified(report: ConnectionReport) {
        guard
            let runtime = ConnectionReportRuntimeFacts.committedLines(
                status: engine.status,
                report: report
            ),
            engine.connectionReport?.transactionID ==
                runtime.transactionID
        else {
            return
        }
        if lastVerifiedTransactionID == runtime.transactionID {
            return
        }
        lastVerifiedTransactionID = runtime.transactionID
        let usedIDs = Set(runtime.lineIDs)

        var changed = false
        for i in profile.lines.indices where usedIDs.contains(profile.lines[i].id) {
            if !profile.lines[i].verified {
                profile.lines[i].verified = true
                changed = true
            }
        }
        // verified 只是"这条线路通过过"的展示标记，不进数据面，
        // 不能因为它把刚连上的会话标成"配置已修改"
        if changed { save(markDirty: false) }
    }

    // MARK: - Connect

    func connect() {
        guard let activeMode else { return }
        connectionDesired.userRequestedConnection(modeID: activeMode.id)
        cancelWakeReconnectTask()
        beginConnection()
    }

    @discardableResult
    private func connectAutomatically(
        expectedModeID: String? = nil
    ) -> Bool {
        guard let activeMode else { return false }
        if let expectedModeID, expectedModeID != activeMode.id {
            appLog(
                "automatic connection ignored: desired Mode "
                    + "\(expectedModeID), active Mode \(activeMode.id)"
            )
            return false
        }
        guard connectionDesired.automaticConnectionRequested(
            modeID: activeMode.id
        ) else {
            appLog("automatic connection ignored after explicit disconnect")
            return false
        }
        beginConnection(automaticRetryTrigger: .automaticConnection)
        return true
    }

    private func beginConnection(
        automaticRetryTrigger: AutomaticReconnectTrigger? = nil
    ) {
        guard installation.isReady else {
            installation.start()
            installation.present()
            return
        }
        guard canConnect else { return }
        let generation = connectionAttempts.begin()
        NetworkInfo.shared.clear()
        // 这次 save 本身就是在下发前落盘，不该把自己标成"未下发"
        save(markDirty: false)
        configurationChanges.markApplied(
            Self.runtimeConfigurationSnapshot(profile)
        )
        configDirtyFlag = false
        let profileJSON = buildProfileJSON()
        let tailscaleLineIDs = profile.lines
            .filter { $0.type == "tailscale" }
            .map(\.id)
        for lineID in tailscaleLineIDs {
            cancelTailscaleConfigurationPolling(lineID: lineID)
        }
        stopTailscaleSetupSessions(
            lineIDs: tailscaleLineIDs,
            profileJSON: profileJSON,
            generation: generation,
            automaticRetryTrigger: automaticRetryTrigger
        )
    }

    private func stopTailscaleSetupSessions(
        lineIDs: [String],
        profileJSON: String,
        generation: Int,
        automaticRetryTrigger: AutomaticReconnectTrigger?
    ) {
        guard connectionAttempts.isCurrent(generation) else { return }
        guard let lineID = lineIDs.first else {
            engine.start(
                profileJSON: profileJSON,
                automaticRetryTrigger: automaticRetryTrigger
            )
            return
        }
        engine.stopTailscaleSetup(lineID: lineID) { [weak self] in
            guard let self,
                  self.connectionAttempts.isCurrent(generation) else {
                return
            }
            self.stopTailscaleSetupSessions(
                lineIDs: Array(lineIDs.dropFirst()),
                profileJSON: profileJSON,
                generation: generation,
                automaticRetryTrigger: automaticRetryTrigger
            )
        }
    }

    func retryAutomaticReconnectNow() {
        guard engine.retryAutomaticReconnectNow() else { return }
        objectWillChange.send()
    }

    func disconnect() {
        // 用户明确断开必须压过尚未消费的冷启动自动连接意图。
        connectionDesired.userRequestedDisconnection()
        launchAutoConnectPending = false
        connectionAttempts.cancel()
        cancelWakeReconnectTask()
        NetworkInfo.shared.clear()
        // 引擎不再攥着旧快照，残留提示没有意义
        configDirtyFlag = false
        configurationChanges.clear()
        // 作废进行中的重连，免得它在用户明确要求断开之后又把连接拉起来
        reconnectGeneration += 1
        reconnecting = false
        engine.stop(userInitiated: true)
    }

    /// 每发起一次重连就 +1。进行中的等待循环每轮比对，代次对不上就自行退场 ——
    /// 比 Task.cancel 更严实：不会出现旧任务醒来后覆盖新任务状态。
    private var reconnectGeneration = 0
    private var reconnecting = false

    /// 一键重连：把当前配置重新下发给引擎。
    ///
    /// Go 侧 Engine.Start 在 connected/connecting/reconnecting 时直接报 "already ..."，
    /// 所以必须先 stop、等它真的落到 disconnected 再 start。等待有上限（10s），
    /// 超时就报错而不是无限等下去。
    func reconnect() {
        guard canConnect, !reconnecting else { return }
        if !engineHoldsSnapshot {
            // 引擎手里本来就没有快照（自己掉线了），直接连即可
            connect()
            return
        }
        connectionAttempts.cancel()
        save(markDirty: false)
        reconnectGeneration += 1
        let gen = reconnectGeneration
        reconnecting = true
        engine.stop()
        Task { [weak self] in
            for _ in 0..<100 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, gen == self.reconnectGeneration else { return }
                // 必须等到 disconnected 本身：disconnecting 期间 canConnect 为 false，
                // 这时 connect() 会静默返回，重连就悄悄失败了。
                if self.engine.status == "disconnected" {
                    self.reconnecting = false
                    self.connect()
                    return
                }
            }
            guard let self, gen == self.reconnectGeneration else { return }
            self.reconnecting = false
            self.engine.lastError = self.tr(
                "重连超时：引擎未能在 10 秒内断开，请手动断开后再连接",
                "Reconnect timed out: engine did not stop within 10s — disconnect manually and retry")
        }
    }

    // MARK: - Intents（UI 与 DebugServer 共用的唯一入口）
    //
    // DebugServer 绝不能自己改 profile —— 那会绕开这里的门禁与 dirty 置位，
    // 让调试验收给出"看起来生效了"的假象。

    /// 激活模式。UI 的模式 Picker、设置窗口的激活按钮、DebugServer 的 select-mode
    /// 全部走这一条路径。
    @discardableResult
    func activateMode(_ id: String) -> Bool {
        guard profile.modes.contains(where: { $0.id == id }) else { return false }
        guard profile.activeModeID != id else { return true }
        profile.activeModeID = id
        save()
        return true
    }

    /// 兼容既有 UI / Debug intent；实际执行统一进入完整安装事务。
    func setupHelper(thenConnect: Bool = false) {
        installation.retry()
        guard thenConnect else { return }
        Task { [weak self] in
            for _ in 0..<180 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                if self.installation.isReady {
                    self.connect()
                    return
                }
                if self.installation.report.state == .failed {
                    return
                }
            }
        }
    }

    @discardableResult
    func requireInstallationReady() -> Bool {
        guard installation.isReady else {
            installation.start()
            installation.present()
            return false
        }
        return true
    }

    // MARK: - Persistence

    /// 落盘 profile。
    ///
    /// - Parameter markDirty: 是否把这次改动记成"引擎尚未拿到"。默认 true —— 所有
    ///   用户编辑都算。只有两类内部写入传 false：连接前的落盘（马上就下发了），
    ///   以及 verified 这类纯展示标记的回写（不影响数据面行为）。
    func save(markDirty: Bool = true) {
        if profile.lines.contains(where: { $0.type == "tailscale" }),
           profile.tailscale.hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            profile.tailscale.hostname = Self.newTailscaleHostname()
        }
        // 先把所有 ASCII 字段做一次全角→半角清洗（兜底）
        for i in profile.lines.indices {
            profile.lines[i].vpnServer = profile.lines[i].vpnServer.normalizedASCII()
            profile.lines[i].vpnUsername = profile.lines[i].vpnUsername.normalizedASCII()
            profile.lines[i].vpnPassword = profile.lines[i].vpnPassword.normalizedASCII()
            profile.lines[i].trojanServer = profile.lines[i].trojanServer.normalizedASCII()
            profile.lines[i].trojanPassword = profile.lines[i].trojanPassword.normalizedASCII()
            profile.lines[i].trojanSNI = profile.lines[i].trojanSNI.normalizedASCII()
            profile.lines[i].ssServer = profile.lines[i].ssServer.normalizedASCII()
            profile.lines[i].ssMethod = profile.lines[i].ssMethod.normalizedASCII()
            profile.lines[i].ssPassword = profile.lines[i].ssPassword.normalizedASCII()
            profile.lines[i].vmessServer = profile.lines[i].vmessServer.normalizedASCII()
            profile.lines[i].vmessUUID = profile.lines[i].vmessUUID.normalizedASCII()
            profile.lines[i].anytlsServer = profile.lines[i].anytlsServer.normalizedASCII()
            profile.lines[i].anytlsPassword = profile.lines[i].anytlsPassword.normalizedASCII()
            profile.lines[i].anytlsSNI = profile.lines[i].anytlsSNI.normalizedASCII()
        }
        for i in profile.ruleSets.indices {
            profile.ruleSets[i].url = profile.ruleSets[i].url.normalizedASCII()
        }
        // 直连恒为已验证
        for i in profile.lines.indices where profile.lines[i].type == "direct" {
            profile.lines[i].verified = true
        }

        // 所有密码收集到一个 vault dict，一次性存入 Keychain（只弹一次授权）
        var vault = [String: String]()
        var sanitized = profile

        for i in sanitized.lines.indices {
            let id = sanitized.lines[i].id
            if !sanitized.lines[i].vpnPassword.isEmpty {
                vault[id + "-vpn"] = sanitized.lines[i].vpnPassword
                sanitized.lines[i].vpnPassword = ""
            }
            if !sanitized.lines[i].trojanPassword.isEmpty {
                vault[id + "-trojan"] = sanitized.lines[i].trojanPassword
                sanitized.lines[i].trojanPassword = ""
            }
            if !sanitized.lines[i].ssPassword.isEmpty {
                vault[id + "-ss"] = sanitized.lines[i].ssPassword
                sanitized.lines[i].ssPassword = ""
            }
            if !sanitized.lines[i].vmessUUID.isEmpty {
                vault[id + "-vmess"] = sanitized.lines[i].vmessUUID
                sanitized.lines[i].vmessUUID = ""
            }
            if !sanitized.lines[i].anytlsPassword.isEmpty {
                vault[id + "-anytls"] = sanitized.lines[i].anytlsPassword
                sanitized.lines[i].anytlsPassword = ""
            }
        }
        for si in sanitized.subscriptions.indices {
            let subID = sanitized.subscriptions[si].id
            for pi in sanitized.subscriptions[si].lines.indices {
                let lineID = sanitized.subscriptions[si].lines[pi].id
                let k = subID + "-" + lineID
                let line = sanitized.subscriptions[si].lines[pi]
                if !line.trojanPassword.isEmpty {
                    vault[k + "-trojan"] = line.trojanPassword
                    sanitized.subscriptions[si].lines[pi].trojanPassword = ""
                }
                if !line.ssPassword.isEmpty {
                    vault[k + "-ss"] = line.ssPassword
                    sanitized.subscriptions[si].lines[pi].ssPassword = ""
                }
                if !line.vmessUUID.isEmpty {
                    vault[k + "-vmess"] = line.vmessUUID
                    sanitized.subscriptions[si].lines[pi].vmessUUID = ""
                }
                if !line.anytlsPassword.isEmpty {
                    vault[k + "-anytls"] = line.anytlsPassword
                    sanitized.subscriptions[si].lines[pi].anytlsPassword = ""
                }
            }
        }

        if vault != cachedVault {
            KeychainStore.saveVault(vault)
            cachedVault = vault
        }

        guard let data = try? JSONEncoder().encode(sanitized) else { return }
        xdialDefaults.set(data, forKey: profileKey)

        configurationChanges.recordSave(
            Self.runtimeConfigurationSnapshot(profile),
            markDirty: markDirty,
            engineHoldsSnapshot: engineHoldsSnapshot
        )
        configDirtyFlag = configurationChanges.isDirty
        synchronizeLineObservations(
            status: engine.status,
            report: engine.connectionReport
        )
    }

    private func loadSaved() {
        guard let data = xdialDefaults.data(forKey: profileKey) else {
            appLog("loadSaved: no saved data, using bootstrap")
            return  // 第一次启动，保留 bootstrap
        }
        appLog("loadSaved: found \(data.count) bytes")

        // 先把原始 JSON 解成字典，做「旧命名 → 新命名」的精确 key 重写：
        // 比喻命名时代（ports/cargoes/cruises/active_cruise_id/cargo_id/port_id/
        // default_port_id）持久化的 profile，key 与新 CodingKeys 不一致。由于 Profile
        // 的所有 key 都是 decodeIfPresent，直接解码旧数据不会抛错、而是静默得到空 profile，
        // 因此必须在解码前把旧 key 改写成新 key（严格精确匹配，绝不子串替换，避免误伤
        // trojan_port / default_subscription_id 等含 "port" 子串的字段）。
        var rewrittenData = data
        var didKeyRewrite = false
        if let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           Self.hasLegacyMetaphorKeys(raw) {
            let migrated = Self.rewriteLegacyMetaphorKeys(raw)
            if let d = try? JSONSerialization.data(withJSONObject: migrated) {
                rewrittenData = d
                didKeyRewrite = true
                appLog("loadSaved: rewrote legacy metaphor keys → new schema")
            }
        }

        // 优先按新格式解析；失败再按更旧格式（v0.2 exits/rules/strategies）迁移
        var loaded: Profile
        do {
            loaded = try JSONDecoder().decode(Profile.self, from: rewrittenData)
            appLog("loadSaved: decoded OK, \(loaded.lines.count) lines, \(loaded.modes.count) modes, \(loaded.subscriptions.count) subs")
        } catch {
            appLog("loadSaved: decode failed: \(error)")
            if let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let migrated = Self.migrate(oldProfile: old) {
                loaded = migrated
                appLog("Profile: migrated from old schema")
            } else {
                appLog("loadSaved: migration also failed, using bootstrap")
                return
            }
        }

        // 从 vault（单条目）恢复密码，回退到旧的逐条方式（迁移）
        var vault = KeychainStore.loadVault()
        cachedVault = vault
        var didMigrate = didKeyRewrite
        if vault.isEmpty {
            didMigrate = true
            // 迁移：从旧的逐条 Keychain 读取（含旧的 "xdial-port-" 前缀）
            let oldPrefixes = [keychainPrefix, "xdial-port-", "xdial-exit-"]
            for line in loaded.lines {
                for pfx in oldPrefixes {
                    for suffix in ["vpn", "trojan", "ss", "vmess", "anytls"] {
                        if let v = KeychainStore.load(account: pfx + line.id + "-" + suffix), !v.isEmpty {
                            vault[line.id + "-" + suffix] = v
                        }
                    }
                }
            }
            appLog("loadSaved: migrated \(vault.count) passwords to vault")
        }

        for i in loaded.lines.indices {
            let id = loaded.lines[i].id
            if let v = vault[id + "-vpn"] { loaded.lines[i].vpnPassword = v }
            if let v = vault[id + "-trojan"] { loaded.lines[i].trojanPassword = v }
            if let v = vault[id + "-ss"] { loaded.lines[i].ssPassword = v }
            if let v = vault[id + "-vmess"] { loaded.lines[i].vmessUUID = v }
            if let v = vault[id + "-anytls"] { loaded.lines[i].anytlsPassword = v }
        }
        for si in loaded.subscriptions.indices {
            let subID = loaded.subscriptions[si].id
            for pi in loaded.subscriptions[si].lines.indices {
                let lineID = loaded.subscriptions[si].lines[pi].id
                let k = subID + "-" + lineID
                if let v = vault[k + "-trojan"] { loaded.subscriptions[si].lines[pi].trojanPassword = v }
                if let v = vault[k + "-ss"] { loaded.subscriptions[si].lines[pi].ssPassword = v }
                if let v = vault[k + "-vmess"] { loaded.subscriptions[si].lines[pi].vmessUUID = v }
                if let v = vault[k + "-anytls"] { loaded.subscriptions[si].lines[pi].anytlsPassword = v }
            }
        }

        // 自愈：清洗存量数据里混入的控制/格式字符。老输入层只 trim 空白，
        // 粘贴带入的 \u{03} 等会存进 profile 并写进 domain_suffix（永远匹配
        // 不中，UI 又看不见）。清洗后走 didMigrate 回写持久化。
        for i in loaded.ruleSets.indices {
            let cleanedDomains = loaded.ruleSets[i].domains
                .map(RuleSet.sanitizeEntry).filter { !$0.isEmpty }
            let cleanedCIDRs = loaded.ruleSets[i].cidrs
                .map(RuleSet.sanitizeEntry).filter { !$0.isEmpty }
            let cleanedApplications = RuleSet.sanitizeApplications(
                loaded.ruleSets[i].applications
            )
            if cleanedDomains != loaded.ruleSets[i].domains
                || cleanedCIDRs != loaded.ruleSets[i].cidrs
                || cleanedApplications != loaded.ruleSets[i].applications {
                loaded.ruleSets[i].domains = cleanedDomains
                loaded.ruleSets[i].cidrs = cleanedCIDRs
                loaded.ruleSets[i].applications = cleanedApplications
                didMigrate = true
                appLog("loadSaved: sanitized control chars in rule set \(loaded.ruleSets[i].id)")
            }
        }

        // D33 恢复桌面内置 Tailscale。旧版本已经留下 Line 但尚未有全局设备名时，
        // 只补一份稳定身份；不迁移、删除或重写任何 Mode 引用。
        if loaded.lines.contains(where: { $0.type == "tailscale" }),
           loaded.tailscale.hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            loaded.tailscale.hostname = Self.newTailscaleHostname()
            didMigrate = true
            appLog("loadSaved: created persistent Tailscale identity")
        }

        self.profile = loaded
        if didMigrate { save() }
    }

    private static func newTailscaleHostname() -> String {
        "xdial-" + String(UUID().uuidString.lowercased().prefix(8))
    }

    private static func runtimeConfigurationSnapshot(
        _ profile: Profile
    ) -> Profile {
        var snapshot = profile
        for index in snapshot.lines.indices {
            snapshot.lines[index].verified = false
        }
        for subscriptionIndex in snapshot.subscriptions.indices {
            for lineIndex in
                snapshot.subscriptions[subscriptionIndex].lines.indices
            {
                snapshot.subscriptions[subscriptionIndex]
                    .lines[lineIndex].verified = false
            }
        }
        return snapshot
    }

    // MARK: - Legacy 命名 key 迁移（比喻命名 → 正式命名）
    //
    // 只做「精确 key 匹配」的重写，绝不做字符串子串替换 —— 否则会误伤 trojan_port、
    // default_subscription_id、vpn_server 这类含 "port"/"cargo"/"cruise" 子串的合法字段。

    /// 判断字典里是否存在任一比喻命名时代的顶层/内嵌 key（用于决定是否需要重写）。
    private static func hasLegacyMetaphorKeys(_ dict: [String: Any]) -> Bool {
        if dict["ports"] != nil || dict["cargoes"] != nil || dict["cruises"] != nil
            || dict["active_cruise_id"] != nil {
            return true
        }
        // 内嵌：cruises[].bindings[].{cargo_id,port_id}、cruises[].default_port_id、
        // subscriptions[].ports。逐层精确探测。
        if let cruises = dict["cruises"] as? [[String: Any]] {
            for c in cruises {
                if c["default_port_id"] != nil { return true }
                if let bs = c["bindings"] as? [[String: Any]] {
                    for b in bs where b["cargo_id"] != nil || b["port_id"] != nil { return true }
                }
            }
        }
        if let subs = dict["subscriptions"] as? [[String: Any]] {
            for s in subs where s["ports"] != nil { return true }
        }
        return false
    }

    /// 把一份比喻命名的 profile 字典按对照表精确重写成正式命名字典。
    /// 顶层：ports→lines、cargoes→rule_sets、cruises→modes、active_cruise_id→active_mode_id。
    /// mode 内嵌：default_port_id→default_line_id；binding 内嵌：cargo_id→rule_set_id、port_id→line_id。
    /// subscription 内嵌：ports→lines（其内部 Line 字段如 trojan_port 保持不变）。
    private static func rewriteLegacyMetaphorKeys(_ dict: [String: Any]) -> [String: Any] {
        var out = dict

        // 顶层 lines
        if let v = out.removeValue(forKey: "ports") { out["lines"] = v }
        // 顶层 rule_sets
        if let v = out.removeValue(forKey: "cargoes") { out["rule_sets"] = v }
        // 顶层 active_mode_id
        if let v = out.removeValue(forKey: "active_cruise_id") { out["active_mode_id"] = v }

        // 顶层 modes（含其内嵌 bindings / default_port_id 重写）
        if let cruises = out.removeValue(forKey: "cruises") as? [[String: Any]] {
            out["modes"] = cruises.map { rewriteLegacyMode($0) }
        } else if let cruises = out["cruises"] {
            // 类型不是 [[String:Any]]（异常数据）也搬过去，避免丢数据
            out.removeValue(forKey: "cruises")
            out["modes"] = cruises
        }

        // subscriptions 内嵌 ports → lines
        if let subs = out["subscriptions"] as? [[String: Any]] {
            out["subscriptions"] = subs.map { sub -> [String: Any] in
                var ns = sub
                if let v = ns.removeValue(forKey: "ports") { ns["lines"] = v }
                return ns
            }
        }

        return out
    }

    /// 重写单个 mode 字典：default_port_id → default_line_id，bindings 逐条重写。
    private static func rewriteLegacyMode(_ dict: [String: Any]) -> [String: Any] {
        var m = dict
        if let v = m.removeValue(forKey: "default_port_id") { m["default_line_id"] = v }
        if let bindings = m["bindings"] as? [[String: Any]] {
            m["bindings"] = bindings.map { b -> [String: Any] in
                var nb = b
                if let v = nb.removeValue(forKey: "cargo_id") { nb["rule_set_id"] = v }
                if let v = nb.removeValue(forKey: "port_id") { nb["line_id"] = v }
                return nb
            }
        }
        return m
    }

    private func loadKeychain(id: String, suffix: String, oldPrefixes: [String]) -> String {
        if let v = KeychainStore.load(account: keychainPrefix + id + "-" + suffix), !v.isEmpty {
            return v
        }
        // 回退到旧 prefix
        for old in oldPrefixes {
            if let v = KeychainStore.load(account: old + id + "-" + suffix), !v.isEmpty {
                return v
            }
        }
        return ""
    }

    /// 把旧格式 profile (v0.2: exits/rules/strategies) 迁移到新格式 (lines/rule_sets/modes)
    static func migrate(oldProfile: [String: Any]) -> Profile? {
        var p = Profile()
        // 旧版本的 v0.2 里是 exits/rules/strategies
        if let oldExits = oldProfile["exits"] as? [[String: Any]] {
            p.lines = oldExits.compactMap { dict -> Line? in
                guard let data = try? JSONSerialization.data(withJSONObject: dict),
                      let line = try? JSONDecoder().decode(Line.self, from: data) else { return nil }
                return line
            }
        }
        if let oldRules = oldProfile["rules"] as? [[String: Any]] {
            p.ruleSets = oldRules.compactMap { dict -> RuleSet? in
                guard let data = try? JSONSerialization.data(withJSONObject: dict),
                      let c = try? JSONDecoder().decode(RuleSet.self, from: data) else { return nil }
                return c
            }
        }
        if let oldStrategies = oldProfile["strategies"] as? [[String: Any]] {
            p.modes = oldStrategies.compactMap { dict -> Mode? in
                // 旧 strategy.bindings 用 rule_id/exit_id；旧 default_exit_id
                var fixed = dict
                if let oldBindings = dict["bindings"] as? [[String: Any]] {
                    fixed["bindings"] = oldBindings.map { b -> [String: Any] in
                        var nb = b
                        if let r = b["rule_id"] { nb["rule_set_id"] = r; nb.removeValue(forKey: "rule_id") }
                        if let e = b["exit_id"] { nb["line_id"] = e; nb.removeValue(forKey: "exit_id") }
                        return nb
                    }
                }
                if let de = dict["default_exit_id"] {
                    fixed["default_line_id"] = de
                    fixed.removeValue(forKey: "default_exit_id")
                }
                guard let data = try? JSONSerialization.data(withJSONObject: fixed),
                      let c = try? JSONDecoder().decode(Mode.self, from: data) else { return nil }
                return c
            }
        }
        if let active = oldProfile["active_strategy_id"] as? String {
            p.activeModeID = active
        }
        return p.lines.isEmpty && p.ruleSets.isEmpty && p.modes.isEmpty ? nil : p
    }

    func checkHelper() {
        // 旧机制的 LaunchDaemon 与 SMAppService 同 label，旧 job 在位时 status
        // 会误报 enabled。只要旧安装残留还在，就当作未配置，引导走一次性迁移。
        if PrivilegeManager.legacyInstalled {
            helperInstalled = false
            helperNeedsApproval = false
            return
        }
        let st = PrivilegeManager.status
        helperInstalled = (st == .enabled)
        helperNeedsApproval = (st == .requiresApproval)
    }

    // MARK: - Subscription Management

    func addSubscription(name: String, url: String, format: String, strategy: String,
                         lines: [Line], proxyGroups: [SubProxyGroup] = [], rules: [SubRule] = []) {
        let sub = Subscription(
            id: "sub-" + String(UUID().uuidString.prefix(8)).lowercased(),
            name: name,
            url: url,
            format: format,
            strategy: strategy,
            lines: lines,
            proxyGroups: proxyGroups,
            rules: rules
        )
        profile.subscriptions.append(sub)
        save()
    }

    func updateSubscription(_ id: String, with result: GoEngine.ParseResult) {
        guard let idx = profile.subscriptions.firstIndex(where: { $0.id == id }) else { return }
        profile.subscriptions[idx].lines = result.lines
        profile.subscriptions[idx].proxyGroups = result.proxyGroups ?? []
        profile.subscriptions[idx].rules = result.rules ?? []
        profile.subscriptions[idx].updatedAt = Int(Date().timeIntervalSince1970)
        save()  // vault 整体覆盖，旧条目自然消失
    }

    func deleteSubscription(_ id: String) {
        profile.subscriptions.removeAll { $0.id == id }
        for i in profile.modes.indices {
            profile.modes[i].bindings.removeAll { $0.subscriptionID == id }
            if profile.modes[i].defaultSubscriptionID == id {
                profile.modes[i].defaultSubscriptionID = ""
            }
        }
        save()
    }

    // MARK: - Mode Management

    func createMode(from template: ModeTemplate, named name: String) {
        let direct = profile.lines.first(where: { $0.type == "direct" })?.id ?? "direct"
        let vpn = profile.lines.first(where: { $0.type == "vpn" })?.id ?? "vpn"
        let ss = profile.lines.first(where: { $0.type != "direct" && $0.type != "vpn" })?.id ?? "ss"

        let manualRules = profile.ruleSets
            .filter { $0.type == "manual" && $0.enabled }
            .map { $0.id }
        let gfwRule = profile.ruleSets
            .first(where: { $0.type == "url" && $0.enabled })?.id ?? ""

        var s: Mode
        switch template {
        case .overseas:
            s = Profile.templateOverseas(
                ruleSetIDs: manualRules,
                vpnLineID: vpn,
                directLineID: direct
            )
        case .domestic:
            s = Profile.templateDomestic(
                ruleSetIDs: manualRules,
                gfwRuleSetID: gfwRule,
                vpnLineID: vpn,
                directLineID: direct
            )
        case .domesticSS:
            s = Profile.templateDomesticSS(
                ruleSetIDs: manualRules,
                gfwRuleSetID: gfwRule,
                vpnLineID: vpn,
                ssLineID: ss,
                directLineID: direct
            )
        case .blank:
            s = Mode(id: UUID().uuidString, name: name, defaultLineID: direct)
        }
        s.name = name
        profile.modes.append(s)
        if profile.activeModeID.isEmpty {
            profile.activeModeID = s.id
        }
        save()
    }

    func deleteMode(_ s: Mode) {
        profile.modes.removeAll { $0.id == s.id }
        if profile.activeModeID == s.id {
            profile.activeModeID = profile.modes.first?.id ?? ""
        }
        save()
    }

    // MARK: - Build profile JSON

    func buildProfileJSON() -> String {
        guard let data = try? JSONEncoder().encode(profile) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

enum ModeTemplate: String, CaseIterable {
    case overseas, domestic, domesticSS, blank

    var displayName: String {
        switch self {
        case .overseas: return "海外"
        case .domestic: return "国内"
        case .domesticSS: return "国内+SS"
        case .blank: return "空白"
        }
    }
}
