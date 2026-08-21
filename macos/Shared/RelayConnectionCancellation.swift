import Foundation
import Network

enum RelayConnectionCancellationMode: Equatable {
    case graceful
    case immediate
}

/// Active relays get a short, explicit drain window during Scenario handoff.
/// Once the registry cancels a relay, graceful protocol shutdown is no longer
/// safe: a sleeping or path-stalled loopback connection can otherwise remain
/// established after its sing-box listener has gone away. Apple documents
/// `forceCancel()` as immediately disconnecting established protocols, which
/// is the teardown contract required by Provider rollback.
enum RelayConnectionCancellation {
    static func mode(for error: Error?) -> RelayConnectionCancellationMode {
        error == nil ? .graceful : .immediate
    }

    static func cancel(_ connection: NWConnection, error: Error?) {
        switch mode(for: error) {
        case .graceful:
            connection.cancel()
        case .immediate:
            connection.forceCancel()
        }
    }
}
