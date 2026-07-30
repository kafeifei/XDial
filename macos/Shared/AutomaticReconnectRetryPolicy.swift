import Foundation

enum ConnectionFailureCode {
    static let underlayEgressUnavailable =
        "underlay-egress-unavailable"
}

/// Underlay 切换通知只证明系统路由、NWPath 与 DNS 快照已经收敛，不证明
/// 下层数据面已经能承载真实连接。自动重建只对这个结构化瞬态错误做有界重试；
/// Line 登录、节点、握手等错误必须原样失败，不能被重试掩盖。
struct AutomaticReconnectRetryPolicy {
    private let delays: [TimeInterval]

    init(delays: [TimeInterval] = [2, 5, 10]) {
        self.delays = delays
    }

    func delay(
        after report: ConnectionReport,
        retryIndex: Int
    ) -> TimeInterval? {
        guard
            report.state == .failed,
            report.rollbackComplete,
            report.systemTakeoverRemoved,
            report.error?.code ==
                ConnectionFailureCode.underlayEgressUnavailable
        else {
            return nil
        }
        return delay(retryIndex: retryIndex)
    }

    func delay(retryIndex: Int) -> TimeInterval? {
        guard delays.indices.contains(retryIndex) else {
            return nil
        }
        return delays[retryIndex]
    }
}
