import Foundation

enum RelaySocketDirectoryError: Error, Equatable, LocalizedError {
    /// The socket path does not fit `sockaddr_un.sun_path`.
    case pathTooLong(Int)

    var errorDescription: String? {
        switch self {
        case let .pathTooLong(length):
            return "relay socket path is \(length) bytes, over the "
                + "\(RelaySocketDirectory.pathLimit) byte limit"
        }
    }
}

/// The directory that holds the Provider's relay sockets.
///
/// Each sing-box generation listens on its own socket file here and removes
/// it when it stops. Whatever the directory holds when a Provider process
/// first uses it was left by an earlier process.
///
/// A socket is named after the process and a counter. While a system
/// extension is replaced, the old process may still be closing its listeners
/// as the new one binds, and a listener removes its file by name: the two
/// must never share one.
final class RelaySocketDirectory: @unchecked Sendable {
    /// `sockaddr_un.sun_path` holds 104 bytes on Darwin, one of them the
    /// terminating NUL.
    static let pathLimit = 103
    static let name = "relay"

    let directory: URL
    private let fileManager: FileManager
    private let processID: Int32
    private let lock = NSLock()
    private var prepared = false
    private var nextSocketNumber: UInt32 = 1

    init(
        container: URL,
        fileManager: FileManager = .default,
        processID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
        directory = container.appendingPathComponent(
            Self.name,
            isDirectory: true
        )
        self.fileManager = fileManager
        self.processID = processID
    }

    /// Reserves a socket path no other generation of this process uses.
    ///
    /// The first call clears what a previous process left behind and makes the
    /// directory owner-only; the sockets inside are owner-only as well.
    func makeSocketPath() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        let path = try Self.socketPath(
            in: directory,
            processID: processID,
            number: nextSocketNumber
        )
        if !prepared {
            try prepare()
            prepared = true
        }
        nextSocketNumber &+= 1
        return path
    }

    /// The path of this process's socket `number` in `directory`, or an error
    /// when the kernel would not take it: a longer path fails to bind, it is
    /// not shortened. Base 36 keeps the name within the few bytes the group
    /// container path leaves.
    static func socketPath(
        in directory: URL,
        processID: Int32,
        number: UInt32
    ) throws -> String {
        let name = String(processID, radix: 36)
            + "-" + String(number, radix: 36)
        let path = directory.appendingPathComponent(
            name,
            isDirectory: false
        ).path
        guard path.utf8.count <= pathLimit else {
            throw RelaySocketDirectoryError.pathTooLong(path.utf8.count)
        }
        return path
    }

    private func prepare() throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // An existing directory keeps the mode it was created with.
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        for entry in try fileManager.contentsOfDirectory(atPath: directory.path) {
            try fileManager.removeItem(
                at: directory.appendingPathComponent(entry)
            )
        }
    }
}
