import Darwin
import Foundation

/// Bridges an asynchronous OS unregister and a launchd KeepAlive start. A token
/// prevents a late completion from changing a successor installation's intent.
enum HelperRegistrationMaintenanceIntent {
    static let path = XDialBuildIdentity.registrationMaintenancePath

    struct Record: Codable, Equatable {
        let version: Int
        let token: String
        var targetHash: String
        var phase: String
        var previousPID: Int32?
        var registrationFingerprint: String?
        enum CodingKeys: String, CodingKey {
            case version, token, phase
            case targetHash = "target_hash"
            case previousPID = "previous_pid"
            case registrationFingerprint = "registration_fingerprint"
        }

        func verifiedRegistrationFingerprint(
            matching fingerprint: String, executableHash: String
        ) -> String? {
            guard phase == "registered", targetHash == executableHash,
                  registrationFingerprint == fingerprint else { return nil }
            return registrationFingerprint
        }
    }

    static func read(at path: String = path) throws -> Record? {
        try withFileLock(at: path, operation: LOCK_SH) {
            try readUnlocked(at: path)
        }
    }

    private static func readUnlocked(at path: String) throws -> Record? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw failure()
        }
        defer { Darwin.close(descriptor) }
        try validate(descriptor)
        let data = try readData(descriptor)
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.version == 1, !record.token.isEmpty else { throw denied() }
        return record
    }

    static func establish(targetHash: String, previousPID: Int32?, at path: String = path) throws -> Record {
        try withMutationLock(at: path) {
            if let existing = try readUnlocked(at: path) { return existing }
            let record = Record(version: 1, token: UUID().uuidString, targetHash: targetHash,
                                phase: "prepared", previousPID: previousPID,
                                registrationFingerprint: nil)
            try atomicWrite(record, at: path, replacing: false)
            return record
        }
    }

    static func update(
        token: String, phase: String, targetHash: String? = nil,
        registrationFingerprint: String? = nil, at path: String = path
    ) throws {
        try withMutationLock(at: path) {
            guard var record = try readUnlocked(at: path), record.token == token else { throw denied() }
            record.phase = phase
            if let targetHash { record.targetHash = targetHash }
            if let registrationFingerprint { record.registrationFingerprint = registrationFingerprint }
            try atomicWrite(record, at: path, replacing: true)
        }
    }

    static func clear(token: String, at path: String = path) throws {
        try withMutationLock(at: path) {
            guard let record = try readUnlocked(at: path) else { return }
            guard record.token == token else { throw denied() }
            guard unlink(path) == 0 else { throw failure() }
            try syncDirectory(containing: path)
        }
    }

    /// Go's finishRegistrationIntent uses this same stable flock. Never
    /// unlink the lock: another process may already be waiting on its inode.
    private static func withMutationLock<T>(at path: String, _ body: () throws -> T) throws -> T {
        try withFileLock(at: path, operation: LOCK_EX) {
            try removeAbandonedTemporaryFiles(at: path)
            return try body()
        }
    }

    private static func withFileLock<T>(at path: String, operation: Int32, _ body: () throws -> T) throws -> T {
        let lockPath = path + ".lock"
        var descriptor = open(lockPath, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if descriptor >= 0 {
            guard fchmod(descriptor, 0o600) == 0 else {
                let error = failure()
                Darwin.close(descriptor)
                throw error
            }
        } else if errno == EEXIST {
            descriptor = open(lockPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw failure() }
        defer { Darwin.close(descriptor) }
        try validate(descriptor)
        while flock(descriptor, operation) != 0 {
            guard errno == EINTR else { throw failure() }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static func removeAbandonedTemporaryFiles(at path: String) throws {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + "."
        // No cooperating writer can own a temporary file while we hold the
        // stable lock. Partial JSON is expected after a crash; its content is
        // not cleanup authority. The exact name and file metadata are required.
        for name in try FileManager.default.contentsOfDirectory(atPath: parent.path) {
            guard name.hasPrefix(prefix),
                  let uuid = UUID(uuidString: String(name.dropFirst(prefix.count))),
                  name == prefix + uuid.uuidString else { continue }
            let temporary = parent.appendingPathComponent(name).path
            let descriptor = open(temporary, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            defer { Darwin.close(descriptor) }
            guard (try? validate(descriptor)) != nil else { continue }
            var opened = stat()
            var current = stat()
            guard fstat(descriptor, &opened) == 0, lstat(temporary, &current) == 0,
                  opened.st_dev == current.st_dev, opened.st_ino == current.st_ino else { continue }
            guard unlink(temporary) == 0 else { throw failure() }
        }
    }

    private static func readData(_ descriptor: Int32) throws -> Data {
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw failure() }
            if count == 0 { return result }
            result.append(contentsOf: bytes.prefix(count))
            guard result.count < 4096 else { throw denied() }
        }
    }

    private static func atomicWrite(_ record: Record, at path: String, replacing: Bool) throws {
        let temporary = path + "." + UUID().uuidString
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw failure() }
        defer {
            Darwin.close(descriptor)
            unlink(temporary)
        }
        guard fchmod(descriptor, 0o600) == 0 else { throw failure() }
        let data = try JSONEncoder().encode(record)
        guard data.count < 4096 else { throw denied() }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw failure() }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw failure() }
        // RENAME_EXCL publishes without overwriting a competing path, and
        // without exposing a transient two-link inode to the root reader.
        if replacing {
            guard rename(temporary, path) == 0 else { throw failure() }
        } else {
            guard renamex_np(temporary, path, UInt32(RENAME_EXCL)) == 0 else { throw failure() }
        }
        try syncDirectory(containing: path)
    }

    private static func syncDirectory(containing path: String) throws {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let descriptor = open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure() }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw failure() }
    }

    private static func validate(_ descriptor: Int32) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw failure() }
        try validateMetadata(metadata)
    }

    static func validateMetadata(_ metadata: stat) throws {
        guard metadata.st_uid == getuid(), metadata.st_nlink == 1,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & 0o777 == 0o600 else { throw denied() }
    }

    private static func denied() -> Error { NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)) }
    private static func failure() -> Error { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
