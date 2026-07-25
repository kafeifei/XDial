import Combine
import Security
import XCTest
@testable import XDial

private final class StartCompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<Void, Error>] = []

    func record(_ result: Result<Void, Error>) {
        lock.lock()
        results.append(result)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return results.count
    }

    var cancellationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return results.filter { result in
            guard case .failure(let error) = result else { return false }
            return error is CancellationError
        }.count
    }

    var successCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return results.filter {
            if case .success = $0 { return true }
            return false
        }.count
    }
}

private final class GenerationQueueProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let group = DispatchGroup()
    private let blockedWorkStarted = DispatchSemaphore(value: 0)
    private let blockedWorkRelease = DispatchSemaphore(value: 0)
    private var inFlight = 0
    private var maxInFlight = 0
    private var completionOrder: [Int] = []

    func prepare() {
        group.enter()
    }

    func execute(index: Int, waitForRelease: Bool = false) {
        lock.lock()
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        lock.unlock()

        if waitForRelease {
            blockedWorkStarted.signal()
            _ = blockedWorkRelease.wait(timeout: .now() + 3)
        }
        Thread.sleep(forTimeInterval: 0.01)

        lock.lock()
        completionOrder.append(index)
        inFlight -= 1
        lock.unlock()
        group.leave()
    }

    func wait() -> DispatchTimeoutResult {
        group.wait(timeout: .now() + 3)
    }

    func waitUntilBlockedWorkStarts() -> DispatchTimeoutResult {
        blockedWorkStarted.wait(timeout: .now() + 3)
    }

    func releaseBlockedWork() {
        blockedWorkRelease.signal()
    }

    var snapshot: (maxInFlight: Int, completionOrder: [Int]) {
        lock.lock()
        defer { lock.unlock() }
        return (maxInFlight, completionOrder)
    }
}

@MainActor
private final class CancellingTunnelManager: TunnelManaging {
    let isProfileInstalled = true
    private(set) var stopCallCount = 0

    func refreshProfileStatus(completion: @escaping @Sendable (Bool) -> Void) {
        completion(true)
    }

    func startTunnel(
        profile: Profile,
        anyConnect: AnyConnectCredentials?,
        allowSystemOnDemand: Bool,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        completion(.failure(CancellationError()))
    }

    func stopTunnel() {
        stopCallCount += 1
    }
}

@MainActor
private final class DisconnectSpyEngine: TunnelEngine {
    let objectWillChange = ObservableObjectPublisher()
    let status = "disconnected"
    var lastError: String?
    var dataPathSummary: String?
    var isConnected: Bool { false }
    var isBusy: Bool { false }
    private(set) var stopCallCount = 0

    func start(profileJSON: String) {}

    func stop() {
        stopCallCount += 1
        lastError = "extension did not respond"
    }

    func syncStatus() {}
}

@MainActor
private final class RuntimeSpyEngine: TunnelEngine, ObservableObject {
    @Published private(set) var status = "disconnected"
    var lastError: String?
    var dataPathSummary: String?
    var statusPublisher: AnyPublisher<String, Never> { $status.eraseToAnyPublisher() }
    var isConnected: Bool { status == "connected" }
    var isBusy: Bool { status == "connecting" || status == "disconnecting" }
    private(set) var selections: [(String, String, String)] = []
    private(set) var tailscaleEndpointTags: [String] = []
    private(set) var tailscaleLoginEndpointTags: [String] = []
    private var automaticReconnectSuppressed = false
    var tailscaleResultsByEndpointTag: [
        String: Result<TailscaleRuntimeStatus, Error>
    ] = [:]
    var tailscaleResult: Result<TailscaleRuntimeStatus, Error> = .success(TailscaleRuntimeStatus(
        backendState: "Running",
        authURL: "",
        exitNodes: []
    ))

    func start(profileJSON: String) { status = "connected" }
    func stop() { status = "disconnected" }
    func syncStatus() {}
    func setStatus(_ value: String) { status = value }
    func suppressNextAutomaticReconnect() { automaticReconnectSuppressed = true }
    func consumeAutomaticReconnectPermission() -> Bool {
        let allowed = !automaticReconnectSuppressed
        automaticReconnectSuppressed = false
        return allowed
    }

    func selectSubscriptionMember(
        profileJSON: String,
        subscriptionID: String,
        groupName: String,
        memberName: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        selections.append((subscriptionID, groupName, memberName))
        completion(.success(()))
    }

    func tailscaleStatus(
        endpointTag: String,
        completion: @escaping (Result<TailscaleRuntimeStatus, Error>) -> Void
    ) {
        tailscaleEndpointTags.append(endpointTag)
        completion(tailscaleResultsByEndpointTag[endpointTag] ?? tailscaleResult)
    }

    func beginTailscaleLogin(
        endpointTag: String,
        completion: @escaping (Result<TailscaleRuntimeStatus, Error>) -> Void
    ) {
        tailscaleLoginEndpointTags.append(endpointTag)
        completion(tailscaleResult)
    }
}

@MainActor
private final class TailscaleSetupRuntimeSpy: TailscaleSetupRuntime {
    private(set) var isActive = false
    private(set) var startCalls: [(profileJSON: String, lineID: String)] = []
    private(set) var statusLineIDs: [String] = []
    private(set) var beginLoginLineIDs: [String] = []
    private(set) var logoutLineIDs: [String] = []
    private(set) var stopCallCount = 0
    var deferStopCompletion = false
    private var stopCompletions: [() -> Void] = []

    var startResult: Result<TailscaleRuntimeStatus, Error> = .success(
        TailscaleRuntimeStatus(
            backendState: "NeedsLogin",
            authURL: "https://login.tailscale.com/a/unit-test",
            exitNodes: []
        )
    )
    var statusResult: Result<TailscaleRuntimeStatus, Error> = .success(
        TailscaleRuntimeStatus(
            backendState: "Running",
            authURL: "",
            exitNodes: [
                TailscaleRuntimeExitNode(
                    id: "mbp64k",
                    name: "mbp64k",
                    ip: "100.64.0.8",
                    online: true,
                    os: "macOS"
                ),
            ]
        )
    )
    var beginLoginResult: Result<TailscaleRuntimeStatus, Error> = .success(
        TailscaleRuntimeStatus(
            backendState: "NeedsLogin",
            authURL: "https://login.tailscale.com/a/unit-test",
            exitNodes: []
        )
    )
    var logoutResult: Result<Void, Error> = .success(())

    func start(
        profileJSON: String,
        lineID: String,
        completion: @escaping (Result<TailscaleRuntimeStatus, Error>) -> Void
    ) {
        startCalls.append((profileJSON, lineID))
        if case .success = startResult {
            isActive = true
        }
        completion(startResult)
    }

    func status(
        lineID: String,
        completion: @escaping (Result<TailscaleRuntimeStatus, Error>) -> Void
    ) {
        statusLineIDs.append(lineID)
        completion(statusResult)
    }

    func beginLogin(
        lineID: String,
        completion: @escaping (Result<TailscaleRuntimeStatus, Error>) -> Void
    ) {
        beginLoginLineIDs.append(lineID)
        completion(beginLoginResult)
    }

    func logout(
        lineID: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        logoutLineIDs.append(lineID)
        completion(logoutResult)
    }

    func stop(completion: @escaping () -> Void) {
        stopCallCount += 1
        if deferStopCompletion {
            stopCompletions.append(completion)
        } else {
            isActive = false
            completion()
        }
    }

    func completeStop() {
        isActive = false
        let completions = stopCompletions
        stopCompletions.removeAll()
        completions.forEach { $0() }
    }
}

@MainActor
private final class TailscaleStatusSession: TunnelSession {
    private(set) var request: [String: String] = [:]

    func sendProviderMessage(_ messageData: Data, responseHandler: ((Data?) -> Void)?) throws {
        request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: messageData) as? [String: String]
        )
        let statusData = try JSONSerialization.data(withJSONObject: [
            "backend_state": "Running",
            "auth_url": "",
            "exit_nodes": [[
                "id": "exit-a",
                "name": "Home",
                "ip": "100.64.0.8",
                "online": true,
                "os": "macOS",
            ]],
        ])
        let status = try XCTUnwrap(String(data: statusData, encoding: .utf8))
        responseHandler?(try JSONSerialization.data(withJSONObject: ["ok": true, "data": status]))
    }
}

@MainActor
private final class RuntimeSpyManager: TunnelManaging {
    private(set) var isProfileInstalled = true
    private(set) var systemOnDemandActive = false
    @Published private(set) var systemOnDemandState: SystemOnDemandState = .disabled
    var systemOnDemandStatePublisher: AnyPublisher<SystemOnDemandState, Never> {
        $systemOnDemandState.eraseToAnyPublisher()
    }
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var removeCallCount = 0
    private(set) var lastAnyConnect: AnyConnectCredentials?
    private(set) var lastProfile: Profile?
    private(set) var lastAllowSystemOnDemand: Bool?
    private(set) var systemOnDemandRequests: [Bool] = []
    private(set) var systemOnDemandSetupSuspensions: [Bool] = []
    private weak var engine: RuntimeSpyEngine?

    init(engine: RuntimeSpyEngine) {
        self.engine = engine
    }

    func refreshProfileStatus(completion: @escaping @Sendable (Bool) -> Void) {
        completion(isProfileInstalled)
    }

    func setSystemOnDemandEnabled(_ enabled: Bool) {
        systemOnDemandRequests.append(enabled)
        if !enabled {
            systemOnDemandActive = false
            systemOnDemandState = .disabled
        } else if !systemOnDemandActive {
            systemOnDemandState = .pending
        }
    }

    func setSystemOnDemandSuspendedForSetup(
        _ suspended: Bool,
        completion: @escaping () -> Void
    ) {
        systemOnDemandSetupSuspensions.append(suspended)
        if suspended {
            systemOnDemandActive = false
            systemOnDemandState = .pending
        }
        completion()
    }

    func simulateSystemOnDemandActive() {
        systemOnDemandActive = true
        systemOnDemandState = .active
    }

    func simulateSystemOnDemandFailure() {
        systemOnDemandActive = false
        systemOnDemandState = .failed("simulated failure")
    }

    func startTunnel(
        profile: Profile,
        anyConnect: AnyConnectCredentials?,
        allowSystemOnDemand: Bool,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        startCallCount += 1
        lastProfile = profile
        lastAnyConnect = anyConnect
        lastAllowSystemOnDemand = allowSystemOnDemand
        engine?.setStatus("connected")
        completion(.success(()))
    }

    func stopTunnel() {
        stopCallCount += 1
        engine?.setStatus("disconnected")
    }

    func removeProfile(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        removeCallCount += 1
        isProfileInstalled = false
        completion(.success(()))
    }
}

@MainActor
final class AppStateTests: XCTestCase {
    private func makePersistence() -> AppPersistenceContext {
        let context = AppPersistenceContext.testing(identifier: "unit-" + UUID().uuidString)
        XCTAssertTrue(context.clearForTesting())
        addTeardownBlock {
            XCTAssertTrue(context.clearForTesting())
        }
        return context
    }

    private func configuredProfile() -> Profile {
        var profile = Profile.bootstrap()
        profile.lines[1].vpnServer = "gateway.example.com"
        profile.lines[1].vpnUsername = "tester"
        profile.lines[1].vpnPassword = "secret"
        profile.modes = [Mode(id: "test-mode", name: "Test", defaultLineID: "vpn")]
        profile.activeModeID = "test-mode"
        profile.ensureConnectivityTestConfiguration()
        return profile
    }

    func testConnectivityAcceptanceRulesAreVisibleAndExplicitlyBound() {
        var profile = Profile.bootstrap()
        profile.ruleSets.removeAll { $0.isConnectivityTestRule }
        profile.modes = [Mode(
            id: "legacy-mode",
            name: "Legacy",
            bindings: [RuleBinding(ruleSetID: "internal", lineID: "vpn")],
            defaultLineID: "direct"
        )]

        XCTAssertTrue(profile.ensureConnectivityTestConfiguration())
        XCTAssertEqual(
            profile.ruleSets.first(where: { $0.id == RuleSet.connectivityDirectID })?.cidrs,
            ["1.0.0.1/32"]
        )
        XCTAssertEqual(
            profile.ruleSets.first(where: { $0.id == RuleSet.connectivityAnyConnectID })?.cidrs,
            ["1.1.1.1/32"]
        )
        XCTAssertEqual(
            Array(profile.modes[0].bindings.prefix(2)),
            [
                RuleBinding(ruleSetID: RuleSet.connectivityDirectID, lineID: "direct"),
                RuleBinding(ruleSetID: RuleSet.connectivityOutboundID, lineID: "vpn"),
            ]
        )
        XCTAssertTrue(profile.modes[0].bindings.contains {
            $0.ruleSetID == "internal" && $0.lineID == "vpn"
        })
        XCTAssertFalse(profile.ensureConnectivityTestConfiguration())
    }

    func testConnectivityAcceptanceMarksPureDirectAsSingleRoute() {
        var profile = Profile.bootstrap()
        profile.lines.append(Line(id: "vpn-two", name: "Second", type: "vpn"))
        profile.modes = [Mode(id: "blank", name: "Blank", defaultLineID: "direct")]

        profile.ensureConnectivityTestConfiguration()

        XCTAssertFalse(profile.modes[0].bindings.contains {
            $0.ruleSetID == RuleSet.connectivityOutboundID
        })
    }

