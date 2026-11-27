import XCTest

final class UDPRelayDownlinkPipelineTests: XCTestCase {
    private struct WriteRejected: Error {}
    private struct AssociationLost: Error {}

    /// Records each write and holds its completion until the test releases it.
    private final class FakeFlow: @unchecked Sendable {
        private let lock = NSLock()
        private var completions: [(Error?) -> Void] = []
        private(set) var batches: [[Int]] = []
        private(set) var writtenBatches: [[Int]] = []
        private(set) var reportedDrops: [Int] = []

        var write: UDPRelayDownlinkPipeline<Int>.Write {
            { batch, completion in
                self.lock.lock()
                self.batches.append(batch)
                self.completions.append(completion)
                self.lock.unlock()
            }
        }

        var written: UDPRelayDownlinkPipeline<Int>.Written {
            { batch, dropped in
                self.lock.lock()
                self.writtenBatches.append(batch)
                self.reportedDrops.append(dropped)
                self.lock.unlock()
            }
        }

        var inFlight: Int {
            lock.lock()
            defer { lock.unlock() }
            return completions.count
        }

        func completeOldest(with error: Error? = nil) {
            lock.lock()
            let completion = completions.removeFirst()
            lock.unlock()
            completion(error)
        }
    }

    private func makePipeline(
        _ flow: FakeFlow,
        limits: UDPRelayDownlinkPipeline<Int>.Limits = .default
    ) -> UDPRelayDownlinkPipeline<Int> {
        UDPRelayDownlinkPipeline(
            limits: limits,
            write: flow.write,
            written: flow.written
        )
    }

    func testIdleDatagramIsWrittenImmediately() {
        let flow = FakeFlow()
        let pipeline = makePipeline(flow)

        XCTAssertEqual(pipeline.push(1, byteCount: 100), .accepted)
        XCTAssertEqual(flow.batches, [[1]])
        XCTAssertEqual(flow.inFlight, 1)
    }

    func testDatagramsArrivingDuringWriteBecomeOneBatchInOrder() {
        let flow = FakeFlow()
        let pipeline = makePipeline(flow)

        XCTAssertEqual(pipeline.push(1, byteCount: 100), .accepted)
        for value in 2 ... 5 {
            XCTAssertEqual(pipeline.push(value, byteCount: 100), .accepted)
        }
        // Only one write is ever in flight.
        XCTAssertEqual(flow.batches, [[1]])

        flow.completeOldest()
        XCTAssertEqual(flow.batches, [[1], [2, 3, 4, 5]])
        XCTAssertEqual(flow.writtenBatches, [[1]])

        flow.completeOldest()
        XCTAssertEqual(flow.writtenBatches, [[1], [2, 3, 4, 5]])
        XCTAssertEqual(flow.inFlight, 0)

        // The pipeline is idle again and writes the next arrival at once.
        XCTAssertEqual(pipeline.push(6, byteCount: 100), .accepted)
        XCTAssertEqual(flow.batches.last, [6])
    }

    func testFullQueueDropsArrivalsAndReportsThemWithNextBatch() {
        let flow = FakeFlow()
        let pipeline = makePipeline(
            flow,
            limits: .init(maximumCount: 3, maximumBytes: 1 << 20)
        )
        XCTAssertEqual(pipeline.push(0, byteCount: 10), .accepted)
        for value in 1 ... 3 {
            XCTAssertEqual(pipeline.push(value, byteCount: 10), .accepted)
        }
        XCTAssertEqual(pipeline.push(4, byteCount: 10), .dropped)
        XCTAssertEqual(pipeline.push(5, byteCount: 10), .dropped)

        flow.completeOldest()
        flow.completeOldest()
        XCTAssertEqual(flow.writtenBatches, [[0], [1, 2, 3]])
        XCTAssertEqual(flow.reportedDrops, [0, 2])
    }

