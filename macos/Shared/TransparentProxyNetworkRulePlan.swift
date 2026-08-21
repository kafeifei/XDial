import Foundation

struct TransparentProxyRemoteNetwork: Equatable, Sendable {
    let address: String
    let prefixLength: Int
}

enum TransparentProxyNetworkRulePlan {
    /// Addresses whose meaning depends on the originating interface or local
    /// broadcast domain cannot retain that meaning after loopback SOCKS relay.
    /// Routable private, ULA, Tailnet and enterprise unicast stay inside XDial.
    static let interfaceScopedRemoteNetworks = [
        TransparentProxyRemoteNetwork(
            address: "169.254.0.0",
            prefixLength: 16
        ),
        TransparentProxyRemoteNetwork(
            address: "224.0.0.0",
            prefixLength: 4
        ),
        TransparentProxyRemoteNetwork(
            address: "255.255.255.255",
            prefixLength: 32
        ),
        TransparentProxyRemoteNetwork(
            address: "fe80::",
            prefixLength: 10
        ),
        TransparentProxyRemoteNetwork(
            address: "ff00::",
            prefixLength: 8
        ),
    ]
}
