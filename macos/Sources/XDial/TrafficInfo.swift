import Foundation

@MainActor
final class TrafficInfo: ObservableObject {
    @Published private(set) var transactionID: String?
    @Published private(set) var downloadBytesPerSecond: Double?
    @Published private(set) var uploadBytesPerSecond: Double?

    private var samplingTask: Task<Void, Never>?
    private var previousSnapshot: ProviderTrafficSnapshot?
    private var previousSampleAt: Date?

    func start(transactionID: String, engine: GoEngine) {
        guard self.transactionID != transactionID else { return }
        stop()
        self.transactionID = transactionID
        samplingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let result = await self.fetch(
                    transactionID: transactionID,
                    engine: engine
                )
                guard !Task.isCancelled,
                      self.transactionID == transactionID else {
                    return
                }
                self.apply(result, sampledAt: Date())
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
        transactionID = nil
        previousSnapshot = nil
        previousSampleAt = nil
        downloadBytesPerSecond = nil
        uploadBytesPerSecond = nil
    }

    private func fetch(
        transactionID: String,
        engine: GoEngine
    ) async -> Result<ProviderTrafficSnapshot, Error> {
        await withCheckedContinuation { continuation in
            engine.trafficSnapshot(transactionID: transactionID) {
                continuation.resume(returning: $0)
            }
        }
    }

    private func apply(
        _ result: Result<ProviderTrafficSnapshot, Error>,
        sampledAt: Date
    ) {
        guard case let .success(snapshot) = result else {
            downloadBytesPerSecond = nil
            uploadBytesPerSecond = nil
            previousSnapshot = nil
            previousSampleAt = nil
            return
        }
        defer {
            previousSnapshot = snapshot
            previousSampleAt = sampledAt
        }
        guard
            let previousSnapshot,
            let previousSampleAt,
            snapshot.downloadBytes >= previousSnapshot.downloadBytes,
            snapshot.uploadBytes >= previousSnapshot.uploadBytes
        else {
            downloadBytesPerSecond = 0
            uploadBytesPerSecond = 0
            return
        }
        let elapsed = sampledAt.timeIntervalSince(previousSampleAt)
        guard elapsed > 0 else { return }
        downloadBytesPerSecond = Double(
            snapshot.downloadBytes - previousSnapshot.downloadBytes
        ) / elapsed
        uploadBytesPerSecond = Double(
            snapshot.uploadBytes - previousSnapshot.uploadBytes
        ) / elapsed
    }
}
