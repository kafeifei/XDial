import XCTest

final class RelayPendingOperationTests: XCTestCase {
    func testCancellationCompletesWhenFrameworkCallbackNeverRuns() async {
        let installed = expectation(description: "callback installed")
        let finished = expectation(description: "task finished")
        let outcome = LockedBool()

        let task = Task {
            do {
                let _: Void = try await awaitRelayCallback { _ in
                    installed.fulfill()
                }
            } catch is CancellationError {
                outcome.set(true)
            } catch {
                outcome.set(false)
            }
            finished.fulfill()
        }

        await fulfillment(of: [installed], timeout: 1)
        task.cancel()
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertTrue(outcome.value)
    }

    func testLateCallbackLosesAfterCancellation() {
        let pending = RelayPendingOperation<Int>()
        XCTAssertTrue(pending.cancel())
        XCTAssertFalse(pending.finish(.success(7)))
    }

    func testCallbackAndCancellationHaveExactlyOneWinner() {
        for _ in 0 ..< 200 {
            let pending = RelayPendingOperation<Int>()
            let winners = LockedInt()
            let group = DispatchGroup()

            group.enter()
            DispatchQueue.global().async {
                if pending.finish(.success(1)) {
                    winners.increment()
                }
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                if pending.cancel() {
                    winners.increment()
                }
                group.leave()
            }

            XCTAssertEqual(group.wait(timeout: .now() + 1), .success)
            XCTAssertEqual(winners.value, 1)
        }
    }
}

private final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Bool) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}

private final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
