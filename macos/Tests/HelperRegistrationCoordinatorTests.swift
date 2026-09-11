import XCTest

@MainActor
final class HelperRegistrationCoordinatorTests: XCTestCase {
    func testVerifiedRegistrationAndMatchingRuntimeAreAlreadyReady() async throws {
        let fixture = Fixture()
        fixture.marker = "current-registration"
        try await fixture.coordinator().prepare()
        XCTAssertEqual(fixture.registrations, 0)
        XCTAssertTrue(fixture.unregisteredPIDs.isEmpty)
        XCTAssertTrue(fixture.savedMarkers.isEmpty)
        XCTAssertEqual(fixture.stages.last, .ready)
    }

    func testEnabledButAbsentHelperRepairsOnceWithoutUserRetry() async throws {
        let fixture = Fixture()
        fixture.runtime = .absent
        try await fixture.coordinator().prepare()
        XCTAssertEqual(fixture.unregisteredPIDs.count, 1)
        XCTAssertNil(fixture.unregisteredPIDs[0])
        XCTAssertEqual(fixture.registrations, 1)
        XCTAssertEqual(fixture.savedMarkers, ["current-registration"])
        XCTAssertGreaterThanOrEqual(fixture.time, 1)
    }

    func testMatchingBinaryDoesNotHideStaleServiceRegistration() async throws {
        let fixture = Fixture()
        fixture.marker = "previous-plist-or-build"
        try await fixture.coordinator().prepare()
        XCTAssertEqual(fixture.unregisteredPIDs, [42])
        XCTAssertEqual(fixture.registrations, 1)
        XCTAssertEqual(fixture.savedMarkers, ["current-registration"])
    }

    func testFreshRegistrationWaitsForApprovalAndRuntimeBeforeSavingMarker() async throws {
        let fixture = Fixture()
        fixture.status = .notRegistered
        fixture.runtime = .absent
        fixture.onRegister = {
            fixture.status = .requiresApproval
            return true
        }
        fixture.onSleep = {
            XCTAssertTrue(fixture.savedMarkers.isEmpty)
            if fixture.time >= 2 {
                fixture.status = .enabled
                fixture.runtime = .running(Fixture.currentDaemon)
            }
        }
        try await fixture.coordinator().prepare()
        XCTAssertEqual(fixture.registrations, 1)
        XCTAssertTrue(fixture.unregisteredPIDs.isEmpty)
        XCTAssertTrue(fixture.stages.contains(.waitingForApproval))
        XCTAssertEqual(fixture.savedMarkers, ["current-registration"])
    }

    func testRevokedApprovalNeverUnregistersTheService() async {
        let fixture = Fixture()
        fixture.status = .requiresApproval
        do {
            try await fixture.coordinator().prepare()
            XCTFail("unapproved service became ready")
        } catch {
            XCTAssertEqual(error as? HelperRegistrationCoordinator.Failure, .approvalRequired)
        }
        XCTAssertEqual(fixture.registrations, 0)
        XCTAssertTrue(fixture.unregisteredPIDs.isEmpty)
        XCTAssertTrue(fixture.savedMarkers.isEmpty)
    }

    func testUnknownAndUnresponsiveProcessesAreNotUnregistered() async {
        for runtime: HelperRegistrationCoordinator.Runtime in [.unknown, .unresponsive] {
            let fixture = Fixture()
            fixture.runtime = runtime
            do {
                try await fixture.coordinator().prepare()
                XCTFail("unknown runtime was replaced")
            } catch {
                XCTAssertEqual(error as? HelperRegistrationCoordinator.Failure, .processStateUnknown)
            }
            XCTAssertTrue(fixture.unregisteredPIDs.isEmpty)
            XCTAssertEqual(fixture.registrations, 0)
        }
    }

    func testProtectedWorkFinishesBeforeAutomaticRefresh() async throws {
        let fixture = Fixture()
        fixture.maintenanceAllowed = false
        fixture.onSleep = {
            XCTAssertTrue(fixture.unregisteredPIDs.isEmpty)
            if fixture.time >= 1 { fixture.maintenanceAllowed = true }
        }
        try await fixture.coordinator().prepare()
        XCTAssertTrue(fixture.stages.contains(.waitingForIdle))
        XCTAssertGreaterThanOrEqual(fixture.unregisterTimes.first ?? 0, 1)
        XCTAssertEqual(fixture.registrations, 1)
    }

