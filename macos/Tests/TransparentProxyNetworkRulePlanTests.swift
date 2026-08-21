import XCTest

final class TransparentProxyNetworkRulePlanTests: XCTestCase {
    func testOnlyInterfaceScopedAddressesBypassTransparentProxy() {
        XCTAssertEqual(
            TransparentProxyNetworkRulePlan.interfaceScopedRemoteNetworks,
            [
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
        )
    }

    func testRoutablePrivateAndOverlayUnicastRemainCaptured() {
        let addresses = Set(
            TransparentProxyNetworkRulePlan.interfaceScopedRemoteNetworks
                .map(\.address)
        )

        for forbidden in [
            "10.0.0.0",
            "100.64.0.0",
            "172.16.0.0",
            "192.168.0.0",
            "fc00::",
        ] {
            XCTAssertFalse(addresses.contains(forbidden))
        }
    }
}
