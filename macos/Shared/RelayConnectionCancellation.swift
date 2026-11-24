import Foundation
import Network

enum RelayConnectionCancellationMode: Equatable {
    case graceful
    case immediate
}

/// Active relays get a short, explicit drain window during Scenario handoff.
/// Once the registry cancels a relay, graceful protocol shutdown is no longer
/// safe: a sleeping or stalled connection can otherwise remain established
/// after its sing-box listener has gone away. Apple documents `forceCancel()`
/// as immediately disconnecting established protocols, which is the teardown
/// contract required by Provider rollback.
///
/// On the relay socket the two modes also differ in what the entry is told:
/// a graceful end announces itself, an immediate one is a cut stream. See
/// `RelayStreamConnection.cancel(with:)`.
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
