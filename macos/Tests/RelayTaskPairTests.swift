import XCTest

final class RelayTaskPairTests: XCTestCase {
    func testNormalHalfCloseWaitsForSiblingBeforeShutdown() async throws {
        let secondStarted = AsyncTestGate()
        let firstFinished = AsyncTestGate()
        let allowSecondFinish = AsyncTestGate()
        let events = LockedEvents()
        let shutdown = RelayTaskShutdown { error in
            XCTAssertNil(error)
            events.append("shutdown")
        }

        let task = Task {
            try await RelayTaskPair.run(
                first: {
                    await secondStarted.wait()
                    events.append("first-half-closed")
                    firstFinished.open()
                },
                second: {
                    events.append("second-started")
                    secondStarted.open()
                    await allowSecondFinish.wait()
                    events.append("second-half-closed")
                },
                shutdown: shutdown
            )
        }

        await firstFinished.wait()
        XCTAssertFalse(events.snapshot().contains("shutdown"))
        allowSecondFinish.open()
        try await task.value

        XCTAssertEqual(
            events.snapshot(),
            [
                "second-started",
                "first-half-closed",
                "second-half-closed",
                "shutdown",
            ]
        )
    }

    func testFirstErrorShutsDownBeforeWaitingForSibling() async {
        let secondStarted = AsyncTestGate()
        let siblingBlocked = AsyncTestGate()
        let events = LockedEvents()
        let shutdown = RelayTaskShutdown { error in
            XCTAssertTrue(error is RelayTaskPairTestError)
            events.append("shutdown")
            siblingBlocked.open()
        }

        do {
            try await RelayTaskPair.run(
                first: {
                    await secondStarted.wait()
                    events.append("first-failed")
                    throw RelayTaskPairTestError.expected
                },
                second: {
                    events.append("second-started")
                    secondStarted.open()
                    await siblingBlocked.wait()
                    events.append("second-finished")
                },
                shutdown: shutdown
            )
            XCTFail("expected relay error")
        } catch {
            XCTAssertTrue(error is RelayTaskPairTestError)
        }

        XCTAssertEqual(
            events.snapshot(),
            [
                "second-started",
                "first-failed",
                "shutdown",
                "second-finished",
            ]
        )
    }

    func testParentCancellationShutsDownBeforeWaitingForChildren() async {
        let firstStarted = AsyncTestGate()
        let secondStarted = AsyncTestGate()
        let childrenBlocked = AsyncTestGate()
        let events = LockedEvents()
        let shutdown = RelayTaskShutdown { error in
            XCTAssertTrue(error is CancellationError)
            events.append("shutdown")
            childrenBlocked.open()
        }

        let task = Task {
            try await RelayTaskPair.run(
                first: {
                    events.append("first-started")
                    firstStarted.open()
                    await childrenBlocked.wait()
                    events.append("first-finished")
                },
                second: {
                    events.append("second-started")
                    secondStarted.open()
                    await childrenBlocked.wait()
                    events.append("second-finished")
                },
                shutdown: shutdown
            )
        }

        await firstStarted.wait()
        await secondStarted.wait()
        task.cancel()

        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let snapshot = events.snapshot()
        guard let shutdownIndex = snapshot.firstIndex(of: "shutdown") else {
            return XCTFail("shutdown was not called")
        }
        XCTAssertLessThan(
            shutdownIndex,
            snapshot.firstIndex(of: "first-finished") ?? snapshot.endIndex
        )
        XCTAssertLessThan(
            shutdownIndex,
            snapshot.firstIndex(of: "second-finished") ?? snapshot.endIndex
        )
        XCTAssertEqual(snapshot.filter { $0 == "shutdown" }.count, 1)
    }

    func testThirdControlOperationTerminatesAssociation() async throws {
        let firstStarted = AsyncTestGate()
        let secondStarted = AsyncTestGate()
        let workersBlocked = AsyncTestGate()
        let events = LockedEvents()
        let shutdown = RelayTaskShutdown { error in
            XCTAssertNil(error)
            events.append("shutdown")
            workersBlocked.open()
        }

        try await RelayTaskGroup.run(
            operations: [
                {
                    events.append("first-started")
                    firstStarted.open()
                    await workersBlocked.wait()
                    events.append("first-finished")
                },
                {
                    events.append("second-started")
                    secondStarted.open()
                    await workersBlocked.wait()
                    events.append("second-finished")
                },
                {
                    await firstStarted.wait()
                    await secondStarted.wait()
                    events.append("control-eof")
                },
            ],
            shutdown: shutdown
        )

        let snapshot = events.snapshot()
        let shutdownIndex = try XCTUnwrap(
            snapshot.firstIndex(of: "shutdown")
        )
        XCTAssertLessThan(
            shutdownIndex,
            try XCTUnwrap(snapshot.firstIndex(of: "first-finished"))
        )
        XCTAssertLessThan(
            shutdownIndex,
            try XCTUnwrap(snapshot.firstIndex(of: "second-finished"))
        )
        XCTAssertEqual(snapshot.filter { $0 == "shutdown" }.count, 1)
        XCTAssertEqual(snapshot.filter { $0 == "control-eof" }.count, 1)
    }
}

private enum RelayTaskPairTestError: Error {
    case expected
}

private final class AsyncTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        guard !isOpen else {
            lock.unlock()
            return
        }
        isOpen = true
        let currentWaiters = waiters
        waiters.removeAll()
        lock.unlock()
        currentWaiters.forEach { $0.resume() }
    }
}

private final class LockedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return events
    }
}
