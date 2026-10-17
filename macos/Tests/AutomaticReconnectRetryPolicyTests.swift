import XCTest

final class AutomaticReconnectRetryPolicyTests: XCTestCase {
    func testRetriesOnlyCompletedUnderlayEgressFailure() {
        let policy = AutomaticReconnectRetryPolicy(
            delays: [2, 5, 10, 20, 30]
        )
        let report = failedReport(
            code: ConnectionFailureCode.underlayEgressUnavailable
        )

        XCTAssertEqual(
            policy.delay(
                after: report,
                attemptsUsed: 0,
                trigger: .underlayChange
            ),
            2
        )
        XCTAssertEqual(
            policy.delay(
                after: report,
                attemptsUsed: 1,
                trigger: .underlayChange
            ),
            5
        )
        XCTAssertEqual(
            policy.delay(
                after: report,
                attemptsUsed: 4,
                trigger: .underlayChange
            ),
            30
        )
        XCTAssertNil(policy.delay(
            after: report,
            attemptsUsed: 5,
            trigger: .underlayChange
        ))
        XCTAssertEqual(policy.maxAttempts, 5)
        XCTAssertEqual(policy.stableResetInterval, 300)
    }

    func testUnexpectedDisconnectRecoveryCanRetryACompletedLineFailure() {
        let policy = AutomaticReconnectRetryPolicy()
        let report = failedReport(
            code: "tailscale-peer-handshake-failed"
        )

        XCTAssertEqual(
            policy.delay(
                after: report,
                attemptsUsed: 0,
                trigger: .unexpectedDisconnect
            ),
            2
        )
    }

    func testUnderlayRecoveryDoesNotRetryLineOrHandshakeFailures() {
        let policy = AutomaticReconnectRetryPolicy()

        XCTAssertNil(policy.delay(
            after: failedReport(
                code: "tailscale-peer-handshake-failed"
            ),
            attemptsUsed: 0,
            trigger: .underlayChange
        ))
        XCTAssertNil(policy.delay(
            after: failedReport(
                code: "tailscale-exit-node-unavailable"
            ),
            attemptsUsed: 0,
            trigger: .underlayChange
        ))
    }

    func testLaunchAutoConnectCanRetryACompletedLineFailure() {
        let policy = AutomaticReconnectRetryPolicy()
        let report = failedReport(code: "tailscale-peer-handshake-failed")

        XCTAssertEqual(
            policy.delay(
                after: report,
                attemptsUsed: 0,
                trigger: .automaticConnection
            ),
            2
        )
    }

    func testTerminalCodesStopFullRecoveryImmediately() throws {
        let policy = AutomaticReconnectRetryPolicy()
        var reports = [
            "tailscale-login-required",
            "tailscale-unavailable",
            "tailscale-status-invalid",
            "tailscale-exit-node-unavailable",
            "line-readiness-terminal",
            "anyconnect-peer-terminate",
        ].map { failedReport(code: $0) }
        for category in ["authentication", "policy", "duplicate-session"] {
            reports.append(failedReport(
                code: "anyconnect-peer-disconnect",
                evidence: try peerDisconnectEvidence(category: category)
            ))
        }

        for report in reports {
            for trigger in [
                AutomaticReconnectTrigger.automaticConnection,
                .unexpectedDisconnect,
            ] {
                XCTAssertFalse(
                    policy.qualifies(report, trigger: trigger),
                    "\(report.error!.code) \(trigger)"
                )
                XCTAssertNil(policy.delay(
                    after: report,
                    attemptsUsed: 0,
                    trigger: trigger
                ), "\(report.error!.code) \(trigger)")
            }
            // The stop keeps the transaction's own error for presentation.
            XCTAssertEqual(report.error?.message, report.error?.code)
        }
    }

