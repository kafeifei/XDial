import Foundation

/// These codes are emitted from structured runtime facts: a missing Underlay
/// egress, an unfinished transport handshake, or a bounded readiness timeout.
/// Authentication, certificate, configuration and unknown errors retain their
/// original terminal code. Display text is never an input to this decision.
enum AutomaticLineReadinessFailurePolicy {
    static func switchCode(for code: String) -> String {
        switch code {
        case "underlay-egress-unavailable",
             "tailscale-home-derp-not-ready",
             "tailscale-peer-handshake-failed",
             "tailscale-readiness-timeout",
             "anyconnect-line-reconnect-timeout":
            return "line-readiness-transient"
        default:
            return code
        }
    }
}
