import Darwin
import Foundation
import XCTest

final class HelperRegistrationMaintenanceIntentTests: XCTestCase {
    private typealias Intent = HelperRegistrationMaintenanceIntent

    func testEstablishPreservesExistingTransactionAndPublishesPrivateSingleLink() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = try Intent.establish(targetHash: "first", previousPID: 42, at: fixture.path)
        let second = try Intent.establish(targetHash: "second", previousPID: 99, at: fixture.path)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try Intent.read(at: fixture.path), first)
        var metadata = stat()
        XCTAssertEqual(lstat(fixture.path, &metadata), 0)
        XCTAssertEqual(metadata.st_nlink, 1)
        XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
        XCTAssertEqual(metadata.st_uid, getuid())
    }

    func testFailedPublicationPreservesOldCompleteRecordAndRemovesTemporaryFile() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = try Intent.establish(targetHash: "original", previousPID: 42, at: fixture.path)
        // A real rename failure after writing/fsyncing the temporary record.
        guard chflags(fixture.path, UInt32(UF_IMMUTABLE)) == 0 else {
            throw XCTSkip("Fixture filesystem does not support user immutable flags")
        }
        defer { _ = chflags(fixture.path, 0) }
        XCTAssertThrowsError(try Intent.update(token: original.token, phase: "committed", at: fixture.path))
        XCTAssertEqual(try Intent.read(at: fixture.path), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted(),
                       ["intent", "intent.lock"])
    }

    func testUnrepresentableUpdateCannotReplaceReadableRecord() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = try Intent.establish(targetHash: "original", previousPID: nil, at: fixture.path)
        XCTAssertThrowsError(try Intent.update(token: original.token,
                                              phase: String(repeating: "x", count: 4096), at: fixture.path))
        XCTAssertEqual(try Intent.read(at: fixture.path), original)
    }

    func testConcurrentEstablishConvergesOnOneToken() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 24) { index in
            do {
                let record = try Intent.establish(targetHash: "hash-\(index)", previousPID: nil, at: fixture.path)
                results.addToken(record.token)
            } catch { results.addError(error) }
        }
        XCTAssertTrue(results.errors.isEmpty, results.errors.joined(separator: "\n"))
        XCTAssertEqual(Set(results.tokens).count, 1)
        XCTAssertEqual(try Intent.read(at: fixture.path)?.token, results.tokens.first)
    }

    func testAtomicUpdatesNeverExposeEmptyMissingOrMalformedRecord() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = try Intent.establish(targetHash: "hash", previousPID: 42, at: fixture.path)
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 4) { worker in
            for index in 0..<80 {
                do {
                    if worker == 0 {
                        try Intent.update(token: original.token, phase: "committed-\(index)", at: fixture.path)
                    } else {
                        guard let record = try Intent.read(at: fixture.path),
                              record.token == original.token, record.targetHash == "hash",
                              record.phase == "prepared" || record.phase.hasPrefix("committed-") else {
                            results.addError(TestFailure.incompleteRead)
                            continue
                        }
                    }
                } catch { results.addError(error) }
            }
        }
        XCTAssertTrue(results.errors.isEmpty, results.errors.joined(separator: "\n"))
    }

    func testWaitingOldTokenCannotClearOrOverwriteSuccessor() throws {
        for clears in [true, false] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let original = try Intent.establish(targetHash: "old", previousPID: 42, at: fixture.path)
            let descriptor = open(fixture.path + ".lock", O_RDONLY | O_NOFOLLOW)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            guard descriptor >= 0 else { return }
            defer { Darwin.close(descriptor) }
            XCTAssertEqual(flock(descriptor, LOCK_EX), 0)
            let started = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            let results = Results()
            DispatchQueue.global().async {
                started.signal()
                do {
                    if clears { try Intent.clear(token: original.token, at: fixture.path) }
                    else { try Intent.update(token: original.token, phase: "aborted", at: fixture.path) }
                } catch { results.addError(error) }
                finished.signal()
            }
            XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
            // The delayed operation must wait on the same lock as a root finalizer.
            XCTAssertEqual(finished.wait(timeout: .now() + 0.05), .timedOut)
            let successor = Intent.Record(version: 1, token: UUID().uuidString,
                                          targetHash: "new", phase: "prepared", previousPID: nil,
                                          registrationFingerprint: nil)
            // Emulate the current lock owner publishing its successor token.
            let replacement = fixture.root.appendingPathComponent("replacement")
            try JSONEncoder().encode(successor).write(to: replacement)
            XCTAssertEqual(chmod(replacement.path, 0o600), 0)
            XCTAssertEqual(rename(replacement.path, fixture.path), 0)
            XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
            XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
            XCTAssertEqual(results.errors.count, 1)
            XCTAssertEqual(try Intent.read(at: fixture.path), successor)
        }
    }

    func testUnsafeIntentLinksAndPermissionsCannotBeModified() throws {
        for kind in ["symlink", "hardlink", "permissions"] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let original = try Intent.establish(targetHash: "original", previousPID: nil, at: fixture.path)
            let originalBytes = try Data(contentsOf: URL(fileURLWithPath: fixture.path))
            let target = fixture.root.appendingPathComponent("retained")
            if kind == "symlink" {
                XCTAssertEqual(rename(fixture.path, target.path), 0)
                XCTAssertEqual(symlink(target.path, fixture.path), 0)
            } else if kind == "hardlink" {
                XCTAssertEqual(link(fixture.path, target.path), 0)
            } else {
                XCTAssertEqual(chmod(fixture.path, 0o644), 0)
            }
            XCTAssertThrowsError(try Intent.read(at: fixture.path))
            XCTAssertThrowsError(try Intent.establish(targetHash: "new", previousPID: nil, at: fixture.path))
            XCTAssertThrowsError(try Intent.update(token: original.token, phase: "committed", at: fixture.path))
            XCTAssertThrowsError(try Intent.clear(token: original.token, at: fixture.path))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixture.path)), originalBytes)
        }
    }

    func testUnsafeLockCannotAuthorizeMutation() throws {
        for kind in ["symlink", "hardlink", "permissions"] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let original = try Intent.establish(targetHash: "original", previousPID: nil, at: fixture.path)
            let lockPath = fixture.path + ".lock"
            let target = fixture.root.appendingPathComponent("retained-lock").path
            if kind == "symlink" {
                XCTAssertEqual(rename(lockPath, target), 0)
                XCTAssertEqual(symlink(target, lockPath), 0)
            } else if kind == "hardlink" {
                XCTAssertEqual(link(lockPath, target), 0)
            } else {
                XCTAssertEqual(chmod(lockPath, 0o644), 0)
            }
            XCTAssertThrowsError(try Intent.update(token: original.token, phase: "committed", at: fixture.path))
            XCTAssertThrowsError(try Intent.clear(token: original.token, at: fixture.path))
            XCTAssertThrowsError(try Intent.read(at: fixture.path))
            let retained = try JSONDecoder().decode(Intent.Record.self,
                from: Data(contentsOf: URL(fileURLWithPath: fixture.path)))
            XCTAssertEqual(retained, original)
        }
    }

    func testForeignOwnerIsRejectedEvenWithPrivateRegularSingleLinkMetadata() throws {
        var metadata = stat()
        metadata.st_uid = getuid()
        metadata.st_nlink = 1
        metadata.st_mode = S_IFREG | 0o600
        XCTAssertNoThrow(try Intent.validateMetadata(metadata))
        metadata.st_uid = getuid() == 0 ? 1 : 0
        XCTAssertThrowsError(try Intent.validateMetadata(metadata))
    }

    func testNextMutationReclaimsOwnedPartialTemporaryFilesOnly() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = try Intent.establish(targetHash: "original", previousPID: nil, at: fixture.path)
        let abandoned = fixture.path + "." + UUID().uuidString
        let invalidName = fixture.path + ".not-a-uuid"
        let wrongPermissions = fixture.path + "." + UUID().uuidString
        let symbolic = fixture.path + "." + UUID().uuidString
        let hardLinked = fixture.path + "." + UUID().uuidString
        let hardLinkTarget = fixture.root.appendingPathComponent("other-file").path
        for path in [abandoned, invalidName, wrongPermissions, hardLinked] {
            try Data("partial JSON".utf8).write(to: URL(fileURLWithPath: path))
            XCTAssertEqual(chmod(path, 0o600), 0)
        }
        XCTAssertEqual(chmod(wrongPermissions, 0o644), 0)
        XCTAssertEqual(symlink(fixture.path, symbolic), 0)
        XCTAssertEqual(link(hardLinked, hardLinkTarget), 0)
        XCTAssertEqual(try Intent.establish(targetHash: "ignored", previousPID: nil, at: fixture.path), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned))
        for path in [invalidName, wrongPermissions, symbolic, hardLinked, hardLinkTarget] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        }
        XCTAssertEqual(try Intent.read(at: fixture.path), original)
    }

    func testRegisteredExecutableCannotProveDifferentRegistrationFingerprint() throws {
        let record = Intent.Record(
            version: 1, token: "transaction", targetHash: "same-helper",
            phase: "registered", previousPID: nil,
            registrationFingerprint: "old-plist-and-build"
        )

        XCTAssertNil(record.verifiedRegistrationFingerprint(
            matching: "new-plist-and-build", executableHash: "same-helper"
        ))
    }

    func testRegisteredRecordProvesExactRegistrationFingerprint() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = try Intent.establish(
            targetHash: "current-helper", previousPID: 42, at: fixture.path
        )
        try Intent.update(
            token: original.token, phase: "registered",
            targetHash: "current-helper", registrationFingerprint: "current-registration",
            at: fixture.path
        )

        let record = try XCTUnwrap(Intent.read(at: fixture.path))
        XCTAssertEqual(record.registrationFingerprint, "current-registration")
        XCTAssertEqual(record.verifiedRegistrationFingerprint(
            matching: "current-registration", executableHash: "current-helper"
        ), "current-registration")
    }

    func testLegacyRegisteredRecordWithoutFingerprintNeedsVerification() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let legacy = Data("""
            {"version":1,"token":"legacy","target_hash":"same-helper","phase":"registered"}
            """.utf8)
        try legacy.write(to: URL(fileURLWithPath: fixture.path))
        XCTAssertEqual(chmod(fixture.path, 0o600), 0)
        try Data().write(to: URL(fileURLWithPath: fixture.path + ".lock"))
        XCTAssertEqual(chmod(fixture.path + ".lock", 0o600), 0)

        let record = try XCTUnwrap(Intent.read(at: fixture.path))
        XCTAssertNil(record.registrationFingerprint)
        XCTAssertNil(record.verifiedRegistrationFingerprint(
            matching: "current-registration", executableHash: "same-helper"
        ))
    }

    private enum TestFailure: Error { case incompleteRead }

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var errors: [String] = []
        private(set) var tokens: [String] = []
        func addError(_ error: Error) {
            lock.lock()
            defer { lock.unlock() }
            errors.append(error.localizedDescription)
        }
        func addToken(_ token: String) {
            lock.lock()
            defer { lock.unlock() }
            tokens.append(token)
        }
    }

    private struct Fixture: @unchecked Sendable {
        let root: URL
        var path: String { root.appendingPathComponent("intent").path }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("xdial-intent-test-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
