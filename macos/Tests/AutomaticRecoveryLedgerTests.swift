import XCTest

final class AutomaticRecoveryLedgerTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 10_000)

    // MARK: - Budget per epoch

    func testEpisodeInNewEpochGetsFreshBudgetAndSameEpochContinues() {
        var ledger = AutomaticRecoveryLedger()
        XCTAssertTrue(ledger.beginEpisode(in: epoch("utun12"), at: start))
        consume(&ledger, attempts: 3)
        XCTAssertEqual(ledger.nextAttempt, 4)

        // A short success then a drop in the same epoch keeps the budget:
        // short-lived connections do not reset it.
        XCTAssertFalse(ledger.beginEpisode(in: epoch("utun12"), at: start))
        XCTAssertEqual(ledger.nextAttempt, 4)

        XCTAssertTrue(ledger.beginEpisode(in: epoch("en0"), at: start))
        XCTAssertEqual(ledger.attemptsUsed, 0)
        XCTAssertEqual(ledger.nextAttempt, 1)
    }

    func testUnderlayWaitDoesNotConsumeEpochBudget() {
        var ledger = AutomaticRecoveryLedger()
        ledger.beginEpisode(in: epoch("en0"), at: start)

        // Waiting for a usable Underlay re-reads the same next attempt.
        XCTAssertEqual(ledger.nextAttempt, 1)
        XCTAssertEqual(ledger.nextAttempt, 1)
        XCTAssertEqual(ledger.attemptsUsed, 0)
        XCTAssertTrue(ledger.recordStarted(1))
        XCTAssertFalse(ledger.recordStarted(1))
        XCTAssertEqual(ledger.nextAttempt, 2)
    }

    func testFiveStableMinutesResetTheBudget() {
        var ledger = AutomaticRecoveryLedger()
        ledger.beginEpisode(in: epoch("en0"), at: start)
        consume(&ledger, attempts: 5)
        XCTAssertTrue(ledger.isExhausted)

        ledger.stableReset()

        XCTAssertEqual(ledger.attemptsUsed, 0)
        XCTAssertNil(ledger.budgetEpoch)
        // The next episode in the same network starts from a full budget.
        XCTAssertTrue(ledger.beginEpisode(in: epoch("en0"), at: start))
        XCTAssertEqual(ledger.nextAttempt, 1)
    }

    func testUserConnectionGrantsFreshBudgetAndEndsParking() {
        var ledger = parkedLedger(on: "utun12")

        ledger.noteUserConnection(at: start.addingTimeInterval(60))

        XCTAssertFalse(ledger.isParked)
        XCTAssertEqual(ledger.attemptsUsed, 0)
        XCTAssertEqual(ledger.lastGrant?.reason, .userConnect)
        XCTAssertTrue(ledger.beginEpisode(in: epoch("utun12"), at: start))
    }

    // MARK: - Parking and failure classification

    func testExhaustedNetworkFailureParksWithIntentKept() {
        var ledger = AutomaticRecoveryLedger()
        ledger.beginEpisode(in: epoch("utun12"), at: start)
        consume(&ledger, attempts: 5)

        XCTAssertTrue(ledger.park(
            epoch: epoch("utun12"),
            failure: failure("line-address-family-unavailable"),
            at: start
        ))
        XCTAssertTrue(ledger.isParked)
        XCTAssertEqual(
            ledger.parking?.failureCode,
            "line-address-family-unavailable"
        )
        let projection = ledger.projection(at: start)
        XCTAssertTrue(projection.parked)
        XCTAssertEqual(projection.parkedScenarioID, "home")
    }

    func testIdentityTerminalFailuresNeverParkOrGrant() {
        for code in [
            "tailscale-login-required",
            "tailscale-status-invalid",
            "anyconnect-peer-terminate",
            "line-readiness-terminal",
            "scenario-switch-prepare-failed",
            "prepare-failed",
            "future-unclassified-code",
        ] {
            var ledger = AutomaticRecoveryLedger()
            ledger.beginEpisode(in: epoch("en0"), at: start)
            consume(&ledger, attempts: 5)

            XCTAssertFalse(
                ledger.park(
                    epoch: epoch("en0"),
                    failure: failure(code),
                    at: start
                ),
                code
            )
            XCTAssertEqual(
                ledger.resume(
                    .networkEpoch(connectivityRestored: false),
                    observed: observed("en7"),
                    systemAsleep: false,
                    at: start.addingTimeInterval(600)
                ),
                .rejected(.notParked),
                code
            )
            XCTAssertTrue(ledger.isExhausted, code)
        }
        XCTAssertFalse(AutomaticReconnectFailurePolicy.permitsNetworkEpochGrant(
            failure(
                "anyconnect-peer-disconnect",
                message: "authentication timed out"
            )
        ))
    }

    func testNetworkRelatedFailuresPark() {
        for code in [
            "line-address-family-unavailable",
            ConnectionFailureCode.underlayEgressUnavailable,
            ProxyResourceReadiness.lineFailureCode,
            "anyconnect-tls-read-reset",
            "tailscale-readiness-timeout",
            ConnectionFailureCode.providerSessionLost,
        ] {
            var ledger = AutomaticRecoveryLedger()
            XCTAssertTrue(
                ledger.park(
                    epoch: epoch("en0"),
                    failure: failure(code),
                    at: start
                ),
                code
            )
        }
    }

    // MARK: - Grant rules

    func testDuplicateNotificationsForTheParkedEpochNeverGrant() {
        var ledger = parkedLedger(on: "utun12")

        for offset in [1.0, 2, 30, 600] {
            XCTAssertEqual(
                ledger.resume(
                    .networkEpoch(connectivityRestored: false),
                    observed: observed("utun12"),
                    systemAsleep: false,
                    at: start.addingTimeInterval(offset)
                ),
                .rejected(.duplicateEpoch)
            )
        }
        XCTAssertTrue(ledger.isParked)
        XCTAssertTrue(ledger.isExhausted)
    }

    func testNewFingerprintGrantsImmediately() {
        var ledger = parkedLedger(on: "utun12")

        XCTAssertEqual(
            ledger.resume(
                .networkEpoch(connectivityRestored: false),
                observed: observed("en0"),
                systemAsleep: false,
                at: start.addingTimeInterval(1)
            ),
            .grant(.underlayChanged)
        )
        XCTAssertFalse(ledger.isParked)
        XCTAssertEqual(ledger.nextAttempt, 1)
        XCTAssertEqual(ledger.budgetEpoch?.underlayFingerprint, "en0")
    }

    func testScenarioChosenWhileParkedGrantsFullBudget() {
        var ledger = parkedLedger(on: "en0")

        XCTAssertEqual(
            ledger.resume(
                .networkEpoch(connectivityRestored: false),
                observed: AutomaticRecoveryObservation(
                    scenarioID: "office",
                    underlayFingerprint: "en0"
                ),
                systemAsleep: false,
                at: start.addingTimeInterval(1)
            ),
            .grant(.scenarioChanged)
        )
        XCTAssertEqual(ledger.budgetEpoch?.scenarioID, "office")
        XCTAssertEqual(ledger.nextAttempt, 1)
    }

    func testConnectivityEdgeOnSameFingerprintDefersUntilFiveMinutes() {
        var ledger = AutomaticRecoveryLedger()
        // The budget for en0 was granted when this episode started.
        ledger.beginEpisode(in: epoch("en0"), at: start)
        consume(&ledger, attempts: 5)
        ledger.park(
            epoch: epoch("en0"),
            failure: failure("proxy-line-egress-unavailable"),
            at: start.addingTimeInterval(60)
        )

        let early = start.addingTimeInterval(120)
        XCTAssertEqual(
            ledger.resume(
                .networkEpoch(connectivityRestored: true),
                observed: observed("en0"),
                systemAsleep: false,
                at: early
            ),
            .deferred(
                .connectivityRestored,
                until: start.addingTimeInterval(300)
            )
        )
        XCTAssertTrue(ledger.isParked)
        XCTAssertEqual(ledger.connectivityGeneration, 1)

        // Not dropped: re-evaluating before the date keeps the deferral.
        XCTAssertEqual(
            ledger.reevaluateDeferredGrant(
                systemAsleep: false,
                at: start.addingTimeInterval(200)
            ),
            .deferred(
                .connectivityRestored,
                until: start.addingTimeInterval(300)
            )
        )
        XCTAssertEqual(
            ledger.reevaluateDeferredGrant(
                systemAsleep: false,
                at: start.addingTimeInterval(300)
            ),
            .grant(.connectivityRestored)
        )
        XCTAssertEqual(ledger.nextAttempt, 1)
        XCTAssertEqual(ledger.budgetEpoch?.connectivityGeneration, 1)
    }

    func testConnectivityEdgeAfterFiveMinutesGrantsImmediately() {
        var ledger = parkedLedger(on: "en0")

        XCTAssertEqual(
            ledger.resume(
                .networkEpoch(connectivityRestored: true),
                observed: observed("en0"),
                systemAsleep: false,
                at: start.addingTimeInterval(301)
            ),
            .grant(.connectivityRestored)
        )
    }

    func testHourlyCapDefersTheSeventhAutomaticGrant() {
        var ledger = parkedLedger(on: "a0")
        var now = start
        var fingerprints = ["a1", "a2", "a3", "a4", "a5", "a6"]
        var grantTimes: [Date] = []
        while let fingerprint = fingerprints.first {
            fingerprints.removeFirst()
            now = now.addingTimeInterval(60)
            XCTAssertEqual(
                ledger.resume(
                    .networkEpoch(connectivityRestored: false),
                    observed: observed(fingerprint),
                    systemAsleep: false,
                    at: now
                ),
                .grant(.underlayChanged),
                fingerprint
            )
            grantTimes.append(now)
            consume(&ledger, attempts: 5)
            ledger.park(
                epoch: epoch(fingerprint),
                failure: failure("line-address-family-unavailable"),
                at: now
            )
        }
        XCTAssertEqual(ledger.rateLimitedGrantCount(at: now), 6)

        now = now.addingTimeInterval(60)
        let expectedUntil = grantTimes[0].addingTimeInterval(3600)
        XCTAssertEqual(
            ledger.resume(
                .networkEpoch(connectivityRestored: false),
                observed: observed("a7"),
                systemAsleep: false,
                at: now
            ),
            .deferred(.underlayChanged, until: expectedUntil)
        )
        XCTAssertTrue(ledger.isParked)
        XCTAssertEqual(
            ledger.projection(at: now).deferredGrantUntil,
            expectedUntil
        )
        // A user retry is a new intent and never waits behind the cap.
        var userLedger = ledger
        XCTAssertEqual(userLedger.userRetry(at: now), .grant(.userRetry))
        XCTAssertEqual(userLedger.rateLimitedGrantCount(at: now), 6)

        XCTAssertEqual(
            ledger.reevaluateDeferredGrant(
                systemAsleep: false,
                at: expectedUntil
            ),
            .grant(.underlayChanged)
        )
        XCTAssertEqual(ledger.budgetEpoch?.underlayFingerprint, "a7")
    }

    func testNewFingerprintGrantsWhileAConnectivityGrantIsDeferred() {
        var ledger = parkedLedger(on: "en0", episodeAge: 0)
        _ = ledger.resume(
            .networkEpoch(connectivityRestored: true),
            observed: observed("en0"),
            systemAsleep: false,
            at: start.addingTimeInterval(10)
        )
        XCTAssertEqual(
            ledger.parking?.deferredGrant?.reason,
            .connectivityRestored
        )

        XCTAssertEqual(
            ledger.resume(
                .networkEpoch(connectivityRestored: false),
                observed: observed("en7"),
                systemAsleep: false,
                at: start.addingTimeInterval(20)
            ),
            .grant(.underlayChanged)
        )
    }

    func testNoGrantOrAttemptWhileAsleep() {
        var ledger = parkedLedger(on: "en0")

        for trigger in [
            AutomaticRecoveryResumeTrigger.networkEpoch(
                connectivityRestored: false
            ),
            .wake,
            .slowTail,
        ] {
            XCTAssertEqual(
                ledger.resume(
                    trigger,
                    observed: observed("en7"),
                    systemAsleep: true,
                    at: start.addingTimeInterval(600)
                ),
                .rejected(.asleep)
            )
        }
        XCTAssertTrue(ledger.isParked)
        XCTAssertEqual(ledger.connectivityGeneration, 0)
    }

    func testUserRetryAlwaysGrantsWhileParked() {
        var ledger = parkedLedger(on: "en0")

        XCTAssertEqual(
            ledger.userRetry(at: start.addingTimeInterval(1)),
            .grant(.userRetry)
        )
        XCTAssertFalse(ledger.isParked)
        XCTAssertEqual(ledger.nextAttempt, 1)
        XCTAssertEqual(ledger.rateLimitedGrantCount(at: start), 0)
        XCTAssertEqual(
            ledger.userRetry(at: start.addingTimeInterval(2)),
            .rejected(.notParked)
        )
    }

    // MARK: - Wake

    func testWakeOnUnchangedEpochKeepsOneAttemptWithoutBudget() {
        var ledger = parkedLedger(on: "utun12")

        XCTAssertEqual(
            ledger.resume(
                .wake,
                observed: observed("utun12"),
                systemAsleep: false,
                at: start.addingTimeInterval(900)
            ),
            .singleAttempt(.wake)
        )
        XCTAssertTrue(ledger.isParked)
        XCTAssertTrue(ledger.isExhausted)
    }

    func testWakeOnChangedNetworkUpgradesToFullBudget() {
        var ledger = parkedLedger(on: "utun12")

        XCTAssertEqual(
            ledger.resume(
                .wake,
                observed: observed("en0"),
                systemAsleep: false,
                at: start.addingTimeInterval(900)
            ),
            .grant(.underlayChanged)
        )
        XCTAssertEqual(ledger.nextAttempt, 1)
    }

    func testWakeStillRunsItsAttemptWhenTheGrantIsDeferred() {
        var ledger = parkedLedger(on: "en0", episodeAge: 0)

        XCTAssertEqual(
            ledger.resume(
                .networkEpoch(connectivityRestored: true),
                observed: observed("en0"),
                systemAsleep: false,
                at: start.addingTimeInterval(30)
            ),
            .deferred(
                .connectivityRestored,
                until: start.addingTimeInterval(300)
            )
        )
        XCTAssertEqual(
            ledger.resume(
                .wake,
                observed: observed("en0"),
                systemAsleep: false,
                at: start.addingTimeInterval(40)
            ),
            .singleAttempt(.wake)
        )
        XCTAssertNotNil(ledger.parking?.deferredGrant)
    }

    // MARK: - Slow tail

    func testSlowTailRunsAtMostFiveBoundedAttemptsInTheSameEpoch() {
        var ledger = parkedLedger(on: "en0")
        var delays: [TimeInterval] = []
        var now = start
        while let delay = ledger.nextTailDelay {
            delays.append(delay)
            now = now.addingTimeInterval(delay)
            let decision = ledger.resume(
                .slowTail,
                observed: observed("en0"),
                systemAsleep: false,
                at: now
            )
            XCTAssertEqual(
                decision,
                .singleAttempt(.tail(delays.count))
            )
            ledger.recordTailAttemptStarted()
            XCTAssertTrue(ledger.park(
                epoch: epoch("en0"),
                failure: failure("proxy-line-egress-unavailable"),
                at: now
            ))
        }

        XCTAssertEqual(delays, [120, 300, 600, 1200, 1800])
        XCTAssertEqual(
            ledger.resume(
                .slowTail,
                observed: observed("en0"),
                systemAsleep: false,
                at: now.addingTimeInterval(3600)
            ),
            .rejected(.tailExhausted)
        )
        XCTAssertTrue(ledger.isExhausted, "tail attempts never refill the budget")
    }

    func testNewEpochReplacesTheTailWithAFullBudget() {
        var ledger = parkedLedger(on: "en0")
        _ = ledger.resume(
            .slowTail,
            observed: observed("en0"),
            systemAsleep: false,
            at: start.addingTimeInterval(120)
        )
        ledger.recordTailAttemptStarted()
        ledger.park(
            epoch: epoch("en0"),
            failure: failure("proxy-line-egress-unavailable"),
            at: start.addingTimeInterval(130)
        )
        XCTAssertEqual(ledger.parking?.tailAttemptsUsed, 1)

        // The tail timer's own preparation found a new network.
        XCTAssertEqual(
            ledger.resume(
                .slowTail,
                observed: observed("en7"),
                systemAsleep: false,
                at: start.addingTimeInterval(400)
            ),
            .grant(.underlayChanged)
        )
        XCTAssertNil(ledger.nextTailDelay)
        consume(&ledger, attempts: 5)
        ledger.park(
            epoch: epoch("en7"),
            failure: failure("proxy-line-egress-unavailable"),
            at: start.addingTimeInterval(500)
        )
        XCTAssertEqual(ledger.parking?.tailAttemptsUsed, 0)
        XCTAssertEqual(ledger.nextTailDelay, 120)
    }

    func testIdentityTerminalTailFailureEndsParking() {
        var ledger = parkedLedger(on: "en0")
        _ = ledger.resume(
            .slowTail,
            observed: observed("en0"),
            systemAsleep: false,
            at: start.addingTimeInterval(120)
        )
        ledger.recordTailAttemptStarted()

        XCTAssertFalse(ledger.park(
            epoch: epoch("en0"),
            failure: failure("tailscale-login-required"),
            at: start.addingTimeInterval(130)
        ))
        XCTAssertFalse(ledger.isParked)
        XCTAssertNil(ledger.nextTailDelay)
    }

    // MARK: - Anti-loop

    func testXDialAttemptsCannotGrantThroughTheirOwnUnderlayEffects() {
        var ledger = parkedLedger(on: "en0")
        // A wake attempt runs; whatever its Provider start / stop left behind
        // is absorbed by the post-rollback capture without a grant.
        XCTAssertEqual(
            ledger.resume(
                .wake,
                observed: observed("en0"),
                systemAsleep: false,
                at: start.addingTimeInterval(60)
            ),
            .singleAttempt(.wake)
        )
        ledger.park(
            epoch: epoch("en0"),
            failure: failure("proxy-line-egress-unavailable"),
            at: start.addingTimeInterval(90)
        )
        ledger.absorbParkedUnderlay(fingerprint: "en0+provider")
        XCTAssertEqual(
            ledger.parking?.epoch.underlayFingerprint,
            "en0+provider"
        )
        XCTAssertTrue(ledger.isExhausted)

        // Equivalent path callbacks and repeated notifications afterwards
        // carry no new fact.
        for offset in [91.0, 95, 120] {
            XCTAssertEqual(
                ledger.resume(
                    .networkEpoch(connectivityRestored: false),
                    observed: observed("en0+provider"),
                    systemAsleep: false,
                    at: start.addingTimeInterval(offset)
                ),
                .rejected(.duplicateEpoch)
            )
        }
        // Absorbing keeps tail progress, so re-anchoring cannot refill it.
        ledger.recordTailAttemptStarted()
        ledger.absorbParkedUnderlay(fingerprint: "en0")
        XCTAssertEqual(ledger.parking?.tailAttemptsUsed, 1)
        XCTAssertEqual(ledger.rateLimitedGrantCount(at: start), 0)
    }

    func testEquivalentUnderlayNotificationsDoNotCreateEpochsWhileParked() {
        var coordinator = NetworkEpochSwitchCoordinator()
        let token = coordinator.observeUnderlayChange(
            currentDesiredScenarioID: "home",
            underlayFingerprint: "en0"
        )!
        let intent = coordinator.settle(token)!
        XCTAssertEqual(
            NetworkEpochTransitionPolicy.decide(
                desiredScenarioID: intent.desiredScenarioID,
                currentDesiredScenarioID: "home",
                committedScenarioID: "home",
                underlayChanged: intent.underlayChanged,
                keepsConnection: true,
                runtimeStatus: "disconnected",
                hasPendingScenarioSwitch: false,
                automaticRecoveryParked: true
            ),
            .resumeParkedRecovery
        )
        XCTAssertTrue(coordinator.complete(intent, outcome: .succeeded))

        // The same physical state reported again is not a new epoch.
        XCTAssertNil(coordinator.observeUnderlayChange(
            currentDesiredScenarioID: "home",
            underlayFingerprint: "en0"
        ))
    }

    // MARK: - 2026-09-04 replay

    /// Launch auto-connect failed with `line-address-family-unavailable`
    /// while another VPN owned the default route (utun12), exhausted after
    /// five retries, then five screen wakes each made one attempt. Around
    /// 20:11 the default interface became en0 without any wake.
    func testReplayOfTwentySixSeptemberFourthExhaustion() throws {
        var ledger = AutomaticRecoveryLedger()
        var history = ReconnectIncidentHistory()
        let utun12 = epoch("utun12")
        let launch = date(hour: 17, minute: 33)
        let incidentID = history.begin(
            at: launch,
            trigger: .automaticConnection,
            report: nil,
            reasonCode: "line-address-family-unavailable",
            reasonMessage: "线路 IPv4 / IPv6 出口均不可用"
        )

        XCTAssertTrue(ledger.beginEpisode(in: utun12, at: launch))
        var attempts = 0
        while let attempt = ledger.nextAttempt {
            history.recordRetryScheduled(
                incidentID: incidentID,
                attempt: attempt,
                failedTransactionID: "t\(attempt - 1)",
                failureCode: "line-address-family-unavailable",
                delay: [2, 5, 10, 20, 30][attempt - 1]
            )
            XCTAssertTrue(ledger.recordStarted(attempt))
            attempts += 1
        }
        XCTAssertEqual(attempts, 5)
        XCTAssertTrue(ledger.park(
            epoch: utun12,
            failure: failure("line-address-family-unavailable"),
            at: date(hour: 17, minute: 36)
        ))
        history.recordParked(
            incidentID: incidentID,
            at: date(hour: 17, minute: 36),
            attemptsUsed: ledger.attemptsUsed,
            transactionID: "t5",
            failureCode: "line-address-family-unavailable"
        )

        for (hour, minute) in [(17, 51), (18, 46), (19, 8), (19, 42), (20, 7)] {
            let wake = date(hour: hour, minute: minute)
            let decision = ledger.resume(
                .wake,
                observed: observed("utun12"),
                systemAsleep: false,
                at: wake
            )
            XCTAssertEqual(decision, .singleAttempt(.wake))
            history.recordSingleAttemptStarted(
                incidentID: incidentID,
                at: wake,
                kind: .wake,
                transactionID: "wake-\(hour)\(minute)"
            )
            XCTAssertTrue(ledger.park(
                epoch: utun12,
                failure: failure("line-address-family-unavailable"),
                at: wake
            ))
            history.recordAttemptFailed(
                incidentID: incidentID,
                at: wake,
                attempt: 0,
                transactionID: "wake-\(hour)\(minute)",
                failureCode: "line-address-family-unavailable"
            )
            XCTAssertTrue(ledger.isExhausted)
        }

        // The parked observer reports utun12 -> en0; AppState settles it.
        XCTAssertEqual(
            ledger.resume(
                .networkEpoch(connectivityRestored: false),
                observed: observed("en0"),
                systemAsleep: false,
                at: date(hour: 20, minute: 11)
            ),
            .grant(.underlayChanged)
        )
        history.recordBudgetGranted(
            incidentID: incidentID,
            at: date(hour: 20, minute: 11),
            reason: .underlayChanged
        )
        XCTAssertEqual(
            (1 ... 5).filter { ledger.recordStarted($0) }.count,
            5
        )

        let incident = try XCTUnwrap(history.incidents.first)
        XCTAssertEqual(incident.outcome, ReconnectIncidentOutcome.recovering)
        XCTAssertFalse(incident.events.contains { $0.type == "exhausted" })
        XCTAssertEqual(
            incident.events.filter {
                $0.type == ReconnectIncidentEventType.parked
            }.count,
            1
        )
        XCTAssertEqual(
            incident.events.filter {
                $0.type == ReconnectIncidentEventType.wakeAttemptStarted
            }.count,
            5
        )
        XCTAssertEqual(
            incident.events.last?.type,
            ReconnectIncidentEventType.budgetGranted
        )
        XCTAssertEqual(incident.events.last?.code, "underlay-changed")
    }

    // MARK: - Projection

    func testProjectionNeverCarriesTheUnderlayFingerprint() throws {
        var ledger = parkedLedger(
            on: "secret-fingerprint-en0",
            episodeAge: 0
        )
        _ = ledger.resume(
            .networkEpoch(connectivityRestored: true),
            observed: observed("secret-fingerprint-en0"),
            systemAsleep: false,
            at: start.addingTimeInterval(1)
        )
        let state = AutomaticReconnectRuntimeState(
            inProgress: false,
            trigger: nil,
            attemptsUsed: ledger.attemptsUsed,
            maxAttempts: 5,
            stableResetAt: nil,
            retryAt: nil,
            retryAttempt: nil,
            parked: true,
            attemptKind: nil,
            tailAttemptAt: start.addingTimeInterval(120),
            recovery: ledger.projection(at: start)
        )
        let data = try JSONEncoder().encode(state)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(json.contains("secret-fingerprint"))
        XCTAssertTrue(json.contains("\"parked\":true"))
        XCTAssertTrue(json.contains("deferred_grant_reason"))
        let decoded = try JSONDecoder().decode(
            AutomaticReconnectRuntimeState.self,
            from: data
        )
        XCTAssertEqual(decoded, state)
    }

    func testRuntimeStateWithoutParkingFieldsDecodes() throws {
        let legacy = """
        {"in_progress":false,"attempts_used":5,"max_attempts":5}
        """
        let decoded = try JSONDecoder().decode(
            AutomaticReconnectRuntimeState.self,
            from: Data(legacy.utf8)
        )

        XCTAssertFalse(decoded.parked)
        XCTAssertNil(decoded.recovery)
        XCTAssertNil(decoded.attemptKind)
    }

    // MARK: - Helpers

    private func epoch(
        _ fingerprint: String,
        scenarioID: String = "home",
        generation: UInt64 = 0
    ) -> AutomaticRecoveryEpoch {
        AutomaticRecoveryEpoch(
            scenarioID: scenarioID,
            underlayFingerprint: fingerprint,
            connectivityGeneration: generation
        )
    }

    private func observed(
        _ fingerprint: String,
        scenarioID: String = "home"
    ) -> AutomaticRecoveryObservation {
        AutomaticRecoveryObservation(
            scenarioID: scenarioID,
            underlayFingerprint: fingerprint
        )
    }

    private func failure(
        _ code: String,
        message: String? = nil
    ) -> ConnectionReportError {
        ConnectionReportError(
            code: code,
            message: message ?? code,
            taskID: "task"
        )
    }

    private func consume(
        _ ledger: inout AutomaticRecoveryLedger,
        attempts: Int
    ) {
        for _ in 0 ..< attempts {
            guard let next = ledger.nextAttempt else { return }
            XCTAssertTrue(ledger.recordStarted(next))
        }
    }

    /// By default parked 6 minutes after the episode's own grant, so the
    /// same-fingerprint spacing only matters where a test says so.
    private func parkedLedger(
        on fingerprint: String,
        episodeAge: TimeInterval = 360
    ) -> AutomaticRecoveryLedger {
        var ledger = AutomaticRecoveryLedger()
        ledger.beginEpisode(
            in: epoch(fingerprint),
            at: start.addingTimeInterval(-episodeAge)
        )
        consume(&ledger, attempts: 5)
        XCTAssertTrue(ledger.park(
            epoch: epoch(fingerprint),
            failure: failure("line-address-family-unavailable"),
            at: start
        ))
        return ledger
    }

    private func date(hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 4
        components.hour = hour
        components.minute = minute
        components.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return Calendar(identifier: .gregorian).date(from: components)!
    }
}
