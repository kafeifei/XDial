import NetworkExtension
import Network
@preconcurrency import Libbox
import os.log

/// NetworkExtension 的 completion handler 尚未标注 Sendable，但 provider 必须把阻塞的
/// Go 引擎工作移出系统回调队列。这个小盒子只负责跨队列携带不可变闭包。
private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// NetworkExtension 要求 startTunnel 的 completion 恰好调用一次。启动取消、
/// Go 回调与 NE 设置回调可能并发到达，因此不能只靠分支约定保证一次性。
private final class StartCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Error?) -> Void)?

    init(_ completion: @escaping (Error?) -> Void) {
        self.completion = completion
    }

    @discardableResult
    func finish(_ error: Error?) -> Bool {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        callback?(error)
        return callback != nil
    }
}

private final class StopCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (() -> Void)?

    init(_ completion: @escaping () -> Void) {
        self.completion = completion
    }

    @discardableResult
    func finish() -> Bool {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        callback?()
        return callback != nil
    }
}

/// XDial iOS / tvOS 的 packet-tunnel 扩展。
///
/// 进程内跑 Libbox(sslcon + gVisor + sing-box):
///   - `startTunnel` 建立到 AnyConnect 的连接、把 NE 的 packetFlow 文件描述符交给
///     sing-box 的 TUN inbound、配置 NEPacketTunnelNetworkSettings 后放行。
///   - `handleAppMessage` 承接 App(GoEngine.swift 的 sendProviderMessage)发来的
///     控制请求(start/stop/status/parse-sub),回一段 DaemonResponse JSON。
///
/// 通信/存储约定(与 GoEngine.swift、AppState.swift、core/libbox 对齐):
///   - App Group:规则文件的共享容器；启动配置只通过 start options 一次性交付。
///   - Libbox 绑定:LibboxNew(cb) → LibboxLibbox;start(server,username,password,configJSON)、
///     setTunFD(_:)、stop()、status()、isRunning()(见 core/libbox/libbox.go 的
///     gomobile 导出面,方法名遵循 gomobile 首字母小写惯例)。
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {

    #if os(iOS)
    private static let appGroupID = "group.com.kafeifei.xdial.ios"
    private static let subsystem = "com.kafeifei.xdial.ios.tunnel"
    #else
    private static let appGroupID = "group.com.kafeifei.xdialtv"
    private static let subsystem = "com.kafeifei.xdialtv.tunnel"
    #endif

    /// 仅用于读取并清理早期版本留在 App Group 的启动参数。
    /// 新版本不会再写这些 key，完整配置统一通过一次性 start options 交付。
    private static let configKey = "xdial.tunnel.config"
    private static let serverKey = "xdial.tunnel.server"
    private static let usernameKey = "xdial.tunnel.username"
    private static let passwordKey = "xdial.tunnel.password"
    private static let diagnosticKey = "xdial.tunnel.diagnostic"

    private let log = OSLog(subsystem: subsystem, category: "provider")

    /// 进程内引擎实例。startTunnel 时创建,stopTunnel 时置空。
    private var libbox: LibboxLibbox?

    /// 引擎最近一次通过 Callback 报上来的错误文本(用于 status 响应带出)。
    private var lastError: String?

    private enum AttemptPhase {
        case idle
        case starting
        case running
    }

    /// NE 回调、Go 回调与后台启动线程会并发触碰启动生命周期。generation 使已经
    /// 被 stop 或后续 start 取代的异步结果失效；资源只由摘除它的路径负责清理。
    private let lifecycleLock = NSLock()
    private var activeGeneration: UInt64 = 0
    private var attemptPhase: AttemptPhase = .idle
    private var activeGenerationUsesSecureEnvelope = false
    private var startCompletion: StartCompletionGate?
    /// sslcon 的会话是进程全局资源。创建、StartResolved 与 Stop 必须经过同一
    /// 串行队列，不能让新 generation 与旧会话在底层并发。
    private let engineOperationQueue = DispatchQueue(label: "com.kafeifei.xdial.tunnel.engine")
    /// 设置 job 连同原始系统 completion 严格串行；失效路径会在同一提交锁下
    /// 排入 barrier，因此新 generation 不会越过旧 generation 的未决设置。
    private let networkSettingsSubmissionLock = NSLock()
    private let networkSettingsOperationQueue = DispatchQueue(
        label: "com.kafeifei.xdial.tunnel.network-settings"
    )
    private let networkSettingsCallbackQueue = DispatchQueue(
        label: "com.kafeifei.xdial.tunnel.network-settings-callback"
    )

    /// sing-box 的 direct/DNS 出站必须使用 NWPath 给出的完整 Underlay。
    /// 下层 VPN 会以 utun/ipsec/ppp 出现，不能按接口名前缀删除；Go 平台层只排除
    /// 当前 XDial 会话通过 RegisterMyInterface 明确登记的 packet tunnel。
    private var pathMonitor: NWPathMonitor?
    private var diagnosticStage = "idle"
    private var activeAttemptID = ""
    private var defaultInterfaceName = ""
    private var defaultInterfaceIndex = -1
    private var diagnosticSensitiveValues: [String] = []
    private let diagnosticLock = NSLock()
    private let diagnosticWriteQueue = DispatchQueue(label: "com.kafeifei.xdial.tunnel.diagnostics")

    // MARK: - Libbox 回调

    /// 桥接 LibboxCallbackProtocol → 本 provider。gomobile 生成的回调协议方法名
    /// 见 DebugSmokeTest.swift 里的 TestCallback(onStatusChanged / onError)。
    private final class EngineCallback: NSObject, LibboxCallbackProtocol {
        weak var provider: PacketTunnelProvider?
        let generation: UInt64

        init(provider: PacketTunnelProvider, generation: UInt64) {
            self.provider = provider
            self.generation = generation
        }
        func onStatusChanged(_ statusJSON: String?) {
            provider?.handleEngineStatus(statusJSON, generation: generation)
            os_log("libbox status changed", log: OSLog(subsystem: PacketTunnelProvider.subsystem, category: "provider"),
                   type: .info)
        }
        func onError(_ code: Int, message: String?) {
            provider?.handleEngineError(code: code, message: message, generation: generation)
            os_log("libbox error code=%d", log: OSLog(subsystem: PacketTunnelProvider.subsystem, category: "provider"),
                   type: .error, code)
        }
    }

    // MARK: - startTunnel

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let completion = StartCompletionGate(completionHandler)
        let generation = beginLifecycleAttempt(completion: completion)
        beginAttempt(options?["attemptID"] as? String ?? "")
        recordDiagnostic("start_begin")
        os_log("startTunnel: begin", log: log, type: .info)

        // 1) 取凭据与 sing-box 配置。手动启动使用一次性 options；系统按需冷启动
        //    没有 options，只允许读取双方共享 Keychain 中最近一次已验收的版本化启动包。
        guard let bundle = resolveStartBundle(options: options) else {
            let err = providerError(2, "缺少完整且已验收的安全启动配置")
            failAttempt(generation, error: err, diagnosticStage: "start_bundle_missing")
            os_log("startTunnel: missing credentials/config", log: log, type: .error)
            return
        }
        setSecureEnvelopeUsage(bundle.fromSecureEnvelope, generation: generation)
        setDiagnosticSensitiveValues(from: bundle)
        recordDiagnostic("start_bundle_loaded")

        engineOperationQueue.async { [weak self] in
            guard let self else {
                completion.finish(providerErrorStatic(4, "provider deallocated"))
                return
            }
            self.prepareAttempt(bundle, generation: generation, completion: completion)
        }
    }

    private func prepareAttempt(
        _ bundle: StartBundle,
        generation: UInt64,
        completion: StartCompletionGate
    ) {
        dispatchPrecondition(condition: .onQueue(engineOperationQueue))
        guard isAttemptStarting(generation) else { return }

        // 2) 创建引擎实例。
        let cb = EngineCallback(provider: self, generation: generation)
        guard let lb = LibboxNew(cb) else {
            let err = providerError(4, "LibboxNew 返回 nil")
            failAttempt(generation, error: err, diagnosticStage: "engine_create_failed")
            os_log("startTunnel: LibboxNew returned nil", log: log, type: .error)
            return
        }
        guard installEngine(lb, generation: generation) else {
            // 当前就在全局会话串行队列上；必须先清掉这个尚未登记的实例，
            // 不能把 Stop 排到已经入队的新 prepare 后面。
            try? lb.stop()
            return
        }

        // 3) 在默认路由切进当前 utun 之前先取得已有 Underlay，并持续监听系统路径变化。
        //    sing-box 官方 Apple 客户端也用 NWPathMonitor 驱动平台接口监控。
        do {
            try startDefaultInterfaceMonitor(generation: generation)
            recordDiagnostic("underlay_interface_ready")
        } catch {
            failAttempt(generation, error: error, diagnosticStage: "underlay_interface_failed")
            os_log("startTunnel: Underlay interface unavailable",
                   log: log, type: .error)
            return
        }

        guard isAttemptStarting(generation) else { return }

        if !bundle.usesAnyConnect {
            prepareStandaloneAttempt(
                bundle,
                engine: lb,
                generation: generation,
                completion: completion
            )
            return
        }

        // 4) 在默认路由进入 utun 前解析控制连接地址。NETunnelNetworkSettings
        //    明确要求 tunnelRemoteAddress 是数值 IP，不能传 hostname；同一个 IP
        //    也会作为 /32 排除路由和 sslcon 的 socket 目标。原始域名仍由 sslcon
        //    用作 TLS SNI/证书校验与 HTTP Host。
        recordDiagnostic("remote_address_resolving")
        var resolveError: NSError?
        let remoteIPv4 = LibboxResolveServerIPv4(bundle.server, &resolveError)
        guard resolveError == nil, IPv4Address(remoteIPv4) != nil else {
            let error = providerError(5, resolveError?.localizedDescription
                ?? "服务器地址未解析为有效 IPv4")
            failAttempt(generation, error: error, diagnosticStage: "remote_address_resolution_failed")
            os_log("startTunnel: remote address resolution failed",
                   log: log, type: .error)
            return
        }
        recordDiagnostic("remote_address_resolved")

        // 5) 先配置 NE 网络设置(隧道地址/DNS/路由),再拨号。
        //    NE 要求在 completionHandler(nil) 之前必须 setTunnelNetworkSettings 一次,
        //    否则 packetFlow 不会真正建立、拿不到有效 fd。
        //    系统 DNS 始终指向隧道内合成地址；引擎启动前它会短暂 fail closed，
        //    启动后由 hijack-dns 交给移动 dispatcher。企业 DNS 地址只留在 Go
        //    bridge 内部，不能直接装进系统设置造成 Tailscale 分域失效。
        let settings = buildNetworkSettings(remoteAddress: remoteIPv4)
        guard setTunnelNetworkSettingsIfStarting(settings, generation: generation, completionHandler: { [weak self] settingsError in
            guard let self else {
                completion.finish(providerErrorStatic(4, "provider deallocated"))
                return
            }
            guard self.isAttemptStarting(generation) else { return }
            if let settingsError {
                self.failAttempt(
                    generation,
                    error: settingsError,
                    diagnosticStage: "network_settings_failed"
                )
                os_log("startTunnel: setTunnelNetworkSettings failed",
                       log: self.log, type: .error)
                return
            }
            self.recordDiagnostic("network_settings_applied")

            // 6) 把 packetFlow 对应的 tun fd 交给引擎(见下方 tunFileDescriptor 说明)。
            if let fd = self.tunFileDescriptor(), fd > 0 {
                lb.setTunFD(fd)
                self.recordDiagnostic("tun_ready")
                os_log("startTunnel: tun fd set = %d", log: self.log, type: .info, fd)
            } else {
                let error = self.providerError(4, "无法获取系统隧道接口")
                self.failAttempt(generation, error: error, diagnosticStage: "tun_unavailable")
                os_log("startTunnel: tun fd unavailable",
                       log: self.log, type: .error)
                return
            }

            // 7) 拨号 + 启动 sing-box。StartResolved 是阻塞调用，socket 直拨
            //    remoteIPv4；TLS/HTTP 身份仍使用 bundle.server 的原始域名。
            self.recordDiagnostic("engine_starting")
            let engineBox = UncheckedSendableBox(lb)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.isAttemptStarting(generation) else { return }
                let stage = engineBox.value.startupStage()
                guard !stage.isEmpty, self.isAttemptStarting(generation) else { return }
                self.recordDiagnostic(stage)
            }
            self.engineOperationQueue.async {
                dispatchPrecondition(condition: .onQueue(self.engineOperationQueue))
                guard self.isAttemptStarting(generation) else { return }
                do {
                    try lb.startResolved(
                        withInsecure: bundle.server,
                        dialAddress: remoteIPv4,
                        username: bundle.username,
                        password: bundle.password,
                        allowInsecure: bundle.allowInsecure,
                        configJSON: bundle.configJSON
                    )
                    guard self.isAttemptStarting(generation) else { return }
                    guard let dnsServers = self.validDNSServers(from: lb.tunnelNameServers()),
                          !dnsServers.isEmpty else {
                        throw self.providerError(6, "连接未下发可用的域名服务器")
                    }

                    // 握手 DNS 只用于确认企业 resolver 可用；系统继续查询合成
                    // 地址，由 dispatcher 把非 Tailscale 域名 fail-closed 地送入 bridge。
                    self.recordDiagnostic("dns_settings_applying")
                    let finalSettings = self.buildNetworkSettings(remoteAddress: remoteIPv4)
                    guard self.setTunnelNetworkSettingsIfStarting(
                        finalSettings,
                        generation: generation,
                        completionHandler: { dnsSettingsError in
                        guard self.isAttemptStarting(generation) else { return }
                        if let dnsSettingsError {
                            self.failAttempt(
                                generation,
                                error: dnsSettingsError,
                                diagnosticStage: "dns_settings_failed"
                            )
                            os_log("startTunnel: tunnel DNS settings failed",
                                   log: self.log, type: .error)
                            return
                        }
                        guard self.completeAttempt(generation) else { return }
                        self.recordDiagnostic("engine_started")
                        os_log("startTunnel: engine and tunnel DNS ready",
                               log: self.log, type: .info)
                    }) else { return }
                } catch {
                    self.failAttempt(generation, error: error, diagnosticStage: "engine_failed")
                    os_log("startTunnel: engine start failed",
                           log: self.log, type: .error)
                }
            }
        }) else { return }
    }

    private func prepareStandaloneAttempt(
        _ bundle: StartBundle,
        engine: LibboxLibbox,
        generation: UInt64,
        completion: StartCompletionGate
    ) {
        dispatchPrecondition(condition: .onQueue(engineOperationQueue))
        let settings = buildNetworkSettings(remoteAddress: "127.0.0.1")
        guard setTunnelNetworkSettingsIfStarting(
            settings,
            generation: generation,
            completionHandler: { [weak self] settingsError in
                guard let self else {
                    completion.finish(providerErrorStatic(4, "provider deallocated"))
                    return
                }
                guard self.isAttemptStarting(generation) else { return }
                if let settingsError {
                    self.failAttempt(
                        generation,
                        error: settingsError,
                        diagnosticStage: "network_settings_failed"
                    )
                    return
                }
                self.recordDiagnostic("network_settings_applied")
                guard let fd = self.tunFileDescriptor(), fd > 0 else {
                    self.failAttempt(
                        generation,
                        error: self.providerError(4, "无法获取系统隧道接口"),
                        diagnosticStage: "tun_unavailable"
                    )
                    return
                }
                engine.setTunFD(fd)
                self.recordDiagnostic("tun_ready")
                self.recordDiagnostic("engine_starting")
                let engineBox = UncheckedSendableBox(engine)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, self.isAttemptStarting(generation) else { return }
                    let stage = engineBox.value.startupStage()
                    guard !stage.isEmpty, self.isAttemptStarting(generation) else { return }
                    self.recordDiagnostic(stage)
                }
                self.engineOperationQueue.async {
                    dispatchPrecondition(condition: .onQueue(self.engineOperationQueue))
                    guard self.isAttemptStarting(generation) else { return }
                    do {
                        try engine.startStandalone(bundle.configJSON)
                        guard self.completeAttempt(generation) else { return }
                        self.recordDiagnostic("engine_started")
                        os_log("startTunnel: standalone engine ready",
                               log: self.log, type: .info)
                    } catch {
                        self.failAttempt(
                            generation,
                            error: error,
                            diagnosticStage: "engine_failed"
                        )
                    }
                }
            }
        ) else { return }
    }

    // MARK: - stopTunnel

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let completion = StopCompletionGate(completionHandler)
        // 先原子失效所有启动回调并摘除资源，再等串行队列真正清理旧会话。
        // 极端情况下 StartResolved 可能长期不返回，兜底只放行系统 completion；
        // 引擎队列仍保持阻塞，后续 start 不会越过旧会话创建第二个 Libbox。
        cancelActiveAttempt(
            startError: providerError(7, "连接启动已取消"),
            afterCleanupQueued: { [weak self] in
                self?.recordDiagnostic("stopping")
                os_log("stopTunnel: reason=%d", log: self?.log ?? .default,
                       type: .info, reason.rawValue)
            },
            cleanupCompletion: { [weak self] in
                self?.recordDiagnostic("stopped")
                os_log("stopTunnel: cleanup done", log: self?.log ?? .default, type: .info)
                completion.finish()
            }
        )
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) { [weak self] in
            if completion.finish() {
                os_log("stopTunnel: cleanup timeout", log: self?.log ?? .default, type: .error)
            }
        }
    }

    // MARK: - 启动生命周期

    private func beginLifecycleAttempt(completion: StartCompletionGate) -> UInt64 {
        networkSettingsSubmissionLock.lock()
        lifecycleLock.lock()
        let previousEngine = libbox
        let previousMonitor = pathMonitor
        let previousCompletion = startCompletion
        libbox = nil
        pathMonitor = nil
        startCompletion = nil
        attemptPhase = .idle
        activeGeneration &+= 1
        let generation = activeGeneration
        attemptPhase = .starting
        activeGenerationUsesSecureEnvelope = false
        startCompletion = completion
        let settingsBarrier = enqueueNetworkSettingsBarrierLocked()
        enqueueEngineCleanupLocked(previousEngine, after: settingsBarrier)
        lifecycleLock.unlock()
        networkSettingsSubmissionLock.unlock()

        previousMonitor?.cancel()
        previousCompletion?.finish(providerError(7, "连接启动已被新的连接请求取代"))
        return generation
    }

    private func installEngine(_ engine: LibboxLibbox, generation: UInt64) -> Bool {
        lifecycleLock.lock()
        guard activeGeneration == generation, attemptPhase == .starting else {
            lifecycleLock.unlock()
            return false
        }
        libbox = engine
        lifecycleLock.unlock()
        return true
    }

    private func setSecureEnvelopeUsage(_ enabled: Bool, generation: UInt64) {
        lifecycleLock.lock()
        if activeGeneration == generation, attemptPhase == .starting {
            activeGenerationUsesSecureEnvelope = enabled
        }
        lifecycleLock.unlock()
    }

    private func installPathMonitor(_ monitor: NWPathMonitor, generation: UInt64) -> Bool {
        lifecycleLock.lock()
        guard activeGeneration == generation, attemptPhase == .starting else {
            lifecycleLock.unlock()
            return false
        }
        pathMonitor = monitor
        lifecycleLock.unlock()
        return true
    }

    private func isAttemptStarting(_ generation: UInt64) -> Bool {
        lifecycleLock.lock()
        let matches = activeGeneration == generation && attemptPhase == .starting
        lifecycleLock.unlock()
        return matches
    }

    private func setTunnelNetworkSettingsIfStarting(
        _ settings: NEPacketTunnelNetworkSettings,
        generation: UInt64,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) -> Bool {
        let completion = UncheckedSendableBox(completionHandler)
        let settings = UncheckedSendableBox(settings)
        networkSettingsSubmissionLock.lock()
        lifecycleLock.lock()
        guard activeGeneration == generation, attemptPhase == .starting else {
            lifecycleLock.unlock()
            networkSettingsSubmissionLock.unlock()
            return false
        }
        networkSettingsOperationQueue.async {
            dispatchPrecondition(condition: .onQueue(self.networkSettingsOperationQueue))
            guard self.isAttemptStarting(generation) else { return }

            let result = OneShotNetworkSettingsResult()
            let finished = DispatchSemaphore(value: 0)
            self.setTunnelNetworkSettings(settings.value) { error in
                if result.finish(error) {
                    finished.signal()
                }
            }
            // 原始系统 completion 只负责 signal；业务 completion 必须等本 job
            // 退出串行队列后再执行，避免回调反向等待同一 operation queue。
            if finished.wait(timeout: .now() + 15) == .timedOut {
                _ = result.finish(self.providerError(31, "应用系统网络设置超时"))
            }
            let outcome = result.snapshot()
            self.networkSettingsCallbackQueue.async {
                completion.value(outcome.error)
            }
        }
        lifecycleLock.unlock()
        networkSettingsSubmissionLock.unlock()
        return true
    }

    private func completeAttempt(_ generation: UInt64) -> Bool {
        lifecycleLock.lock()
        guard activeGeneration == generation, attemptPhase == .starting else {
            lifecycleLock.unlock()
            return false
        }
        attemptPhase = .running
        let completion = startCompletion
        lifecycleLock.unlock()

        // 回调不能在 lifecycleLock 内执行；completion gate 与 stop/new start 竞争，
        // 只有先到的一方能决定结果，因此失效后不会再补一次成功。
        let completed = completion?.finish(nil) ?? false
        lifecycleLock.lock()
        if activeGeneration == generation, startCompletion === completion {
            startCompletion = nil
        }
        lifecycleLock.unlock()
        return completed
    }

    private func failAttempt(
        _ generation: UInt64,
        error: Error,
        diagnosticStage: String
    ) {
        networkSettingsSubmissionLock.lock()
        lifecycleLock.lock()
        guard activeGeneration == generation, attemptPhase == .starting else {
            lifecycleLock.unlock()
            networkSettingsSubmissionLock.unlock()
            return
        }
        let engine = libbox
        let monitor = pathMonitor
        let completion = startCompletion
        let clearSecureEnvelope = activeGenerationUsesSecureEnvelope
        libbox = nil
        pathMonitor = nil
        startCompletion = nil
        attemptPhase = .idle
        activeGenerationUsesSecureEnvelope = false
        activeGeneration &+= 1
        let settingsBarrier = enqueueNetworkSettingsBarrierLocked()
        enqueueEngineCleanupLocked(engine, after: settingsBarrier)
        lifecycleLock.unlock()
        networkSettingsSubmissionLock.unlock()

        #if os(iOS)
        if OnDemandStartEnvelopeFailurePolicy.shouldClear(
            startedFromSecureEnvelope: clearSecureEnvelope,
            startOrRuntimeFailed: true
        ) {
            _ = OnDemandStartEnvelopeStore.clear()
        }
        #endif
        setLastError(error.localizedDescription)
        recordDiagnostic(diagnosticStage)
        monitor?.cancel()
        completion?.finish(error)
    }

    private func cancelActiveAttempt(
        startError: Error,
        afterCleanupQueued: (() -> Void)? = nil,
        cleanupCompletion: (() -> Void)? = nil
    ) {
        networkSettingsSubmissionLock.lock()
        lifecycleLock.lock()
        let engine = libbox
        let monitor = pathMonitor
        let completion = startCompletion
        libbox = nil
        pathMonitor = nil
        startCompletion = nil
        attemptPhase = .idle
        activeGenerationUsesSecureEnvelope = false
        activeGeneration &+= 1
        let settingsBarrier = enqueueNetworkSettingsBarrierLocked()
        enqueueEngineCleanupLocked(
            engine,
            after: settingsBarrier,
            completion: cleanupCompletion
        )
        lifecycleLock.unlock()
        networkSettingsSubmissionLock.unlock()

        afterCleanupQueued?()
        monitor?.cancel()
        completion?.finish(startError)
    }

    /// 调用方必须同时持有 submission/lifecycle 锁，保证 barrier 排在此前设置 job 后。
    private func enqueueNetworkSettingsBarrierLocked() -> DispatchGroup {
        let barrier = DispatchGroup()
        barrier.enter()
        networkSettingsOperationQueue.async {
            dispatchPrecondition(condition: .onQueue(self.networkSettingsOperationQueue))
            barrier.leave()
        }
        return barrier
    }

    /// 调用方必须持有 lifecycleLock；只做入队，不等待队列执行，也不触发外部回调。
    private func enqueueEngineCleanupLocked(
        _ engine: LibboxLibbox?,
        after settingsBarrier: DispatchGroup,
        completion: (() -> Void)? = nil
    ) {
        let completion = completion.map(UncheckedSendableBox.init)
        engineOperationQueue.async {
            dispatchPrecondition(condition: .onQueue(self.engineOperationQueue))
            if let engine {
                try? engine.stop()
            }
            settingsBarrier.wait()
            completion?.value()
        }
    }

    private func currentEngine() -> LibboxLibbox? {
        lifecycleLock.lock()
        let engine = libbox
        lifecycleLock.unlock()
        return engine
    }

    private func engine(for generation: UInt64) -> LibboxLibbox? {
        lifecycleLock.lock()
        let engine = activeGeneration == generation && attemptPhase != .idle ? libbox : nil
        lifecycleLock.unlock()
        return engine
    }

    private func phase(for generation: UInt64) -> AttemptPhase? {
        lifecycleLock.lock()
        let phase = activeGeneration == generation ? attemptPhase : nil
        lifecycleLock.unlock()
        return phase
    }

    private func handleEngineError(code: Int, message: String?, generation: UInt64) {
        let detail = message.flatMap { $0.isEmpty ? nil : $0 }
            ?? "底层连接发生错误(代码 \(code))"
        let error = providerError(20 + code, detail)
        switch phase(for: generation) {
        case .starting:
            failAttempt(generation, error: error, diagnosticStage: "engine_failed")
        case .running:
            terminateRunningAttempt(generation, error: error)
        case .idle, nil:
            break
        }
    }

    private func handleEngineStatus(_ statusJSON: String?, generation: UInt64) {
        guard let statusJSON,
              let data = statusJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["status"] as? String)?.lowercased() == "disconnected" else {
            return
        }
        let error = providerError(8, "底层连接意外断开")
        switch phase(for: generation) {
        case .starting:
            failAttempt(generation, error: error, diagnosticStage: "engine_disconnected")
        case .running:
            terminateRunningAttempt(generation, error: error)
        case .idle, nil:
            break
        }
    }

    private func terminateRunningAttempt(_ generation: UInt64, error: Error) {
        networkSettingsSubmissionLock.lock()
        lifecycleLock.lock()
        guard activeGeneration == generation, attemptPhase == .running else {
            lifecycleLock.unlock()
            networkSettingsSubmissionLock.unlock()
            return
        }
        let engine = libbox
        let monitor = pathMonitor
        let completion = startCompletion
        let clearSecureEnvelope = activeGenerationUsesSecureEnvelope
        libbox = nil
        pathMonitor = nil
        startCompletion = nil
        attemptPhase = .idle
        activeGenerationUsesSecureEnvelope = false
        activeGeneration &+= 1
        let settingsBarrier = enqueueNetworkSettingsBarrierLocked()
        enqueueEngineCleanupLocked(engine, after: settingsBarrier)
        lifecycleLock.unlock()
        networkSettingsSubmissionLock.unlock()

        #if os(iOS)
        if OnDemandStartEnvelopeFailurePolicy.shouldClear(
            startedFromSecureEnvelope: clearSecureEnvelope,
            startOrRuntimeFailed: true
        ) {
            _ = OnDemandStartEnvelopeStore.clear()
        }
        #endif
        setLastError(error.localizedDescription)
        recordDiagnostic("runtime_disconnected")
        monitor?.cancel()
        completion?.finish(error)
        cancelTunnelWithError(error)
    }

    // MARK: - handleAppMessage

    /// 处理 App(GoEngine.sendProviderMessage)发来的一段 JSON 请求,回一段
    /// DaemonResponse JSON。请求结构见 GoEngine.swift 的 sendRequest / sendSubRequest:
    ///   {"cmd":"start","profile":"<...>"}            // 目前扩展侧不再从 profile 拨号
    ///   {"cmd":"stop"}
    ///   {"cmd":"status"}
    ///   {"cmd":"parse-sub","sub_url":"...","sub_format":"...","sub_content":"..."}
    ///   {"cmd":"select-outbound","group_tag":"...","outbound_tag":"..."}
    ///   {"cmd":"test-outbound","outbound_tag":"...","test_url":"...","timeout_ms":"5000"}
    ///   {"cmd":"probe-outbound-address","outbound_tag":"...","timeout_ms":"7000"}
    ///   {"cmd":"routing-probe-snapshot"}
    ///   {"cmd":"tailscale-status","endpoint_tag":"tailscale-..."}
    /// 响应结构见 GoEngine.swift 的 DaemonResponse:{id?, ok?, message?, data?, event?}。
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let completionHandler else { return }
        let completion = UncheckedSendableBox(completionHandler)

        guard let obj = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
              let cmd = obj["cmd"] as? String else {
            completion.value(encodeResponse(ok: false, message: "无法解析请求(缺少 cmd)"))
            return
        }
        os_log("handleAppMessage: cmd=%{public}@", log: log, type: .info, cmd)

        switch cmd {
        case "status":
            completion.value(handleStatus())

        case "start":
            // 扩展的真实启动由 NETunnelProviderManager.startVPNTunnel(options:) 触发
            // (走 startTunnel 而非本消息)。这里保留一条幂等语义的应答:若引擎已在跑
            // 回 ok,便于 App 在既有隧道上做「确认」。真正的拨号不在此路径完成。
            let running = currentEngine()?.isRunning() ?? false
            completion.value(encodeResponse(ok: true,
                message: running ? nil : "隧道由系统连接配置启动,非此消息路径",
                dataString: statusJSONString()))

        case "stop":
            // 与 start 对称:真正停止隧道应调 NETunnelProviderManager.stopVPNTunnel()。
            // 这里做一次尽力而为的引擎停止,并回 ok。
            cancelActiveAttempt(startError: providerError(7, "连接启动已取消"))
            completion.value(encodeResponse(ok: true, dataString: "{\"status\":\"disconnected\"}"))

        case "parse-sub":
            // 兼容旧 App 的消息。当前 App 已在主进程直接调用 Libbox 解析，不再依赖扩展会话。
            completion.value(encodeResponse(ok: false, message: "请更新 XDial 后重试订阅解析"))

        case "select-outbound":
            guard let groupTag = obj["group_tag"] as? String, !groupTag.isEmpty,
                  let outboundTag = obj["outbound_tag"] as? String, !outboundTag.isEmpty else {
                completion.value(encodeResponse(ok: false, message: "线路选择参数不完整"))
                return
            }
            engineOperationQueue.async { [weak self] in
                guard let self, let engine = self.currentEngine() else {
                    completion.value(self?.encodeResponse(ok: false, message: "连接引擎未运行"))
                    return
                }
                do {
                    try engine.selectOutbound(groupTag, outboundTag: outboundTag)
                    completion.value(self.encodeResponse(ok: true))
                } catch {
                    completion.value(self.encodeResponse(ok: false, message: "无法切换到所选线路"))
                }
            }

        case "test-outbound":
            guard let outboundTag = obj["outbound_tag"] as? String, !outboundTag.isEmpty else {
                completion.value(encodeResponse(ok: false, message: "线路测试参数不完整"))
                return
            }
            let testURL = obj["test_url"] as? String ?? ""
            let timeoutMS = Int(obj["timeout_ms"] as? String ?? "") ?? 5_000
            engineOperationQueue.async { [weak self] in
                guard let self, let engine = self.currentEngine() else {
                    completion.value(self?.encodeResponse(ok: false, message: "连接引擎未运行"))
                    return
                }
                do {
                    var delay = 0
                    try engine.testOutbound(
                        outboundTag,
                        testURL: testURL,
                        timeoutMS: timeoutMS,
                        ret0_: &delay
                    )
                    completion.value(self.encodeResponse(ok: true, dataString: String(delay)))
                } catch {
                    completion.value(self.encodeResponse(ok: false, message: "所选线路测试失败"))
                }
            }

        case "probe-outbound-address":
            guard let outboundTag = obj["outbound_tag"] as? String, !outboundTag.isEmpty else {
                completion.value(encodeResponse(ok: false, message: "出口地址探测参数不完整"))
                return
            }
            let timeoutMS = Int(obj["timeout_ms"] as? String ?? "") ?? 7_000
            engineOperationQueue.async { [weak self] in
                guard let self, let engine = self.currentEngine() else {
                    completion.value(self?.encodeResponse(ok: false, message: "连接引擎未运行"))
                    return
                }
                do {
                    var probeError: NSError?
                    let address = engine.probeOutboundIP(
                        outboundTag,
                        timeoutMS: timeoutMS,
                        error: &probeError
                    )
                    if let probeError { throw probeError }
                    completion.value(self.encodeResponse(ok: true, dataString: address))
                } catch {
                    completion.value(self.encodeResponse(
                        ok: false,
                        message: "无法确认所选线路的出口地址：\(error.localizedDescription)"
                    ))
                }
            }

        case "routing-probe-snapshot":
            guard let engine = currentEngine(), engine.isRunning() else {
                completion.value(encodeResponse(ok: false, message: "连接引擎未运行"))
                return
            }
            completion.value(encodeResponse(
                ok: true,
                dataString: engine.routingProbeSnapshot()
            ))

        case "tailscale-status":
            guard let endpointTag = obj["endpoint_tag"] as? String, !endpointTag.isEmpty else {
                completion.value(encodeResponse(ok: false, message: "Tailscale 状态参数不完整"))
                return
            }
            engineOperationQueue.async { [weak self] in
                guard let self, let engine = self.currentEngine() else {
                    completion.value(self?.encodeResponse(ok: false, message: "连接引擎未运行"))
                    return
                }
                do {
                    var statusError: NSError?
                    let rawStatus = engine.tailscaleStatus(endpointTag, error: &statusError)
                    if let statusError { throw statusError }
                    guard !rawStatus.isEmpty else {
                        completion.value(self.encodeResponse(ok: false, message: "Tailscale 状态为空"))
                        return
                    }
                    if self.tailscaleBackendIsRunning(rawStatus) {
                        // reconfig 已原地更新 Tailscale DNS transport；清掉登录前
                        // 可能缓存的公共 NXDOMAIN 后，下一条查询立即按新分域选择。
                        try engine.refreshDNS()
                    }
                    completion.value(self.encodeResponse(ok: true, dataString: rawStatus))
                } catch {
                    completion.value(self.encodeResponse(ok: false, message: "无法读取 Tailscale 状态"))
                }
            }

        case "tailscale-begin-login":
            guard let endpointTag = obj["endpoint_tag"] as? String, !endpointTag.isEmpty else {
                completion.value(encodeResponse(ok: false, message: "Tailscale 登录参数不完整"))
                return
            }
            engineOperationQueue.async { [weak self] in
                guard let self, let engine = self.currentEngine() else {
                    completion.value(self?.encodeResponse(ok: false, message: "连接引擎未运行"))
                    return
                }
                do {
                    var loginError: NSError?
                    let rawStatus = engine.beginTailscaleLogin(endpointTag, error: &loginError)
                    if let loginError { throw loginError }
                    guard !rawStatus.isEmpty else {
                        completion.value(self.encodeResponse(ok: false, message: "Tailscale 登录状态为空"))
                        return
                    }
                    completion.value(self.encodeResponse(ok: true, dataString: rawStatus))
                } catch {
                    completion.value(self.encodeResponse(ok: false, message: "无法启动 Tailscale 登录"))
                }
            }

        default:
            completion.value(encodeResponse(ok: false, message: "未知命令: \(cmd)"))
        }
    }

    // MARK: - status 辅助

    private func handleStatus() -> Data {
        encodeResponse(ok: true, dataString: statusJSONString())
    }

    /// 组装 GoEngine.EngineStatus 期望的 JSON:{"status": "...", "error": "..."?}。
    /// EngineStatus 只解 status / scenario_id / connected_at / error；这里给 status(+error)。
    private func statusJSONString() -> String {
        let running = currentEngine()?.isRunning() ?? false
        var dict: [String: Any] = ["status": running ? "connected" : "disconnected"]
        dict["diagnostics"] = diagnosticSnapshot(includeEngine: true)
        if let lastError = currentLastError(), !lastError.isEmpty {
            dict["error"] = lastError
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else {
            return running ? "{\"status\":\"connected\"}" : "{\"status\":\"disconnected\"}"
        }
        return s
    }

    // MARK: - 响应编码(对齐 GoEngine.DaemonResponse)

    /// DaemonResponse 里 data 是 String?(它自身是一段被转义的 JSON 文本,
    /// 比如 EngineStatus/ParseResult 的 JSON)。这里把 dataString 原样放进 data 字段。
    private func encodeResponse(ok: Bool, message: String? = nil, dataString: String? = nil) -> Data {
        var dict: [String: Any] = ["ok": ok]
        if let message { dict["message"] = message }
        if let dataString { dict["data"] = dataString }
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else {
            // 兜底:手写一个最小合法响应,保证 App 侧能解出 ok=false。
            return Data("{\"ok\":false,\"message\":\"响应编码失败\"}".utf8)
        }
        return data
    }

    // MARK: - 凭据/配置读取

    private struct StartBundle: Sendable {
        let fromSecureEnvelope: Bool
        let usesAnyConnect: Bool
        let server: String
        let username: String
        let password: String
        let allowInsecure: Bool
        let configJSON: String
    }

    /// 优先从一次性 options 读取；回退 App Group 只为兼容早期版本。
    /// 成功复制到内存后立即清理旧 key，避免敏感配置继续持久化。
    private func resolveStartBundle(options: [String: NSObject]?) -> StartBundle? {
        let defaults = UserDefaults(suiteName: Self.appGroupID)
        for key in [Self.serverKey, Self.usernameKey, Self.passwordKey, Self.configKey] {
            defaults?.removeObject(forKey: key)
        }

        let configJSON = options?["configJSON"] as? String
        let explicitAnyConnect = (options?["usesAnyConnect"] as? NSNumber)?.boolValue
        let server = options?["server"] as? String
        let username = options?["username"] as? String
        let password = options?["password"] as? String
        if OnDemandManualStartContract.isComplete(
            configJSON: configJSON,
            usesAnyConnect: explicitAnyConnect,
            server: server,
            username: username,
            password: password
        ), let configJSON, let explicitAnyConnect {
            return StartBundle(
                fromSecureEnvelope: false,
                usesAnyConnect: explicitAnyConnect,
                server: server ?? "",
                username: username ?? "",
                password: password ?? "",
                allowInsecure: (options?["allowInsecure"] as? NSNumber)?.boolValue ?? false,
                configJSON: configJSON
            )
        }

        // NetworkExtension 可能传入包含系统字段的非空 options。只要不满足主 App
        // 的完整手动契约，就必须按冷启动处理，不能误读为旧版手动启动。
        do {
            #if os(iOS)
            guard case .available(let envelope) = OnDemandStartEnvelopeStore.load(),
                  envelope.isValid,
                  ["anyconnect", "standalone"].contains(envelope.transport),
                  let acceptancePlan = envelope.parameters["acceptance_plan"],
                  let acceptanceData = acceptancePlan.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: acceptanceData)) is [String: Any] else {
                return nil
            }
            let usesAnyConnect = envelope.transport == "anyconnect"
            let server = envelope.parameters["server"] ?? ""
            let username = envelope.parameters["username"] ?? ""
            let password = envelope.parameters["password"] ?? ""
            guard !usesAnyConnect || (!server.isEmpty && !username.isEmpty && !password.isEmpty) else {
                return nil
            }
            return StartBundle(
                fromSecureEnvelope: true,
                usesAnyConnect: usesAnyConnect,
                server: server,
                username: username,
                password: password,
                allowInsecure: envelope.parameters["allow_insecure"] == "true",
                configJSON: envelope.configJSON
            )
            #else
            return nil
            #endif
        }
    }

    // MARK: - NE 网络设置

    /// 启动 Underlay 接口监控并同步等待首个结果。默认接口和完整候选列表必须在
    /// Libbox.Start 前发布，否则 route.auto_detect_interface 没有可用出口。
    private func startDefaultInterfaceMonitor(generation: UInt64) throws {
        let monitor = NWPathMonitor()
        let ready = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "\(Self.subsystem).path-monitor")

        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            self?.updateDefaultInterface(path, generation: generation)
            ready.signal()
            monitor?.pathUpdateHandler = { [weak self] path in
                self?.updateDefaultInterface(path, generation: generation)
            }
        }
        guard installPathMonitor(monitor, generation: generation) else {
            throw providerError(7, "连接启动已取消")
        }
        monitor.start(queue: queue)

        guard ready.wait(timeout: .now() + 5) == .success else {
            throw providerError(5, "等待 Underlay 网络接口超时")
        }
        guard isAttemptStarting(generation) else {
            throw providerError(7, "连接启动已取消")
        }
        guard monitor.currentPath.status == .satisfied,
              selectDefaultInterface(from: monitor.currentPath) != nil else {
            throw providerError(5, "没有可用的 Underlay 网络接口")
        }
    }

    private struct PathInterfaceSnapshot: Codable {
        let name: String
        let index: Int
        let type: String
    }

    private func updateDefaultInterface(_ path: NWPath, generation: UInt64) {
        guard let engine = engine(for: generation) else { return }
        guard path.status == .satisfied, let interface = selectDefaultInterface(from: path) else {
            setDefaultInterfaceDiagnostic(name: "", index: -1)
            try? engine.setNetworkInterfaces("[]")
            engine.setDefaultInterface("", index: -1)
            refreshDiagnostic()
            os_log("Underlay interface unavailable", log: log, type: .error)
            return
        }

        var seenInterfaceNames = Set<String>()
        let snapshots: [PathInterfaceSnapshot] = path.availableInterfaces.compactMap {
            candidate -> PathInterfaceSnapshot? in
            guard seenInterfaceNames.insert(candidate.name).inserted else { return nil }
            return PathInterfaceSnapshot(
                name: candidate.name,
                index: candidate.index,
                type: networkTypeName(candidate.type)
            )
        }
        do {
            let data = try JSONEncoder().encode(snapshots)
            guard let json = String(data: data, encoding: .utf8) else {
                throw providerError(5, "无法编码 Underlay 接口快照")
            }
            try engine.setNetworkInterfaces(json)
        } catch {
            setLastError("发布 Underlay 接口失败：\(error.localizedDescription)")
            os_log("publish Underlay interfaces failed: %{public}@",
                   log: log, type: .error, error.localizedDescription)
        }

        setDefaultInterfaceDiagnostic(name: interface.name, index: interface.index)
        engine.setDefaultInterface(interface.name, index: interface.index)
        refreshDiagnostic()
        os_log("default Underlay interface: %{public}@ (%d)", log: log, type: .info,
               interface.name, interface.index)
    }

    private func selectDefaultInterface(from path: NWPath) -> NWInterface? {
        path.availableInterfaces.first
    }

    private func networkTypeName(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi:
            return "wifi"
        case .cellular:
            return "cellular"
        case .wiredEthernet:
            return "ethernet"
        default:
            return "other"
        }
    }

    /// 构造 NEPacketTunnelNetworkSettings。
    /// 隧道地址与 core/config buildTUNInbound 对齐。IPv6 也必须进入 packetFlow，
    /// 即使远端仅支持 IPv4，也应在受控出口 fail closed，不能绕过默认路由直出。
    private func buildNetworkSettings(remoteAddress: String) -> NEPacketTunnelNetworkSettings {
        // 调用方已用 IPv4Address 做过最终数值校验；不要在这里回退 hostname。
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remoteAddress)

        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.254.0.0"]) // /15
        // 默认路由:全部流量进隧道,由 sing-box 的 route 规则再做分流。
        ipv4.includedRoutes = [NEIPv4Route.default()]
        // 控制连接必须始终走已有 Underlay，不能被刚安装的默认路由套回自身。
        ipv4.excludedRoutes = [
            NEIPv4Route(destinationAddress: remoteAddress, subnetMask: "255.255.255.255"),
        ]
        settings.ipv4Settings = ipv4

        let ipv6 = NEIPv6Settings(addresses: ["fd00::1"], networkPrefixLengths: [126])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6

        let dns = NEDNSSettings(servers: ["198.18.0.2"])
        dns.matchDomains = [""]
        dns.matchDomainsNoSearch = true
        if #available(iOS 26.0, tvOS 26.0, *) {
            dns.allowFailover = false
        }
        settings.dnsSettings = dns

        settings.mtu = 9000 // 与 buildTUNInbound 的 mtu 对齐

        return settings
    }

    private func validDNSServers(from json: String) -> [String]? {
        guard let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        let validated = values.filter { IPv4Address($0) != nil }
        return validated.count == values.count ? validated : nil
    }

    private func tailscaleBackendIsRunning(_ rawStatus: String) -> Bool {
        guard let data = rawStatus.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = object["backend_state"] as? String else {
            return false
        }
        return state.caseInsensitiveCompare("running") == .orderedSame
    }

    // MARK: - 发布版诊断

    private struct DiagnosticState {
        let stage: String
        let attemptID: String
        let defaultInterfaceName: String
        let defaultInterfaceIndex: Int
        let lastError: String?
    }

    private func beginAttempt(_ attemptID: String) {
        diagnosticLock.lock()
        activeAttemptID = attemptID
        lastError = nil
        diagnosticStage = "idle"
        defaultInterfaceName = ""
        defaultInterfaceIndex = -1
        diagnosticSensitiveValues = []
        diagnosticLock.unlock()
    }

    private func setLastError(_ value: String?) {
        let safeValue = sanitizedDiagnosticText(value)
        diagnosticLock.lock()
        lastError = safeValue
        diagnosticLock.unlock()
    }

    private func currentLastError() -> String? {
        diagnosticLock.lock()
        let value = lastError
        diagnosticLock.unlock()
        return value
    }

    private func setDefaultInterfaceDiagnostic(name: String, index: Int) {
        diagnosticLock.lock()
        defaultInterfaceName = name
        defaultInterfaceIndex = index
        diagnosticLock.unlock()
    }

    private func captureDiagnosticState(updatingStage stage: String? = nil) -> DiagnosticState {
        diagnosticLock.lock()
        if let stage {
            diagnosticStage = stage
        }
        let state = DiagnosticState(
            stage: diagnosticStage,
            attemptID: activeAttemptID,
            defaultInterfaceName: defaultInterfaceName,
            defaultInterfaceIndex: defaultInterfaceIndex,
            lastError: lastError
        )
        diagnosticLock.unlock()
        return state
    }

    private func recordDiagnostic(_ stage: String) {
        diagnosticWriteQueue.sync {
            let state = captureDiagnosticState(updatingStage: stage)
            persistDiagnostic(makeDiagnosticSnapshot(from: state, includeEngine: false))
            os_log("diagnostic stage=%{public}@ interface=%{public}@",
                   log: log, type: .info, state.stage, state.defaultInterfaceName)
        }
    }

    /// 接口监控只刷新当前快照，不允许把已经推进的启动 stage 写回旧值。
    private func refreshDiagnostic() {
        diagnosticWriteQueue.sync {
            let state = captureDiagnosticState()
            persistDiagnostic(makeDiagnosticSnapshot(from: state, includeEngine: false))
        }
    }

    private func persistDiagnostic(_ snapshot: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: snapshot),
           let text = String(data: data, encoding: .utf8) {
            let defaults = UserDefaults(suiteName: Self.appGroupID)
            defaults?.set(text, forKey: Self.diagnosticKey)
            // 诊断的价值恰恰在进程异常退出时仍可读取；这里主动落盘，避免只留在缓存。
            defaults?.synchronize()
        }
    }

    private func diagnosticSnapshot(includeEngine: Bool) -> [String: Any] {
        makeDiagnosticSnapshot(from: captureDiagnosticState(), includeEngine: includeEngine)
    }

    private func makeDiagnosticSnapshot(
        from state: DiagnosticState,
        includeEngine: Bool
    ) -> [String: Any] {
        var snapshot: [String: Any] = [
            "stage": state.stage,
            "timestamp": Date().timeIntervalSince1970,
            "default_interface_name": state.defaultInterfaceName,
            "default_interface_index": state.defaultInterfaceIndex,
            // 旧 App 仍读取这两个键；完成桌面迁移并提升诊断 schema 后删除。
            "physical_interface_name": state.defaultInterfaceName,
            "physical_interface_index": state.defaultInterfaceIndex,
        ]
        if !state.attemptID.isEmpty {
            snapshot["attempt_id"] = state.attemptID
        }
        if let lastError = state.lastError, !lastError.isEmpty {
            snapshot["last_error"] = lastError
        }
        if includeEngine, let engineJSON = currentEngine()?.diagnostics(),
           let data = engineJSON.data(using: .utf8),
           let engine = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            snapshot["engine"] = sanitizedDiagnosticObject(engine)
        }
        return snapshot
    }

    private func setDiagnosticSensitiveValues(from bundle: StartBundle) {
        var values = Set([bundle.server, bundle.username, bundle.password])
        if let data = bundle.configJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            collectDiagnosticSensitiveValues(from: object, key: nil, into: &values)
        }
        diagnosticLock.lock()
        diagnosticSensitiveValues = values.filter { $0.count >= 3 }.sorted { $0.count > $1.count }
        diagnosticLock.unlock()
    }

    private func collectDiagnosticSensitiveValues(
        from object: Any,
        key: String?,
        into values: inout Set<String>
    ) {
        if let dictionary = object as? [String: Any] {
            for (childKey, child) in dictionary {
                collectDiagnosticSensitiveValues(from: child, key: childKey, into: &values)
            }
            return
        }
        if let array = object as? [Any] {
            for child in array {
                collectDiagnosticSensitiveValues(from: child, key: key, into: &values)
            }
            return
        }
        guard let value = object as? String, let key else { return }
        switch key.lowercased() {
        case "server", "server_name", "username", "password", "uuid", "url", "path":
            values.insert(value)
        default:
            break
        }
    }

    private func sanitizedDiagnosticText(_ value: String?) -> String? {
        guard var result = value, !result.isEmpty else { return value }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            for match in detector.matches(in: result, range: range).reversed() {
                guard let swiftRange = Range(match.range, in: result) else { continue }
                result.replaceSubrange(swiftRange, with: "<redacted-url>")
            }
        }
        diagnosticLock.lock()
        let sensitiveValues = diagnosticSensitiveValues
        diagnosticLock.unlock()
        for sensitive in sensitiveValues {
            result = result.replacingOccurrences(of: sensitive, with: "<redacted>")
        }
        return String(result.prefix(1_024))
    }

    private func sanitizedDiagnosticObject(_ object: Any) -> Any {
        if let dictionary = object as? [String: Any] {
            return dictionary.mapValues { sanitizedDiagnosticObject($0) }
        }
        if let array = object as? [Any] {
            return array.map { sanitizedDiagnosticObject($0) }
        }
        if let text = object as? String {
            return sanitizedDiagnosticText(text) ?? ""
        }
        return object
    }

    // MARK: - tun fd 获取

    /// 取 NE packetFlow 对应的文件描述符。
    ///
    /// NEPacketTunnelFlow 不公开暴露底层 fd。直接采用 sing-box Apple 客户端的
    /// 官方做法：扫描扩展进程持有的 utun control socket。不要先读私有 KVC keyPath；
    /// key 不存在时会抛 Objective-C exception，Swift 无法捕获并会让扩展直接退出。
    private func tunFileDescriptor() -> Int? {
        let discoveredFD = LibboxGetTunnelFileDescriptor()
        if discoveredFD > 0 { return Int(discoveredFD) }
        return nil
    }

    // MARK: - 错误构造

    private func providerError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: Self.subsystem, code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// 静态版错误构造:供 startTunnel 内 `[weak self]` 闭包在 self 已释放时使用。
private func providerErrorStatic(_ code: Int, _ message: String) -> NSError {
    #if os(iOS)
    let domain = "com.kafeifei.xdial.ios.tunnel"
    #else
    let domain = "com.kafeifei.xdialtv.tunnel"
    #endif
    return NSError(domain: domain, code: code,
            userInfo: [NSLocalizedDescriptionKey: message])
}
