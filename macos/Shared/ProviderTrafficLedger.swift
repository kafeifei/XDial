import Foundation

/// Provider 会话内的单调流量账本。每笔连接事务重置一次，快照必须携带相同事务 ID。
final class ProviderTrafficLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var transactionID = ""
    private var downloadBytes: UInt64 = 0
    private var uploadBytes: UInt64 = 0

    func reset(transactionID: String) {
        lock.lock()
        self.transactionID = transactionID
        downloadBytes = 0
        uploadBytes = 0
        lock.unlock()
    }

    func recordDownload(_ byteCount: Int) {
        guard byteCount > 0 else { return }
        lock.lock()
        downloadBytes = adding(byteCount, to: downloadBytes)
        lock.unlock()
    }

    func recordUpload(_ byteCount: Int) {
        guard byteCount > 0 else { return }
        lock.lock()
        uploadBytes = adding(byteCount, to: uploadBytes)
        lock.unlock()
    }

    func snapshot(transactionID: String) -> ProviderTrafficSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard self.transactionID == transactionID else { return nil }
        return ProviderTrafficSnapshot(
            downloadBytes: downloadBytes,
            uploadBytes: uploadBytes
        )
    }

    private func adding(_ byteCount: Int, to total: UInt64) -> UInt64 {
        let increment = UInt64(byteCount)
        let (sum, overflow) = total.addingReportingOverflow(increment)
        return overflow ? .max : sum
    }
}
