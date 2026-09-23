import Foundation

/// Main-queue ownership gate. A connection handoff waits for accepted account
/// operations before asking the helper to release its standalone endpoint.
final class TailscaleConfigurationLease {
    private(set) var suspended = false
    private var operations = 0
    private var idle: (() -> Void)?

    func begin() -> Bool {
        guard !suspended else { return false }
        operations += 1
        return true
    }

    func end() {
        precondition(operations > 0)
        operations -= 1
        if operations == 0 {
            let completion = idle
            idle = nil
            completion?()
        }
    }

    func suspend(whenIdle: @escaping () -> Void) {
        precondition(!suspended)
        suspended = true
        if operations == 0 { whenIdle() } else { idle = whenIdle }
    }

    func resume() {
        precondition(operations == 0 && idle == nil)
        suspended = false
    }
}