    func testDaemonBusyResponsePreservesServiceAndContinuesSameInstallation() async throws {
        let fixture = Fixture()
        var attempts = 0
        fixture.onUnregister = { _ in
            attempts += 1
            if attempts == 1 { throw HelperRegistrationCoordinator.Failure.serviceBusy }
            fixture.status = .notRegistered
        }
        try await fixture.coordinator().prepare()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(fixture.registrations, 1)
        XCTAssertEqual(fixture.savedMarkers, ["current-registration"])
    }

    func testLongHostBusyWaitDoesNotRepeatVerificationEvents() async throws {
        let fixture = Fixture()
        fixture.maintenanceAllowed = false
        fixture.onSleep = {
            XCTAssertEqual(fixture.stages, [.checking, .verifying, .waitingForIdle])
            if fixture.time >= 5 { fixture.maintenanceAllowed = true }
        }
        try await fixture.coordinator().prepare()
        XCTAssertEqual(fixture.stages.filter { $0 == .waitingForIdle }.count, 1)
        XCTAssertEqual(fixture.stages.filter { $0 == .verifying }.count, 2)
    }

    func testRepeatedDaemonBusyDoesNotRepeatRefreshEvents() async throws {
        let fixture = Fixture()
        var attempts = 0
        fixture.onUnregister = { _ in
            attempts += 1
            if attempts < 20 { throw HelperRegistrationCoordinator.Failure.serviceBusy }
            fixture.status = .notRegistered
        }
        try await fixture.coordinator().prepare()
        XCTAssertEqual(attempts, 20)
        XCTAssertEqual(fixture.stages.filter { $0 == .waitingForIdle }.count, 1)
        XCTAssertEqual(fixture.stages.filter { $0 == .verifying }.count, 2)
        XCTAssertEqual(fixture.stages.filter { $0 == .refreshingRegistration }.count, 2)
    }

    func testUnregisterFailureNeverRegistersOrWritesMarker() async {
        let fixture = Fixture()
        fixture.onUnregister = { _ in throw TestFailure.unregistration }
        do {
            try await fixture.coordinator().prepare()
            XCTFail("unregister failure was ignored")
        } catch {
            XCTAssertEqual(error as? TestFailure, .unregistration)
        }
        XCTAssertEqual(fixture.registrations, 0)
        XCTAssertTrue(fixture.savedMarkers.isEmpty)
    }

    func testRegisterFailureDoesNotClaimCurrentRegistration() async {
        let fixture = Fixture()
        fixture.onRegister = { throw TestFailure.registration }
        do {
            try await fixture.coordinator().prepare()
            XCTFail("register failure was ignored")
        } catch {
            XCTAssertEqual(error as? TestFailure, .registration)
        }
        XCTAssertEqual(fixture.registrations, 1)
        XCTAssertTrue(fixture.savedMarkers.isEmpty)
    }

    func testRefreshedRegistrationWithWrongRuntimeDoesNotWriteMarker() async {
        let fixture = Fixture()
        fixture.onRegister = {
            fixture.status = .enabled
            fixture.runtime = .running(.init(pid: 50, executableHash: "wrong", handoffProtocolVersion: 1))
            return true
        }
        do {
            try await fixture.coordinator().prepare()
            XCTFail("wrong helper became ready")
        } catch {
            XCTAssertEqual(error as? HelperRegistrationCoordinator.Failure, .versionMismatch)
        }
        XCTAssertEqual(fixture.registrations, 1)
        XCTAssertEqual(fixture.unregisteredPIDs.count, 1)
        XCTAssertTrue(fixture.savedMarkers.isEmpty)
    }

    func testRefreshedRegistrationWithoutRuntimeStopsAfterOneAttempt() async {
        let fixture = Fixture()
        fixture.runtime = .absent
        fixture.onRegister = {
            fixture.status = .enabled
            return true
        }
        do {
            try await fixture.coordinator().prepare()
            XCTFail("missing helper became ready")
        } catch {
            XCTAssertEqual(error as? HelperRegistrationCoordinator.Failure, .serviceUnavailable)
        }
        XCTAssertEqual(fixture.registrations, 1)
        XCTAssertEqual(fixture.unregisteredPIDs.count, 1)
        XCTAssertTrue(fixture.savedMarkers.isEmpty)
    }

