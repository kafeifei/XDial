import XCTest

final class RelayAssociationSlotTests: XCTestCase {
    private final class Association {}

    func testInitialPayloadWaitsForFirstReadyAssociation() async throws {
        let slot = RelayAssociationSlot<Association>()
        let association = Association()
        let waiting = Task {
            try await slot.waitForCurrent()
        }

        await Task.yield()
        let result = slot.adopt(association)
        let received = try await waiting.value

        XCTAssertTrue(result.accepted)
        XCTAssertTrue(received === association)
    }

    func testCloseReleasesWaiterWithoutAnAssociation() async throws {
        let slot = RelayAssociationSlot<Association>()
        let waiting = Task {
            try await slot.waitForCurrent()
        }

        await Task.yield()
        XCTAssertTrue(slot.close().didClose)
        let received = try await waiting.value
        XCTAssertNil(received)
    }

    func testCancellationReleasesWaiter() async {
        let slot = RelayAssociationSlot<Association>()
        let waiting = Task {
            try await slot.waitForCurrent()
        }

        await Task.yield()
        waiting.cancel()

        do {
            _ = try await waiting.value
            XCTFail("cancelled waiter unexpectedly returned")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testReleasedAssociationIsNotReturnedToFollowingWaiter() async throws {
        let slot = RelayAssociationSlot<Association>()
        let first = Association()
        let second = Association()
        XCTAssertTrue(slot.adopt(first).accepted)
        slot.release(first)

        let waiting = Task {
            try await slot.waitForCurrent()
        }
        await Task.yield()
        XCTAssertTrue(slot.adopt(second).accepted)

        let received = try await waiting.value
        XCTAssertTrue(received === second)
    }

    func testHealthDurationStartsOnlyAfterAssociationIsReady() {
        let handshakeStarted = Date(timeIntervalSince1970: 100)
        let readyAt = handshakeStarted.addingTimeInterval(1.1)
        var clock = RelayAssociationHealthClock()

        XCTAssertEqual(clock.duration(endingAt: readyAt), 0)

        clock.markReady(at: readyAt)
        XCTAssertEqual(
            clock.duration(endingAt: readyAt.addingTimeInterval(0.4)),
            0.4,
            accuracy: 0.000_001
        )
    }

    func testSlowFailedHandshakeDoesNotResetRetryBudget() {
        var budget = RelayReassociationBudget()
        var clock = RelayAssociationHealthClock()
        let start = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(
            budget.nextDelay(
                afterAssociationLasting: clock.duration(
                    endingAt: start.addingTimeInterval(1.1)
                ),
                now: start.addingTimeInterval(1.1)
            ),
            0
        )

        clock.markReady(at: start.addingTimeInterval(2))
        XCTAssertEqual(
            budget.nextDelay(
                afterAssociationLasting: clock.duration(
                    endingAt: start.addingTimeInterval(2.2)
                ),
                now: start.addingTimeInterval(2.2)
            ),
            0.1
        )
        XCTAssertEqual(budget.attempt, 2)
    }
}
