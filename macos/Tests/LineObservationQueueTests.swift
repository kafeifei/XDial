import XCTest

@MainActor
final class LineObservationQueueTests: XCTestCase {
    func testReplacementWaitsForPreviousOperationToReturn() async {
        let queue = LineObservationQueue()
        let gate = SuspensionGate()
        var events: [String] = []

        queue.replace {
            events.append("old-started")
            await gate.wait()
            events.append("old-finished")
        }
        await waitUntil { events == ["old-started"] }

        queue.replace {
            events.append("new-started")
        }
        await drainTasks()
        XCTAssertEqual(events, ["old-started"])

        gate.release()
        await waitUntil { events.count == 3 }
        XCTAssertEqual(events, ["old-started", "old-finished", "new-started"])
    }

    func testConsecutiveReplacementsRunOnlyLatestOperation() async {
        let queue = LineObservationQueue()
        let gate = SuspensionGate()
        var events: [String] = []

        queue.replace {
            events.append("old-started")
            await gate.wait()
            events.append("old-finished")
        }
        await waitUntil { events == ["old-started"] }

        queue.replace { events.append("superseded") }
        queue.replace { events.append("latest") }
        gate.release()

        await waitUntil { events.contains("latest") }
        XCTAssertEqual(events, ["old-started", "old-finished", "latest"])
    }

    func testReplaceAfterCancelStillWaitsForCancelledOperation() async {
        let queue = LineObservationQueue()
        let gate = SuspensionGate()
        var events: [String] = []

        queue.replace {
            events.append("old-started")
            await gate.wait()
            events.append("old-finished")
        }
        await waitUntil { events == ["old-started"] }

        queue.cancel()
        queue.replace { events.append("new-started") }
        await drainTasks()
        XCTAssertEqual(events, ["old-started"])

        gate.release()
        await waitUntil { events.count == 3 }
        XCTAssertEqual(events, ["old-started", "old-finished", "new-started"])
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private func drainTasks() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }
}

@MainActor
private final class SuspensionGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
