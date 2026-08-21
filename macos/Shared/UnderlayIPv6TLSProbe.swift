import Foundation
import Network
import Security

struct UnderlayIPv6TLSProbeDecision: Equatable {
    private let attemptCount: Int
    private var completedAttempts: Set<Int> = []
    private var sawSuccessfulTLS = false

    init(attemptCount: Int) {
        precondition(attemptCount > 0)
        self.attemptCount = attemptCount
    }

    mutating func record(attempt: Int, successfulTLS: Bool) {
        guard (0 ..< attemptCount).contains(attempt) else { return }
        guard completedAttempts.insert(attempt).inserted else { return }
        sawSuccessfulTLS = sawSuccessfulTLS || successfulTLS
    }

    var result: Bool? {
        if sawSuccessfulTLS {
            return true
        }
        if completedAttempts.count == attemptCount {
            return false
        }
        return nil
    }
}

/// Probes literal IPv6 endpoints from the Provider process before XDial commits
/// its Transparent Proxy settings. A `.ready` NWConnection with TLS means the
/// TCP and authenticated TLS handshakes both completed on the current Underlay;
/// an installed IPv6 route or an OS-level IPv6 address alone is not sufficient.
enum UnderlayIPv6TLSProbe {
    private struct Target {
        let address: String
        let serverName: String
    }

    private static let targets = [
        Target(
            address: "2606:4700:4700::1111",
            serverName: "one.one.one.one"
        ),
        Target(
            address: "2001:4860:4860::8888",
            serverName: "dns.google"
        ),
    ]

    private final class Coordinator: @unchecked Sendable {
        private let lock = NSLock()
        private var decision: UnderlayIPv6TLSProbeDecision
        let signal = DispatchSemaphore(value: 0)

        init(attemptCount: Int) {
            decision = UnderlayIPv6TLSProbeDecision(
                attemptCount: attemptCount
            )
        }

        func record(attempt: Int, successfulTLS: Bool) {
            lock.lock()
            decision.record(
                attempt: attempt,
                successfulTLS: successfulTLS
            )
            lock.unlock()
            signal.signal()
        }

        var result: Bool? {
            lock.lock()
            let value = decision.result
            lock.unlock()
            return value
        }
    }

    static func probe(
        timeout: TimeInterval = 2.5,
        isCancelled: () -> Bool
    ) -> Bool {
        let coordinator = Coordinator(attemptCount: targets.count)
        let callbackQueue = DispatchQueue(
            label: "com.kafeifei.xdial.underlay-ipv6-tls-probe"
        )
        let port = NWEndpoint.Port(rawValue: 443)!
        var connections: [NWConnection] = []

        for (attempt, target) in targets.enumerated() {
            guard let address = IPv6Address(target.address) else {
                coordinator.record(
                    attempt: attempt,
                    successfulTLS: false
                )
                continue
            }
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(
                tls.securityProtocolOptions,
                target.serverName
            )
            let parameters = NWParameters(
                tls: tls,
                tcp: NWProtocolTCP.Options()
            )
            let connection = NWConnection(
                host: .ipv6(address),
                port: port,
                using: parameters
            )
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    coordinator.record(
                        attempt: attempt,
                        successfulTLS: true
                    )
                case .failed, .cancelled:
                    coordinator.record(
                        attempt: attempt,
                        successfulTLS: false
                    )
                default:
                    break
                }
            }
            connections.append(connection)
            connection.start(queue: callbackQueue)
        }

        defer {
            for connection in connections {
                connection.stateUpdateHandler = nil
                connection.cancel()
            }
        }

        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        while Date() < deadline, !isCancelled() {
            if let result = coordinator.result {
                return result
            }
            _ = coordinator.signal.wait(timeout: .now() + 0.05)
        }
        return coordinator.result ?? false
    }
}
