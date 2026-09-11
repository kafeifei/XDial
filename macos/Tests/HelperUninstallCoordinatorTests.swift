import XCTest

@MainActor
final class HelperUninstallCoordinatorTests: XCTestCase {
    func testWaitsForUnregisterCompletionBeforeCheckingExitAndClearingIntent() async throws {
        var registration: HelperUninstallCoordinator.RegistrationStatus = .registered
        var processes: HelperUninstallCoordinator.ProcessSnapshot = .available([42])
        var resumeUnregister: CheckedContinuation<Void, Never>?
        var events: [String] = []
        let coordinator = makeCoordinator(
            registration: { registration },
            processes: { _ in
                events.append("process-check")
                return processes
            },
            unregister: {
                events.append("unregister-begin")
                await withCheckedContinuation { resumeUnregister = $0 }
                events.append("unregister-complete")
                registration = .removed
                processes = .available([])
            },
            clear: { events.append("intent-cleared") }
        )

        let task = Task { try await coordinator.run() }
        for _ in 0..<20 where resumeUnregister == nil { await Task.yield() }
        XCTAssertNotNil(resumeUnregister)
        XCTAssertEqual(events, ["process-check", "unregister-begin"])

        resumeUnregister?.resume()
        try await task.value
        XCTAssertEqual(events, [
            "process-check", "unregister-begin", "unregister-complete",
            "process-check", "intent-cleared",
        ])
    }

    func testUnregisterErrorStopsBeforeIntentClear() async {
        var cleared = false
        let coordinator = makeCoordinator(
            registration: { .registered },
            processes: { _ in .available([42]) },
            unregister: { throw TestError.unregisterFailed },
            clear: { cleared = true }
        )

        do {
            try await coordinator.run()
            XCTFail("failed unregister passed the teardown barrier")
        } catch {
            XCTAssertEqual(error as? TestError, .unregisterFailed)
        }
        XCTAssertFalse(cleared)
    }

    func testWaitsForOwnedPIDExitAfterRegistrationIsRemoved() async throws {
        var processes: HelperUninstallCoordinator.ProcessSnapshot = .available([42])
        var time: TimeInterval = 0
        var clearedAt: TimeInterval?
        var limits = HelperUninstallCoordinator.Limits()
        limits.teardown = 3
        limits.poll = 1
        // Model SM completion changing the structured status while PID 42 is
        // still terminating.
        var status: HelperUninstallCoordinator.RegistrationStatus = .registered
        let waitingCoordinator = HelperUninstallCoordinator(limits: limits, io: .init(
            unregisterPending: { false },
            registrationStatus: { status },
            ownedProcesses: { _ in processes },
            unregister: { status = .removed },
            clearMaintenanceIntent: { clearedAt = time },
            now: { time },
            sleep: {
                time += $0
                if time >= 2 { processes = .available([]) }
            }
        ))
        try await waitingCoordinator.run()
        XCTAssertEqual(clearedAt, 2)
    }

    func testProcessTimeoutDoesNotClearIntent() async {
        var status: HelperUninstallCoordinator.RegistrationStatus = .registered
        var time: TimeInterval = 0
        var cleared = false
        var limits = HelperUninstallCoordinator.Limits()
        limits.teardown = 2
        limits.poll = 1
        let coordinator = HelperUninstallCoordinator(limits: limits, io: .init(
            unregisterPending: { false },
            registrationStatus: { status },
            ownedProcesses: { _ in .available([42]) },
            unregister: { status = .removed },
            clearMaintenanceIntent: { cleared = true },
            now: { time },
            sleep: { time += $0 }
        ))

        do {
            try await coordinator.run()
            XCTFail("live helper passed the teardown barrier")
        } catch {
            XCTAssertEqual(error as? HelperUninstallCoordinator.Failure, .processExitTimedOut)
        }
        XCTAssertFalse(cleared)
    }

    func testUnknownProcessStateDoesNotStartUnregister() async {
        var unregistered = false
        let coordinator = makeCoordinator(
            registration: { .registered },
            processes: { _ in .unknown },
            unregister: { unregistered = true },
            clear: {}
        )

        do {
            try await coordinator.run()
            XCTFail("unknown owner state started teardown")
        } catch {
            XCTAssertEqual(error as? HelperUninstallCoordinator.Failure, .processStateUnknown)
        }
        XCTAssertFalse(unregistered)
    }

    func testAuthenticatedOutgoingPIDForcesUnregisterWhenIncomingStatusIsRemoved() async throws {
        var unregistered = false
        var processes: HelperUninstallCoordinator.ProcessSnapshot = .available([42])
        let coordinator = HelperUninstallCoordinator(
            authenticatedProcessIDs: [42],
            io: .init(
                unregisterPending: { false },
                registrationStatus: { .removed },
                ownedProcesses: { retained in
                    guard case let .available(pids) = processes else { return .unknown }
                    return .available(pids.intersection(retained))
                },
                unregister: {
                    unregistered = true
                    processes = .available([])
                },
                clearMaintenanceIntent: {},
                now: { 0 },
                sleep: { _ in XCTFail("unexpected wait") }
            )
        )

        try await coordinator.run()
        XCTAssertTrue(unregistered)
    }

