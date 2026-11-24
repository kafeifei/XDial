import XCTest

final class RelaySocketDirectoryTests: XCTestCase {
    private var container: URL!

    override func setUpWithError() throws {
        container = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("xdrd-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: container, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: container)
    }

    func testSocketsLiveInAnOwnerOnlyDirectory() throws {
        let sockets = RelaySocketDirectory(container: container)
        let path = try sockets.makeSocketPath()
        XCTAssertEqual(
            URL(fileURLWithPath: path).deletingLastPathComponent().path,
            container.appendingPathComponent("relay").path
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: sockets.directory.path
        )
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o700)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: path),
            "reserving a path creates nothing; sing-box binds it"
        )
    }

    func testAnExistingDirectoryIsTightenedToOwnerOnly() throws {
        let directory = container.appendingPathComponent("relay", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        _ = try RelaySocketDirectory(container: container).makeSocketPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o700)
    }

    /// A Provider that crashed leaves its socket files behind. The next
    /// process clears them once, and never touches its own afterwards.
    func testLeftoversAreClearedOnceAtFirstUse() throws {
        let directory = container.appendingPathComponent("relay", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stale = directory.appendingPathComponent("7")
        try Data().write(to: stale)

        let sockets = RelaySocketDirectory(container: container)
        let first = try sockets.makeSocketPath()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))

        // The live generation's socket must survive later reservations.
        try Data().write(to: URL(fileURLWithPath: first))
        let second = try sockets.makeSocketPath()
        XCTAssertTrue(FileManager.default.fileExists(atPath: first))
        XCTAssertNotEqual(first, second)
    }

    func testPathsAreNeverReusedWithinAProcess() throws {
        let sockets = RelaySocketDirectory(container: container)
        let paths = try (0..<64).map { _ in try sockets.makeSocketPath() }
        XCTAssertEqual(Set(paths).count, paths.count)
    }

    /// While a system extension is replaced, the old process may still be
    /// closing its listeners — each removes its socket file by name — as the
    /// new process binds its first ones.
    func testTwoProcessesNeverShareASocketName() throws {
        let old = RelaySocketDirectory(container: container, processID: 4_001)
        let new = RelaySocketDirectory(container: container, processID: 4_002)
        let oldPaths = try (0..<8).map { _ in try old.makeSocketPath() }
        let newPaths = try (0..<8).map { _ in try new.makeSocketPath() }
        XCTAssertTrue(Set(oldPaths).isDisjoint(with: newPaths))
    }

    func testAPathTheKernelWouldRefuseIsReportedBeforeAnythingListens() {
        // "/" + 98 bytes + "/1-f" is 103 bytes: the last path that fits.
        let atLimit = URL(fileURLWithPath: "/" + String(repeating: "a", count: 98))
        XCTAssertNoThrow(
            try RelaySocketDirectory.socketPath(
                in: atLimit, processID: 1, number: 15
            )
        )
        XCTAssertThrowsError(
            try RelaySocketDirectory.socketPath(
                in: atLimit, processID: 1, number: 36
            )
        ) { error in
            XCTAssertEqual(
                error as? RelaySocketDirectoryError,
                .pathTooLong(104)
            )
            XCTAssertEqual(
                error.localizedDescription,
                "relay socket path is 104 bytes, over the 103 byte limit"
            )
        }
    }

    /// The system extension runs as root, so its group container is under
    /// root's home. Every shipped identity must leave room for the socket
    /// name: the largest process ID macOS hands out, and more generations
    /// than a Provider process will ever start.
    func testEveryShippedIdentityFitsTheSocketPathLimit() throws {
        let groups = [
            "UVZM439VGU.com.kafeifei.xdial.network",
            "UVZM439VGU.com.kafeifei.xdial.debug.network",
            XDialBuildIdentity.appGroupIdentifier,
        ]
        for group in groups {
            let directory = URL(
                fileURLWithPath: "/private/var/root/Library/Group Containers/\(group)",
                isDirectory: true
            ).appendingPathComponent(RelaySocketDirectory.name, isDirectory: true)
            let path = try RelaySocketDirectory.socketPath(
                in: directory, processID: 99_998, number: 60_466_175
            )
            XCTAssertLessThanOrEqual(
                path.utf8.count, RelaySocketDirectory.pathLimit, group
            )
        }
    }
}