    func testTransientCodesRetryWithinTheSharedBudget() throws {
        let policy = AutomaticReconnectRetryPolicy()
        var reports = [
            "line-readiness-transient",
            ConnectionFailureCode.underlayEgressUnavailable,
            "tailscale-home-derp-not-ready",
            "tailscale-readiness-timeout",
            "anyconnect-line-reconnect-timeout",
            HostUnderlayCaptureFailureReason.pathUnsatisfied.rawValue,
            HostUnderlayCaptureFailureReason.defaultRouteUnavailable.rawValue,
            ConnectionFailureCode.providerSessionLost,
            "interrupted-transaction-recovered",
            "data-plane-failed",
            "anyconnect-tls-dpd-timeout",
            "anyconnect-tls-read-timeout",
            "line-address-family-unavailable",
            "line-address-family-capability-changed",
            ProxyResourceReadiness.lineFailureCode,
            "network-superseded",
        ].map { failedReport(code: $0) }
        for category in ["idle-timeout", "session-timeout"] {
            reports.append(failedReport(
                code: "anyconnect-peer-disconnect",
                evidence: try peerDisconnectEvidence(category: category)
            ))
        }

        for report in reports {
            for trigger in [
                AutomaticReconnectTrigger.automaticConnection,
                .unexpectedDisconnect,
            ] {
                XCTAssertEqual(
                    (0 ..< 5).compactMap {
                        policy.delay(
                            after: report,
                            attemptsUsed: $0,
                            trigger: trigger
                        )
                    },
                    [2, 5, 10, 20, 30],
                    "\(report.error!.code) \(trigger)"
                )
                XCTAssertNil(policy.delay(
                    after: report,
                    attemptsUsed: 5,
                    trigger: trigger
                ))
                // Out of budget, the failure still qualifies: exhausted,
                // not terminal.
                XCTAssertTrue(policy.qualifies(report, trigger: trigger))
            }
        }
    }

    /// Unknown codes follow Scenario Switch: no structured proof of a
    /// transient fault means no retry, whatever the display text says.
    func testUnknownCodesDoNotRetryEvenWithTimeoutText() throws {
        let policy = AutomaticReconnectRetryPolicy()
        var reports = [
            "prepare-failed",
            "scenario-switch-prepare-failed",
            "host-start-failed",
            "rule-set-refresh-failed",
            "future-unclassified-code",
        ].map {
            failedReport(
                code: $0,
                message: "context deadline exceeded: line-readiness-transient"
            )
        }
        reports.append(failedReport(code: "anyconnect-peer-disconnect"))
        reports.append(failedReport(
            code: "anyconnect-peer-disconnect",
            evidence: try peerDisconnectEvidence(category: "other")
        ))

        for report in reports {
            for trigger in [
                AutomaticReconnectTrigger.automaticConnection,
                .unexpectedDisconnect,
            ] {
                XCTAssertNil(policy.delay(
                    after: report,
                    attemptsUsed: 0,
                    trigger: trigger
                ), "\(report.error!.code) \(trigger)")
            }
        }
        XCTAssertFalse(AutomaticReconnectFailurePolicy.isTransient(nil))
    }

    func testRuntimeStateExposesRetryCountdown() {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let state = AutomaticReconnectRuntimeState(
            inProgress: true,
            trigger: .automaticConnection,
            attemptsUsed: 1,
            maxAttempts: 5,
            stableResetAt: nil,
            retryAt: now.addingTimeInterval(2),
            retryAttempt: 1
        )

        XCTAssertEqual(
            state.retryCountdownSeconds(
                at: now.addingTimeInterval(0.1)
            ),
            2
        )
        XCTAssertEqual(
            state.retryCountdownSeconds(
                at: now.addingTimeInterval(1.1)
            ),
            1
        )
        XCTAssertEqual(
            state.retryCountdownSeconds(
                at: now.addingTimeInterval(2.1)
            ),
            0
        )
        XCTAssertEqual(state.retryAttempt, 1)
    }

    func testRuntimeStateExposesStructuredUnderlayWaitReason() {
        let evidence = HostUnderlayCaptureEvidence(
            schemaVersion: 1,
            reason: .pathUnsatisfied,
            pathStatus: "unsatisfied",
            routeInterface: "",
            candidateInterfaces: ["en0"],
            invalidCandidateInterfaces: [],
            routeError: ""
        )
        let state = AutomaticReconnectRuntimeState(
            inProgress: true,
            trigger: .unexpectedDisconnect,
            attemptsUsed: 0,
            maxAttempts: 5,
            stableResetAt: nil,
            retryAt: nil,
            retryAttempt: nil,
            underlayWaitEvidence: evidence
        )

        XCTAssertEqual(state.underlayWaitEvidence, evidence)
    }

    func testDoesNotRetryBeforeRollbackCompletes() {
        let policy = AutomaticReconnectRetryPolicy()
        var report = failedReport(
            code: ConnectionFailureCode.underlayEgressUnavailable
        )
        report.rollbackComplete = false

        XCTAssertNil(policy.delay(
            after: report,
            attemptsUsed: 0,
            trigger: .unexpectedDisconnect
        ))
    }

