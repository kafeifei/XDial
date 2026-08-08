import AppKit
import XCTest

final class AppAppearanceTests: XCTestCase {
    func testSystemAppearanceClearsTheWindowOverride() {
        XCTAssertNil(AppAppearance.system.windowAppearance)
    }

    func testExplicitAppearancesMapToWholeWindowAppearances() {
        XCTAssertEqual(AppAppearance.light.windowAppearance?.name, .aqua)
        XCTAssertEqual(AppAppearance.dark.windowAppearance?.name, .darkAqua)
    }

    @MainActor
    func testControllerClearsAWindowOverrideForSystemAppearance() {
        let window = NSWindow()
        XDialWindowAppearanceController.apply(.dark, to: window)
        XCTAssertEqual(window.appearance?.name, .darkAqua)

        XDialWindowAppearanceController.apply(.system, to: window)
        XCTAssertNil(window.appearance)
    }
}
