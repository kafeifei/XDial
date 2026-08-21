import XCTest

final class UnderlayIPv6TLSProbeTests: XCTestCase {
    func testAnyAuthenticatedTLSHandshakeProvesIPv6Available() {
        var decision = UnderlayIPv6TLSProbeDecision(attemptCount: 2)

        decision.record(attempt: 0, successfulTLS: false)
        XCTAssertNil(decision.result)

        decision.record(attempt: 1, successfulTLS: true)
        XCTAssertEqual(decision.result, true)
    }

    func testEveryTerminalFailureProvesIPv6Unavailable() {
        var decision = UnderlayIPv6TLSProbeDecision(attemptCount: 2)

        decision.record(attempt: 1, successfulTLS: false)
        XCTAssertNil(decision.result)

        decision.record(attempt: 0, successfulTLS: false)
        XCTAssertEqual(decision.result, false)
    }

    func testDuplicateTerminalCallbackCannotCompleteAnotherAttempt() {
        var decision = UnderlayIPv6TLSProbeDecision(attemptCount: 2)

        decision.record(attempt: 0, successfulTLS: false)
        decision.record(attempt: 0, successfulTLS: false)

        XCTAssertNil(decision.result)
    }
}
