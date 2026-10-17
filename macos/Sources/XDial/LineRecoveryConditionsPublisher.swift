import AppKit
import Foundation
import Network

/// 把宿主掌握的电源生命周期与 Underlay 可用性告诉 Provider（合同见
/// `ProviderLineRecoveryConditions`，送达策略见 `LineRecoveryConditionsPublisherState`）。
/// 宿主不替 Provider 做恢复决定；Provider 只据此判断 Line 局部恢复能否消耗预算。
/// 休眠信号只来自 AppState 的 `willSleep` / 完整 `didWake`，这里不另行订阅电源通知。
///
/// 只在主线程使用。
final class LineRecoveryConditionsPublisher {
    /// 发送一份报告；completion 报告 Provider 是否确认收到。
    typealias Send = (
        ProviderLineRecoveryConditions,
        @escaping (LineRecoveryConditionsDeliveryResult) -> Void
    ) -> Void

    private var state = LineRecoveryConditionsPublisherState(
        source: UUID().uuidString
    )
    private let monitor = NWPathMonitor()
    private var send: Send?
    private var timer: DispatchWorkItem?
    private var terminationObserver: NSObjectProtocol?

    func start(send: @escaping Send) {
        guard self.send == nil else { return }
        self.send = send
        monitor.pathUpdateHandler = { [weak self] path in
            let usable = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self else { return }
                self.apply(self.state.observeUnderlay(usable: usable))
            }
        }
        monitor.start(queue: .global(qos: .utility))
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stop()
        }
    }

    func noteSystemWillSleep() {
        apply(state.noteSystemWillSleep())
    }

    func noteSystemDidWake() {
        // 重新读取当前路径，不沿用休眠前最后一次回调的结论。
        let usable = monitor.currentPath.status == .satisfied
        apply(state.noteSystemDidWake(underlayUsable: usable))
    }

    /// 由宿主的 NE 状态观察在每次状态变化时调用。
    func noteProviderConnected(_ connected: Bool) {
        apply(state.noteProviderConnected(connected))
    }

    private func stop() {
        cancelTimer()
        send = nil
        monitor.pathUpdateHandler = nil
        monitor.cancel()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        terminationObserver = nil
    }

    private func apply(_ step: LineRecoveryConditionsDeliveryStep) {
        switch step {
        case .sendNow:
            deliver()
        case let .wait(delay):
            arm(after: delay)
        case .idle:
            cancelTimer()
        case .unchanged:
            break
        }
    }

    private func deliver() {
        cancelTimer()
        guard let send else { return }
        let message = state.makeMessage()
        send(message) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.apply(self.state.finishDelivery(
                    sequence: message.sequence,
                    result: result
                ))
            }
        }
    }

    /// `DispatchTime` 与 Provider 的租约时钟一样不计休眠时间。
    private func arm(after delay: TimeInterval) {
        cancelTimer()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.timer = nil
            self.apply(self.state.timerFired())
        }
        timer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }
}
