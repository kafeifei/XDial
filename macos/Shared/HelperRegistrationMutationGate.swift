import Foundation

/// Serializes helper registration with an asynchronous unregister. Once an
/// unregister begins, only its real ServiceManagement completion releases the
/// gate; a caller-side timeout deliberately leaves it held.
final class HelperRegistrationMutationGate: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case unregisterPending
    }

    private let lock = NSLock()
    private var unregisterPending = false

    var hasPendingUnregister: Bool {
        lock.lock()
        defer { lock.unlock() }
        return unregisterPending
    }

    func beginUnregister() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !unregisterPending else { throw Failure.unregisterPending }
        unregisterPending = true
    }

    func completeUnregister() {
        lock.lock()
        unregisterPending = false
        lock.unlock()
    }

    func withRegistration<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !unregisterPending else { throw Failure.unregisterPending }
        return try operation()
    }
}
