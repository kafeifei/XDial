import XCTest

@MainActor
final class NetworkInfoTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testSchedulesAllIPv4BeforeAvailableIPv6() {
        let subject = NetworkInfo()
        XCTAssertEqual(
            subject.begin(
                transactionID: "tx",
                lineIDs: ["first", "second"],
                capabilities: [
                    "first": .dualStack,
                    "second": LineAddressFamilyCapability(
                        ipv4Available: true,
                        ipv6Available: false
                    ),
                ],
                now: start
            ),
            [
                request("first", .ipv4),
                request("second", .ipv4),
                request("first", .ipv6),
            ]
        )
        XCTAssertEqual(
            subject.observation(for: "first", transactionID: "tx")?.ipv4?.phase,
            .querying
        )
        XCTAssertEqual(
            subject.observation(for: "first", transactionID: "tx")?.ipv6?.phase,
            .querying
        )
    }

    func testFailureRetriesAtDeadlineAndSuccessStopsFurtherRequests() {
        let subject = NetworkInfo()
        XCTAssertEqual(
            subject.begin(transactionID: "tx", lineIDs: ["line"], now: start),
            [request("line", .ipv4)]
        )
        subject.recordFailure(
            code: "timeout",
            lineID: "line",
            transactionID: "tx",
            observedAt: start
        )

        XCTAssertEqual(subject.nextRetryDate, start.addingTimeInterval(2))
        XCTAssertEqual(
            subject.observation(for: "line", transactionID: "tx")?.ipv4?.phase,
            .waiting
        )
        XCTAssertTrue(subject.begin(
            transactionID: "tx", lineIDs: ["line"],
            now: start.addingTimeInterval(1.999)
        ).isEmpty)
        XCTAssertEqual(
            subject.begin(
                transactionID: "tx", lineIDs: ["line"],
                now: start.addingTimeInterval(2)
            ),
            [request("line", .ipv4)]
        )

        subject.recordAddress(
            "192.0.2.10",
            lineID: "line",
            transactionID: "tx",
            observedAt: start.addingTimeInterval(2)
        )
        XCTAssertNil(subject.nextRetryDate)
        XCTAssertTrue(subject.begin(
            transactionID: "tx", lineIDs: ["line"],
            now: start.addingTimeInterval(1_000)
        ).isEmpty)
        XCTAssertEqual(
            subject.observation(for: "line", transactionID: "tx")?.ipv4?.address,
            "192.0.2.10"
        )
        XCTAssertEqual(
            subject.observation(for: "line", transactionID: "tx")?.ipv4?.phase,
            .available
        )
    }

    func testBeginDoesNotDuplicateInflightRequest() {
        let subject = NetworkInfo()
        XCTAssertEqual(
            subject.begin(transactionID: "tx", lineIDs: ["line"], now: start),
            [request("line", .ipv4)]
        )
        XCTAssertTrue(subject.begin(
            transactionID: "tx", lineIDs: ["line"], now: start
        ).isEmpty)
        XCTAssertFalse(subject.retry(
            lineID: "line", transactionID: "tx", family: .ipv4, now: start
        ))
    }

    func testTransactionSwitchRejectsOldCallback() {
        let subject = NetworkInfo()
        _ = subject.begin(transactionID: "old", lineIDs: ["line"], now: start)
        XCTAssertEqual(
            subject.begin(transactionID: "new", lineIDs: ["line"], now: start),
            [request("line", .ipv4)]
        )

        subject.recordAddress(
            "192.0.2.1", lineID: "line", transactionID: "old", observedAt: start
        )
        XCTAssertNil(subject.observation(for: "line", transactionID: "old"))
        XCTAssertEqual(
            subject.observation(for: "line", transactionID: "new")?.ipv4?.phase,
            .querying
        )
        XCTAssertEqual(
            subject.observation(for: "line", transactionID: "new")?.ipv4?.address,
            ""
        )

        subject.recordAddress(
            "192.0.2.2", lineID: "line", transactionID: "new", observedAt: start
        )
        XCTAssertEqual(
            subject.observation(for: "line", transactionID: "new")?.ip,
            "192.0.2.2"
        )
    }

    func testClearCancelsInflightAndScheduledRetry() {
        let subject = NetworkInfo()
        _ = subject.begin(
            transactionID: "tx",
            lineIDs: ["line"],
            capabilities: ["line": .dualStack],
            now: start
        )
        subject.recordFailure(
            code: "timeout", lineID: "line", transactionID: "tx", observedAt: start
        )
        subject.recordFailure(
            code: "timeout", lineID: "line", transactionID: "tx",
            family: .ipv6, observedAt: start
        )
        XCTAssertNotNil(subject.nextRetryDate)

        subject.clear()
        subject.recordAddress(
            "192.0.2.1", lineID: "line", transactionID: "tx", observedAt: start
        )
        XCTAssertNil(subject.transactionID)
        XCTAssertNil(subject.nextRetryDate)
        XCTAssertTrue(subject.perLine.isEmpty)
    }

    func testWrongAddressFamilyIsFailure() {
        let subject = NetworkInfo()
        _ = subject.begin(transactionID: "tx", lineIDs: ["line"], now: start)
        subject.recordAddress(
            "2001:db8::1", lineID: "line", transactionID: "tx",
            family: .ipv4, observedAt: start
        )

        let observation = subject.observation(for: "line", transactionID: "tx")?.ipv4
        XCTAssertEqual(observation?.address, "")
        XCTAssertEqual(observation?.errorCode, "invalid-outbound-address")
        XCTAssertEqual(subject.nextRetryDate, start.addingTimeInterval(2))
    }

    func testUnavailableIPv6IsNeverProbed() {
        let subject = NetworkInfo()
        let capability = LineAddressFamilyCapability(
            ipv4Available: true,
            ipv6Available: false
        )
        XCTAssertEqual(
            subject.begin(
                transactionID: "tx", lineIDs: ["line"],
                capabilities: ["line": capability], now: start
            ),
            [request("line", .ipv4)]
        )
        subject.recordAddress(
            "192.0.2.1", lineID: "line", transactionID: "tx", observedAt: start
        )
        XCTAssertTrue(subject.begin(
            transactionID: "tx", lineIDs: ["line"],
            capabilities: ["line": capability], now: start.addingTimeInterval(100)
        ).isEmpty)
    }

    func testDualStackRetainsSuccessfulFamilyWhileRetryingFailedFamily() {
        let subject = NetworkInfo()
        let capabilities = ["line": LineAddressFamilyCapability.dualStack]
        XCTAssertEqual(
            subject.begin(
                transactionID: "tx", lineIDs: ["line"],
                capabilities: capabilities, now: start
            ),
            [request("line", .ipv4), request("line", .ipv6)]
        )
        subject.recordAddress(
            "192.0.2.1", lineID: "line", transactionID: "tx",
            family: .ipv4, observedAt: start
        )
        subject.recordFailure(
            code: "timeout", lineID: "line", transactionID: "tx",
            family: .ipv6, observedAt: start
        )

        XCTAssertEqual(
            subject.begin(
                transactionID: "tx", lineIDs: ["line"],
                capabilities: capabilities, now: start.addingTimeInterval(2)
            ),
            [request("line", .ipv6)]
        )
        subject.recordAddress(
            "2001:db8::1", lineID: "line", transactionID: "tx",
            family: .ipv6, observedAt: start.addingTimeInterval(2)
        )
        let info = subject.observation(for: "line", transactionID: "tx")
        XCTAssertEqual(info?.ipv4?.address, "192.0.2.1")
        XCTAssertEqual(info?.ipv6?.address, "2001:db8::1")
    }

    func testFourthFailureTerminatesAutomaticRetries() {
        let subject = NetworkInfo()
        _ = subject.begin(transactionID: "tx", lineIDs: ["line"], now: start)
        var failureAt = start
        for delay: TimeInterval in [2, 5, 10] {
            subject.recordFailure(
                code: "timeout", lineID: "line", transactionID: "tx",
                observedAt: failureAt
            )
            let retryAt = failureAt.addingTimeInterval(delay)
            XCTAssertEqual(subject.nextRetryDate, retryAt)
            XCTAssertEqual(
                subject.begin(
                    transactionID: "tx", lineIDs: ["line"], now: retryAt
                ),
                [request("line", .ipv4)]
            )
            failureAt = retryAt
        }
        subject.recordFailure(
            code: "timeout", lineID: "line", transactionID: "tx",
            observedAt: failureAt
        )
        XCTAssertNil(subject.nextRetryDate)
        XCTAssertEqual(
            subject.observation(for: "line", transactionID: "tx")?.ipv4?.phase,
            .failed
        )
        XCTAssertTrue(subject.begin(
            transactionID: "tx", lineIDs: ["line"],
            now: failureAt.addingTimeInterval(10_000)
        ).isEmpty)
    }

    func testManualRetryStartsFreshBudgetAndRejectsRepeatedClick() {
        let subject = NetworkInfo()
        failFourTimes(subject, lineID: "line", family: .ipv4)

        let manualAt = start.addingTimeInterval(100)
        XCTAssertTrue(subject.retry(
            lineID: "line", transactionID: "tx", family: .ipv4, now: manualAt
        ))
        XCTAssertEqual(
            subject.observation(for: "line", transactionID: "tx")?.ipv4?.phase,
            .querying
        )
        XCTAssertFalse(subject.retry(
            lineID: "line", transactionID: "tx", family: .ipv4, now: manualAt
        ))
        XCTAssertEqual(
            subject.begin(
                transactionID: "tx", lineIDs: ["line"], now: manualAt
            ),
            [request("line", .ipv4)]
        )
        subject.recordFailure(
            code: "timeout", lineID: "line", transactionID: "tx",
            observedAt: manualAt
        )
        XCTAssertEqual(subject.nextRetryDate, manualAt.addingTimeInterval(2))
        var failureAt = manualAt
        for delay: TimeInterval in [2, 5, 10] {
            let retryAt = failureAt.addingTimeInterval(delay)
            XCTAssertEqual(
                subject.begin(
                    transactionID: "tx", lineIDs: ["line"], now: retryAt
                ),
                [request("line", .ipv4)]
            )
            failureAt = retryAt
            subject.recordFailure(
                code: "timeout", lineID: "line", transactionID: "tx",
                observedAt: failureAt
            )
        }
        XCTAssertNil(subject.nextRetryDate)
        XCTAssertEqual(
            subject.observation(for: "line", transactionID: "tx")?.ipv4?.phase,
            .failed
        )
    }

    func testUnavailableFamilyCannotBeManuallyRetried() {
        let subject = NetworkInfo()
        _ = subject.begin(
            transactionID: "tx",
            lineIDs: ["line"],
            capabilities: [
                "line": LineAddressFamilyCapability(
                    ipv4Available: true,
                    ipv6Available: false
                ),
            ],
            now: start
        )
        XCTAssertFalse(subject.retry(
            lineID: "line", transactionID: "tx", family: .ipv6, now: start
        ))
    }

    func testDualStackFailureBudgetsAreIndependent() {
        let subject = NetworkInfo()
        let capabilities = ["line": LineAddressFamilyCapability.dualStack]
        _ = subject.begin(
            transactionID: "tx", lineIDs: ["line"],
            capabilities: capabilities, now: start
        )
        subject.recordFailure(
            code: "v4-timeout", lineID: "line", transactionID: "tx",
            family: .ipv4, observedAt: start
        )
        subject.recordAddress(
            "2001:db8::1", lineID: "line", transactionID: "tx",
            family: .ipv6, observedAt: start
        )
        XCTAssertEqual(
            subject.begin(
                transactionID: "tx", lineIDs: ["line"],
                capabilities: capabilities, now: start.addingTimeInterval(2)
            ),
            [request("line", .ipv4)]
        )
        XCTAssertEqual(
            subject.observation(for: "line", transactionID: "tx")?.ipv6?.phase,
            .available
        )
    }

    private func failFourTimes(
        _ subject: NetworkInfo,
        lineID: String,
        family: LineAddressFamily
    ) {
        let capabilities = [lineID: LineAddressFamilyCapability.dualStack]
        _ = subject.begin(
            transactionID: "tx", lineIDs: [lineID],
            capabilities: capabilities, now: start
        )
        var failureAt = start
        for delay: TimeInterval in [2, 5, 10] {
            subject.recordFailure(
                code: "timeout", lineID: lineID, transactionID: "tx",
                family: family, observedAt: failureAt
            )
            failureAt = failureAt.addingTimeInterval(delay)
            _ = subject.begin(
                transactionID: "tx", lineIDs: [lineID],
                capabilities: capabilities, now: failureAt
            )
        }
        subject.recordFailure(
            code: "timeout", lineID: lineID, transactionID: "tx",
            family: family, observedAt: failureAt
        )
    }

    private func request(
        _ lineID: String,
        _ family: LineAddressFamily
    ) -> LineAddressRequest {
        LineAddressRequest(lineID: lineID, family: family)
    }
}