    func testReplacementForcesUnregisterWhenIncomingStatusCannotSeeRegistration() async throws {
        var unregistered = false
        let coordinator = HelperUninstallCoordinator(
            requiresUnregister: true,
            io: .init(
                unregisterPending: { false },
                registrationStatus: { .removed },
                ownedProcesses: { _ in .available([]) },
                unregister: { unregistered = true },
                clearMaintenanceIntent: {},
                now: { 0 },
                sleep: { _ in XCTFail("unexpected wait") }
            )
        )

        try await coordinator.run()
        XCTAssertTrue(unregistered)
    }

    func testTimedOutUnregisterBlocksRemovedStateRetryUntilRealCompletion() async throws {
        let gate = HelperRegistrationMutationGate()
        var status: HelperUninstallCoordinator.RegistrationStatus = .registered
        var cleared = false
        let coordinator = HelperUninstallCoordinator(io: .init(
            unregisterPending: { gate.hasPendingUnregister },
            registrationStatus: { status },
            ownedProcesses: { _ in .available([]) },
            unregister: {
                try gate.beginUnregister()
                status = .removed
                throw TestError.unregisterTimedOut
            },
            clearMaintenanceIntent: { cleared = true },
            now: { 0 },
            sleep: { _ in XCTFail("unexpected wait") }
        ))

        do {
            try await coordinator.run()
            XCTFail("timed out unregister succeeded")
        } catch {
            XCTAssertEqual(error as? TestError, .unregisterTimedOut)
        }
        do {
            try await coordinator.run()
            XCTFail("removed status bypassed an unregister without completion")
        } catch {
            XCTAssertEqual(error as? HelperUninstallCoordinator.Failure, .unregisterPending)
        }
        XCTAssertFalse(cleared)

        gate.completeUnregister()
        try await coordinator.run()
        XCTAssertTrue(cleared)
    }

    func testRegistrationMutationGateBlocksUntilUnregisterCompletion() throws {
        let gate = HelperRegistrationMutationGate()
        try gate.beginUnregister()
        XCTAssertTrue(gate.hasPendingUnregister)
        XCTAssertThrowsError(try gate.withRegistration { "registered" }) { error in
            XCTAssertEqual(error as? HelperRegistrationMutationGate.Failure, .unregisterPending)
        }

        gate.completeUnregister()
        XCTAssertFalse(gate.hasPendingUnregister)
        XCTAssertEqual(try gate.withRegistration { "registered" }, "registered")
    }

    func testOwnedProcessSelectionUsesExactBundleExecutablePath() {
        let bundle = URL(fileURLWithPath: "/Applications/XDial.app")
        let owned = bundle.appendingPathComponent("Contents/MacOS/xdial-daemon")
        let foreign = URL(fileURLWithPath: "/Applications/Other.app/Contents/MacOS/xdial-daemon")
        let snapshot = LocalProcessInventory.Snapshot.available([
            .init(pid: 41, name: "xdial-daemon", executableURL: foreign),
            .init(pid: 42, name: "renamed", executableURL: owned),
        ])

        XCTAssertEqual(
            HelperUninstallCoordinator.ownedDaemonProcesses(in: snapshot, bundleURLs: [bundle]),
            .available([42])
        )
    }

    func testSameNameWithoutExecutablePathIsUnknownRatherThanOwned() {
        let snapshot = LocalProcessInventory.Snapshot.available([
            .init(pid: 42, name: "xdial-daemon", executableURL: nil),
        ])
        XCTAssertEqual(
            HelperUninstallCoordinator.ownedDaemonProcesses(
                in: snapshot, bundleURLs: [URL(fileURLWithPath: "/Applications/XDial.app")]
            ),
            .unknown
        )
    }

    func testAuthenticatedPIDRemainsOwnedAfterItsBundlePathMoves() {
        let moved = URL(fileURLWithPath: "/Applications/.XDial.backup-old.app")
            .appendingPathComponent("Contents/MacOS/xdial-daemon")
        let snapshot = LocalProcessInventory.Snapshot.available([
            .init(pid: 42, name: "xdial-daemon", executableURL: moved),
        ])

        XCTAssertEqual(
            HelperUninstallCoordinator.ownedDaemonProcesses(
                in: snapshot,
                bundleURLs: [URL(fileURLWithPath: "/Applications/XDial.app")],
                retaining: [42]
            ),
            .available([42])
        )
    }

    private func makeCoordinator(
        registration: @escaping () -> HelperUninstallCoordinator.RegistrationStatus,
        processes: @escaping (Set<Int32>) -> HelperUninstallCoordinator.ProcessSnapshot,
        unregister: @escaping () async throws -> Void,
        clear: @escaping () throws -> Void
    ) -> HelperUninstallCoordinator {
        HelperUninstallCoordinator(io: .init(
            unregisterPending: { false },
            registrationStatus: registration,
            ownedProcesses: processes,
            unregister: unregister,
            clearMaintenanceIntent: clear,
            now: { 0 },
            sleep: { _ in XCTFail("unexpected wait") }
        ))
    }

    private enum TestError: Error, Equatable {
        case unregisterFailed
        case unregisterTimedOut
    }
}
