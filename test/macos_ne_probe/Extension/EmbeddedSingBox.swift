import Darwin
import Foundation
import Libbox
import Network
import OSLog

final class EmbeddedSingBox: NSObject, LibboxCallbackProtocol {
    private let logger: Logger
    private var engine: LibboxLibbox?

    init(logger: Logger) {
        self.logger = logger
    }

    func start(port: UInt16) throws {
        guard engine == nil else {
            return
        }
        guard let instance = LibboxNew(self) else {
            throw EmbeddedSingBoxError.unavailable
        }
        guard let networkInterface = currentInterfaceSnapshot() else {
            throw EmbeddedSingBoxError.defaultInterfaceUnavailable
        }
        instance.setDefaultInterface(
            networkInterface.name,
            index: networkInterface.index
        )
        logger.notice(
            "embedded-platform-interface name=\(networkInterface.name, privacy: .public)"
        )
        let config = """
        {
          "log": {"level": "debug", "timestamp": true},
          "dns": {
            "servers": [{"type": "local", "tag": "underlay-dns"}],
            "final": "underlay-dns"
          },
          "inbounds": [{
            "type": "socks",
            "tag": "transparent-flow-in",
            "listen": "127.0.0.1",
            "listen_port": \(port)
          }],
          "outbounds": [{"type": "direct", "tag": "underlay"}],
          "route": {
            "rules": [
              {"action": "sniff"},
              {"protocol": "dns", "action": "hijack-dns"}
            ],
            "default_domain_resolver": "underlay-dns",
            "final": "underlay"
          }
        }
        """
        do {
            try instance.startStandalone(config)
            engine = instance
            logger.notice("embedded-sing-box-started port=\(port)")
        } catch {
            try? instance.stop()
            throw error
        }
    }

    func stop() {
        guard let engine else {
            return
        }
        self.engine = nil
        try? engine.stop()
        logger.notice("embedded-sing-box-stopped")
    }

    func onStatusChanged(_ statusJSON: String?) {
        logger.notice(
            "embedded-status value=\(statusJSON ?? "-", privacy: .public)"
        )
    }

    func onError(_ code: Int, message: String?) {
        logger.error(
            "embedded-error code=\(code) message=\(message ?? "-", privacy: .public)"
        )
    }

    private func currentInterfaceSnapshot() -> (name: String, index: Int)? {
        let gate = InterfaceSnapshotGate()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else {
                return
            }
            for networkInterface in path.availableInterfaces {
                let index = Int(if_nametoindex(networkInterface.name))
                if index > 0 {
                    gate.fulfill(
                        name: networkInterface.name,
                        index: index
                    )
                    return
                }
            }
        }
        monitor.start(queue: .global(qos: .userInitiated))
        defer {
            monitor.cancel()
        }
        return gate.wait(timeout: .now() + 3)
    }
}

private enum EmbeddedSingBoxError: Error {
    case unavailable
    case defaultInterfaceUnavailable
}

private final class InterfaceSnapshotGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var snapshot: (name: String, index: Int)?

    func fulfill(name: String, index: Int) {
        lock.lock()
        guard snapshot == nil else {
            lock.unlock()
            return
        }
        snapshot = (name, index)
        lock.unlock()
        semaphore.signal()
    }

    func wait(
        timeout: DispatchTime
    ) -> (name: String, index: Int)? {
        guard semaphore.wait(timeout: timeout) == .success else {
            return nil
        }
        lock.lock()
        defer {
            lock.unlock()
        }
        return snapshot
    }
}