    func testConnectivityAcceptanceDoesNotInjectUnreferencedSingleAnyConnectLine() {
        var profile = Profile.bootstrap()
        profile.modes = [Mode(id: "blank", name: "Blank", defaultLineID: "direct")]

        profile.ensureConnectivityTestConfiguration()

        XCTAssertFalse(profile.modes[0].bindings.contains {
            $0.ruleSetID == RuleSet.connectivityOutboundID
        })
    }

    func testConnectivityAcceptanceUsesFirstOrdinaryNonDirectBindingWhenDefaultIsDirect() {
        var profile = Profile.bootstrap()
        profile.lines.append(Line(
            id: "proxy-one",
            name: "Proxy",
            type: "trojan",
            trojanServer: "proxy.example.com",
            trojanPassword: "secret"
        ))
        profile.ruleSets.append(RuleSet(
            id: "proxy-rule",
            name: "Proxy",
            type: "manual",
            domains: ["proxy.example"]
        ))
        profile.modes = [Mode(
            id: "mixed",
            name: "Mixed",
            bindings: [
                RuleBinding(ruleSetID: "proxy-rule", lineID: "proxy-one"),
                RuleBinding(ruleSetID: "internal", lineID: "vpn"),
            ],
            defaultLineID: "direct"
        )]

        profile.ensureConnectivityTestConfiguration()

        XCTAssertEqual(
            profile.modes[0].bindings.first(where: {
                $0.ruleSetID == RuleSet.connectivityOutboundID
            }),
            RuleBinding(ruleSetID: RuleSet.connectivityOutboundID, lineID: "proxy-one")
        )
    }

    func testConnectivityAcceptanceUsesEnabledDirectLine() {
        var profile = Profile.bootstrap()
        profile.lines[0].enabled = false
        profile.lines.append(Line(id: "direct-enabled", name: "Direct Enabled", type: "direct"))
        profile.modes = [Mode(id: "test", name: "Test", defaultLineID: "vpn")]

        profile.ensureConnectivityTestConfiguration()

        XCTAssertTrue(profile.modes[0].bindings.contains {
            $0.ruleSetID == RuleSet.connectivityDirectID && $0.lineID == "direct-enabled"
        })
        XCTAssertFalse(profile.modes[0].bindings.contains {
            $0.ruleSetID == RuleSet.connectivityDirectID && $0.lineID == "direct"
        })
    }

    func testConnectionRebindsAcceptanceToCurrentDirectRouteAfterSaveNormalization() async {
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)
        let persistence = makePersistence()
        let app = AppState(engine: engine, tunnelManager: manager, persistence: persistence)
        var profile = configuredProfile()
        profile.modes[0].defaultLineID = "direct"
        profile.modes[0].bindings.removeAll { !$0.isConnectivityAcceptanceBindingForTest }
        app.profile = profile

        XCTAssertTrue(app.save())
        XCTAssertTrue(app.canConnect)
        app.connect()
        await Task.yield()