    func testByteLimitBoundsQueueButEmptyQueueAcceptsOversizedDatagram() {
        let flow = FakeFlow()
        let pipeline = makePipeline(
            flow,
            limits: .init(maximumCount: 100, maximumBytes: 1_000)
        )
        XCTAssertEqual(pipeline.push(0, byteCount: 5_000), .accepted)
        XCTAssertEqual(pipeline.push(1, byteCount: 5_000), .accepted)
        XCTAssertEqual(pipeline.push(2, byteCount: 1), .dropped)

        flow.completeOldest()
        XCTAssertEqual(pipeline.push(3, byteCount: 600), .accepted)
        XCTAssertEqual(pipeline.push(4, byteCount: 400), .accepted)
        XCTAssertEqual(pipeline.push(5, byteCount: 1), .dropped)
        flow.completeOldest()
        XCTAssertEqual(flow.batches, [[0], [1], [3, 4]])
    }

    func testFinishWaitsForAcceptedDatagramsToBeWritten() async {
        let flow = FakeFlow()
        let pipeline = makePipeline(flow)
        XCTAssertEqual(pipeline.push(1, byteCount: 1), .accepted)
        XCTAssertEqual(pipeline.push(2, byteCount: 1), .accepted)
        pipeline.finish()
        XCTAssertEqual(pipeline.push(3, byteCount: 1), .closed)

        let waiting = Task {
            await pipeline.wait()
        }
        flow.completeOldest()
        flow.completeOldest()

        guard case .finished = await waiting.value else {
            return XCTFail("pipeline did not finish")
        }
        XCTAssertEqual(flow.writtenBatches, [[1], [2]])
    }

    func testFinishWhileIdleResolvesAtOnce() async {
        let flow = FakeFlow()
        let pipeline = makePipeline(flow)
        pipeline.finish()

        guard case .finished = await pipeline.wait() else {
            return XCTFail("pipeline did not finish")
        }
        XCTAssertTrue(flow.batches.isEmpty)
    }

    func testReceiveFailureIsReportedAfterAcceptedDatagrams() async {
        let flow = FakeFlow()
        let pipeline = makePipeline(flow)
        XCTAssertEqual(pipeline.push(1, byteCount: 1), .accepted)
        pipeline.finish(throwing: AssociationLost())
        // Only the first end counts.
        pipeline.finish()

        let waiting = Task {
            await pipeline.wait()
        }
        flow.completeOldest()

        guard case let .receiveFailed(error) = await waiting.value else {
            return XCTFail("receive failure was not reported")
        }
        XCTAssertTrue(error is AssociationLost)
        XCTAssertEqual(flow.writtenBatches, [[1]])
    }

    func testWriteFailureEndsPipelineAndDiscardsQueue() async {
        let flow = FakeFlow()
        let pipeline = makePipeline(flow)
        XCTAssertEqual(pipeline.push(1, byteCount: 1), .accepted)
        XCTAssertEqual(pipeline.push(2, byteCount: 1), .accepted)

        flow.completeOldest(with: WriteRejected())

        guard case let .writeFailed(error) = await pipeline.wait() else {
            return XCTFail("write failure was not reported")
        }
        XCTAssertTrue(error is WriteRejected)
        XCTAssertEqual(flow.batches, [[1]])
        XCTAssertTrue(flow.writtenBatches.isEmpty)
        XCTAssertEqual(pipeline.push(3, byteCount: 1), .closed)
    }

    func testCancellingWaiterStopsPipelineWithoutFurtherWrites() async {
        let flow = FakeFlow()
        let pipeline = makePipeline(flow)
        XCTAssertEqual(pipeline.push(1, byteCount: 1), .accepted)
        XCTAssertEqual(pipeline.push(2, byteCount: 1), .accepted)

        let waiting = Task {
            await pipeline.wait()
        }
        await Task.yield()
        waiting.cancel()
        guard case .stopped = await waiting.value else {
            return XCTFail("cancelled waiter did not stop the pipeline")
        }

        // The write already in flight completes and is still observed, but
        // the queued datagram is never written and the receiver is told to
        // stop.
        flow.completeOldest()
        XCTAssertEqual(flow.batches, [[1]])
        XCTAssertEqual(flow.writtenBatches, [[1]])
        XCTAssertEqual(pipeline.push(3, byteCount: 1), .closed)
    }

