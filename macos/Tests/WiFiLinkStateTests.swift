import XCTest

final class WiFiLinkStateTests: XCTestCase {
    private func link(
        _ interfaces: WiFiInterfaceLinkFacts...
    ) -> WiFiLinkState {
        WiFiLinkStatePolicy.state(for: interfaces)
    }

    private func manualSelectionOnHome() -> SSIDScenarioSelectionState {
        var selection = SSIDScenarioSelectionState()
        XCTAssertEqual(
            selection.observe(
                ssid: "Home",
                link: link(.init(powerOn: true, linkActive: true)),
                matchedScenarioID: "home"
            ),
            "home"
        )
        selection.noteManualSelection()
        return selection
    }

    func testWiFiPowerOffThenSameSSIDRestoresAutomaticMatch() {
        var selection = manualSelectionOnHome()

        XCTAssertNil(
            selection.observe(
                ssid: nil,
                link: link(.init(powerOn: false, linkActive: false)),
                matchedScenarioID: nil
            )
        )
        XCTAssertEqual(
            selection.observe(
                ssid: "Home",
                link: link(.init(powerOn: true, linkActive: true)),
                matchedScenarioID: "home"
            ),
            "home"
        )
    }

    func testLeavingWiFiRangeThenSameSSIDRestoresAutomaticMatch() {
        var selection = manualSelectionOnHome()

        XCTAssertNil(
            selection.observe(
                ssid: nil,
                link: link(.init(powerOn: true, linkActive: false)),
                matchedScenarioID: nil
            )
        )
        XCTAssertEqual(
            selection.observe(
                ssid: "Home",
                link: link(.init(powerOn: true, linkActive: true)),
                matchedScenarioID: "home"
            ),
            "home"
        )
    }

    func testUnreadableSSIDOnAssociatedWiFiKeepsManualSelection() {
        var selection = manualSelectionOnHome()

        XCTAssertNil(
            selection.observe(
                ssid: nil,
                link: link(.init(powerOn: true, linkActive: true)),
                matchedScenarioID: nil
            )
        )
        XCTAssertNil(
            selection.observe(
                ssid: "Home",
                link: link(.init(powerOn: true, linkActive: true)),
                matchedScenarioID: "home"
            )
        )
    }

    func testUnreadableSSIDWithoutLinkFactsKeepsManualSelection() {
        // Lost location permission and unreadable configd keys both arrive
        // as an unknown link; neither proves the Wi-Fi was left.
        var selection = manualSelectionOnHome()

        for unknown in [
            link(),
            link(.init(powerOn: nil, linkActive: nil)),
            link(.init(powerOn: true, linkActive: nil)),
            link(.init(powerOn: false, linkActive: true)),
        ] {
            XCTAssertEqual(unknown, .unknown)
            XCTAssertNil(
                selection.observe(
                    ssid: nil, link: unknown, matchedScenarioID: nil
                )
            )
        }
        XCTAssertNil(
            selection.observe(
                ssid: "Home",
                link: link(.init(powerOn: true, linkActive: true)),
                matchedScenarioID: "home"
            )
        )
    }

    func testReadableSSIDOverridesContradictoryDisconnectedLink() {
        var selection = manualSelectionOnHome()

        XCTAssertNil(
            selection.observe(
                ssid: "Home",
                link: .disconnected,
                matchedScenarioID: "home"
            )
        )
        XCTAssertNil(
            selection.observe(
                ssid: "Home",
                link: .associated,
                matchedScenarioID: "home"
            )
        )
    }

    func testAnyAssociatedInterfaceMeansAssociated() {
        XCTAssertEqual(
            link(
                .init(powerOn: false, linkActive: false),
                .init(powerOn: true, linkActive: true)
            ),
            .associated
        )
    }

    func testDisconnectRequiresEveryInterfaceToConfirmIt() {
        XCTAssertEqual(
            link(
                .init(powerOn: false, linkActive: nil),
                .init(powerOn: nil, linkActive: false)
            ),
            .disconnected
        )
        XCTAssertEqual(
            link(
                .init(powerOn: false, linkActive: false),
                .init(powerOn: nil, linkActive: nil)
            ),
            .unknown
        )
    }
}
