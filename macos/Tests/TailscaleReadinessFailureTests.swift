import XCTest

final class TailscaleReadinessFailureTests: XCTestCase {
    func testTimeoutKeepsBoundedRetryAcrossPresentationAndIPC() throws {
        let underlying = ConnectionRuntimeFailure(
            code: "line-readiness-transient",
            message: "context deadline exceeded",
            taskID: "data-plane:sing-box",
            evidence: nil
        )
        let failure = TailscaleEgressFailure.wrap(
            underlying, taskID: "line:tailscale"
        )
        XCTAssertEqual(failure.taskID, "line:tailscale")
        XCTAssertTrue(failure.message.contains("内置 Tailscale 出口"))
        let response = ProviderScenarioSwitchResponse(
            v: ProviderScenarioSwitchCodec.version,
            cmd: .switchScenario,
            requestID: "hotel-switch",
            ok: false,
            sourceTransactionID: "office-transaction",
            activeTransactionID: "office-transaction",
            code: AutomaticLineReadinessFailurePolicy.switchCode(for: failure.code),
            message: failure.message,
            reportJSON: nil
        )
        let received = try ProviderScenarioSwitchCodec.decodeResponse(
            ProviderScenarioSwitchCodec.encodeResponse(response)
        )
        XCTAssertEqual(received.activeTransactionID, "office-transaction")
        var retry = AutomaticScenarioSwitchRetryState()
        retry.begin(.init(epoch: 26, scenarioGeneration: 1, targetScenarioID: "hotel"))
        for delay in [2.0, 5.0, 10.0] {
            let scheduled = try XCTUnwrap(retry.scheduleRetry(failureCode: received.code))
            XCTAssertEqual(scheduled.delay, delay)
            XCTAssertTrue(retry.takeRetry(scheduled.token))
        }
        XCTAssertNil(retry.scheduleRetry(failureCode: received.code))
    }

    func testTerminalAndInvalidatedFailuresKeepTheirClassification() {
        for code in ["line-readiness-terminal", "line-readiness-cancelled", "network-superseded"] {
            let underlying = ConnectionRuntimeFailure(
                code: code, message: "probe failed", taskID: "data-plane:sing-box", evidence: nil
            )
            let failure = TailscaleEgressFailure.wrap(underlying, taskID: "line:tailscale")
            XCTAssertEqual(failure.code, code)
            var retry = AutomaticScenarioSwitchRetryState()
            retry.begin(.init(epoch: 26, scenarioGeneration: 1, targetScenarioID: "hotel"))
            XCTAssertNil(retry.scheduleRetry(failureCode: failure.code))
        }
    }

    func testUnclassifiedErrorTextDoesNotAuthorizeRetry() {
        let underlying = NSError(
            domain: "unclassified", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "context deadline exceeded: line-readiness-transient"]
        )
        let failure = TailscaleEgressFailure.wrap(underlying, taskID: "line:tailscale")
        XCTAssertEqual(failure.code, "scenario-switch-prepare-failed")
    }
}
