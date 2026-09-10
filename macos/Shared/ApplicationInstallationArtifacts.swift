import Darwin
import Foundation

/// Owns only the installer's adjacent temporary bundles. The durable receipt is
/// written before copying, so a killed installer can leave an incomplete bundle
/// without making the next launch guess whether it is safe to delete.
struct ApplicationInstallationArtifacts {
    struct Transaction: Codable {
        let schemaVersion: Int
        let id: UUID
        let applicationIdentifier: String
        let teamIdentifier: String

        var stagingName: String { ".XDial.install-\(id.uuidString).app" }
        var backupName: String { ".XDial.backup-\(id.uuidString).app" }
        var receiptName: String { ".XDial.transaction-\(id.uuidString).json" }
    }

    let destinationURL: URL
    let applicationIdentifier: String
    let teamIdentifier: String
    let isTrustedApplication: (URL) -> Bool
    let isInUse: (URL) -> Bool
    let unregisterApplication: (URL) throws -> Void
    var fileManager: FileManager = .default

    private var directoryURL: URL { destinationURL.deletingLastPathComponent() }

    /// Keep one zero-byte lock as coordination state. Unlinking a lock while
    /// another process holds its old inode would permit two concurrent installs.
    func withExclusiveAccess<T>(_ body: () throws -> T) throws -> T {
        let lockURL = directoryURL.appendingPathComponent(".XDial.installation.lock")
        let descriptor = open(
            lockURL.path, O_RDONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644
        )
        guard descriptor >= 0 else { throw POSIXError(.EACCES) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1 else {
            throw ArtifactError.invalidReceipt
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw ArtifactError.installationInProgress
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    func stagingURL(for transaction: Transaction) -> URL {
        directoryURL.appendingPathComponent(transaction.stagingName)
    }

    /// Housekeeping after a verified canonical launch is retryable. Preserve
    /// the receipt on failure without turning a working launch into a failure.
    func recoverAfterSuccessfulLaunch() -> String? {
        do {
            try withExclusiveAccess { try recoverAbandonedTransactions() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func perform<T>(_ operation: (Transaction) throws -> T) throws -> T {
        let transaction = Transaction(
            schemaVersion: 1,
            id: UUID(),
            applicationIdentifier: applicationIdentifier,
            teamIdentifier: teamIdentifier
        )
        let receiptURL = directoryURL.appendingPathComponent(transaction.receiptName)
        try JSONEncoder().encode(transaction).write(to: receiptURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
        let result: T
        do {
            result = try operation(transaction)
        } catch {
            // A failed replacement may have retained its only usable backup.
            // Reconcile that state before deleting anything, including a copy
            // left at the staging path by Foundation's replacement operation.
            do { try recover(transaction) }
            catch let recoveryError {
                throw ArtifactError.recoveryFailed(
                    original: error.localizedDescription,
                    recovery: recoveryError.localizedDescription
                )
            }
            throw error
        }
        try recover(transaction)
        return result
    }

    /// Must be called under the install lock, including on canonical launches.
    /// Receipts from another identity and user-supplied lookalike paths are not
    /// authority to delete files. Legacy bundles require signature validation.
    func recoverAbandonedTransactions() throws {
        let entries = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey],
            options: []
        )
        for url in entries where url.lastPathComponent.hasPrefix(".XDial.transaction-") {
            guard let id = artifactID(url, prefix: ".XDial.transaction-", suffix: ".json"),
                  let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]),
                  values.isSymbolicLink != true, values.isRegularFile == true,
                  let data = try? Data(contentsOf: url),
                  let transaction = try? JSONDecoder().decode(Transaction.self, from: data),
                  transaction.schemaVersion == 1, transaction.id == id,
                  transaction.receiptName == url.lastPathComponent,
                  transaction.applicationIdentifier == applicationIdentifier,
                  transaction.teamIdentifier == teamIdentifier else { continue }
            try recover(transaction)
        }

        // Earlier versions had no receipt. Delete only complete signed copies,
        // and only when the canonical app is itself a verified replacement.
        guard isTrustedApplication(destinationURL) else { return }
        for url in entries {
            guard let id = artifactID(url, prefix: ".XDial.install-", suffix: ".app")
                    ?? artifactID(url, prefix: ".XDial.backup-", suffix: ".app"),
                  !entries.contains(where: {
                    artifactID($0, prefix: ".XDial.transaction-", suffix: ".json") == id
                        && exists($0)
                  }),
                  exists(url), !isSymbolicLink(url),
                  !isInUse(url), isTrustedApplication(url) else { continue }
            try removeBundle(at: url)
        }
    }

    private func recover(_ transaction: Transaction) throws {
        let stagingURL = stagingURL(for: transaction)
        let backupURL = directoryURL.appendingPathComponent(transaction.backupName)
        let receiptURL = directoryURL.appendingPathComponent(transaction.receiptName)
        guard !isSymbolicLink(stagingURL), !isSymbolicLink(backupURL) else {
            throw ArtifactError.invalidReceipt
        }
        // A predecessor can still be finishing its launch handoff. Its own
        // post-handoff cleanup or the next launch will finish this receipt.
        guard !isInUse(stagingURL), !isInUse(backupURL) else { return }
        if exists(backupURL) {
            if isTrustedApplication(destinationURL) {
                try removeBundle(at: backupURL)
            } else if !exists(destinationURL), !isInUse(destinationURL),
                      isTrustedApplication(backupURL) {
                // Never destroy the only verified app after an interrupted swap.
                try unregisterApplication(backupURL)
                try fileManager.moveItem(at: backupURL, to: destinationURL)
            } else {
                throw ArtifactError.backupRequiresRecovery
            }
        }
        if exists(stagingURL) { try removeBundle(at: stagingURL) }
        if exists(receiptURL) { try fileManager.removeItem(at: receiptURL) }
    }

    private func removeBundle(at url: URL) throws {
        // Registration has to be removed while the bundle still exists. Doing
        // this after deleting it misses registrations filtered by LaunchServices.
        try unregisterApplication(url)
        try fileManager.removeItem(at: url)
    }

    private func artifactID(_ url: URL, prefix: String, suffix: String) -> UUID? {
        let name = url.lastPathComponent
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count)))
    }

    private func exists(_ url: URL) -> Bool { fileManager.fileExists(atPath: url.path) }
    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    enum ArtifactError: LocalizedError {
        case installationInProgress
        case invalidReceipt
        case backupRequiresRecovery
        case recoveryFailed(original: String, recovery: String)

        var errorDescription: String? {
            switch self {
            case .installationInProgress:
                "另一笔 XDial 安装正在进行，请等待它完成。"
            case .invalidReceipt:
                "安装临时文件的归属无法确认，已保留原文件。"
            case .backupRequiresRecovery:
                "上次安装的备份尚未恢复，已保留备份以避免丢失原应用。"
            case let .recoveryFailed(original, recovery):
                "安装未完成（\(original)）；恢复临时文件失败（\(recovery)）。"
            }
        }
    }
}
