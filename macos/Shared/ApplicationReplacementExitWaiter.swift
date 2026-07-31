import Foundation

/// Waits for a previous XDial process to finish its graceful application
/// termination. The caller supplies a fresh process snapshot on every poll;
/// retaining one `NSRunningApplication` instance can otherwise keep reporting
/// stale termination state across an app replacement.
enum ApplicationReplacementExitWaiter {
    static let gracefulTerminationTimeout: TimeInterval = 12
    static let pollInterval: TimeInterval = 0.05

    static func otherProcessIdentifiers(
        currentProcessIdentifier: Int32,
        candidateProcessIdentifiers: [Int32]
    ) -> Set<Int32> {
        Set(
            candidateProcessIdentifiers.filter {
                $0 > 0 && $0 != currentProcessIdentifier
            }
        )
    }

    static func wait(
        timeout: TimeInterval = gracefulTerminationTimeout,
        pollInterval: TimeInterval = pollInterval,
        requestGracefulTermination: (Int32) -> Void,
        remainingProcessIdentifiers: () -> Set<Int32>
    ) -> Bool {
        wait(
            timeout: timeout,
            pollInterval: pollInterval,
            monotonicNow: {
                ProcessInfo.processInfo.systemUptime
            },
            sleep: {
                Thread.sleep(forTimeInterval: $0)
            },
            requestGracefulTermination:
                requestGracefulTermination,
            remainingProcessIdentifiers:
                remainingProcessIdentifiers
        )
    }

    static func wait(
        timeout: TimeInterval,
        pollInterval: TimeInterval,
        monotonicNow: () -> TimeInterval,
        sleep: (TimeInterval) -> Void,
        requestGracefulTermination: (Int32) -> Void,
        remainingProcessIdentifiers: () -> Set<Int32>
    ) -> Bool {
        let boundedTimeout = max(0, timeout)
        let boundedPollInterval = max(0.001, pollInterval)
        let deadline = monotonicNow() + boundedTimeout
        var previouslyVisibleProcessIdentifiers = Set<Int32>()

        while true {
            let remaining = remainingProcessIdentifiers()
            guard !remaining.isEmpty else {
                return true
            }
            let newlyVisible =
                remaining.subtracting(
                    previouslyVisibleProcessIdentifiers
                )
            for processIdentifier in newlyVisible.sorted() {
                requestGracefulTermination(processIdentifier)
            }
            previouslyVisibleProcessIdentifiers = remaining
            let now = monotonicNow()
            guard now < deadline else {
                return false
            }
            sleep(min(boundedPollInterval, deadline - now))
        }
    }
}
