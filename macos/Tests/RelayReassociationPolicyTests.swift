import XCTest

final class RelayReassociationPolicyTests: XCTestCase {
    func testFirstReassociationIsImmediateThenBacksOff() {
        let policy = RelayReassociationPolicy.default

        XCTAssertEqual(policy.delay(forAttempt: 1, elapsed: 0), 0)
        XCTAssertEqual(policy.delay(forAttempt: 2, elapsed: 0), 0.1)
        XCTAssertEqual(policy.delay(forAttempt: 3, elapsed: 0.1), 0.3)
        XCTAssertEqual(policy.delay(forAttempt: 4, elapsed: 0.4), 1)
    }

    func testBudgetIsExhaustedByAttemptsAndByWallClock() {
        let policy = RelayReassociationPolicy.default

        XCTAssertNil(
            policy.delay(forAttempt: policy.delays.count + 1, elapsed: 0)
        )
        XCTAssertNil(policy.delay(forAttempt: 1, elapsed: policy.budget))
        XCTAssertNil(
            policy.delay(forAttempt: 4, elapsed: policy.budget - 0.5)
        )
    }

    func testEveryScheduledAttemptFitsInsideTheBudget() {
        let policy = RelayReassociationPolicy.default
        var elapsed: TimeInterval = 0

        for attempt in 1 ... policy.delays.count {
            let delay = policy.delay(forAttempt: attempt, elapsed: elapsed)
            XCTAssertNotNil(delay, "attempt \(attempt) lost its budget")
            elapsed += delay ?? 0
        }

        XCTAssertLessThanOrEqual(elapsed, policy.budget)
    }

    func testBudgetGivesUpAfterRepeatedImmediateFailures() {
        var budget = RelayReassociationBudget()
        let start = Date(timeIntervalSince1970: 0)
        var now = start
        var attempts = 0

        while let delay = budget.nextDelay(
            afterAssociationLasting: 0,
            now: now
        ) {
            attempts += 1
            now = now.addingTimeInterval(delay)
            XCTAssertLessThan(attempts, 100)
        }

        XCTAssertEqual(attempts, RelayReassociationPolicy.default.delays.count)
        XCTAssertLessThanOrEqual(
            now.timeIntervalSince(start),
            RelayReassociationPolicy.default.budget
        )
    }

    func testHealthyAssociationRestartsTheBudget() {
        var budget = RelayReassociationBudget()
        let now = Date(timeIntervalSince1970: 0)

        XCTAssertEqual(budget.nextDelay(afterAssociationLasting: 0, now: now), 0)
        XCTAssertEqual(
            budget.nextDelay(afterAssociationLasting: 0, now: now),
            0.1
        )

        // A generation which carried traffic for a while is not a retry storm.
        XCTAssertEqual(
            budget.nextDelay(afterAssociationLasting: 30, now: now),
            0
        )
        XCTAssertEqual(budget.attempt, 1)
    }

    func testShortLivedAssociationKeepsConsumingTheBudget() {
        var budget = RelayReassociationBudget()
        let start = Date(timeIntervalSince1970: 0)

        _ = budget.nextDelay(afterAssociationLasting: 0.2, now: start)
        _ = budget.nextDelay(
            afterAssociationLasting: 0.2,
            now: start.addingTimeInterval(0.2)
        )

        XCTAssertEqual(budget.attempt, 2)
        XCTAssertNil(
            budget.nextDelay(
                afterAssociationLasting: 0.2,
                now: start.addingTimeInterval(
                    RelayReassociationPolicy.default.budget
                )
            )
        )
    }
}
