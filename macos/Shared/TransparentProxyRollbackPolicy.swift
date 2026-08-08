import Foundation

/// Defines who can prove that Transparent Proxy network settings are gone.
///
/// A provider-initiated rollback may explicitly remove settings while its
/// session is still active. Once `stopProxy` has begun, however, Network
/// Extension owns the teardown. The provider must finish its runtime cleanup
/// and wait for the host to observe the manager's disconnected state instead
/// of issuing another settings mutation during system teardown.
enum TransparentProxyNetworkSettingsRollbackAction: Equatable {
    case alreadyAbsent
    case removeExplicitly
    case awaitSystemDisconnect

    static func providerStop(settingsCommitted: Bool) -> Self {
        settingsCommitted ? .awaitSystemDisconnect : .alreadyAbsent
    }
}