        XCTAssertEqual(manager.startCallCount, 1)
        XCTAssertNil(manager.lastAnyConnect)
        XCTAssertFalse(app.profile.modes[0].bindings.contains {
            $0.ruleSetID == RuleSet.connectivityOutboundID
        })
    }

    func testPureProxyModeStartsWithoutAnyConnectCredentials() async {
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)
        let app = AppState(engine: engine, tunnelManager: manager, persistence: makePersistence())
        var profile = Profile.bootstrap()
        profile.lines.append(Line(
            id: "proxy-one",
            name: "Proxy One",
            type: "shadowsocks",
            ssServer: "proxy.example.com",
            ssPort: 443,
            ssMethod: "aes-128-gcm",
            ssPassword: "secret"
        ))
        profile.modes = [Mode(id: "proxy-mode", name: "Proxy", defaultLineID: "proxy-one")]
        profile.activeModeID = "proxy-mode"
        profile.ensureConnectivityTestConfiguration()
        app.profile = profile

        XCTAssertTrue(app.canConnect, app.activeConfigurationIssues.joined(separator: "\n"))
        app.connect()
        await Task.yield()

        XCTAssertEqual(manager.startCallCount, 1)
        XCTAssertNil(manager.lastAnyConnect)
    }

    func testPureTailscaleModeStartsWithoutAnyConnectCredentials() async {
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)
        let app = AppState(engine: engine, tunnelManager: manager, persistence: makePersistence())
        var profile = Profile.bootstrap()
        profile.lines.append(Line(
            id: "tail",
            name: "Tail",
            type: "tailscale",
            tailscaleExitNode: "100.64.0.8",
            tailscaleAuthenticated: true
        ))
        profile.modes = [Mode(id: "tail-mode", name: "Tail", defaultLineID: "tail")]
        profile.activeModeID = "tail-mode"
        profile.ensureConnectivityTestConfiguration()
        app.profile = profile

        XCTAssertTrue(app.canConnect, app.activeConfigurationIssues.joined(separator: "\n"))
        app.connect()
        await Task.yield()

        XCTAssertEqual(manager.startCallCount, 1)
        XCTAssertNil(manager.lastAnyConnect)
    }

    func testTailscaleSetupUsesLocalRuntimeWithoutStartingSystemTunnel() throws {
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)
        let setupRuntime = TailscaleSetupRuntimeSpy()
        let persistence = makePersistence()
        persistence.defaults.set(true, forKey: persistence.systemOnDemandKey)
        let app = AppState(
            engine: engine,
            tunnelManager: manager,
            tailscaleSetupRuntime: setupRuntime,
            persistence: persistence
        )
        var profile = configuredProfile()
        profile.lines.append(Line(
            id: "tail",
            name: "Home Tailnet",
            type: "tailscale",
            enabled: false,
            tailscaleAcceptRoutes: true,
            tailscaleExitNode: "100.64.0.99"
        ))
        app.profile = profile
        XCTAssertTrue(app.canConnect, app.activeConfigurationIssues.joined(separator: "\n"))

        let recorder = StartCompletionRecorder()
        app.prepareTailscaleLogin(lineID: "tail") { recorder.record($0) }

        XCTAssertEqual(recorder.successCount, 1)
        XCTAssertEqual(manager.startCallCount, 0)
        XCTAssertEqual(manager.stopCallCount, 0)
        XCTAssertEqual(engine.status, "disconnected")
        XCTAssertEqual(app.tailscaleSetupLineID, "tail")
        XCTAssertTrue(app.isTailscaleSetupActive)
        XCTAssertFalse(app.canConnect)
        XCTAssertEqual(setupRuntime.startCalls.map(\.lineID), ["tail"])
        XCTAssertEqual(
            app.profile.lines.first(where: { $0.id == "tail" })?.tailscaleExitNode,
            "100.64.0.99"
        )
        let setupProfileData = try XCTUnwrap(
            setupRuntime.startCalls.first?.profileJSON.data(using: .utf8)
        )
        let setupProfile = try JSONDecoder().decode(Profile.self, from: setupProfileData)
        XCTAssertEqual(
            setupProfile.lines.first(where: { $0.id == "tail" })?.enabled,
            false
        )
        XCTAssertEqual(manager.systemOnDemandSetupSuspensions, [true])

        app.finishTailscaleSetup()
        XCTAssertEqual(setupRuntime.stopCallCount, 1)
        XCTAssertEqual(manager.startCallCount, 0)
        XCTAssertEqual(manager.stopCallCount, 0)
        XCTAssertEqual(engine.status, "disconnected")
        XCTAssertEqual(manager.systemOnDemandSetupSuspensions, [true, false])
        XCTAssertNil(app.tailscaleSetupLineID)
        XCTAssertNil(persistence.defaults.string(forKey: persistence.tailscaleSetupLineKey))
        XCTAssertTrue(app.canConnect, app.activeConfigurationIssues.joined(separator: "\n"))
    }

    func testTailscaleSetupCompletesBeforeFormalConnectionWithoutInterimSystemTunnel() {
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)
        let setupRuntime = TailscaleSetupRuntimeSpy()
        setupRuntime.beginLoginResult = .success(TailscaleRuntimeStatus(
            backendState: "Running",
            authURL: "",
            exitNodes: [
                TailscaleRuntimeExitNode(
                    id: "mbp64k",
                    name: "mbp64k",
                    ip: "100.64.0.8",
                    online: true,
                    os: "macOS"
                ),
            ]
        ))
        let app = AppState(
            engine: engine,
            tunnelManager: manager,
            tailscaleSetupRuntime: setupRuntime,
            persistence: makePersistence()
        )
        var profile = Profile.bootstrap()
        profile.lines.append(Line(
            id: "tail",
            name: "Tail",
            type: "tailscale",
            enabled: true
        ))
        profile.modes = [Mode(id: "tail-mode", name: "Tail", defaultLineID: "tail")]
        profile.activeModeID = "tail-mode"
        profile.ensureConnectivityTestConfiguration()
        app.profile = profile

        XCTAssertFalse(app.canConnect)
        XCTAssertTrue(app.activeConfigurationIssues.contains {
            $0.contains("登录") || $0.lowercased().contains("sign")
        })

        let setupRecorder = StartCompletionRecorder()
        app.prepareTailscaleLogin(lineID: "tail") { setupRecorder.record($0) }
        XCTAssertEqual(setupRecorder.successCount, 1, "离线 Tailscale 设置未成功启动")
        XCTAssertEqual(engine.status, "disconnected")
        XCTAssertEqual(manager.startCallCount, 0)
        XCTAssertEqual(manager.stopCallCount, 0)
        XCTAssertEqual(manager.systemOnDemandSetupSuspensions, [true])

        var loginStatus: TailscaleRuntimeStatus?
        app.beginTailscaleLogin(lineID: "tail") { loginStatus = try? $0.get() }
        XCTAssertEqual(loginStatus?.backendState, "Running")
        XCTAssertTrue(app.applyTailscaleRuntimeStatus(
            lineID: "tail",
            status: loginStatus ?? TailscaleRuntimeStatus(
                backendState: "",
                authURL: "",
                exitNodes: []
            )
        ))
        XCTAssertTrue(app.updateTailscaleExitSelection(
            lineID: "tail",
            selected: "100.64.0.8"
        ))

        app.finishTailscaleSetup()
        XCTAssertEqual(setupRuntime.stopCallCount, 1)
        XCTAssertEqual(manager.startCallCount, 0)
        XCTAssertEqual(manager.stopCallCount, 0)
        XCTAssertEqual(engine.status, "disconnected")
        XCTAssertNil(app.tailscaleSetupLineID)
        XCTAssertEqual(manager.systemOnDemandSetupSuspensions, [true, false])
        XCTAssertTrue(app.canConnect, app.activeConfigurationIssues.joined(separator: "\n"))

        app.connect()
        XCTAssertEqual(manager.startCallCount, 1)
        XCTAssertEqual(engine.status, "connected")
    }

    func testFinishingTailscaleSetupIsExactOnceAndKeepsConnectLockedUntilStopCompletes() {
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)
        let setupRuntime = TailscaleSetupRuntimeSpy()
        let app = AppState(
            engine: engine,
            tunnelManager: manager,
            tailscaleSetupRuntime: setupRuntime,
            persistence: makePersistence()
        )
        var profile = configuredProfile()
        profile.lines.append(Line(
            id: "tail",
            name: "Tail",
            type: "tailscale",
            enabled: false
        ))
        app.profile = profile
        app.prepareTailscaleLogin(lineID: "tail") { _ in }
        setupRuntime.deferStopCompletion = true

        var finishCount = 0
        app.finishTailscaleSetup { finishCount += 1 }
        app.finishTailscaleSetup { finishCount += 1 }

        XCTAssertEqual(setupRuntime.stopCallCount, 1)
        XCTAssertEqual(finishCount, 0)
        XCTAssertTrue(app.isStoppingTailscaleSetup)
        XCTAssertEqual(app.tailscaleSetupLineID, "tail")
        XCTAssertFalse(app.canConnect)

        setupRuntime.completeStop()

        XCTAssertEqual(finishCount, 2)
        XCTAssertFalse(app.isStoppingTailscaleSetup)
        XCTAssertNil(app.tailscaleSetupLineID)
        XCTAssertTrue(app.canConnect)
    }

    func testConnectedTunnelCanConfigureDifferentInactiveTailscaleLine() {
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)
        let setupRuntime = TailscaleSetupRuntimeSpy()
        let app = AppState(
            engine: engine,
            tunnelManager: manager,
            tailscaleSetupRuntime: setupRuntime,
            persistence: makePersistence()
        )
        var profile = configuredProfile()
        profile.lines.append(Line(
            id: "tail-inactive",
            name: "Inactive Tail",
            type: "tailscale",
            enabled: false
        ))
        app.profile = profile
        app.connect()

        XCTAssertEqual(engine.status, "connected")
        XCTAssertEqual(manager.startCallCount, 1)
        XCTAssertFalse(app.isTailscaleLineGeneratedByFormalTunnel("tail-inactive"))
        XCTAssertTrue(app.canStartTailscaleSetup(lineID: "tail-inactive"))

        let setupRecorder = StartCompletionRecorder()
        app.prepareTailscaleLogin(lineID: "tail-inactive") {
            setupRecorder.record($0)
        }
        XCTAssertEqual(
            setupRecorder.successCount,
            1,
            "稳定正式连接中未能启动另一条 disabled Tailscale 的独立设置"
        )

        XCTAssertTrue(app.isConnected)
        XCTAssertTrue(app.isTailscaleSetupActive)
        XCTAssertTrue(
            app.statusText.contains("已连接") || app.statusText.contains("Connected")
        )
        XCTAssertTrue(
            app.statusText.contains("正在设置") || app.statusText.contains("Setting Up")
        )
        XCTAssertTrue(app.canQueryTailscaleRuntime(lineID: "tail-inactive"))
        XCTAssertEqual(manager.startCallCount, 1)
        XCTAssertEqual(manager.stopCallCount, 0)
        XCTAssertTrue(manager.systemOnDemandSetupSuspensions.isEmpty)

        app.finishTailscaleSetup()

        XCTAssertTrue(app.isConnected)
        XCTAssertNil(app.tailscaleSetupLineID)
        XCTAssertEqual(manager.stopCallCount, 0)
    }

    func testTailscaleSetupStatusAndLoginUseLocalRuntime() {
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)
        let setupRuntime = TailscaleSetupRuntimeSpy()
        let persistence = makePersistence()
        let app = AppState(
            engine: engine,
            tunnelManager: manager,
            tailscaleSetupRuntime: setupRuntime,
            persistence: persistence
        )
        var profile = Profile.bootstrap()
        profile.lines.append(Line(
            id: "tail",
            name: "Tail",
            type: "tailscale"
        ))
        app.profile = profile

        let recorder = StartCompletionRecorder()
        app.prepareTailscaleLogin(lineID: "tail") { recorder.record($0) }
        XCTAssertEqual(recorder.successCount, 1)
        XCTAssertEqual(app.tailscaleSetupLineID, "tail")

        var refreshedStatus: TailscaleRuntimeStatus?
        app.refreshTailscaleStatus(lineID: "tail") { result in
            refreshedStatus = try? result.get()
        }
        var loginStatus: TailscaleRuntimeStatus?
        app.beginTailscaleLogin(lineID: "tail") { result in
            loginStatus = try? result.get()
        }

        XCTAssertEqual(setupRuntime.statusLineIDs, ["tail"])
        XCTAssertEqual(setupRuntime.beginLoginLineIDs, ["tail"])
        XCTAssertEqual(refreshedStatus?.backendState, "Running")
        XCTAssertEqual(refreshedStatus?.exitNodes.map(\.name), ["mbp64k"])
        XCTAssertEqual(loginStatus?.authURL, "https://login.tailscale.com/a/unit-test")
        XCTAssertTrue(engine.tailscaleEndpointTags.isEmpty)
        XCTAssertTrue(engine.tailscaleLoginEndpointTags.isEmpty)
        XCTAssertEqual(manager.startCallCount, 0)
        XCTAssertEqual(manager.stopCallCount, 0)
        XCTAssertEqual(engine.status, "disconnected")
    }

    func testTailscaleLogoutClearsPersistedLineStateAfterRuntimeSuccess() {
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)
        let setupRuntime = TailscaleSetupRuntimeSpy()
        setupRuntime.startResult = .success(TailscaleRuntimeStatus(
            backendState: "Running",
            authURL: "",
            exitNodes: []
        ))
        let app = AppState(
            engine: engine,
            tunnelManager: manager,
            tailscaleSetupRuntime: setupRuntime,
            persistence: makePersistence()
        )
        var profile = Profile.bootstrap()
        profile.lines.append(Line(
            id: "tail",
            name: "Tail",
            type: "tailscale",
            verified: true,
            tailscaleExitNode: "100.64.0.8",
            tailscaleAuthenticated: true
        ))
        app.profile = profile
        app.prepareTailscaleLogin(lineID: "tail") { _ in }

        var logoutSucceeded = false
        app.logoutTailscale(lineID: "tail") { result in
            if case .success = result {
                logoutSucceeded = true
            }
        }

        XCTAssertTrue(logoutSucceeded)
        XCTAssertEqual(setupRuntime.logoutLineIDs, ["tail"])
        let line = app.profile.lines.first(where: { $0.id == "tail" })
        XCTAssertEqual(line?.tailscaleAuthenticated, false)
        XCTAssertEqual(line?.tailscaleExitNode, "")
        XCTAssertEqual(line?.verified, false)
    }

    func testTailscaleLogoutFailureKeepsPersistedLineState() {
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)
        let setupRuntime = TailscaleSetupRuntimeSpy()
        setupRuntime.startResult = .success(TailscaleRuntimeStatus(
            backendState: "Running",
            authURL: "",
            exitNodes: []
        ))
        setupRuntime.logoutResult = .failure(NSError(
            domain: "TailscaleSetupRuntimeSpy",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "logout failed"]
        ))
        let app = AppState(
            engine: engine,
            tunnelManager: manager,
            tailscaleSetupRuntime: setupRuntime,
            persistence: makePersistence()
        )
        var profile = Profile.bootstrap()
        profile.lines.append(Line(
            id: "tail",
            name: "Tail",
            type: "tailscale",
            verified: true,
            tailscaleExitNode: "100.64.0.8",
            tailscaleAuthenticated: true
        ))
        app.profile = profile
        app.prepareTailscaleLogin(lineID: "tail") { _ in }

        var logoutFailed = false
        app.logoutTailscale(lineID: "tail") { result in
            if case .failure = result {
                logoutFailed = true
            }
        }

        XCTAssertTrue(logoutFailed)
        XCTAssertEqual(setupRuntime.logoutLineIDs, ["tail"])
        let line = app.profile.lines.first(where: { $0.id == "tail" })
        XCTAssertEqual(line?.tailscaleAuthenticated, true)
        XCTAssertEqual(line?.tailscaleExitNode, "100.64.0.8")
        XCTAssertEqual(line?.verified, true)
    }

    func testTailscaleDefaultRouteRequiresExitNodeBeforeConnection() {
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)
        let app = AppState(engine: engine, tunnelManager: manager, persistence: makePersistence())
        var profile = Profile.bootstrap()
        profile.lines.append(Line(
            id: "tail",
            name: "Home Tailnet",
            type: "tailscale",
            tailscaleAuthenticated: true
        ))
        profile.modes = [Mode(id: "tail-mode", name: "Tail", defaultLineID: "tail")]
        profile.activeModeID = "tail-mode"
        profile.ensureConnectivityTestConfiguration()
        app.profile = profile

        XCTAssertFalse(app.canConnect)
        XCTAssertTrue(app.activeConfigurationIssues.contains {
            $0.contains("出口节点") || $0.contains("exit node")
        })

        guard let tailIndex = app.profile.lines.firstIndex(where: { $0.id == "tail" }) else {
            return XCTFail("Tailscale line missing")
        }
        app.profile.lines[tailIndex].tailscaleExitNode = "100.64.0.8"
        app.profile.ensureConnectivityTestConfiguration()
        XCTAssertTrue(app.canConnect, app.activeConfigurationIssues.joined(separator: "\n"))
    }

    func testInterruptedTailscaleSetupMarkerIsClearedBeforeRestoringOnDemandPreference() async {
        let persistence = makePersistence()
        persistence.defaults.set(true, forKey: persistence.systemOnDemandKey)
        persistence.defaults.set("tail", forKey: persistence.tailscaleSetupLineKey)
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)

        let app = AppState(
            engine: engine,
            tunnelManager: manager,
            persistence: persistence
        )
        await Task.yield()

        XCTAssertEqual(manager.stopCallCount, 0)
        XCTAssertEqual(manager.systemOnDemandRequests, [true])
        XCTAssertTrue(app.systemOnDemandEnabled)
        XCTAssertNil(persistence.defaults.string(forKey: persistence.tailscaleSetupLineKey))
        XCTAssertTrue(
            app.engine.lastError?.contains("Tailscale") == true,
            app.engine.lastError ?? "missing recovery message"
        )
    }

    func testLineConfigurationIssuesNameEveryMissingField() {
        let app = AppState(persistence: makePersistence())
        let line = Line(id: "vpn", name: "Test Line", type: "vpn")

        let issues = app.routeLineConfigurationIssues(line)

        XCTAssertTrue(issues.contains { $0.contains("服务器") || $0.contains("server") })
        XCTAssertTrue(issues.contains { $0.contains("用户名") || $0.contains("username") })
        XCTAssertTrue(issues.contains { $0.contains("密码") || $0.contains("password") })
    }

    func testEveryConfigurableLineTypeReportsItsRequiredSetupBeforeConnection() {
        let app = AppState(persistence: makePersistence())
        let incompleteLines: [(Line, [String])] = [
            (
                Line(id: "vpn", name: "AnyConnect", type: "vpn"),
                ["server", "username", "password"]
            ),
            (
                Line(
                    id: "trojan",
                    name: "Trojan",
                    type: "trojan",
                    trojanPort: 0
                ),
                ["server", "port", "password"]
            ),
            (
                Line(
                    id: "ss",
                    name: "Shadowsocks",
                    type: "shadowsocks",
                    ssPort: 0,
                    ssMethod: ""
                ),
                ["server", "port", "method", "password"]
            ),
            (
                Line(
                    id: "vmess",
                    name: "VMess",
                    type: "vmess",
                    vmessPort: 0
                ),
                ["server", "port", "UUID"]
            ),
            (
                Line(id: "tailscale", name: "Tailscale", type: "tailscale"),
                ["sign-in"]
            ),
        ]

        for (line, expectedTokens) in incompleteLines {
            let issues = app.routeLineConfigurationIssues(line)
                .map { $0.lowercased() }
                .joined(separator: "\n")
            for token in expectedTokens {
                XCTAssertTrue(
                    issues.contains(token.lowercased()),
                    "\(line.type) should report missing \(token), got: \(issues)"
                )
            }
        }
        XCTAssertTrue(
            app.routeLineConfigurationIssues(
                Line(id: "direct", name: "Direct", type: "direct")
            ).isEmpty
        )
    }

    func testEveryIncompleteDefaultLineTypeBlocksManagerStart() async {
        let incompleteLines = [
            Line(id: "vpn", name: "AnyConnect", type: "vpn"),
            Line(id: "trojan", name: "Trojan", type: "trojan"),
            Line(id: "ss-incomplete", name: "Shadowsocks", type: "shadowsocks"),
            Line(id: "vmess", name: "VMess", type: "vmess"),
            Line(id: "tailscale", name: "Tailscale", type: "tailscale"),
        ]

        for line in incompleteLines {
            let engine = RuntimeSpyEngine()
            let manager = RuntimeSpyManager(engine: engine)
            let app = AppState(
                engine: engine,
                tunnelManager: manager,
                persistence: makePersistence()
            )
            var profile = Profile.bootstrap()
            profile.lines.append(line)
            profile.modes = [Mode(
                id: "mode-\(line.id)",
                name: "Mode \(line.name)",
                defaultLineID: line.id
            )]
            profile.activeModeID = profile.modes[0].id
            profile.ensureConnectivityTestConfiguration()
            app.profile = profile

            XCTAssertFalse(app.canConnect, "\(line.type) must require setup")
            XCTAssertTrue(
                app.activeConfigurationIssues.contains { $0.contains(line.name) },
                "\(line.type) issue must name the line"
            )
            app.connect()
            await Task.yield()
            XCTAssertEqual(
                manager.startCallCount,
                0,
                "\(line.type) must not reach the tunnel manager before setup"
            )
        }
    }

    func testReferencedTailscaleLineRequiresCompletedSetupLogin() {
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)
        let app = AppState(engine: engine, tunnelManager: manager, persistence: makePersistence())
        var profile = Profile.bootstrap()
        profile.lines.append(Line(id: "tail", name: "Tailnet", type: "tailscale"))
        profile.ruleSets.append(RuleSet(
            id: "tailnet",
            name: "Tailnet",
            type: "manual",
            domains: ["internal.example"]
        ))
        profile.modes = [Mode(
            id: "mode",
            name: "Mode",
            bindings: [RuleBinding(ruleSetID: "tailnet", lineID: "tail")],
            defaultLineID: "direct"
        )]
        profile.activeModeID = "mode"
        profile.ensureConnectivityTestConfiguration()
        app.profile = profile

        XCTAssertFalse(app.canConnect)
        XCTAssertTrue(app.activeConfigurationIssues.contains {
            $0.contains("登录") || $0.contains("sign-in")
        })
        XCTAssertTrue(app.updateTailscaleAuthentication(lineID: "tail", authenticated: true))
        XCTAssertTrue(app.canConnect, app.activeConfigurationIssues.joined(separator: "\n"))
    }

    func testUnreferencedEnabledTailscaleRequiresLoginBecauseItIsGloballyGenerated() {
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)
        let app = AppState(
            engine: engine,
            tunnelManager: manager,
            persistence: makePersistence()
        )
        var profile = configuredProfile()
        profile.lines.append(Line(
            id: "global-tail",
            name: "Global Tailnet",
            type: "tailscale"
        ))
        profile.ensureConnectivityTestConfiguration()
        app.profile = profile

        XCTAssertFalse(app.canConnect)
        XCTAssertTrue(app.activeConfigurationIssues.contains {
            $0.contains("Global Tailnet")
                && ($0.contains("登录") || $0.contains("sign-in"))
        })

        guard let index = app.profile.lines.firstIndex(where: {
            $0.id == "global-tail"
        }) else {
            return XCTFail("Tailscale line missing")
        }
        app.profile.lines[index].enabled = false
        app.profile.ensureConnectivityTestConfiguration()
        XCTAssertTrue(app.canConnect, app.activeConfigurationIssues.joined(separator: "\n"))
    }

    func testIncompleteLineUsedByEnabledRuleBlocksConnectionBeforeManagerStart() async {
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)
        let app = AppState(engine: engine, tunnelManager: manager, persistence: makePersistence())
        var profile = configuredProfile()
        profile.lines.append(Line(
            id: "incomplete-proxy",
            name: "Incomplete Proxy",
            type: "shadowsocks"
        ))
        profile.ruleSets.append(RuleSet(
            id: "incomplete-rule",
            name: "Incomplete Rule",
            type: "manual",
            domains: ["example.invalid"]
        ))
        profile.modes[0].bindings.append(RuleBinding(
            ruleSetID: "incomplete-rule",
            lineID: "incomplete-proxy"
        ))
        profile.ensureConnectivityTestConfiguration()
        app.profile = profile

        XCTAssertFalse(app.canConnect)
        XCTAssertTrue(app.activeConfigurationIssues.contains {
            $0.contains("Incomplete Proxy") && ($0.contains("服务器") || $0.contains("server"))
        })
        app.connect()
        await Task.yield()
        XCTAssertEqual(manager.startCallCount, 0)
    }

    func testSelectedIncompleteSubscriptionNodeBlocksInsteadOfSilentlyFallingBack() async {
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)
        let app = AppState(
            engine: engine,
            tunnelManager: manager,
            persistence: makePersistence()
        )
        var profile = Profile.bootstrap()
        profile.subscriptions = [Subscription(
            id: "subscription",
            name: "Subscription",
            url: "https://example.com/subscription",
            strategy: "selector",
            lines: [
                Line(
                    id: "broken",
                    name: "Broken Node",
                    type: "shadowsocks"
                ),
                Line(
                    id: "working",
                    name: "Working Node",
                    type: "trojan",
                    trojanServer: "working.example.com",
                    trojanPassword: "secret"
                ),
            ],
            selected: "Broken Node"
        )]
        profile.modes = [Mode(
            id: "subscription-mode",
            name: "Subscription",
            defaultSubscriptionID: "subscription"
        )]
        profile.activeModeID = "subscription-mode"
        profile.ensureConnectivityTestConfiguration()
        app.profile = profile

        XCTAssertFalse(app.canConnect)
        XCTAssertTrue(app.activeConfigurationIssues.contains {
            $0.contains("Broken Node")
                && ($0.contains("服务器") || $0.contains("server"))
                && ($0.contains("密码") || $0.contains("password"))
        })
        app.connect()
        await Task.yield()
        XCTAssertEqual(manager.startCallCount, 0)
    }

    func testSelectedIncompleteSubscriptionGroupMemberBlocksSilentFallback() async {
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)
        let app = AppState(
            engine: engine,
            tunnelManager: manager,
            persistence: makePersistence()
        )
        var profile = Profile.bootstrap()
        profile.subscriptions = [Subscription(
            id: "subscription",
            name: "Subscription",
            url: "https://example.com/subscription",
            strategy: "selector",
            lines: [
                Line(
                    id: "broken",
                    name: "Broken Node",
                    type: "vmess"
                ),
                Line(
                    id: "working",
                    name: "Working Node",
                    type: "trojan",
                    trojanServer: "working.example.com",
                    trojanPassword: "secret"
                ),
            ],
            proxyGroups: [SubProxyGroup(
                name: "Primary",
                type: "select",
                proxies: ["Broken Node", "Working Node"],
                selected: "Broken Node"
            )]
        )]
        profile.modes = [Mode(
            id: "subscription-mode",
            name: "Subscription",
            defaultSubscriptionID: "subscription"
        )]
        profile.activeModeID = "subscription-mode"
        profile.ensureConnectivityTestConfiguration()
        app.profile = profile

        XCTAssertFalse(app.canConnect)
        XCTAssertTrue(app.activeConfigurationIssues.contains {
            $0.contains("Primary")
                && $0.contains("Broken Node")
                && ($0.contains("UUID") || $0.contains("uuid"))
        })
        app.connect()
        await Task.yield()
        XCTAssertEqual(manager.startCallCount, 0)
    }

    func testDisabledRuleIsIgnoredButEnabledRuleCannotUseDisabledLine() {
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)
        let app = AppState(
            engine: engine,
            tunnelManager: manager,
            persistence: makePersistence()
        )
        var profile = configuredProfile()
        profile.lines.append(Line(
            id: "disabled-line",
            name: "Disabled Line",
            type: "trojan",
            enabled: false,
            trojanServer: "disabled.example.com",
            trojanPassword: "secret"
        ))
        profile.ruleSets.append(RuleSet(
            id: "optional-rule",
            name: "Optional Rule",
            type: "manual",
            enabled: false,
            domains: ["optional.example"]
        ))
        profile.modes[0].bindings.append(RuleBinding(
            ruleSetID: "optional-rule",
            lineID: "disabled-line"
        ))
        profile.ensureConnectivityTestConfiguration()
        app.profile = profile

        XCTAssertTrue(app.canConnect, app.activeConfigurationIssues.joined(separator: "\n"))

        guard let ruleIndex = app.profile.ruleSets.firstIndex(where: {
            $0.id == "optional-rule"
        }) else {
            return XCTFail("rule missing")
        }
        app.profile.ruleSets[ruleIndex].enabled = true
        app.profile.ensureConnectivityTestConfiguration()
        XCTAssertFalse(app.canConnect)
        XCTAssertTrue(app.activeConfigurationIssues.contains {
            $0.contains("Disabled Line")
                && ($0.contains("停用") || $0.contains("disabled"))
        })
    }

    func testOverlayOnlyTailscaleNeedsNoExitUntilUsedAsDefault() {
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)
        let app = AppState(
            engine: engine,
            tunnelManager: manager,
            persistence: makePersistence()
        )
        var profile = Profile.bootstrap()
        profile.lines.append(Line(
            id: "tail-overlay",
            name: "Tailnet",
            type: "tailscale",
            tailscaleExitNode: " \n ",
            tailscaleAuthenticated: true
        ))
        profile.ruleSets.append(RuleSet(
            id: "tailnet-only",
            name: "Tailnet Only",
            type: "manual",
            domains: ["internal.example"]
        ))
        profile.modes = [Mode(
            id: "overlay",
            name: "Overlay",
            bindings: [RuleBinding(ruleSetID: "tailnet-only", lineID: "tail-overlay")],
            defaultLineID: "direct"
        )]
        profile.activeModeID = "overlay"
        profile.ensureConnectivityTestConfiguration()
        app.profile = profile

        XCTAssertTrue(app.canConnect, app.activeConfigurationIssues.joined(separator: "\n"))
        XCTAssertNil(app.profile.connectivityOutboundBinding(for: app.profile.modes[0]))

        app.profile.modes[0].defaultLineID = "tail-overlay"
        app.profile.ensureConnectivityTestConfiguration()
        XCTAssertFalse(app.canConnect)
        XCTAssertTrue(app.activeConfigurationIssues.contains {
            $0.contains("出口节点") || $0.contains("exit node")
        })
    }

    func testMissingDirectAcceptanceBindingFailsBeforeConnectionStart() {
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)
        let app = AppState(engine: engine, tunnelManager: manager, persistence: makePersistence())
        var profile = configuredProfile()
        profile.lines.removeAll { $0.type == "direct" }
        profile.ensureConnectivityTestConfiguration()
        app.profile = profile

        XCTAssertFalse(app.canConnect)
        XCTAssertTrue(app.activeConfigurationIssues.contains {
            $0.contains("连接验收") || $0.contains("acceptance")
        })
    }

    func testConnectedEditsBecomePendingButVerificationMetadataDoesNot() async {
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)
        let app = AppState(engine: engine, tunnelManager: manager, persistence: makePersistence())
        app.profile = configuredProfile()

        app.connect()
        await Task.yield()
        XCTAssertTrue(app.isConnected)
        XCTAssertFalse(app.hasPendingRuntimeChanges)

        guard app.profile.lines.indices.contains(1), !app.profile.modes.isEmpty else {
            XCTFail("configured profile disappeared while testing connected edits")
            return
        }
        app.profile.lines[1].verified.toggle()
        XCTAssertTrue(app.save())
        XCTAssertFalse(app.hasPendingRuntimeChanges)

        app.profile.modes[0].name = "Changed"
        XCTAssertTrue(app.save())
        XCTAssertTrue(app.hasPendingRuntimeChanges)
    }

    func testLiveSubscriptionSelectionClearsPendingReconnectFlag() async {
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)
        let app = AppState(engine: engine, tunnelManager: manager, persistence: makePersistence())
        var profile = configuredProfile()
        profile.subscriptions = [Subscription(
            id: "sub-one",
            name: "Subscription",
            url: "https://example.com/sub",
            strategy: "selector",
            lines: [Line(
                id: "node-one",
                name: "Node One",
                type: "shadowsocks",
                ssServer: "node.example.com",
                ssPassword: "node-secret"
            )],
            proxyGroups: [SubProxyGroup(
                name: "Proxy",
                type: "select",
                proxies: ["Node One"]
            )]
        )]
        app.profile = profile
        app.connect()
        await Task.yield()

        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            app.selectSubscriptionMember(
                subscriptionID: "sub-one",
                groupName: "Proxy",
                selected: "Node One"
            ) { continuation.resume(returning: $0) }
        }

        if case .failure(let error) = result {
            XCTFail("selection failed: \(error)")
        }
        XCTAssertEqual(engine.selections.count, 1)
        XCTAssertEqual(engine.selections.first?.0, "sub-one")
        XCTAssertEqual(engine.selections.first?.1, "Proxy")
        XCTAssertEqual(engine.selections.first?.2, "Node One")
        XCTAssertFalse(app.hasPendingRuntimeChanges)
    }

    func testUnexpectedDisconnectRetriesButManualDisconnectDoesNot() async {
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)
        let app = AppState(engine: engine, tunnelManager: manager, persistence: makePersistence())
        app.profile = configuredProfile()
        app.autoReconnectEnabled = true
        app.connect()
        await Task.yield()
        XCTAssertEqual(manager.startCallCount, 1)

        engine.setStatus("disconnected")
        XCTAssertTrue(app.canConnect, app.activeConfigurationIssues.joined(separator: "\n"))
        try? await Task.sleep(for: .milliseconds(1_200))
        XCTAssertEqual(manager.startCallCount, 2)
        XCTAssertTrue(app.isConnected)

        app.disconnect()
        try? await Task.sleep(for: .milliseconds(1_200))
        XCTAssertEqual(manager.stopCallCount, 1)
        XCTAssertEqual(manager.startCallCount, 2)
    }

    func testAcceptanceFailureSuppressesAutomaticReconnect() async {
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)
        let app = AppState(engine: engine, tunnelManager: manager, persistence: makePersistence())
        app.profile = configuredProfile()
        app.autoReconnectEnabled = true
        app.connect()
        await Task.yield()
        XCTAssertEqual(manager.startCallCount, 1)

        engine.suppressNextAutomaticReconnect()
        engine.setStatus("disconnected")
        try? await Task.sleep(for: .milliseconds(1_200))

        XCTAssertEqual(manager.startCallCount, 1)
        XCTAssertFalse(app.isConnected)
    }

    func testForegroundRetryDoesNotCompeteWithActiveSystemOnDemand() async {
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)
        let app = AppState(engine: engine, tunnelManager: manager, persistence: makePersistence())
        app.profile = configuredProfile()
        app.autoReconnectEnabled = true
        app.connect()
        await Task.yield()
        XCTAssertEqual(manager.startCallCount, 1)

        manager.simulateSystemOnDemandActive()
        engine.setStatus("disconnected")
        try? await Task.sleep(for: .milliseconds(1_200))

        XCTAssertEqual(manager.startCallCount, 1)
    }

    func testOnDemandStatusReportsPendingActiveAndFailure() async {
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)
        let app = AppState(engine: engine, tunnelManager: manager, persistence: makePersistence())

        app.systemOnDemandEnabled = true
        XCTAssertEqual(app.systemOnDemandState, .pending)
        manager.simulateSystemOnDemandActive()
        await Task.yield()
        XCTAssertEqual(app.systemOnDemandState, .active)
        manager.simulateSystemOnDemandFailure()
        await Task.yield()
        XCTAssertEqual(app.systemOnDemandState, .failed("simulated failure"))
    }

    func testAppStateStronglyRetainsTunnelManager() {
        let engine = RuntimeSpyEngine()
        var manager: RuntimeSpyManager? = RuntimeSpyManager(engine: engine)
        weak var weakManager = manager
        let app = AppState(
            engine: engine,
            tunnelManager: manager,
            persistence: makePersistence()
        )

        manager = nil

        XCTAssertNotNil(weakManager)
        app.profile = configuredProfile()
        app.connect()
        XCTAssertEqual(weakManager?.startCallCount, 1)
        withExtendedLifetime(app) {}
    }

    func testAutoReconnectPreferenceAndProfileRemoval() async {
        let persistence = makePersistence()
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)
        let app = AppState(engine: engine, tunnelManager: manager, persistence: persistence)
        app.autoReconnectEnabled = false
        app.systemOnDemandEnabled = true
        let reloaded = AppState(engine: RuntimeSpyEngine(), persistence: persistence)
        XCTAssertFalse(reloaded.autoReconnectEnabled)
        XCTAssertTrue(reloaded.systemOnDemandEnabled)

        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            app.removeTunnelProfile { continuation.resume(returning: $0) }
        }
        if case .failure(let error) = result {
            XCTFail("profile removal failed: \(error)")
        }
        XCTAssertEqual(manager.removeCallCount, 1)
        XCTAssertFalse(app.helperInstalled)
    }

    #if targetEnvironment(simulator)
    func testConnectingDoesNotLookLikeIncompleteConfiguration() {
        let engine = FakeTunnelEngine()
        let manager = FakeTunnelManager(engine: engine)
        engine.retain(manager: manager)
        let app = AppState(engine: engine, tunnelManager: manager, persistence: makePersistence())

        var profile = Profile.bootstrap()
        profile.lines[1].vpnServer = "gateway.example.com"
        profile.lines[1].vpnUsername = "tester"
        profile.lines[1].vpnPassword = "secret"
        profile.modes = [
            Mode(
                id: "test-mode",
                name: "Test",
                bindings: [RuleBinding(ruleSetID: "internal", lineID: "vpn")],
                defaultLineID: "direct"
            ),
        ]
        profile.activeModeID = "test-mode"
        profile.ensureConnectivityTestConfiguration()
        app.profile = profile

        XCTAssertTrue(app.isConnectionConfigured)
        XCTAssertTrue(app.canConnect)

        engine.simulateConnect()

        XCTAssertTrue(app.isBusy)
        XCTAssertFalse(app.canConnect)
        XCTAssertTrue(app.isConnectionConfigured)
    }

    func testMissingCredentialsRemainIncomplete() {
        let engine = FakeTunnelEngine()
        let manager = FakeTunnelManager(engine: engine)
        engine.retain(manager: manager)
        let app = AppState(engine: engine, tunnelManager: manager, persistence: makePersistence())

        var profile = Profile.bootstrap()
        profile.modes = [
            Mode(
                id: "test-mode",
                name: "Test",
                bindings: [RuleBinding(ruleSetID: "internal", lineID: "vpn")],
                defaultLineID: "direct"
            ),
        ]
        profile.activeModeID = "test-mode"
        app.profile = profile

        XCTAssertFalse(app.isConnectionConfigured)
        XCTAssertFalse(app.canConnect)
    }
    #endif

    func testStatusTextUsesProductConnectionWordingForSystemErrors() {
        let engine = NoopTunnelEngine()
        let app = AppState(engine: engine, persistence: makePersistence())
        engine.lastError = "NEVPNErrorDomain: VPN configuration failed"

        XCTAssertFalse(app.statusText.lowercased().contains("vpn"))
        XCTAssertTrue(app.statusText.contains("AnyConnect"))
    }

    func testCancelledConnectDoesNotOverwriteVisibleError() {
        let engine = NoopTunnelEngine()
        let manager = CancellingTunnelManager()
        let app = AppState(engine: engine, tunnelManager: manager, persistence: makePersistence())
        var profile = Profile.bootstrap()
        profile.lines[1].vpnServer = "gateway.example.com"
        profile.lines[1].vpnUsername = "tester"
        profile.lines[1].vpnPassword = "secret"
        profile.modes = [Mode(id: "test-mode", name: "Test", defaultLineID: "vpn")]
        profile.activeModeID = "test-mode"
        app.profile = profile
        engine.lastError = "keep this message"

        app.connect()

        XCTAssertEqual(engine.lastError, "keep this message")
    }

    func testDisconnectWithManagerUsesOnlySystemStop() {
        let engine = DisconnectSpyEngine()
        let manager = CancellingTunnelManager()
        let app = AppState(engine: engine, tunnelManager: manager, persistence: makePersistence())

        app.disconnect()

        XCTAssertEqual(manager.stopCallCount, 1)
        XCTAssertEqual(engine.stopCallCount, 0)
        XCTAssertNil(engine.lastError)
    }

    func testDisconnectWithoutManagerFallsBackToEngineStop() {
        let engine = DisconnectSpyEngine()
        let app = AppState(engine: engine, persistence: makePersistence())

        app.disconnect()

        XCTAssertEqual(engine.stopCallCount, 1)
        XCTAssertEqual(engine.lastError, "extension did not respond")
    }

    func testTunnelStartOperationStateReplacesAndCancelsExactlyOnce() throws {
        var state = TunnelStartOperationState()
        let first = StartCompletionRecorder()
        let second = StartCompletionRecorder()

        let firstRegistration = state.begin { first.record($0) }
        XCTAssertNil(firstRegistration.cancelled)
        let secondRegistration = state.begin { second.record($0) }
        secondRegistration.cancelled?(.failure(CancellationError()))

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.cancellationCount, 1)
        XCTAssertNil(state.finish(firstRegistration.id))
        let secondCompletion = try XCTUnwrap(state.finish(secondRegistration.id))
        secondCompletion(.success(()))
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.successCount, 1)
        XCTAssertNil(state.finish(secondRegistration.id))
        XCTAssertNil(state.cancel())
    }

    func testTunnelStartOperationStateCancelsPreparationExactlyOnce() throws {
        var state = TunnelStartOperationState()
        let recorder = StartCompletionRecorder()
        let registration = state.begin { recorder.record($0) }

        let cancelled = try XCTUnwrap(state.cancel())
        cancelled(.failure(CancellationError()))

        XCTAssertEqual(recorder.count, 1)
        XCTAssertEqual(recorder.cancellationCount, 1)
        XCTAssertFalse(state.isCurrent(registration.id))
        XCTAssertNil(state.finish(registration.id))
        XCTAssertEqual(recorder.count, 1)
    }

    func testConfigGenerationQueueIsFIFOAndNeverRunsConcurrentWork() {
        let queue = TunnelConfigGenerationQueue(label: "test.config-generation." + UUID().uuidString)
        let probe = GenerationQueueProbe()

        for index in 0..<8 {
            probe.prepare()
            queue.submit {
                probe.execute(index: index)
            }
        }

        XCTAssertEqual(probe.wait(), .success)
        let snapshot = probe.snapshot
        XCTAssertEqual(snapshot.maxInFlight, 1)
        XCTAssertEqual(snapshot.completionOrder, Array(0..<8))
    }

    func testCancelledQueuedGenerationResultDoesNotAdvanceReplacement() {
        var state = TunnelStartOperationState()
        let oldCompletion = StartCompletionRecorder()
        let replacementCompletion = StartCompletionRecorder()
        let queue = TunnelConfigGenerationQueue(label: "test.config-generation.cancel." + UUID().uuidString)
        let probe = GenerationQueueProbe()

        let old = state.begin { oldCompletion.record($0) }
        probe.prepare()
        queue.submit {
            probe.execute(index: 0, waitForRelease: true)
        }
        XCTAssertEqual(probe.waitUntilBlockedWorkStarts(), .success)

        let replacement = state.begin { replacementCompletion.record($0) }
        replacement.cancelled?(.failure(CancellationError()))
        probe.prepare()
        queue.submit {
            probe.execute(index: 1)
        }

        probe.releaseBlockedWork()
        XCTAssertEqual(probe.wait(), .success)
        let operations = [old.id, replacement.id]
        let advancingResults = probe.snapshot.completionOrder.compactMap { index in
            state.isCurrent(operations[index]) ? operations[index] : nil
        }
        XCTAssertEqual(advancingResults, [replacement.id])
        XCTAssertEqual(oldCompletion.cancellationCount, 1)
        XCTAssertNil(state.finish(old.id))
        state.finish(replacement.id)?(.success(()))
        XCTAssertEqual(replacementCompletion.successCount, 1)
    }

    #if targetEnvironment(simulator)
    func testActiveModeRejectsMultipleAnyConnectLines() {
        let engine = FakeTunnelEngine()
        let manager = FakeTunnelManager(engine: engine)
        engine.retain(manager: manager)
        let app = AppState(engine: engine, tunnelManager: manager, persistence: makePersistence())

        var profile = Profile.bootstrap()
        profile.lines[1].vpnServer = "a.example.com"
        profile.lines[1].vpnUsername = "tester-a"
        profile.lines[1].vpnPassword = "secret-a"
        profile.lines.append(Line(
            id: "vpn-b",
            name: "AnyConnect B",
            type: "vpn",
            vpnServer: "b.example.com",
            vpnUsername: "tester-b",
            vpnPassword: "secret-b"
        ))
        profile.modes = [
            Mode(
                id: "test-mode",
                name: "Test",
                bindings: [RuleBinding(ruleSetID: "internal", lineID: "vpn-b")],
                defaultLineID: "vpn"
            ),
        ]
        profile.activeModeID = "test-mode"
        app.profile = profile

        XCTAssertEqual(app.activeAnyConnectLineIDs, Set(["vpn", "vpn-b"]))
        XCTAssertFalse(app.canConnect)
        XCTAssertTrue(app.activeConfigurationIssues.contains { $0.contains("只能使用一条") || $0.contains("only one") })

        app.profile.modes[0].bindings[0].lineID = "vpn"
        app.profile.ensureConnectivityTestConfiguration()
        XCTAssertEqual(app.activeAnyConnectLineIDs, Set(["vpn"]))
        XCTAssertTrue(app.canConnect)

        guard let internalBindingIndex = app.profile.modes[0].bindings.firstIndex(where: {
            $0.ruleSetID == "internal"
        }) else {
            return XCTFail("internal binding missing")
        }
        app.profile.modes[0].bindings[internalBindingIndex].lineID = "vpn-b"
        if let index = app.profile.ruleSets.firstIndex(where: { $0.id == "internal" }) {
            app.profile.ruleSets[index].enabled = false
        }
        XCTAssertEqual(app.activeAnyConnectLineIDs, Set(["vpn"]))
        XCTAssertTrue(app.canConnect)
    }
    #endif

    func testTailscaleOnlyAndMixedModesCanConnect() {
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)
        let app = AppState(engine: engine, tunnelManager: manager, persistence: makePersistence())

        var profile = Profile.bootstrap()
        profile.lines.append(Line(
            id: "tailscale-home",
            name: "Tailscale Home",
            type: "tailscale",
            enabled: true,
            tailscaleHostname: "xdial-mobile",
            tailscaleExitNode: "100.64.0.8",
            tailscaleAuthenticated: true
        ))
        profile.ruleSets = [RuleSet(
            id: "internal",
            name: "Internal",
            type: "manual",
            domains: ["internal.example"]
        )]
        profile.modes = [Mode(
            id: "tailscale-mode",
            name: "Tailscale",
            defaultLineID: "tailscale-home"
        )]
        profile.activeModeID = "tailscale-mode"
        profile.ensureConnectivityTestConfiguration()
        app.profile = profile

        XCTAssertEqual(app.activeTailscaleLineIDs, Set(["tailscale-home"]))
        XCTAssertTrue(app.canConnect, app.activeConfigurationIssues.joined(separator: "\n"))

        guard let anyConnectIndex = app.profile.lines.firstIndex(where: { $0.id == "vpn" }) else {
            return XCTFail("bootstrap AnyConnect line missing")
        }
        app.profile.lines[anyConnectIndex].vpnServer = "gateway.example.com"
        app.profile.lines[anyConnectIndex].vpnUsername = "tester"
        app.profile.lines[anyConnectIndex].vpnPassword = "secret"
        app.profile.modes[0].bindings = [RuleBinding(ruleSetID: "internal", lineID: "vpn")]
        app.profile.ensureConnectivityTestConfiguration()

        XCTAssertEqual(app.activeAnyConnectLineIDs, Set(["vpn"]))
        XCTAssertTrue(app.canConnect)
    }

    func testConnectedTailscaleStatusUsesGeneratedEndpointTag() async {
        let engine = RuntimeSpyEngine()
        engine.tailscaleResult = .success(TailscaleRuntimeStatus(
            backendState: "NeedsLogin",
            authURL: "https://login.tailscale.com/a/test",
            exitNodes: [TailscaleRuntimeExitNode(
                id: "exit-a",
                name: "Home",
                ip: "100.64.0.8",
                online: true,
                os: "macOS"
            )]
        ))
        let manager = RuntimeSpyManager(engine: engine)
        let app = AppState(engine: engine, tunnelManager: manager, persistence: makePersistence())
        var profile = configuredProfile()
        profile.lines.append(Line(
            id: "tailscale-home",
            name: "Tailscale Home",
            type: "tailscale",
            enabled: true,
            tailscaleExitNode: "100.64.0.8",
            tailscaleAuthenticated: true
        ))
        profile.modes = [Mode(
            id: "tailscale-mode",
            name: "Tailscale",
            defaultLineID: "tailscale-home"
        )]
        profile.activeModeID = "tailscale-mode"
        profile.ensureConnectivityTestConfiguration()
        app.profile = profile
        app.connect()
        await Task.yield()

        let result: Result<TailscaleRuntimeStatus, Error> = await withCheckedContinuation { continuation in
            app.refreshTailscaleStatus(lineID: "tailscale-home") {
                continuation.resume(returning: $0)
            }
        }

        guard case .success(let status) = result else {
            return XCTFail("Tailscale status request failed")
        }
        XCTAssertEqual(engine.tailscaleEndpointTags, ["tailscale-tailscale-home"])
        XCTAssertEqual(status.backendState, "NeedsLogin")
        XCTAssertEqual(status.exitNodes.first?.ip, "100.64.0.8")
    }

    func testTailscaleActionRequiredKeepsRuntimeQueryableLocksConfigurationAndCanDisconnect() async {
        let engine = RuntimeSpyEngine()
        engine.tailscaleResult = .success(TailscaleRuntimeStatus(
            backendState: "NeedsLogin",
            authURL: "https://login.tailscale.com/a/test",
            exitNodes: []
        ))
        let manager = RuntimeSpyManager(engine: engine)
        let app = AppState(engine: engine, tunnelManager: manager, persistence: makePersistence())
        var profile = Profile.bootstrap()
        profile.lines.append(Line(
            id: "tail",
            name: "Tail",
            type: "tailscale",
            tailscaleExitNode: "100.64.0.8",
            tailscaleAuthenticated: true
        ))
        profile.modes = [Mode(id: "tail-mode", name: "Tail", defaultLineID: "tail")]
        profile.activeModeID = "tail-mode"
        profile.ensureConnectivityTestConfiguration()
        app.profile = profile

        app.connect()
        await Task.yield()
        XCTAssertEqual(manager.startCallCount, 1)
        engine.setStatus("action-required")
        await Task.yield()

        XCTAssertTrue(app.requiresUserAction)
        XCTAssertTrue(app.hasActiveTunnel)
        XCTAssertFalse(app.isConnected)
        XCTAssertFalse(app.canConnect)
        XCTAssertFalse(app.canMutateConfiguration)
        XCTAssertTrue(app.statusText.contains("Tailscale"))
        XCTAssertTrue(app.statusText.contains("登录") || app.statusText.contains("Sign-in"))

        let originalModeCount = app.profile.modes.count
        app.createMode(from: .blank, named: "Must Not Be Added")
        XCTAssertEqual(app.profile.modes.count, originalModeCount)

        let result: Result<TailscaleRuntimeStatus, Error> = await withCheckedContinuation {
            continuation in
            app.refreshTailscaleStatus(lineID: "tail") {
                continuation.resume(returning: $0)
            }
        }
        guard case .success(let status) = result else {
            return XCTFail("active Tailscale endpoint must remain queryable while sign-in is required")
        }
        XCTAssertEqual(status.backendState, "NeedsLogin")

        app.disconnect()
        XCTAssertEqual(manager.stopCallCount, 1)
        XCTAssertFalse(app.hasActiveTunnel)
    }

    func testTailscaleActionRequiredPublishesRuntimeAuthRequestAndClearsAfterLogin() async {
        let engine = RuntimeSpyEngine()
        engine.tailscaleResult = .success(TailscaleRuntimeStatus(
            backendState: "NeedsLogin",
            authURL: "https://login.tailscale.com/a/runtime-token",
            exitNodes: []
        ))
        let manager = RuntimeSpyManager(engine: engine)
        let app = AppState(engine: engine, tunnelManager: manager, persistence: makePersistence())
        var profile = Profile.bootstrap()
        profile.lines.append(Line(
            id: "tail",
            name: "Home Tailnet",
            type: "tailscale",
            tailscaleExitNode: "100.64.0.8",
            tailscaleAuthenticated: true
        ))
        profile.lines.append(Line(
            id: "tail-running",
            name: "Running Tailnet",
            type: "tailscale",
            tailscaleAuthenticated: true
        ))
        profile.modes = [Mode(id: "tail-mode", name: "Tail", defaultLineID: "tail")]
        profile.activeModeID = "tail-mode"
        profile.ensureConnectivityTestConfiguration()
        app.profile = profile
        engine.tailscaleResultsByEndpointTag = [
            "tailscale-tail": .success(TailscaleRuntimeStatus(
                backendState: "NeedsLogin",
                authURL: "https://login.tailscale.com/a/runtime-token",
                exitNodes: []
            )),
            "tailscale-tail-running": .success(TailscaleRuntimeStatus(
                backendState: "Running",
                authURL: "",
                exitNodes: []
            )),
        ]

        app.connect()
        await Task.yield()
        XCTAssertEqual(manager.startCallCount, 1)
        engine.setStatus("action-required")

        for _ in 0..<20 where app.tailscaleAuthRequests.count != 1
            || app.tailscaleAuthRequests.first?.lineID != "tail" {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(app.tailscaleAuthRequests, [
            TailscaleAuthRequest(
                lineID: "tail",
                lineName: "Home Tailnet"
            ),
        ])
        XCTAssertEqual(
            Set(engine.tailscaleEndpointTags),
            Set(["tailscale-tail", "tailscale-tail-running"])
        )

        XCTAssertTrue(app.applyTailscaleRuntimeStatus(
            lineID: "tail",
            status: TailscaleRuntimeStatus(
                backendState: "NeedsLogin",
                authURL: "https://login.tailscale.com/a/runtime-token",
                exitNodes: []
            )
        ))
        XCTAssertFalse(
            app.profile.lines.first(where: { $0.id == "tail" })?.tailscaleAuthenticated ?? true
        )
        engine.setStatus("connected")
        await Task.yield()
        XCTAssertTrue(app.tailscaleAuthRequests.isEmpty)
        XCTAssertTrue(
            app.profile.lines.first(where: { $0.id == "tail" })?.tailscaleAuthenticated == true
        )
        XCTAssertFalse(app.hasPendingRuntimeChanges)

        app.disconnect()
        XCTAssertEqual(engine.status, "disconnected")
        app.connect()
        XCTAssertEqual(manager.startCallCount, 2)
    }

    func testTailscaleAuthRequestQueriesOnlyEnabledGeneratedLines() async {
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)
        let app = AppState(engine: engine, tunnelManager: manager, persistence: makePersistence())
        var profile = Profile.bootstrap()
        profile.lines.append(Line(
            id: "tail",
            name: "Tail",
            type: "tailscale",
            tailscaleExitNode: "100.64.0.8",
            tailscaleAuthenticated: true
        ))
        profile.lines.append(Line(
            id: "tail-disabled",
            name: "Disabled Tail",
            type: "tailscale",
            enabled: false
        ))
        profile.modes = [Mode(id: "tail-mode", name: "Tail", defaultLineID: "tail")]
        profile.activeModeID = "tail-mode"
        profile.ensureConnectivityTestConfiguration()
        app.profile = profile

        app.connect()
        await Task.yield()
        XCTAssertEqual(manager.startCallCount, 1)
        engine.tailscaleResult = .success(TailscaleRuntimeStatus(
            backendState: "NeedsLogin",
            authURL: "",
            exitNodes: []
        ))
        engine.setStatus("action-required")
        for _ in 0..<20 where app.tailscaleAuthRequests.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(app.tailscaleAuthRequests, [
            TailscaleAuthRequest(lineID: "tail", lineName: "Tail"),
        ])
        XCTAssertEqual(engine.tailscaleEndpointTags, ["tailscale-tail"])
    }

    func testBeginTailscaleLoginUsesGeneratedRuntimeEndpoint() async {
        let engine = RuntimeSpyEngine()
        engine.tailscaleResult = .success(TailscaleRuntimeStatus(
            backendState: "NeedsLogin",
            authURL: "https://login.tailscale.com/a/fresh-token",
            exitNodes: []
        ))
        let manager = RuntimeSpyManager(engine: engine)
        let app = AppState(engine: engine, tunnelManager: manager, persistence: makePersistence())
        var profile = Profile.bootstrap()
        profile.lines.append(Line(
            id: "tail",
            name: "Tail",
            type: "tailscale",
            tailscaleExitNode: "100.64.0.8",
            tailscaleAuthenticated: true
        ))
        profile.modes = [Mode(id: "tail-mode", name: "Tail", defaultLineID: "tail")]
        profile.activeModeID = "tail-mode"
        profile.ensureConnectivityTestConfiguration()
        app.profile = profile

        app.connect()
        await Task.yield()
        XCTAssertEqual(manager.startCallCount, 1)
        engine.setStatus("action-required")
        try? await Task.sleep(for: .milliseconds(10))

        let result: Result<TailscaleRuntimeStatus, Error> = await withCheckedContinuation {
            continuation in
            app.beginTailscaleLogin(lineID: "tail") {
                continuation.resume(returning: $0)
            }
        }
        guard case .success(let status) = result else {
            return XCTFail("explicit Tailscale sign-in did not return runtime state")
        }
        XCTAssertEqual(status.authURL, "https://login.tailscale.com/a/fresh-token")
        XCTAssertEqual(engine.tailscaleLoginEndpointTags, ["tailscale-tail"])
    }

    func testRestoredTailscaleActionRequiredRebuildsRuntimeSnapshotBeforeLogin() async {
        let engine = RuntimeSpyEngine()
        engine.tailscaleResult = .success(TailscaleRuntimeStatus(
            backendState: "NeedsLogin",
            authURL: "https://login.tailscale.com/a/restored-token",
            exitNodes: []
        ))
        let manager = RuntimeSpyManager(engine: engine)
        let app = AppState(engine: engine, tunnelManager: manager, persistence: makePersistence())
        var profile = Profile.bootstrap()
        profile.lines.append(Line(id: "tail", name: "Tail", type: "tailscale"))
        profile.modes = [Mode(id: "tail-mode", name: "Tail", defaultLineID: "tail")]
        profile.activeModeID = "tail-mode"
        profile.ensureConnectivityTestConfiguration()
        app.profile = profile

        engine.setStatus("action-required")
        await Task.yield()

        XCTAssertEqual(app.tailscaleAuthRequests, [
            TailscaleAuthRequest(lineID: "tail", lineName: "Tail"),
        ])
        let result: Result<TailscaleRuntimeStatus, Error> = await withCheckedContinuation {
            continuation in
            app.beginTailscaleLogin(lineID: "tail") {
                continuation.resume(returning: $0)
            }
        }
        guard case .success(let status) = result else {
            return XCTFail("restored Tailscale sign-in did not reach the runtime endpoint")
        }
        XCTAssertEqual(status.authURL, "https://login.tailscale.com/a/restored-token")
        XCTAssertEqual(engine.tailscaleLoginEndpointTags, ["tailscale-tail"])
    }

    func testTailscaleExitSelectionPersistsOfflineAndMarksConnectedReconnect() async {
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)
        let persistence = makePersistence()
        let app = AppState(engine: engine, tunnelManager: manager, persistence: persistence)
        var profile = Profile.bootstrap()
        profile.lines.append(Line(
            id: "tail",
            name: "Tail",
            type: "tailscale",
            tailscaleAuthenticated: true
        ))
        profile.modes = [Mode(id: "tail-mode", name: "Tail", defaultLineID: "tail")]
        profile.activeModeID = "tail-mode"
        profile.ensureConnectivityTestConfiguration()
        app.profile = profile

        XCTAssertTrue(app.updateTailscaleExitSelection(
            lineID: "tail",
            selected: "100.64.0.8"
        ))
        XCTAssertEqual(
            app.profile.lines.first(where: { $0.id == "tail" })?.tailscaleExitNode,
            "100.64.0.8"
        )

        let restoredEngine = RuntimeSpyEngine()
        let restoredManager = RuntimeSpyManager(engine: restoredEngine)
        let restored = AppState(
            engine: restoredEngine,
            tunnelManager: restoredManager,
            persistence: persistence
        )
        XCTAssertEqual(
            restored.profile.lines.first(where: { $0.id == "tail" })?.tailscaleExitNode,
            "100.64.0.8"
        )

        app.connect()
        await Task.yield()
        XCTAssertTrue(app.updateTailscaleExitSelection(
            lineID: "tail",
            selected: "100.64.0.9"
        ))
        XCTAssertTrue(app.hasPendingRuntimeChanges)

        engine.setStatus("action-required")
        await Task.yield()
        XCTAssertFalse(app.updateTailscaleExitSelection(
            lineID: "tail",
            selected: "100.64.0.10"
        ))
        XCTAssertEqual(
            app.profile.lines.first(where: { $0.id == "tail" })?.tailscaleExitNode,
            "100.64.0.9"
        )
    }

    func testLegacyVerifiedTailscalePreservesLoginWhenExitNodeChanges() {
        let app = AppState(persistence: makePersistence())
        var profile = Profile.bootstrap()
        profile.lines.append(Line(
            id: "tail",
            name: "Tail",
            type: "tailscale",
            verified: true,
            tailscaleExitNode: "100.64.0.8"
        ))
        app.profile = profile

        XCTAssertTrue(app.updateTailscaleExitSelection(
            lineID: "tail",
            selected: "100.64.0.9"
        ))
        let updated = app.profile.lines.first(where: { $0.id == "tail" })
        XCTAssertEqual(updated?.tailscaleExitNode, "100.64.0.9")
        XCTAssertEqual(updated?.verified, false)
        XCTAssertEqual(updated?.tailscaleAuthenticated, true)
    }

    func testLegacyVerifiedTailscaleMigratesToDedicatedLoginStateOnReload() {
        let persistence = makePersistence()
        let original = AppState(persistence: persistence)
        var profile = Profile.bootstrap()
        profile.lines.append(Line(
            id: "tail",
            name: "Tail",
            type: "tailscale",
            verified: true,
            tailscaleExitNode: "100.64.0.8"
        ))
        original.profile = profile
        XCTAssertTrue(original.save())

        let restored = AppState(persistence: persistence)
        let line = restored.profile.lines.first(where: { $0.id == "tail" })
        XCTAssertEqual(line?.tailscaleAuthenticated, true)
        XCTAssertFalse(
            restored.routeLineConfigurationIssues(line ?? Line(
                id: "missing",
                name: "Missing",
                type: "tailscale"
            )).contains { $0.contains("登录") || $0.contains("sign-in") }
        )
    }

    func testEveryGeneratedTailscaleEndpointIsQueryableWhileActionIsRequired() async {
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)
        let app = AppState(engine: engine, tunnelManager: manager, persistence: makePersistence())
        var profile = Profile.bootstrap()
        profile.lines.append(Line(id: "tail-active", name: "Active", type: "tailscale"))
        profile.lines.append(Line(id: "tail-unused", name: "Unused", type: "tailscale"))
        profile.modes = [Mode(id: "tail-mode", name: "Tail", defaultLineID: "tail-active")]
        profile.activeModeID = "tail-mode"
        profile.ensureConnectivityTestConfiguration()
        app.profile = profile
        app.connect()
        await Task.yield()
        engine.setStatus("action-required")
        await Task.yield()
        let expectedEndpointTags = [
            "tailscale-tail-active",
            "tailscale-tail-unused",
        ]
        XCTAssertEqual(engine.tailscaleEndpointTags, expectedEndpointTags)

        for lineID in ["tail-active", "tail-unused"] {
            let result: Result<TailscaleRuntimeStatus, Error> = await withCheckedContinuation {
                continuation in
                app.refreshTailscaleStatus(lineID: lineID) {
                    continuation.resume(returning: $0)
                }
            }
            guard case .success(let status) = result else {
                return XCTFail("globally generated endpoint must remain queryable")
            }
            XCTAssertEqual(status.backendState, "Running")
        }
        XCTAssertEqual(
            Array(engine.tailscaleEndpointTags.suffix(expectedEndpointTags.count)),
            expectedEndpointTags
        )
    }

    func testActiveRouteSummaryIncludesSubscriptionAndIgnoresDisabledRuleBinding() {
        var profile = Profile.bootstrap()
        profile.lines.append(Line(
            id: "proxy-disabled-rule",
            name: "Should Not Appear",
            type: "trojan",
            trojanServer: "proxy.example.com",
            trojanPassword: "secret"
        ))
        profile.ruleSets.append(RuleSet(
            id: "disabled-rule",
            name: "Disabled",
            type: "manual",
            enabled: false,
            domains: ["disabled.example"]
        ))
        profile.subscriptions = [Subscription(
            id: "sub-main",
            name: "Main Subscription",
            url: "https://example.com/sub",
            lines: [Line(
                id: "sub-node",
                name: "Node",
                type: "trojan",
                trojanServer: "node.example.com",
                trojanPassword: "secret"
            )]
        )]
        profile.modes = [Mode(
            id: "sub-mode",
            name: "Subscription",
            bindings: [
                RuleBinding(ruleSetID: "disabled-rule", lineID: "proxy-disabled-rule"),
            ],
            defaultSubscriptionID: "sub-main"
        )]
        profile.ensureConnectivityTestConfiguration()

        let targets = profile.activeRouteTargetSummaries(for: profile.modes[0])

        XCTAssertTrue(targets.contains {
            $0.id == "sub:sub-main" && $0.name == "Main Subscription"
                && $0.isSubscription
        })
        XCTAssertTrue(targets.contains { $0.id == "port:direct" })
        XCTAssertFalse(targets.contains { $0.name == "Should Not Appear" })
    }

    func testGoEngineRequestsAndDecodesTailscaleStatus() async {
        let engine = GoEngine()
        let session = TailscaleStatusSession()
        engine.session = session

        let result: Result<TailscaleRuntimeStatus, Error> = await withCheckedContinuation { continuation in
            engine.tailscaleStatus(endpointTag: "tailscale-home") {
                continuation.resume(returning: $0)
            }
        }

        guard case .success(let status) = result else {
            return XCTFail("GoEngine did not decode Tailscale status")
        }
        XCTAssertEqual(session.request["cmd"], "tailscale-status")
        XCTAssertEqual(session.request["endpoint_tag"], "tailscale-home")
        XCTAssertEqual(status.backendState, "Running")
        XCTAssertEqual(status.exitNodes.first?.name, "Home")
    }

    func testGoEngineBeginsInteractiveTailscaleLogin() async {
        let engine = GoEngine()
        let session = TailscaleStatusSession()
        engine.session = session

        let result: Result<TailscaleRuntimeStatus, Error> = await withCheckedContinuation {
            continuation in
            engine.beginTailscaleLogin(endpointTag: "tailscale-home") {
                continuation.resume(returning: $0)
            }
        }

        guard case .success(let status) = result else {
            return XCTFail("GoEngine did not decode refreshed Tailscale login status")
        }
        XCTAssertEqual(session.request["cmd"], "tailscale-begin-login")
        XCTAssertEqual(session.request["endpoint_tag"], "tailscale-home")
        XCTAssertEqual(status.backendState, "Running")
    }

    func testDeletingReferencedSubscriptionFailsClosed() {
        let app = AppState(engine: NoopTunnelEngine(), persistence: makePersistence())
        var profile = Profile.bootstrap()
        profile.subscriptions = [
            Subscription(id: "sub-1", name: "Example", url: "https://example.com/sub")
        ]
        profile.modes = [
            Mode(id: "mode-1", name: "Example", defaultSubscriptionID: "sub-1")
        ]
        profile.activeModeID = "mode-1"
        app.profile = profile

        app.deleteSubscription("sub-1")

        XCTAssertTrue(app.profile.subscriptions.isEmpty)
        guard let mode = app.profile.modes.first else {
            XCTFail("Deleting a subscription must not remove its referencing mode")
            return
        }
        XCTAssertEqual(mode.defaultSubscriptionID, "sub-1")
        XCTAssertEqual(mode.defaultLineID, "")
        XCTAssertTrue(app.activeConfigurationIssues.contains { $0.contains("订阅已删除") || $0.contains("deleted subscription") })
    }

    func testSaveKeepsRemoteAddressesOutOfUserDefaults() throws {
        let persistence = makePersistence()
        let app = AppState(engine: NoopTunnelEngine(), persistence: persistence)
        app.profile.lines[1].vpnServer = "https://gateway.example.com/private-path?token=server-secret"
        app.profile.lines[1].vpnUsername = "private-account-name"
        app.profile.lines[1].vpnPassword = "private-account-password"
        app.profile.ruleSets = [
            RuleSet(
                id: "remote-secret",
                name: "Remote",
                type: "url",
                url: "https://example.com/rules/path-secret?token=rule-secret"
            ),
        ]
        var subscription = Subscription(
                id: "sub-secret",
                name: "Secret",
                url: "https://example.com/list?token=must-not-be-in-defaults"
        )
        subscription.testURL = "https://example.com/check?token=test-secret"
        app.profile.subscriptions = [subscription]

        XCTAssertTrue(app.save())

        let savedData = try XCTUnwrap(persistence.defaults.data(forKey: persistence.profileKey))
        let savedEnvelope = try JSONDecoder().decode(ProfilePersistenceEnvelope.self, from: savedData)
        let savedProfile = savedEnvelope.profile
        XCTAssertEqual(savedProfile.ruleSets[0].url, "")
        XCTAssertEqual(savedProfile.subscriptions[0].url, "")
        XCTAssertEqual(savedProfile.subscriptions[0].testURL, "")
        XCTAssertEqual(savedProfile.lines[1].vpnServer, "")
        let savedJSON = try XCTUnwrap(String(data: savedData, encoding: .utf8))
        XCTAssertFalse(savedJSON.contains("path-secret"))
        XCTAssertFalse(savedJSON.contains("rule-secret"))
        XCTAssertFalse(savedJSON.contains("must-not-be-in-defaults"))
        XCTAssertFalse(savedJSON.contains("test-secret"))
        XCTAssertFalse(savedJSON.contains("private-account-name"))
        XCTAssertFalse(savedJSON.contains("private-account-password"))
        XCTAssertFalse(savedJSON.contains("gateway.example.com"))
        XCTAssertFalse(savedJSON.contains("private-path"))
        XCTAssertFalse(savedJSON.contains("server-secret"))
        XCTAssertEqual(app.profile.ruleSets[0].url, "https://example.com/rules/path-secret?token=rule-secret")
        XCTAssertEqual(app.profile.subscriptions[0].url, "https://example.com/list?token=must-not-be-in-defaults")
        XCTAssertEqual(app.profile.subscriptions[0].testURL, "https://example.com/check?token=test-secret")

        let reloaded = AppState(engine: NoopTunnelEngine(), persistence: persistence)
        XCTAssertEqual(
            reloaded.profile.lines[1].vpnServer,
            "https://gateway.example.com/private-path?token=server-secret"
        )
        XCTAssertEqual(reloaded.profile.lines[1].vpnUsername, "private-account-name")
        XCTAssertEqual(reloaded.profile.lines[1].vpnPassword, "private-account-password")
    }

    func testPlaintextEnvelopeIsRewrittenIntoSecureVault() throws {
        let persistence = makePersistence()
        let legacyRevision = "plaintext-envelope-revision"
        var stored = Profile.bootstrap()
        stored.lines[1].vpnServer = "gateway.example.com"
        stored.lines[1].vpnUsername = "plaintext-user"
        stored.lines[1].vpnPassword = "plaintext-password"
        stored.ruleSets = [
            RuleSet(
                id: "remote-rule",
                name: "Remote",
                type: "url",
                url: "https://example.com/private-rules"
            ),
        ]
        persistence.defaults.set(
            try JSONEncoder().encode(
                ProfilePersistenceEnvelope(revision: legacyRevision, profile: stored)
            ),
            forKey: persistence.profileKey
        )
        XCTAssertEqual(
            KeychainStore.saveVault(
                values: [:],
                revision: legacyRevision,
                context: persistence.keychain
            ),
            .success
        )

        let app = AppState(engine: NoopTunnelEngine(), persistence: persistence)

        XCTAssertFalse(app.persistenceRequiresRecovery)
        XCTAssertEqual(app.profile.lines[1].vpnUsername, "plaintext-user")
        XCTAssertEqual(app.profile.lines[1].vpnPassword, "plaintext-password")
        XCTAssertEqual(app.profile.ruleSets[0].url, "https://example.com/private-rules")

        let savedData = try XCTUnwrap(persistence.defaults.data(forKey: persistence.profileKey))
        let savedEnvelope = try JSONDecoder().decode(ProfilePersistenceEnvelope.self, from: savedData)
        XCTAssertNotEqual(savedEnvelope.revision, legacyRevision)
        XCTAssertEqual(savedEnvelope.profile.lines[1].vpnServer, "")
        XCTAssertEqual(savedEnvelope.profile.lines[1].vpnUsername, "")
        XCTAssertEqual(savedEnvelope.profile.lines[1].vpnPassword, "")
        XCTAssertEqual(savedEnvelope.profile.ruleSets[0].url, "")

        guard case .available(let vaultEnvelope, _) = KeychainStore.loadVaultState(
            context: persistence.keychain
        ) else {
            return XCTFail("rewritten secure vault missing")
        }
        XCTAssertEqual(vaultEnvelope.revision, savedEnvelope.revision)
        XCTAssertTrue(vaultEnvelope.values.values.contains("gateway.example.com"))
        XCTAssertTrue(vaultEnvelope.values.values.contains("plaintext-user"))
        XCTAssertTrue(vaultEnvelope.values.values.contains("plaintext-password"))
        XCTAssertTrue(vaultEnvelope.values.values.contains("https://example.com/private-rules"))
    }

    func testSubscriptionParsingRunsWithoutTunnelSession() async {
        let engine = GoEngine()
        let content = """
        proxies:
          - name: Test-SS
            type: ss
            server: node.example.com
            port: 8388
            cipher: aes-256-gcm
            password: test-password
        proxy-groups:
          - name: Proxy
            type: select
            proxies: [Test-SS]
        rules:
          - DOMAIN-SUFFIX,example.com,Proxy
        """

        let result: Result<ParseResult, Error> = await withCheckedContinuation { continuation in
            engine.parseSubscription(url: "", content: content, format: "clash") {
                continuation.resume(returning: $0)
            }
        }

        switch result {
        case .success(let parsed):
            XCTAssertEqual(parsed.lines.count, 1)
            XCTAssertEqual(parsed.lines.first?.type, "shadowsocks")
            XCTAssertEqual(parsed.proxyGroups?.first?.name, "Proxy")
            XCTAssertEqual(parsed.rules?.first?.type, "DOMAIN-SUFFIX")
        case .failure(let error):
            XCTFail("subscription parsing failed: \(error)")
        }
    }

    func testSecureVaultRoundTrip() {
        let persistence = makePersistence()
        let marker = "vault-test-" + UUID().uuidString

        XCTAssertEqual(
            KeychainStore.saveVault(
                values: ["test-marker": marker],
                revision: "revision-a",
                context: persistence.keychain
            ),
            .success
        )
        guard case .available(let envelope, let cleanupRequired) = KeychainStore.loadVaultState(
            context: persistence.keychain
        ) else {
            return XCTFail("secure vault was not readable")
        }
        XCTAssertEqual(envelope.revision, "revision-a")
        XCTAssertEqual(envelope.values["test-marker"], marker)
        XCTAssertFalse(cleanupRequired)
    }

    func testRevisionedVaultWinsOverStaleLegacyFile() throws {
        let persistence = makePersistence()
        XCTAssertEqual(
            KeychainStore.saveVault(
                values: ["credential": "current-keychain-value"],
                revision: "revision-current",
                context: persistence.keychain
            ),
            .success
        )

        let legacyURL = persistence.keychain.legacyVaultFileURL
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(["credential": "stale-file-value"])
            .write(to: legacyURL, options: [.atomic])

        guard case .available(let envelope, let cleanupRequired) = KeychainStore.loadVaultState(
            context: persistence.keychain
        ) else {
            return XCTFail("revisioned vault did not remain authoritative")
        }
        XCTAssertEqual(envelope.values["credential"], "current-keychain-value")
        XCTAssertFalse(cleanupRequired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testExplicitlyEmptyVaultDoesNotRestoreLegacyCredential() throws {
        let persistence = makePersistence()
        let legacyAccount = "xdial-line-vpn-vpn"
        let revision = "empty-vault-revision"
        var stored = Profile.bootstrap()
        stored.lines[1].vpnServer = "gateway.example.com"
        stored.lines[1].vpnUsername = ""
        stored.lines[1].vpnPassword = ""
        persistence.defaults.set(
            try JSONEncoder().encode(ProfilePersistenceEnvelope(revision: revision, profile: stored)),
            forKey: persistence.profileKey
        )
        XCTAssertEqual(
            KeychainStore.saveVault(values: [:], revision: revision, context: persistence.keychain),
            .success
        )
        KeychainStore.save(
            password: "must-not-return",
            account: legacyAccount,
            context: persistence.keychain
        )

        let reloaded = AppState(engine: NoopTunnelEngine(), persistence: persistence)
        XCTAssertEqual(reloaded.profile.lines.first(where: { $0.id == "vpn" })?.vpnPassword, "")
        XCTAssertFalse(reloaded.persistenceRequiresRecovery)
    }

    func testStructuredVaultKeysKeepCollidingLegacyIDsSeparate() throws {
        let persistence = makePersistence()
        let app = AppState(engine: NoopTunnelEngine(), persistence: persistence)
        var profile = Profile.bootstrap()
        profile.lines.append(Line(
            id: "foo-bar",
            name: "Top level",
            type: "shadowsocks",
            ssServer: "top.example.com",
            ssPassword: "top-secret"
        ))
        profile.subscriptions = [
            Subscription(
                id: "foo",
                name: "Subscription",
                url: "https://example.com/subscription",
                lines: [
                    Line(
                        id: "bar",
                        name: "Subscription node",
                        type: "shadowsocks",
                        ssServer: "sub.example.com",
                        ssPassword: "subscription-secret"
                    ),
                ]
            ),
        ]
        app.profile = profile
        XCTAssertTrue(app.save())

        let reloaded = AppState(engine: NoopTunnelEngine(), persistence: persistence)
        XCTAssertEqual(
            reloaded.profile.lines.first(where: { $0.id == "foo-bar" })?.ssPassword,
            "top-secret"
        )
        XCTAssertEqual(
            reloaded.profile.lines.first(where: { $0.id == "foo-bar" })?.ssServer,
            "top.example.com"
        )
        XCTAssertEqual(
            reloaded.profile.subscriptions.first(where: { $0.id == "foo" })?.lines
                .first(where: { $0.id == "bar" })?.ssPassword,
            "subscription-secret"
        )
        XCTAssertEqual(
            reloaded.profile.subscriptions.first(where: { $0.id == "foo" })?.lines
                .first(where: { $0.id == "bar" })?.ssServer,
            "sub.example.com"
        )
    }

    func testProfileAndVaultRevisionMismatchFailsClosed() throws {
        let persistence = makePersistence()
        var stored = Profile.bootstrap()
        stored.lines[1].vpnServer = "gateway.example.com"
        persistence.defaults.set(
            try JSONEncoder().encode(ProfilePersistenceEnvelope(revision: "profile-revision", profile: stored)),
            forKey: persistence.profileKey
        )
        XCTAssertEqual(
            KeychainStore.saveVault(
                values: ["unrelated": "secret"],
                revision: "vault-revision",
                context: persistence.keychain
            ),
            .success
        )

        let app = AppState(engine: NoopTunnelEngine(), persistence: persistence)
        XCTAssertTrue(app.persistenceRequiresRecovery)
        XCTAssertFalse(app.canConnect)
        XCTAssertNotNil(app.engine.lastError)
    }

    func testExplicitProfileReplacementRecoversRevisionMismatch() throws {
        let persistence = makePersistence()
        persistence.defaults.set(
            try JSONEncoder().encode(
                ProfilePersistenceEnvelope(
                    revision: "profile-revision",
                    profile: Profile.bootstrap()
                )
            ),
            forKey: persistence.profileKey
        )
        XCTAssertEqual(
            KeychainStore.saveVault(
                values: ["unrelated": "secret"],
                revision: "vault-revision",
                context: persistence.keychain
            ),
            .success
        )
        let app = AppState(engine: NoopTunnelEngine(), persistence: persistence)
        XCTAssertTrue(app.persistenceRequiresRecovery)

        var replacement = Profile.bootstrap()
        replacement.modes = [
            Mode(id: "recovered-mode", name: "Recovered", defaultLineID: "direct"),
        ]
        replacement.activeModeID = "recovered-mode"
        XCTAssertTrue(app.replaceProfileAndSave(replacement))
        XCTAssertFalse(app.persistenceRequiresRecovery)

        let reloaded = AppState(engine: NoopTunnelEngine(), persistence: persistence)
        XCTAssertFalse(reloaded.persistenceRequiresRecovery)
        guard let reloadedMode = reloaded.profile.modes.first else {
            XCTFail("The explicitly replaced profile must survive reload")
            return
        }
        XCTAssertEqual(reloadedMode.name, "Recovered")
    }

    func testCorruptStoredProfileFailsClosed() {
        let persistence = makePersistence()
        persistence.defaults.set(Data("{}".utf8), forKey: persistence.profileKey)

        let app = AppState(engine: NoopTunnelEngine(), persistence: persistence)
        XCTAssertTrue(app.persistenceRequiresRecovery)
        XCTAssertFalse(app.canConnect)
    }

    func testCorruptSecureVaultFailsClosed() throws {
        let persistence = makePersistence()
        let revision = "corrupt-vault-revision"
        persistence.defaults.set(
            try JSONEncoder().encode(
                ProfilePersistenceEnvelope(revision: revision, profile: Profile.bootstrap())
            ),
            forKey: persistence.profileKey
        )
        XCTAssertEqual(
            KeychainStore.writeRawVaultDataForTesting(
                Data("not-json".utf8),
                context: persistence.keychain
            ),
            errSecSuccess
        )

        let app = AppState(engine: NoopTunnelEngine(), persistence: persistence)
        XCTAssertTrue(app.persistenceRequiresRecovery)
        XCTAssertFalse(app.canConnect)
    }

    func testAmbiguousLegacyFlatKeyIsQuarantinedInsteadOfDuplicated() throws {
        let persistence = makePersistence()
        var profile = Profile.bootstrap()
        profile.lines.append(Line(
            id: "foo-bar",
            name: "Top level",
            type: "shadowsocks",
            ssServer: "top.example.com",
            ssPort: 8388,
            ssMethod: "aes-256-gcm"
        ))
        profile.subscriptions = [
            Subscription(
                id: "foo",
                name: "Subscription",
                url: "",
                lines: [
                    Line(
                        id: "bar",
                        name: "Nested",
                        type: "shadowsocks",
                        ssServer: "nested.example.com",
                        ssPort: 8388,
                        ssMethod: "aes-256-gcm"
                    ),
                ]
            ),
        ]
        persistence.defaults.set(try JSONEncoder().encode(profile), forKey: persistence.profileKey)
        XCTAssertEqual(
            KeychainStore.writeRawVaultDataForTesting(
                try JSONEncoder().encode(["foo-bar-ss": "ambiguous-secret"]),
                context: persistence.keychain
            ),
            errSecSuccess
        )

        let app = AppState(engine: NoopTunnelEngine(), persistence: persistence)
        XCTAssertEqual(app.profile.lines.first(where: { $0.id == "foo-bar" })?.ssPassword, "")
        XCTAssertEqual(app.profile.subscriptions[0].lines[0].ssPassword, "")
        XCTAssertFalse(app.persistenceRequiresRecovery)
        XCTAssertNotNil(app.engine.lastError)

        guard case .available(let envelope, _) = KeychainStore.loadVaultState(
            context: persistence.keychain
        ) else {
            return XCTFail("migrated vault missing")
        }
        XCTAssertEqual(envelope.quarantinedLegacyValues["foo-bar-ss"], "ambiguous-secret")
        XCTAssertFalse(envelope.values.values.contains("ambiguous-secret"))
    }

    func testPersistenceNamespacesAreIsolated() {
        let first = makePersistence()
        let second = makePersistence()
        XCTAssertEqual(
            KeychainStore.saveVault(
                values: ["marker": "first"], revision: "one", context: first.keychain
            ),
            .success
        )
        XCTAssertEqual(KeychainStore.loadVaultState(context: second.keychain), .missing)
        first.defaults.set(Data("first".utf8), forKey: first.profileKey)
        XCTAssertNil(second.defaults.data(forKey: second.profileKey))
    }

    func testRuleFieldsPersistAcrossColdRestart() {
        let persistence = makePersistence()
        let engine = RuntimeSpyEngine()
        let manager = RuntimeSpyManager(engine: engine)
        let app = AppState(engine: engine, tunnelManager: manager, persistence: persistence)
        let ruleID = "cold-restart-rule"
        app.profile.ruleSets.append(RuleSet(
            id: ruleID,
            name: "Cold Restart",
            type: "manual",
            domains: ["example.com"],
            cidrs: ["203.0.113.0/24"]
        ))
        XCTAssertTrue(app.save())

        let restoredEngine = RuntimeSpyEngine()
        let restoredManager = RuntimeSpyManager(engine: restoredEngine)
        let restored = AppState(
            engine: restoredEngine,
            tunnelManager: restoredManager,
            persistence: persistence
        )
        let rule = restored.profile.ruleSets.first(where: { $0.id == ruleID })
        XCTAssertEqual(rule?.name, "Cold Restart")
        XCTAssertEqual(rule?.domains, ["example.com"])
        XCTAssertEqual(rule?.cidrs, ["203.0.113.0/24"])
    }

    func testTunnelDiagnosticSummaryKeepsProviderError() {
        let summary = TunnelDiagnosticFormatter.summary([
            "stage": "engine_failed",
            "last_error": "authentication rejected",
        ])

        XCTAssertEqual(summary, "error=authentication rejected · stage=engine_failed")
    }

    func testTunnelDiagnosticSummaryKeepsNestedEngineError() {
        let summary = TunnelDiagnosticFormatter.summary([
            "stage": "engine_started",
            "engine": [
                "last_error": "route setup failed",
                "gvisor_compiled": true,
                "selected_stack": "gvisor",
            ],
        ])

        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.contains("engine_error=route setup failed") == true)
        XCTAssertTrue(summary?.contains("stage=engine_started") == true)
    }

    func testTunnelDiagnosticSummaryRejectsAnotherAttempt() {
        let snapshot: [String: Any] = [
            "attempt_id": "attempt-a",
            "stage": "tun_unavailable",
        ]

        XCTAssertNotNil(TunnelDiagnosticFormatter.summary(
            snapshot,
            matchingAttemptID: "attempt-a"
        ))
        XCTAssertNil(TunnelDiagnosticFormatter.summary(
            snapshot,
            matchingAttemptID: "attempt-b"
        ))
    }

    func testSystemProfileServerAddressDropsURLSecrets() {
        XCTAssertEqual(
            TunnelManager.systemProfileServerAddress(
                "https://private-user:private-password@gateway.example.com:8443/group?token=secret"
            ),
            "gateway.example.com:8443"
        )
        XCTAssertEqual(
            TunnelManager.systemProfileServerAddress("gateway.example.com/group?token=secret"),
            "gateway.example.com"
        )
        XCTAssertEqual(TunnelManager.systemProfileServerAddress(""), "XDial")
    }
}

private extension RuleBinding {
    var isConnectivityAcceptanceBindingForTest: Bool {
        ruleSetID == RuleSet.connectivityDirectID || ruleSetID == RuleSet.connectivityAnyConnectID
    }
}