    func testConcurrentProducerLosesNothingButOverflowAndKeepsOrder() async {
        let total = 20_000
        let limit = 64
        let writeQueue = DispatchQueue(label: "UDPRelayDownlinkPipelineTests.write")
        let lock = NSLock()
        var written: [Int] = []
        var dropped = 0
        var largestBatch = 0
        let pipeline = UDPRelayDownlinkPipeline<Int>(
            limits: .init(maximumCount: limit, maximumBytes: 1 << 20),
            write: { batch, completion in
                writeQueue.async {
                    completion(nil)
                }
            },
            written: { batch, droppedBefore in
                lock.lock()
                written.append(contentsOf: batch)
                dropped += droppedBefore
                largestBatch = max(largestBatch, batch.count)
                lock.unlock()
            }
        )
        let producer = Thread {
            for value in 0 ..< total {
                _ = pipeline.push(value, byteCount: 1_200)
            }
            pipeline.finish()
        }
        producer.start()

        guard case .finished = await pipeline.wait() else {
            return XCTFail("pipeline did not finish")
        }
        let result = lock.withLock { (written, dropped, largestBatch) }
        XCTAssertEqual(result.0.count + result.1, total)
        XCTAssertEqual(result.0, result.0.sorted())
        XCTAssertEqual(Set(result.0).count, result.0.count)
        XCTAssertLessThanOrEqual(result.2, limit)
    }

    /// Stopping from inside the observer of a finished write, which a flow
    /// may run before its write returns, neither deadlocks nor lets the queued
    /// datagrams through.
    func testStopDuringSynchronousCompletionIssuesNoFurtherWrite() async {
        let lock = NSLock()
        var writes: [[Int]] = []
        var pipeline: UDPRelayDownlinkPipeline<Int>?
        var queueDuringFirstWrite = true
        pipeline = UDPRelayDownlinkPipeline<Int>(
            write: { batch, completion in
                lock.withLock { writes.append(batch) }
                if queueDuringFirstWrite {
                    // A datagram arrives while the first write is in flight.
                    queueDuringFirstWrite = false
                    XCTAssertEqual(pipeline?.push(2, byteCount: 1), .accepted)
                }
                completion(nil)
            },
            written: { _, _ in
                pipeline?.stop()
            }
        )
        let subject = pipeline!
        XCTAssertEqual(subject.push(1, byteCount: 1), .accepted)
        guard case .stopped = await subject.wait() else {
            return XCTFail("stop inside the observer did not stop the pipeline")
        }
        XCTAssertEqual(lock.withLock { writes }, [[1]])
        XCTAssertEqual(subject.push(3, byteCount: 1), .closed)
        pipeline = nil
    }

    /// Once `stop()` returns, no write starts: the association that stopped
    /// the pipeline may be replaced, and a late write from it would reach the
    /// application after the new association's datagrams.
    func testNoWriteStartsAfterStopReturns() async {
        for _ in 0 ..< 200 {
            let lock = NSLock()
            var stopReturned = false
            var lateWrites = 0
            let completionQueue = DispatchQueue(
                label: "UDPRelayDownlinkPipelineTests.completion",
                attributes: .concurrent
            )
            let pipeline = UDPRelayDownlinkPipeline<Int>(
                limits: .init(maximumCount: 4, maximumBytes: 1 << 20),
                write: { _, completion in
                    lock.withLock {
                        if stopReturned {
                            lateWrites += 1
                        }
                    }
                    completionQueue.async {
                        completion(nil)
                    }
                },
                written: { _, _ in }
            )
            let producer = Thread {
                for value in 0 ..< 2_000 {
                    if pipeline.push(value, byteCount: 1) == .closed {
                        return
                    }
                }
            }
            producer.start()
            let stopper = Thread {
                usleep(UInt32.random(in: 0 ... 200))
                pipeline.stop()
                lock.withLock { stopReturned = true }
            }
            stopper.start()

            guard case .stopped = await pipeline.wait() else {
                return XCTFail("pipeline did not stop")
            }
            // Let in-flight completions and the producer settle.
            try? await Task.sleep(nanoseconds: 2_000_000)
            XCTAssertEqual(lock.withLock { lateWrites }, 0)
        }
    }
}