    func testFiveAttemptBudgetHasNoSixthDelay() {
        let policy = AutomaticReconnectRetryPolicy()
        XCTAssertEqual(
            (0 ..< 5).compactMap {
                policy.delayForNextAttempt(attemptsUsed: $0)
            },
            [2, 5, 10, 20, 30]
        )
        XCTAssertNil(policy.delayForNextAttempt(attemptsUsed: 5))
    }

    func testUnderlayWaitDoesNotConsumeConnectionAttemptBudget() {
        var budget = AutomaticReconnectAttemptBudget(maxAttempts: 5)

        XCTAssertEqual(budget.nextAttempt, 1)
        XCTAssertEqual(budget.attemptsUsed, 0)

        // Repeated host snapshot failures reserve the same first attempt;
        // no connection transaction has started yet.
        XCTAssertEqual(budget.nextAttempt, 1)
        XCTAssertEqual(budget.nextAttempt, 1)
        XCTAssertEqual(budget.attemptsUsed, 0)

        XCTAssertTrue(budget.recordStarted(1))
        XCTAssertEqual(budget.attemptsUsed, 1)
        XCTAssertEqual(budget.nextAttempt, 2)
        XCTAssertFalse(budget.recordStarted(1))
        XCTAssertFalse(budget.recordStarted(3))

        for attempt in 2 ... 5 {
            XCTAssertTrue(budget.recordStarted(attempt))
        }
        XCTAssertNil(budget.nextAttempt)

        budget.reset()
        XCTAssertEqual(budget.attemptsUsed, 0)
        XCTAssertEqual(budget.nextAttempt, 1)
    }

    func testUnderlayWaitUsesShortestRetryCadence() {
        let policy = AutomaticReconnectRetryPolicy(
            delays: [2, 5, 10, 20, 30]
        )

        XCTAssertEqual(policy.underlayWaitRetryDelay, 2)
    }

    private func failedReport(
        code: String,
        message: String? = nil,
        evidence: AnyConnectFailureEvidence? = nil
    ) -> ConnectionReport {
        let plan = ConnectionPlan(
            schemaVersion: 3,
            scenario: ConnectionPlanScenario(id: "scenario", name: "Scenario"),
            tasks: [
                ConnectionPlanTask(
                    id: "underlay:system",
                    kind: "underlay",
                    name: "Underlay",
                    preparation: "capture"
                ),
            ]
        )
        var report = ConnectionReport(
            transactionID: "transaction",
            plan: plan
        )
        report.updateTask(
            id: "underlay:system",
            state: .running
        )
        report.fail(
            code: code,
            message: message ?? code,
            taskID: "underlay:system",
            evidence: evidence.map {
                ConnectionFailureEvidence(anyConnect: $0)
            }
        )
        report.setState(.rollingBack)
        report.rollbackSessionTasks(
            systemTakeoverRemoved: true,
            cleanupComplete: true,
            finalState: .failed
        )
        return report
    }

    private func peerDisconnectEvidence(
        category: String
    ) throws -> AnyConnectFailureEvidence {
        let raw = """
        {
          "schema_version": 1,
          "force_dpd_seconds": 0,
          "negotiated": {
            "tls_dpd_seconds": 30,
            "tls_keepalive_seconds": 20,
            "dtls_dpd_seconds": 30,
            "dtls_keepalive_seconds": 20
          },
          "tls": {
            "effective_dpd_seconds": 30,
            "dpd_requests_queued": 0,
            "dpd_requests_dropped": 0,
            "dpd_requests_written": 0,
            "dpd_responses_received": 0,
            "peer_dpd_requests_received": 0,
            "keepalives_received": 0
          },
          "dtls": {
            "effective_dpd_seconds": 30,
            "dpd_requests_queued": 0,
            "dpd_requests_dropped": 0,
            "dpd_requests_written": 0,
            "dpd_responses_received": 0,
            "peer_dpd_requests_received": 0,
            "keepalives_received": 0,
            "ever_connected": true,
            "currently_connected": false
          },
          "close": {
            "code": "peer-disconnect",
            "channel": "tls",
            "operation": "read",
            "error_class": "peer",
            "occurred_at_unix_milli": 1000,
            "peer_reason_category": "\(category)"
          }
        }
        """
        return try JSONDecoder().decode(
            AnyConnectFailureEvidence.self,
            from: Data(raw.utf8)
        )
    }
}
