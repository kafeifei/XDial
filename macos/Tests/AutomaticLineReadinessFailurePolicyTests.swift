import XCTest

final class AutomaticLineReadinessFailurePolicyTests: XCTestCase {
    func testUnfinishedNetworkRecoveryIsRetryable() {
        for code in ["underlay-egress-unavailable",
                     "tailscale-home-derp-not-ready",
                     "tailscale-peer-handshake-failed",
                     "tailscale-readiness-timeout",
                     "anyconnect-line-reconnect-timeout"] {
            XCTAssertEqual(
                AutomaticLineReadinessFailurePolicy.switchCode(for: code),
                "line-readiness-transient"
            )
        }
    }

    func testAuthenticationConfigurationAndCancellationRemainTerminal() {
        for code in ["tailscale-exit-node-unavailable",
                     "tailscale-derp-key-mismatch",
                     "tailscale-magic-dns-unavailable",
                     "switch-anyconnect-rebuild-required",
                     "line-readiness-terminal",
                     "line-readiness-cancelled",
                     "network-superseded",
                     "scenario-switch-prepare-failed"] {
            XCTAssertEqual(
                AutomaticLineReadinessFailurePolicy.switchCode(for: code), code
            )
        }
    }
}
