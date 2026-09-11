enum ResolverRefreshReason: String {
    case transactionCommitted = "transaction-committed"
    case proxyStopped = "proxy-stopped"
    case hostLaunch = "host-launch"
}

/// macOS hands each captured UDP socket exactly one NEAppProxyUDPFlow: once the
/// provider closes that flow the socket never gets another one and its
/// datagrams are dropped silently. mDNSResponder keeps one long-lived querier
/// socket per DNS question and retries on it forever, so a query in flight when
/// the provider stops becomes a permanent black hole for that name. XDial's
/// NETransparentProxyNetworkSettings carries no dnsSettings, so the system
/// emits no configuration-change event of its own; the host asks the privileged
/// daemon to SIGHUP mDNSResponder after every transition that can close UDP
/// flows, which makes it rebuild its queriers on fresh sockets.
///
/// This type only decides *whether* a transition deserves a nudge. It is
/// deliberately free of I/O so the decision stays testable.
struct ResolverRefreshTrigger {
    private var nudgedTransactionIDs: Set<String> = []
    private var lastRuntimeStatus = "disconnected"
    private var launchNudged = false

    /// A committed transaction means the provider has just applied network
    /// settings — the start of a session and every Scenario/epoch switch.
    mutating func noteConnectionReport(
        transactionID: String,
        state: ConnectionTransactionState
    ) -> ResolverRefreshReason? {
        guard state == .committed, !transactionID.isEmpty else { return nil }
        guard nudgedTransactionIDs.insert(transactionID).inserted else {
            return nil
        }
        return .transactionCommitted
    }

    /// Reaching `disconnected` from anything else is the stop path: a user
    /// disconnect, a provider exit, or a rolled back transaction.
    mutating func noteRuntimeStatus(
        _ status: String
    ) -> ResolverRefreshReason? {
        let previous = lastRuntimeStatus
        lastRuntimeStatus = status
        guard status == "disconnected", previous != "disconnected" else {
            return nil
        }
        return .proxyStopped
    }

    /// The previous application instance may have been replaced or killed while
    /// a query was in flight; nothing in this process can observe that stop, so
    /// launch nudges once as soon as the daemon is usable.
    mutating func noteHostLaunch() -> ResolverRefreshReason? {
        guard !launchNudged else { return nil }
        launchNudged = true
        return .hostLaunch
    }
}
