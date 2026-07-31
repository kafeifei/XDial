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
