import Foundation
import Network

/// 唤醒后的 Wi-Fi / 有线网络需要时间重新形成可用路径。这里仅等待系统报告
/// `satisfied`，真正的默认接口、候选接口和 DNS 快照仍由连接事务重新捕获。
enum NetworkAvailabilityWaiter {
    static func wait(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            OneShotNetworkWait(
                timeout: timeout,
                continuation: continuation
            ).start()
        }
    }
}

private final class OneShotNetworkWait {
    private let monitor = NWPathMonitor()
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(
        timeout: TimeInterval,
        continuation: CheckedContinuation<Bool, Never>
    ) {
        self.timeout = timeout
        self.continuation = continuation
    }

    func start() {
        monitor.pathUpdateHandler = { [self] path in
            guard path.status == .satisfied else { return }
            finish(true)
        }
        monitor.start(queue: .global(qos: .utility))
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout
        ) { [self] in
            finish(false)
        }
    }

    private func finish(_ available: Bool) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()

        monitor.pathUpdateHandler = nil
        monitor.cancel()
        continuation.resume(returning: available)
    }
}
