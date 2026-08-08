import Foundation

/// 宿主层的连接意图只决定何时发起一笔完整连接事务；它不读取或改写
/// Line / RuleSet / Scenario，也不绕过 ConnectionPlan 直接操作数据面。
struct AutomaticConnectionPolicy {
    static let defaultEnabled = true

    static func shouldConnectOnLaunch(
        enabled: Bool,
        initialStatusSynchronized: Bool,
        installationReady: Bool,
        runtimeStatus: String,
        canConnect: Bool
    ) -> Bool {
        enabled
            && initialStatusSynchronized
            && installationReady
            && runtimeStatus == "disconnected"
            && canConnect
    }

    static func holdsConnectionIntent(runtimeStatus: String) -> Bool {
        switch runtimeStatus {
        case "connected", "connecting", "reconnecting":
            true
        default:
            false
        }
    }
}

/// 用户对连接的长期期望。网络变化和 Provider 状态都只是
/// reconcile 的输入，绝不能消费或清除这份期望。
struct ConnectionDesiredState: Equatable {
    enum RuntimeOwnership: String, Equatable {
        /// 冷启动时发现的既有 Provider 会话，不受当前宿主的有界重试托管。
        case adopted
        /// 既有会话已经丢失，当前宿主已领取一次恢复责任。
        case restoring
        /// 当前宿主发起的事务，失败与掉线由数据面的有界重试托管。
        case owned
    }

    enum Value: Equatable {
        case unresolved
        case disconnected(explicit: Bool)
        case connected(
            scenarioID: String,
            runtimeOwnership: RuntimeOwnership
        )
    }

    private(set) var value: Value = .unresolved

    var scenarioID: String? {
        guard case let .connected(scenarioID, _) = value else { return nil }
        return scenarioID
    }

    var wantsConnection: Bool { scenarioID != nil }

    var runtimeOwnership: RuntimeOwnership? {
        guard case let .connected(_, ownership) = value else { return nil }
        return ownership
    }

    mutating func observeExistingConnection(scenarioID: String) {
        // 冷启动同步只允许补齐未知事实。用户已经明确点过断开时，迟到的系统
        // 状态回调不能反向恢复连接期望。
        guard case .unresolved = value else { return }
        value = .connected(
            scenarioID: scenarioID,
            runtimeOwnership: .adopted
        )
    }

    mutating func userRequestedConnection(scenarioID: String) {
        value = .connected(
            scenarioID: scenarioID,
            runtimeOwnership: .owned
        )
    }

    @discardableResult
    mutating func automaticConnectionRequested(scenarioID: String) -> Bool {
        if case .disconnected(explicit: true) = value {
            return false
        }
        value = .connected(
            scenarioID: scenarioID,
            runtimeOwnership: .owned
        )
        return true
    }

    @discardableResult
    mutating func beginRestoringAdoptedRuntime() -> Bool {
        guard case let .connected(scenarioID, .adopted) = value else {
            return false
        }
        value = .connected(
            scenarioID: scenarioID,
            runtimeOwnership: .restoring
        )
        return true
    }

    mutating func userRequestedDisconnection() {
        value = .disconnected(explicit: true)
    }

    mutating func settleInitialDisconnection() {
        guard case .unresolved = value else { return }
        value = .disconnected(explicit: false)
    }

    func permitsRestoration(activeScenarioID: String) -> Bool {
        scenarioID == activeScenarioID
    }
}

/// 所有断线 / 唤醒恢复入口都先归一成同一项动作。调用方可以重复投递
/// `didWake`、屏幕唤醒和会话激活；只要输入事实没变，决策就是幂等的。
enum DesiredConnectionReconcileAction: Equatable {
    case none
    case stopRuntime
    case waitForRuntime
    case waitForNetwork
    case startAutomatically(scenarioID: String)
    case scenarioChanged(expectedScenarioID: String, activeScenarioID: String)
    case configurationUnavailable(scenarioID: String)
}

struct DesiredConnectionReconcilePolicy {
    static func decide(
        desired: ConnectionDesiredState,
        activeScenarioID: String,
        runtimeStatus: String,
        canConnect: Bool,
        networkWaitCompleted: Bool
    ) -> DesiredConnectionReconcileAction {
        guard let desiredScenarioID = desired.scenarioID else {
            if AutomaticConnectionPolicy.holdsConnectionIntent(
                runtimeStatus: runtimeStatus
            ) {
                return .stopRuntime
            }
            return .none
        }

        guard desiredScenarioID == activeScenarioID else {
            return .scenarioChanged(
                expectedScenarioID: desiredScenarioID,
                activeScenarioID: activeScenarioID
            )
        }

        if AutomaticConnectionPolicy.holdsConnectionIntent(
            runtimeStatus: runtimeStatus
        ) {
            return .none
        }
        guard runtimeStatus == "disconnected" else {
            return .waitForRuntime
        }
        guard networkWaitCompleted else {
            return .waitForNetwork
        }
        guard canConnect else {
            return .configurationUnavailable(scenarioID: desiredScenarioID)
        }
        return .startAutomatically(scenarioID: desiredScenarioID)
    }
}

/// 宿主退出前必须等系统网络接管确实移除，而不能把异步 `stop()` 的调用返回
/// 当成回滚完成。等待仍有上限，避免 macOS 回调丢失时应用永远无法退出。
struct ApplicationTerminationPolicy {
    static func requiresDrain(
        runtimeStatus: String,
        hasConnectionReport: Bool,
        rollbackComplete: Bool,
        systemTakeoverRemoved: Bool
    ) -> Bool {
        guard runtimeStatus == "disconnected" else { return true }
        guard hasConnectionReport else { return false }
        return !rollbackComplete || !systemTakeoverRemoved
    }
}

/// 连接前可能要异步结束 Tailscale 配置会话。新连接或显式断开发生后，
/// 旧回调不得再启动一笔过期的连接事务。
struct ConnectionAttemptGate {
    private var generation = 0

    mutating func begin() -> Int {
        generation += 1
        return generation
    }

    mutating func cancel() {
        generation += 1
    }

    func isCurrent(_ candidate: Int) -> Bool {
        candidate == generation
    }
}

/// 唤醒时发现系统会话正在自行断开，或已经断开但新的连接事务尚未开始时，宿主需要
/// 表达一段短暂的恢复态。这段时间保留旧事务日志用于诊断，但不能把旧事务的
/// `cancelled` 当成当前状态展示。
enum WakeReconnectPhase: String, CaseIterable {
    case finishingDisconnect = "finishing_disconnect"
    case waitingForNetwork = "waiting_for_network"
    case startingConnection = "starting_connection"

    var presentsConnectionReport: Bool { false }

    var zhStatusText: String {
        switch self {
        case .finishingDisconnect: "正在准备唤醒重连…"
        case .waitingForNetwork: "等待网络恢复…"
        case .startingConnection: "正在重新连接…"
        }
    }

    var enStatusText: String {
        switch self {
        case .finishingDisconnect:
            "Preparing to reconnect after wake…"
        case .waitingForNetwork: "Waiting for network…"
        case .startingConnection: "Reconnecting…"
        }
    }
}
