import Darwin
import Foundation

/// A relay socket entry for tests, written against the wire format with plain
/// BSD sockets so it shares no code with `RelayStreamConnection`. It stands in
/// for the sing-box entry of `patches/sing-box/0019-…`.
final class RelaySocketTestEntry: @unchecked Sendable {
    enum Frame: Equatable {
        case data(Data)
        case finish
    }

    /// One accepted connection. All calls block; each connection is served on
    /// its own thread.
    final class Peer: @unchecked Sendable {
        private let descriptor: Int32
        private let lock = NSLock()
        private var closed = false
        private var pending = Data()

        fileprivate init(descriptor: Int32) {
            self.descriptor = descriptor
            var enabled: Int32 = 1
            setsockopt(
                descriptor, SOL_SOCKET, SO_NOSIGPIPE,
                &enabled, socklen_t(MemoryLayout<Int32>.size)
            )
        }

        /// The next frame, or `nil` when the client's stream ended without one.
        func readFrame() -> Frame? {
            guard let header = readRaw(4) else {
                return nil
            }
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            switch header[0] {
            case 0x01:
                guard length > 0, let payload = readRaw(length) else {
                    return nil
                }
                return .data(payload)
            case 0x02:
                return length == 0 ? .finish : nil
            default:
                return nil
            }
        }

        /// Reads `count` stream bytes out of DATA frames.
        func readStream(_ count: Int) -> Data? {
            while pending.count < count {
                guard case let .data(payload)? = readFrame() else {
                    return nil
                }
                pending.append(payload)
            }
            let taken = Data(pending.prefix(count))
            pending = Data(pending.dropFirst(count))
            return taken
        }

        func writeData(_ payload: Data) {
            var frame = Data([
                0x01,
                UInt8((payload.count >> 16) & 0xff),
                UInt8((payload.count >> 8) & 0xff),
                UInt8(payload.count & 0xff),
            ])
            frame.append(payload)
            writeRaw(frame)
        }

        func writeFinish() {
            writeRaw(Data([0x02, 0x00, 0x00, 0x00]))
        }

        func writeRaw(_ bytes: Data) {
            bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(
                        descriptor,
                        buffer.baseAddress! + offset,
                        buffer.count - offset
                    )
                    if written <= 0 {
                        return
                    }
                    offset += written
                }
            }
        }

        /// Closes the socket. Without a FIN frame before it, the client sees a
        /// cut stream.
        func close() {
            lock.lock()
            defer { lock.unlock() }
            guard !closed else {
                return
            }
            closed = true
            Darwin.close(descriptor)
        }

        private func readRaw(_ count: Int) -> Data? {
            var data = Data(count: count)
            var offset = 0
            let complete = data.withUnsafeMutableBytes { buffer -> Bool in
                while offset < count {
                    let received = Darwin.read(
                        descriptor,
                        buffer.baseAddress! + offset,
                        count - offset
                    )
                    if received <= 0 {
                        return false
                    }
                    offset += received
                }
                return true
            }
            return complete ? data : nil
        }
    }

    let path: String
    private let directory: String
    private let listener: Int32
    private let lock = NSLock()
    private var accepted = 0
    private var stopped = false

    var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return accepted
    }

    /// Listens in a short private directory: the test's temporary directory is
    /// already longer than a socket path may be.
    init(serve: @escaping @Sendable (Peer) -> Void) throws {
        var template = Array("/tmp/xdrXXXXXX".utf8CString)
        guard let created = mkdtemp(&template) else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        directory = String(cString: created)
        path = directory + "/relay"

        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        precondition(path.utf8.count < capacity)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard bound == 0, Darwin.listen(listener, 16) == 0 else {
            let failure = POSIXError(.init(rawValue: errno) ?? .EIO)
            Darwin.close(listener)
            throw failure
        }

        let listener = self.listener
        Thread.detachNewThread { [weak self] in
            while true {
                let descriptor = Darwin.accept(listener, nil, nil)
                guard descriptor >= 0 else {
                    return
                }
                self?.noteAccepted()
                let peer = Peer(descriptor: descriptor)
                Thread.detachNewThread {
                    serve(peer)
                    peer.close()
                }
            }
        }
    }

    func stop() {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        lock.unlock()
        guard !alreadyStopped else {
            return
        }
        Darwin.close(listener)
        try? FileManager.default.removeItem(atPath: directory)
    }

    private func noteAccepted() {
        lock.lock()
        accepted += 1
        lock.unlock()
    }
}