    func testLegacyMigrationKeepsFullIdleWindowThenRegistersNewHelper() async throws {
        let fixture = Fixture()
        fixture.runtime = .running(Fixture.legacyDaemon)
        try await fixture.coordinator().prepare()
        XCTAssertTrue(fixture.respawnTimes.isEmpty)
        XCTAssertGreaterThanOrEqual(fixture.unregisterTimes[0], 4)
        XCTAssertTrue(fixture.stages.contains(.waitingForLegacyIdle))
        XCTAssertEqual(fixture.unregisteredPIDs, [42])
        XCTAssertEqual(fixture.registrations, 1)
        XCTAssertEqual(fixture.savedMarkers, ["current-registration"])
    }

    func testLegacyIdleWindowRestartsWhenOtherWorkAppears() async throws {
        let fixture = Fixture()
        fixture.runtime = .running(Fixture.legacyDaemon)
        fixture.onSleep = {
            fixture.legacyExclusive = fixture.time < 2 || fixture.time >= 3
        }
        try await fixture.coordinator().prepare()
        XCTAssertGreaterThanOrEqual(fixture.unregisterTimes.first ?? 0, 7)
    }

    func testLegacyPIDReplacementIsReevaluatedWithinSameInstallation() async throws {
        let fixture = Fixture()
        fixture.runtime = .running(Fixture.legacyDaemon)
        fixture.onSleep = {
            if fixture.time >= 1 { fixture.runtime = .running(Fixture.currentDaemon) }
        }
        try await fixture.coordinator().prepare()
        XCTAssertEqual(fixture.unregisteredPIDs, [Fixture.currentDaemon.pid])
        XCTAssertEqual(fixture.registrations, 1)
        XCTAssertEqual(fixture.savedMarkers, ["current-registration"])
    }

