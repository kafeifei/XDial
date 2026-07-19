import XCTest

final class HomeViewUITests: XCTestCase {
    func testConnectingDoesNotShowIncompleteConfigurationWarning() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()

        let connectButton = app.buttons["连接"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 5))
        connectButton.tap()

        XCTAssertTrue(app.staticTexts["正在连接…"].waitForExistence(timeout: 1))
        XCTAssertFalse(app.staticTexts["连接配置尚未完成"].exists)
    }
}
