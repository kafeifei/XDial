import XCTest

final class ProviderRelayRegistryTests: XCTestCase {
    func testDeactivateCancelsAndDrainsEveryAttachedRelay() async {
        let registry = ProviderRelayRegistry<String>()
        registry.activate(generation: "A", endpoint: "endpoint-A")
        let first = RelayFixture()
        let second = RelayFixture()

        let firstReservation = try! XCTUnwrap(registry.reserve())
        let secondReservation = try! XCTUnwrap(registry.reserve())
        XCTAssertTrue(registry.attach(first.handle, to: firstReservation))
        XCTAssertTrue(registry.attach(second.handle, to: secondReservation))
        XCTAssertTrue(first.handle.start {
            registry.finish(firstReservation)
        })
        XCTAssertTrue(second.handle.start {
            registry.finish(secondReservation)
        })
        await first.waitUntilStarted()
        await second.waitUntilStarted()

        let drain = registry.deactivateCurrent()

        XCTAssertEqual(drain.count, 2)
        XCTAssertTrue(drain.wait(timeout: 1))
        XCTAssertEqual(first.shutdownCount, 1)
        XCTAssertEqual(second.shutdownCount, 1)
        XCTAssertEqual(registry.registeredCount, 0)
    }

    func testReservationThatLosesStopRaceCannotAttach() {
        let registry = ProviderRelayRegistry<String>()
        registry.activate(generation: "A", endpoint: "endpoint-A")
        let reservation = try! XCTUnwrap(registry.reserve())
        let fixture = RelayFixture()

        _ = registry.deactivateCurrent()

        XCTAssertFalse(registry.attach(fixture.handle, to: reservation))
        fixture.handle.cancel(with: AppProxyFlowCloseError.aborted)
        XCTAssertEqual(fixture.shutdownCount, 1)
        XCTAssertEqual(registry.registeredCount, 0)
    }

    func testLateOldGenerationFinishCannotTouchNewGeneration() {
        let registry = ProviderRelayRegistry<String>()
        registry.activate(generation: "A", endpoint: "endpoint-A")
        let oldReservation = try! XCTUnwrap(registry.reserve())

        registry.activate(generation: "B", endpoint: "endpoint-B")
        let currentReservation = try! XCTUnwrap(registry.reserve())
        let current = RelayFixture()
        XCTAssertTrue(
            registry.attach(current.handle, to: currentReservation)
        )

        registry.finish(oldReservation)

        XCTAssertEqual(registry.registeredCount, 1)
        let drain = registry.deactivateCurrent()
        XCTAssertEqual(drain.count, 1)
        XCTAssertEqual(current.shutdownCount, 1)
    }

    func testStopBetweenAttachAndStartCancelsDormantHandle() {
        let registry = ProviderRelayRegistry<String>()
        registry.activate(generation: "A", endpoint: "endpoint-A")
        let reservation = try! XCTUnwrap(registry.reserve())
        let fixture = RelayFixture()
        XCTAssertTrue(registry.attach(fixture.handle, to: reservation))

        let drain = registry.deactivateCurrent()

        XCTAssertFalse(fixture.handle.start {})
        XCTAssertTrue(drain.wait(timeout: 1))
        XCTAssertEqual(fixture.shutdownCount, 1)
        XCTAssertEqual(registry.registeredCount, 0)
    }

    func testDeactivateRejectsUntilSystemTakeoverIsGone() {
        let registry = ProviderRelayRegistry<String>()
        registry.activate(generation: "A", endpoint: "endpoint-A")

        let drain = registry.deactivateCurrent()

        guard case .reject = registry.claim() else {
            return XCTFail("teardown must fail new flows closed")
        }
        XCTAssertTrue(registry.isRejecting)

        registry.markInactive(
            generation: try! XCTUnwrap(drain.generation)
        )

        guard case .passThrough = registry.claim() else {
            return XCTFail("pass-through is allowed only after removal")
        }
        XCTAssertFalse(registry.isRejecting)
    }

    func testLateOldRemovalCannotClearNewRejectingGeneration() {
        let registry = ProviderRelayRegistry<String>()
        registry.activate(generation: "A", endpoint: "endpoint-A")
        let oldDrain = registry.deactivateCurrent()

        registry.activate(generation: "B", endpoint: "endpoint-B")
        let currentDrain = registry.deactivateCurrent()
        registry.markInactive(
            generation: try! XCTUnwrap(oldDrain.generation)
        )

        guard case .reject = registry.claim() else {
            return XCTFail("old completion cleared the new tombstone")
        }

        registry.markInactive(
            generation: try! XCTUnwrap(currentDrain.generation)
        )
        guard case .passThrough = registry.claim() else {
            return XCTFail("current completion did not clear tombstone")
        }
    }

    func testImmediatelyFinishingHandleStillDrains() {
        let handle = ProviderRelayHandle(
            shutdown: RelayTaskShutdown { _ in },
            operation: {}
        )

        XCTAssertTrue(handle.start {})
        XCTAssertTrue(handle.wait(until: .now() + 1))
    }

    func testDrainWaitsForRelayCleanupButRemainsBounded() async {
        let registry = ProviderRelayRegistry<String>()
        registry.activate(generation: "A", endpoint: "endpoint-A")
        let cleanupGate = RegistryAsyncGate()
        let fixture = RelayFixture(cleanupGate: cleanupGate)
        let reservation = try! XCTUnwrap(registry.reserve())
        XCTAssertTrue(registry.attach(fixture.handle, to: reservation))
        XCTAssertTrue(fixture.handle.start {
            registry.finish(reservation)
        })
        await fixture.waitUntilStarted()

        let drain = registry.deactivateCurrent()

        XCTAssertFalse(drain.wait(timeout: 0.01))
        cleanupGate.open()
        XCTAssertTrue(drain.wait(timeout: 1))
        XCTAssertEqual(fixture.shutdownCount, 1)
    }
}

private final class RelayFixture: @unchecked Sendable {
    private let shutdownCounter: RelayShutdownCounter
    private let started: RegistryAsyncGate
    private let cleanupGate: RegistryAsyncGate?
    let handle: ProviderRelayHandle

    init(cleanupGate: RegistryAsyncGate? = nil) {
        let started = RegistryAsyncGate()
        let shutdownCounter = RelayShutdownCounter()
        self.started = started
        self.shutdownCounter = shutdownCounter
        self.cleanupGate = cleanupGate
        handle = ProviderRelayHandle(
            shutdown: RelayTaskShutdown { _ in
                shutdownCounter.increment()
            },
            operation: {
                started.open()
                if let cleanupGate {
                    await cleanupGate.wait()
                } else {
                    do {
                        let _: Void = try await awaitRelayCallback { _ in }
                    } catch {
                        // Cancellation is the expected terminal result.
                    }
                }
            }
        )
    }

    var shutdownCount: Int {
        shutdownCounter.value
    }

    func waitUntilStarted() async {
        await started.wait()
    }
}

private final class RelayShutdownCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class RegistryAsyncGate: @unchecked Sendable {
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