    func testLegacyUnknownWorkIsPreservedUntilCancellation() async {
        let fixture = Fixture()
        fixture.runtime = .running(Fixture.legacyDaemon)
        fixture.legacyIdle = false
        fixture.onSleep = {
            if fixture.time >= 3 { throw CancellationError() }
        }
        do {
            try await fixture.coordinator().prepare()
            XCTFail("unknown legacy work was interrupted")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(fixture.respawnTimes.isEmpty)
        XCTAssertTrue(fixture.unregisteredPIDs.isEmpty)
        XCTAssertTrue(fixture.savedMarkers.isEmpty)
    }

    func testInterruptedUnregisterRecoversEvenWhenStatusIsNotRegistered() async throws {
        let fixture = Fixture()
        fixture.status = .notRegistered
        fixture.runtime = .absent
        fixture.pendingRecovery = true
        try await fixture.coordinator().prepare()
        XCTAssertEqual(fixture.unregisteredPIDs.count, 1)
        XCTAssertEqual(fixture.registrations, 1)
        XCTAssertEqual(fixture.finalizations, 1)
    }

    func testCompletedMissingJobBarrierCanRegisterCurrentBundle() async throws {
        let fixture = Fixture()
        fixture.onUnregister = { _ in fixture.status = .notFound }
        try await fixture.coordinator().prepare()
        XCTAssertEqual(fixture.unregisteredPIDs.count, 1)
        XCTAssertEqual(fixture.registrations, 1)
        XCTAssertEqual(fixture.savedMarkers, ["current-registration"])
    }

    func testMatchingMarkerWithInterruptedUnregisterStillRefreshes() async throws {
        let fixture = Fixture()
        fixture.marker = "current-registration"
        fixture.pendingRecovery = true
        try await fixture.coordinator().prepare()
        XCTAssertEqual(fixture.unregisteredPIDs.count, 1)
        XCTAssertEqual(fixture.registrations, 1)
    }

    func testPreviouslyRegisteredIntentOnlyFinalizesWithoutAnotherUnregister() async throws {
        let fixture = Fixture()
        // The production adapter exposes a matching marker only for the
        // persisted registered phase and the current executable hash.
        fixture.marker = "current-registration"
        try await fixture.coordinator().prepare()
        XCTAssertEqual(fixture.finalizations, 1)
        XCTAssertTrue(fixture.unregisteredPIDs.isEmpty)
        XCTAssertEqual(fixture.registrations, 0)
    }

    func testFinalizeFailureDoesNotPublishReadyOrRegistrationMarker() async {
        let fixture = Fixture()
        fixture.onFinalize = { throw TestFailure.unregistration }
        do {
            try await fixture.coordinator().prepare()
            XCTFail("missing finalize acknowledgement became ready")
        } catch {}
        XCTAssertTrue(fixture.savedMarkers.isEmpty)
        XCTAssertFalse(fixture.stages.contains(.ready))
    }

    func testPostUnregisterSMDenialWaitsThenRetriesWithoutAnotherUnregister() async throws {
        let fixture = Fixture()
        var operations: [String] = []
        fixture.onUnregister = { _ in
            operations.append("unregister-completed")
            fixture.status = .notRegistered
            fixture.runtime = .absent
            XCTAssertTrue(fixture.savedMarkers.isEmpty)
        }
        fixture.onSleep = { operations.append("sleep-completed") }
        fixture.onRegister = {
            operations.append("register")
            if fixture.registrations == 1 { throw Self.smDenial }
            fixture.status = .enabled
            fixture.runtime = .running(Fixture.currentDaemon)
            return true
        }
        fixture.onFinalize = { operations.append("finalize-acknowledged") }
        try await fixture.coordinator().prepare()
        XCTAssertEqual(
            operations,
            ["unregister-completed", "register", "sleep-completed", "register", "finalize-acknowledged"]
        )
        XCTAssertEqual(fixture.registrations, 2)
        XCTAssertEqual(fixture.registrationTimes, [0, 1])
        XCTAssertEqual(fixture.unregisteredPIDs, [Fixture.currentDaemon.pid])
        XCTAssertEqual(fixture.stages.filter { $0 == .reconcilingRegistration }.count, 1)
        XCTAssertEqual(fixture.savedMarkers, ["current-registration"])
        XCTAssertEqual(fixture.stages.last, .ready)
    }

    func testRepeatedPostUnregisterDenialUsesThirtySecondRetryBudget() async {
        let fixture = reconciliationFixture()
        let originalError = NSError(domain: "SMAppServiceErrorDomain", code: 1)
        fixture.onRegister = {
            if fixture.registrations == 1 { throw originalError }
            throw Self.smDenial
        }
        do {
            try await fixture.coordinator().prepare()
            XCTFail("retry budget did not stop registration")
        } catch {
            XCTAssertTrue(error as NSError === originalError)
        }
        XCTAssertEqual(fixture.registrations, 6)
        XCTAssertEqual(fixture.registrationTimes, [0, 1, 3, 7, 15, 30])
        XCTAssertEqual(fixture.unregisteredPIDs.count, 1)
        XCTAssertEqual(fixture.finalizations, 0)
        XCTAssertTrue(fixture.savedMarkers.isEmpty)
        XCTAssertTrue(fixture.pendingRecovery)
        XCTAssertEqual(fixture.currentMaintenanceTarget, Fixture.maintenanceTarget)
    }

    func testReconciliationRequiresServiceDomainCodeAndOwnedCommittedTarget() async {
        for invalidCase in 0..<6 {
            let fixture = reconciliationFixture()
            fixture.onRegister = {
                switch invalidCase {
                case 0: throw NSError(domain: NSPOSIXErrorDomain, code: 1)
                case 1: throw NSError(domain: "SMAppServiceErrorDomain", code: 4)
                case 2: fixture.hasOwnedCommittedTarget = false
                case 3: fixture.pendingRecovery = false
                case 4: fixture.currentMaintenanceTarget?.targetHash = "replacement-binary"
                default: fixture.currentMaintenanceTarget?.registrationFingerprint = "replacement-registration"
                }
                throw Self.smDenial
            }
            do {
                try await fixture.coordinator().prepare()
                XCTFail("ineligible denial was recovered")
            } catch {}
            XCTAssertEqual(fixture.registrations, 1)
            XCTAssertEqual(fixture.unregisteredPIDs.count, 1)
            XCTAssertFalse(fixture.stages.contains(.reconcilingRegistration))
            XCTAssertTrue(fixture.savedMarkers.isEmpty)
        }
    }

    func testRetryBoundaryRejectsUnknownLiveBusyApprovalAndEnabledStates() async {
        for invalidCase in 0..<6 {
            let fixture = reconciliationFixture()
            fixture.onRegister = {
                switch invalidCase {
                case 0: fixture.runtime = .unknown
                case 1: fixture.runtime = .unresponsive
                case 2: fixture.runtime = .running(Fixture.currentDaemon)
                case 3: fixture.maintenanceAllowed = false
                case 4: fixture.status = .requiresApproval
                default: fixture.status = .enabled
                }
                throw Self.smDenial
            }
            await assertRegistrationDenied(fixture)
            XCTAssertEqual(fixture.registrations, 1)
            XCTAssertEqual(fixture.unregisteredPIDs.count, 1)
            XCTAssertFalse(fixture.stages.contains(.reconcilingRegistration))
        }
    }

    func testWaitRevalidatesStatusBeforeRetrying() async {
        for status: HelperRegistrationCoordinator.ServiceStatus in [.enabled, .requiresApproval, .notFound] {
            let fixture = reconciliationFixture()
            fixture.onRegister = { throw Self.smDenial }
            fixture.onSleep = { fixture.status = status }
            await assertRegistrationDenied(fixture)
            XCTAssertEqual(fixture.registrations, 1)
            XCTAssertEqual(fixture.unregisteredPIDs.count, 1)
        }
    }

    func testWaitRevalidatesMaintenanceAndRuntimeBeforeRetrying() async {
        for invalidCase in 0..<4 {
            let fixture = reconciliationFixture()
            fixture.onRegister = { throw Self.smDenial }
            fixture.onSleep = {
                switch invalidCase {
                case 0: fixture.maintenanceAllowed = false
                case 1: fixture.runtime = .unknown
                case 2: fixture.runtime = .unresponsive
                default: fixture.runtime = .running(Fixture.currentDaemon)
                }
            }
            await assertRegistrationDenied(fixture)
            XCTAssertEqual(fixture.registrations, 1)
            XCTAssertEqual(fixture.unregisteredPIDs.count, 1)
        }
    }

    func testWaitRejectsReplacementTransactionWithTheSameTargetHash() async {
        let fixture = reconciliationFixture()
        fixture.onRegister = { throw Self.smDenial }
        fixture.onSleep = {
            fixture.currentMaintenanceTarget?.token = "replacement-token"
        }
        await assertRegistrationDenied(fixture)
        XCTAssertEqual(fixture.registrations, 1)
        XCTAssertEqual(fixture.unregisteredPIDs.count, 1)
    }

    func testWaitRejectsChangedBundleFingerprintWithTheSameHelperHash() async {
        let fixture = reconciliationFixture()
        fixture.onRegister = { throw Self.smDenial }
        fixture.onSleep = {
            fixture.currentMaintenanceTarget?.registrationFingerprint = "replacement-registration"
        }
        await assertRegistrationDenied(fixture)
        XCTAssertEqual(fixture.registrations, 1)
        XCTAssertEqual(fixture.unregisteredPIDs.count, 1)
    }

    func testRuntimeProbeRevalidatesTransactionBeforeRetrying() async {
        let fixture = reconciliationFixture()
        fixture.onRegister = { throw Self.smDenial }
        fixture.onRuntime = {
            if fixture.runtimeReads == 4 {
                fixture.currentMaintenanceTarget?.token = "replacement-during-runtime-probe"
            }
            return fixture.runtime
        }
        await assertRegistrationDenied(fixture)
        XCTAssertEqual(fixture.registrations, 1)
        XCTAssertEqual(fixture.unregisteredPIDs.count, 1)
    }

    func testRuntimeProbeCrossingDeadlineDoesNotStartAnotherRegister() async {
        let fixture = reconciliationFixture()
        fixture.onRegister = { throw Self.smDenial }
        fixture.onRuntime = {
            if fixture.runtimeReads == 4 { fixture.time = 31 }
            return fixture.runtime
        }
        await assertRegistrationDenied(fixture)
        XCTAssertEqual(fixture.registrations, 1)
        XCTAssertEqual(fixture.unregisteredPIDs.count, 1)
    }

    func testCancellationDuringRetryWaitPreservesCommittedRecovery() async {
        let fixture = reconciliationFixture()
        fixture.onRegister = { throw Self.smDenial }
        fixture.onSleep = { throw CancellationError() }
        do {
            try await fixture.coordinator().prepare()
            XCTFail("cancelled retry continued")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(fixture.registrations, 1)
        XCTAssertEqual(fixture.unregisteredPIDs.count, 1)
        XCTAssertTrue(fixture.pendingRecovery)
        XCTAssertTrue(fixture.savedMarkers.isEmpty)
    }

    func testNonEPERMRetryFailureStopsImmediately() async {
        let fixture = reconciliationFixture()
        fixture.onRegister = {
            if fixture.registrations == 1 { throw Self.smDenial }
            throw TestFailure.registration
        }
        do {
            try await fixture.coordinator().prepare()
            XCTFail("general registration failure was retried")
        } catch {
            XCTAssertEqual(error as? TestFailure, .registration)
        }
        XCTAssertEqual(fixture.registrations, 2)
        XCTAssertEqual(fixture.unregisteredPIDs.count, 1)
    }

    func testAlreadyRegisteredResultIsNotAcceptedAsRetrySuccess() async {
        let fixture = reconciliationFixture()
        fixture.onRegister = {
            if fixture.registrations == 1 { throw Self.smDenial }
            fixture.status = .enabled
            return false
        }
        do {
            try await fixture.coordinator().prepare()
            XCTFail("AlreadyRegistered result became ready")
        } catch {
            XCTAssertEqual(error as? HelperRegistrationCoordinator.Failure, .registrationFailed)
        }
        XCTAssertEqual(fixture.registrations, 2)
        XCTAssertEqual(fixture.unregisteredPIDs.count, 1)
        XCTAssertEqual(fixture.finalizations, 0)
        XCTAssertTrue(fixture.savedMarkers.isEmpty)
    }

    func testFreshRegistrationDenialDoesNotInventAnUnregisterRecovery() async {
        let fixture = Fixture()
        fixture.status = .notRegistered
        fixture.runtime = .absent
        fixture.hasOwnedCommittedTarget = true
        fixture.onRegister = { throw Self.smDenial }
        await assertRegistrationDenied(fixture)
        XCTAssertEqual(fixture.registrations, 1)
        XCTAssertTrue(fixture.unregisteredPIDs.isEmpty)
    }

    func testRetriedRegistrationStillRequiresTheCurrentRuntimeHash() async {
        let fixture = reconciliationFixture()
        fixture.onRegister = {
            if fixture.registrations == 1 { throw Self.smDenial }
            fixture.status = .enabled
            fixture.runtime = .running(Fixture.legacyDaemon)
            return true
        }
        do {
            try await fixture.coordinator().prepare()
            XCTFail("wrong runtime became ready after reconciliation")
        } catch {
            XCTAssertEqual(error as? HelperRegistrationCoordinator.Failure, .versionMismatch)
        }
        XCTAssertEqual(fixture.registrations, 2)
        XCTAssertEqual(fixture.unregisteredPIDs.count, 1)
        XCTAssertEqual(fixture.finalizations, 0)
        XCTAssertTrue(fixture.savedMarkers.isEmpty)
    }

    private static var smDenial: NSError { NSError(domain: "SMAppServiceErrorDomain", code: 1) }

    private func reconciliationFixture() -> Fixture {
        let fixture = Fixture()
        fixture.onUnregister = { _ in
            fixture.status = .notRegistered
            fixture.runtime = .absent
            fixture.pendingRecovery = true
            fixture.hasOwnedCommittedTarget = true
        }
        return fixture
    }

    private func assertRegistrationDenied(_ fixture: Fixture) async {
        do {
            try await fixture.coordinator().prepare()
            XCTFail("denied registration became ready")
        } catch {
            XCTAssertEqual((error as NSError).domain, "SMAppServiceErrorDomain")
            XCTAssertEqual((error as NSError).code, 1)
        }
        XCTAssertTrue(fixture.savedMarkers.isEmpty)
        XCTAssertFalse(fixture.stages.contains(.ready))
    }

    private enum TestFailure: Error { case unregistration, registration, runaway }

    @MainActor
    private final class Fixture {
        static let currentDaemon = HelperRegistrationCoordinator.Daemon(
            pid: 42, executableHash: "current-binary", handoffProtocolVersion: 1
        )
        static let legacyDaemon = HelperRegistrationCoordinator.Daemon(
            pid: 42, executableHash: "legacy-binary", handoffProtocolVersion: 0
        )
        static let maintenanceTarget = HelperRegistrationCoordinator.MaintenanceTarget(
            token: "committed-transaction",
            targetHash: "current-binary",
            registrationFingerprint: "current-registration"
        )
        var time: TimeInterval = 0
        var status: HelperRegistrationCoordinator.ServiceStatus = .enabled
        var runtime: HelperRegistrationCoordinator.Runtime = .running(currentDaemon)
        var marker: String?
        var pendingRecovery = false
        var hasOwnedCommittedTarget = false
        var currentMaintenanceTarget: HelperRegistrationCoordinator.MaintenanceTarget?
        var finalizations = 0
        var onFinalize: (() throws -> Void)?
        var maintenanceAllowed = true
        var legacyExclusive = true
        var legacyIdle = true
        var registrations = 0
        var registrationTimes: [TimeInterval] = []
        var runtimeReads = 0
        var unregisteredPIDs: [Int32?] = []
        var unregisterTimes: [TimeInterval] = []
        var respawnTimes: [TimeInterval] = []
        var savedMarkers: [String] = []
        var stages: [HelperRegistrationCoordinator.Stage] = []
        var onSleep: (() throws -> Void)?
        var onRuntime: (() -> HelperRegistrationCoordinator.Runtime)?
        var onRegister: (() throws -> Bool)?
        var onUnregister: ((HelperRegistrationCoordinator.Daemon?) throws -> Void)?
        var onRespawn: (() -> Bool)?

        func coordinator() -> HelperRegistrationCoordinator {
            var limits = HelperRegistrationCoordinator.Limits()
            limits.startup = 1
            limits.approval = 3
            limits.legacyIdle = 4
            limits.poll = 0.25
            return HelperRegistrationCoordinator(
                fingerprint: "current-registration",
                expectedExecutableHash: "current-binary",
                limits: limits,
                io: .init(
                    status: { self.status },
                    runtime: {
                        self.runtimeReads += 1
                        return self.onRuntime?() ?? self.runtime
                    },
                    registrationMarker: { self.pendingRecovery ? nil : self.marker },
                    pendingMaintenanceRecovery: { self.pendingRecovery },
                    storeRegistrationMarker: {
                        self.savedMarkers.append($0)
                        self.marker = $0
                    },
                    maintenanceAllowed: { self.maintenanceAllowed },
                    legacyMaintenanceIsExclusive: { _ in self.legacyExclusive },
                    legacyEngineIsIdle: { self.legacyIdle },
                    unregister: {
                        self.unregisteredPIDs.append($0?.pid)
                        self.unregisterTimes.append(self.time)
                        if let operation = self.onUnregister { try operation($0) }
                        else { self.status = .notRegistered }
                        self.runtime = .absent
                        self.pendingRecovery = true
                        self.hasOwnedCommittedTarget = true
                        self.currentMaintenanceTarget = Self.maintenanceTarget
                        return Self.maintenanceTarget
                    },
                    registrationMaintenanceTarget: {
                        self.hasOwnedCommittedTarget ? self.currentMaintenanceTarget : nil
                    },
                    register: {
                        self.registrations += 1
                        self.registrationTimes.append(self.time)
                        if let operation = self.onRegister { return try operation() }
                        self.status = .enabled
                        self.runtime = .running(Self.currentDaemon)
                        return true
                    },
                    canReconcileRegistrationFailure: {
                        let error = $0 as NSError
                        return error.domain == "SMAppServiceErrorDomain" && error.code == 1
                            && self.hasOwnedCommittedTarget
                    },
                    finishMaintenance: {
                        self.finalizations += 1
                        try self.onFinalize?()
                        self.pendingRecovery = false
                    },
                    stageChanged: { self.stages.append($0) },
                    now: { self.time },
                    sleep: {
                        self.time += $0
                        guard self.time <= 60 else { throw TestFailure.runaway }
                        try self.onSleep?()
                    }
                )
            )
        }
    }
}
