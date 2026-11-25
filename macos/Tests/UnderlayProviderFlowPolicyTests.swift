import XCTest

final class UnderlayProviderFlowPolicyTests: XCTestCase {
    private let systemExtensionProvider =
        "/Library/SystemExtensions/5251A931-9094-4450-8C88-6472387E2CCC/"
        + "vpn.example.tunnel.systemextension/Contents/MacOS/vpn.example.tunnel"
    private let appExtensionProvider =
        "/Applications/Example VPN.app/Contents/PlugIns/"
        + "Tunnel.appex/Contents/MacOS/Tunnel"
    private let packetTunnel = ["packet-tunnel-provider-systemextension"]

    func testSystemExtensionProviderIsReleasedToTheUnderlay() {
        XCTAssertTrue(UnderlayProviderFlowPolicy.isUnderlayProvider(
            executablePath: systemExtensionProvider,
            entitlementValue: { self.packetTunnel }
        ))
    }

    func testAppExtensionProviderIsReleasedToTheUnderlay() {
        XCTAssertTrue(UnderlayProviderFlowPolicy.isUnderlayProvider(
            executablePath: appExtensionProvider,
            entitlementValue: { ["packet-tunnel-provider"] }
        ))
    }

    func testContainingAppWithTheSameEntitlementStaysInXDial() {
        var entitlementRead = false
        XCTAssertFalse(UnderlayProviderFlowPolicy.isUnderlayProvider(
            executablePath:
                "/Applications/Example VPN.app/Contents/MacOS/Example VPN",
            entitlementValue: {
                entitlementRead = true
                return self.packetTunnel
            }
        ))
        // Ordinary application flows never pay for the signing lookup.
        XCTAssertFalse(entitlementRead)
    }

    func testProviderLayoutWithoutNetworkExtensionEntitlementStaysInXDial() {
        XCTAssertFalse(UnderlayProviderFlowPolicy.isUnderlayProvider(
            executablePath: systemExtensionProvider,
            entitlementValue: { nil }
        ))
        XCTAssertFalse(UnderlayProviderFlowPolicy.isUnderlayProvider(
            executablePath: appExtensionProvider,
            entitlementValue: { [String]() }
        ))
    }

    func testSystemExtensionOutsideTheActivatedDirectoryStaysInXDial() {
        XCTAssertFalse(UnderlayProviderFlowPolicy.isUnderlayProvider(
            executablePath:
                "/Users/me/Downloads/vpn.example.tunnel.systemextension/"
                + "Contents/MacOS/vpn.example.tunnel",
            entitlementValue: { self.packetTunnel }
        ))
        XCTAssertFalse(UnderlayProviderFlowPolicy.isUnderlayProvider(
            executablePath:
                "/Library/SystemExtensions/vpn.example.tunnel.systemextension/"
                + "Contents/MacOS/vpn.example.tunnel",
            entitlementValue: { self.packetTunnel }
        ))
    }

    func testMissingExecutablePathStaysInXDial() {
        XCTAssertFalse(UnderlayProviderFlowPolicy.isUnderlayProvider(
            executablePath: nil,
            entitlementValue: { self.packetTunnel }
        ))
    }
}
