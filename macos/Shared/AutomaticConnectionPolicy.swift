import Foundation

/// 宿主层的连接意图只决定何时发起一笔完整连接事务；它不读取或改写
/// Line / RuleSet / Mode，也不绕过 ConnectionPlan 直接操作数据面。
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

struct SleepWakeConnectionIntent {
    private(set) var shouldReconnectAfterWake = false

    @discardableResult
    mutating func prepareForSleep(runtimeStatus: String) -> Bool {
        shouldReconnectAfterWake =
            AutomaticConnectionPolicy.holdsConnectionIntent(
                runtimeStatus: runtimeStatus
            )
        return shouldReconnectAfterWake
    }

    mutating func consumeWakeReconnect() -> Bool {
        let reconnect = shouldReconnectAfterWake
        shouldReconnectAfterWake = false
        return reconnect
    }

    mutating func cancel() {
        shouldReconnectAfterWake = false
    }
}

/// 连接前可能要异步结束 Tailscale 配置会话。新连接、显式断开或休眠发生后，
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

/// 显式断开在当前 App 生命周期内压过尚未送达的自动连接回调；只有用户再次
/// 点连接/重连，或下一次冷启动，才恢复自动请求的进入资格。
struct ConnectionIntentLatch {
    private(set) var allowsAutomaticConnection = true

    mutating func userRequestedConnection() {
        allowsAutomaticConnection = true
    }

    mutating func userRequestedDisconnection() {
        allowsAutomaticConnection = false
    }
}

/// 合盖连接已停止、但新的连接事务尚未开始时，宿主需要表达一段短暂的恢复态。
/// 这段时间保留旧事务日志用于诊断，但不能把旧事务的 `cancelled` 当成当前状态展示。
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
