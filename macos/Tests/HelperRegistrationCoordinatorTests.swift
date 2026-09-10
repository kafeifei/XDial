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

    func testPostUnregisterSMDenialReconcilesOnceWithinSameInstallation() async throws {
        let fixture = Fixture()
        var operations: [String] = []
        fixture.onUnregister = { _ in
            operations.append("unregister-completed")
            fixture.status = .notRegistered
            fixture.runtime = .absent
            fixture.pendingRecovery = true
            fixture.hasOwnedCommittedTarget = true
            XCTAssertTrue(fixture.savedMarkers.isEmpty)
        }
        fixture.onRegister = {
            operations.append("register")
            if fixture.registrations == 1 { throw Self.smDenial }
            fixture.status = .enabled
            fixture.runtime = .running(Fixture.currentDaemon)
            return true
        }
        fixture.onFinalize = { operations.append("finalize-acknowledged") }
        try await fixture.coordinator().prepare()
        XCTAssertEqual(operations, ["unregister-completed", "register", "unregister-completed", "register", "finalize-acknowledged"])
        XCTAssertEqual(fixture.registrations, 2)
        XCTAssertEqual(fixture.unregisteredPIDs, [Fixture.currentDaemon.pid, nil])
        XCTAssertEqual(fixture.stages.filter { $0 == .reconcilingRegistration }.count, 1)
        XCTAssertEqual(fixture.savedMarkers, ["current-registration"])
        XCTAssertEqual(fixture.stages.last, .ready)
    }

    func testRepeatedPostUnregisterDenialStopsAfterOneReconciliation() async {
        let fixture = reconciliationFixture()
        fixture.onRegister = { throw Self.smDenial }
        await assertRegistrationDenied(fixture)
        XCTAssertEqual(fixture.registrations, 2)
        XCTAssertEqual(fixture.unregisteredPIDs.count, 2)
        XCTAssertEqual(fixture.finalizations, 0)
        XCTAssertTrue(fixture.savedMarkers.isEmpty)
    }

    func testReconciliationRequiresServiceDomainCodeAndOwnedCommittedTarget() async {
        for invalidCase in 0..<4 {
            let fixture = reconciliationFixture()
            fixture.onRegister = {
                switch invalidCase {
                case 0: throw NSError(domain: NSPOSIXErrorDomain, code: 1)
                case 1: throw NSError(domain: "SMAppServiceErrorDomain", code: 4)
                case 2: fixture.hasOwnedCommittedTarget = false
                default: fixture.pendingRecovery = false
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

    func testReconciliationPreservesUnknownLiveBusyAndApprovalStates() async {
        for invalidCase in 0..<5 {
            let fixture = reconciliationFixture()
            fixture.onRegister = {
                switch invalidCase {
                case 0: fixture.runtime = .unknown
                case 1: fixture.runtime = .unresponsive
                case 2: fixture.runtime = .running(Fixture.currentDaemon)
                case 3: fixture.maintenanceAllowed = false
                default: fixture.status = .requiresApproval
                }
                throw Self.smDenial
            }
            await assertRegistrationDenied(fixture)
            XCTAssertEqual(fixture.registrations, 1)
            XCTAssertEqual(fixture.unregisteredPIDs.count, 1)
            XCTAssertFalse(fixture.stages.contains(.reconcilingRegistration))
        }
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

    func testReconciliationBarrierFailureCannotProceedToRegister() async {
        let fixture = reconciliationFixture()
        fixture.onRegister = {
            fixture.onUnregister = { _ in throw TestFailure.unregistration }
            throw Self.smDenial
        }
        do {
            try await fixture.coordinator().prepare()
            XCTFail("second registration bypassed failed unregister barrier")
        } catch {
            XCTAssertEqual(error as? TestFailure, .unregistration)
        }
        XCTAssertEqual(fixture.registrations, 1)
        XCTAssertEqual(fixture.unregisteredPIDs.count, 2)
        XCTAssertTrue(fixture.savedMarkers.isEmpty)
    }

    func testReconciledRegistrationStillRequiresTheCurrentRuntimeHash() async {
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
        var time: TimeInterval = 0
        var status: HelperRegistrationCoordinator.ServiceStatus = .enabled
        var runtime: HelperRegistrationCoordinator.Runtime = .running(currentDaemon)
        var marker: String?
        var pendingRecovery = false
        var hasOwnedCommittedTarget = false
        var finalizations = 0
        var onFinalize: (() throws -> Void)?
        var maintenanceAllowed = true
        var legacyExclusive = true
        var legacyIdle = true
        var registrations = 0
        var unregisteredPIDs: [Int32?] = []
        var unregisterTimes: [TimeInterval] = []
        var respawnTimes: [TimeInterval] = []
        var savedMarkers: [String] = []
        var stages: [HelperRegistrationCoordinator.Stage] = []
        var onSleep: (() throws -> Void)?
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
                    runtime: { self.runtime },
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
                    },
                    register: {
                        self.registrations += 1
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
                        guard self.time < 30 else { throw TestFailure.runaway }
                        try self.onSleep?()
                    }
                )
            )
        }
    }
}
