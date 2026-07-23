import XCTest

@MainActor
final class HomeViewUITests: XCTestCase {
    func testConnectingDoesNotShowIncompleteConfigurationWarning() {
        let app = launchApp()

        let connectButton = app.buttons["连接"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 5))
        connectButton.tap()

        let activeStatus = app.staticTexts.matching(NSPredicate(
            format: "label == %@ OR label == %@",
            "正在连接…",
            "已连接"
        )).firstMatch
        XCTAssertTrue(activeStatus.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["连接配置尚未完成"].exists)

        app.tabBars.buttons["设置"].tap()
        let simulatorProbe = app.staticTexts.containing(NSPredicate(
            format: "label CONTAINS %@",
            "模拟器 FakeTunnel：未接管系统流量"
        )).firstMatch
        if !simulatorProbe.exists {
            app.swipeUp()
        }
        XCTAssertTrue(simulatorProbe.waitForExistence(timeout: 2))
    }

    func testConfigurationModeAndDiagnosticsEntryPoints() {
        let app = launchApp()

        app.tabBars.buttons["配置"].tap()
        XCTAssertTrue(app.segmentedControls.buttons["线路"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.segmentedControls.buttons["规则"].exists)
        XCTAssertTrue(app.segmentedControls.buttons["订阅"].exists)

        app.buttons["添加线路"].tap()
        app.buttons["VMess"].tap()
        XCTAssertTrue(app.staticTexts["VMess"].waitForExistence(timeout: 2))

        app.segmentedControls.buttons["规则"].tap()
        app.buttons["添加规则"].tap()
        app.buttons["手工规则"].tap()
        XCTAssertTrue(app.staticTexts["新手工规则"].waitForExistence(timeout: 2))

        app.segmentedControls.buttons["订阅"].tap()
        app.buttons["添加订阅"].tap()
        XCTAssertTrue(app.textFields["订阅 URL"].waitForExistence(timeout: 2))
        app.buttons["取消"].tap()

        app.tabBars.buttons["模式"].tap()
        app.buttons["添加模式"].tap()
        app.buttons["空白模式"].tap()
        XCTAssertTrue(app.staticTexts["空白模式"].waitForExistence(timeout: 2))

        app.tabBars.buttons["设置"].tap()
        let diagnosticsButton = app.buttons["查看诊断详情"]
        if !diagnosticsButton.exists {
            app.swipeUp()
        }
        XCTAssertTrue(diagnosticsButton.waitForExistence(timeout: 2))
        let tailscaleCapability = app.staticTexts.containing(NSPredicate(
            format: "label CONTAINS %@",
            "MagicDNS/.ts.net 分域解析"
        )).firstMatch
        if !tailscaleCapability.exists {
            app.swipeUp()
        }
        XCTAssertTrue(tailscaleCapability.waitForExistence(timeout: 2))
        diagnosticsButton.tap()
        XCTAssertTrue(app.navigationBars["诊断详情"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'XDial 诊断'")).firstMatch.exists)
    }

    func testConnectivityAcceptanceRulesAreVisibleAndProtected() {
        let app = launchApp()

        app.tabBars.buttons["配置"].tap()
        app.segmentedControls.buttons["规则"].tap()

        for name in ["连接验收 · Direct", "连接验收 · 非 Direct 出口"] {
            let rule = visibleAcceptanceRule(named: name, in: app)
            rule.tap()
            XCTAssertTrue(app.navigationBars["编辑规则"].waitForExistence(timeout: 2))
            let enabledSwitch = app.switches["启用"]
            XCTAssertTrue(enabledSwitch.exists)
            XCTAssertFalse(enabledSwitch.isEnabled)
            XCTAssertFalse(app.buttons["删除规则"].exists)
            app.navigationBars["编辑规则"].buttons["配置"].tap()
        }
    }

    func testAnyConnectCredentialsPersistAfterSaveAndRestart() {
        let app = launchApp()
        openAnyConnectEditor(in: app)

        let serverMarker = ".persist-ui.invalid"
        let usernameMarker = "-persist-user"
        let passwordMarker = "persist-password"
        let server = app.textFields["服务器"]
        let username = app.textFields["用户名"]
        let password = app.secureTextFields["密码"]
        XCTAssertTrue(server.waitForExistence(timeout: 2))
        XCTAssertTrue(username.exists)
        XCTAssertTrue(password.exists)

        server.tap()
        server.typeText(serverMarker)
        username.tap()
        username.typeText(usernameMarker)
        password.tap()
        password.typeText(passwordMarker)

        XCTAssertTrue((server.value as? String)?.contains(serverMarker) == true)
        XCTAssertTrue((username.value as? String)?.contains(usernameMarker) == true)
        let savedPasswordLength = secureValueLength(password)
        XCTAssertGreaterThan(savedPasswordLength, 0)

        XCTAssertTrue(app.buttons["已保存"].waitForExistence(timeout: 2))
        app.navigationBars["编辑线路"].buttons["配置"].tap()
        XCTAssertTrue(app.navigationBars["配置"].waitForExistence(timeout: 2))

        app.terminate()

        let relaunched = launchApp(reset: false)
        openAnyConnectEditor(in: relaunched)
        let restoredServer = relaunched.textFields["服务器"]
        let restoredUsername = relaunched.textFields["用户名"]
        let restoredPassword = relaunched.secureTextFields["密码"]
        XCTAssertTrue(restoredServer.waitForExistence(timeout: 2))
        XCTAssertTrue((restoredServer.value as? String)?.contains(serverMarker) == true)
        XCTAssertTrue((restoredUsername.value as? String)?.contains(usernameMarker) == true)
        XCTAssertEqual(secureValueLength(restoredPassword), savedPasswordLength)
    }

    func testSubscriptionRuntimeControlsExposeDelayAndExitAddress() {
        let app = launchApp()
        let connectButton = app.buttons["连接"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 5))
        connectButton.tap()
        XCTAssertTrue(app.staticTexts["已连接"].waitForExistence(timeout: 4))

        app.tabBars.buttons["配置"].tap()
        app.segmentedControls.buttons["订阅"].tap()
        let subscription = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", "UI 测试订阅"
        )).firstMatch
        XCTAssertTrue(subscription.waitForExistence(timeout: 2))
        subscription.tap()

        XCTAssertTrue(app.navigationBars["编辑订阅"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["手动选择"].exists)

        let selector = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@",
            "当前节点"
        )).firstMatch
        XCTAssertTrue(selector.waitForExistence(timeout: 2))
        XCTAssertTrue((selector.label).contains("演示节点一"))
        selector.tap()
        let secondNode = app.buttons["演示节点二"]
        XCTAssertTrue(secondNode.waitForExistence(timeout: 2))
        secondNode.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@",
            "当前节点",
            "演示节点二"
        )).firstMatch.waitForExistence(timeout: 2))

        XCTAssertTrue(app.buttons["测试节点"].firstMatch.waitForExistence(timeout: 2))
        app.buttons["测试节点"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label ENDSWITH %@", " ms"
        )).firstMatch.waitForExistence(timeout: 2))

        XCTAssertTrue(app.buttons["确认出口 IP"].firstMatch.exists)
        app.buttons["确认出口 IP"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@", "模拟 198.51.100."
        )).firstMatch.waitForExistence(timeout: 2))
    }

    func testTailscaleLineCanBeCreatedAndOpened() {
        let app = launchApp()

        app.tabBars.buttons["配置"].tap()
        app.buttons["添加线路"].tap()
        let tailscaleMenuItem = app.buttons["Tailscale"]
        XCTAssertTrue(tailscaleMenuItem.waitForExistence(timeout: 2))
        tailscaleMenuItem.tap()

        let tailscaleLine = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@",
            "Tailscale"
        )).firstMatch
        XCTAssertTrue(tailscaleLine.waitForExistence(timeout: 2))
        tailscaleLine.tap()
        XCTAssertTrue(app.navigationBars["编辑线路"].waitForExistence(timeout: 2))
        let deviceName = app.textFields["设备名称（可选）"]
        let acceptRoutes = app.switches["接受子网路由"]
        XCTAssertTrue(deviceName.waitForExistence(timeout: 2))
        XCTAssertTrue(acceptRoutes.exists)
        XCTAssertTrue(app.staticTexts["请先连接，再登录或刷新状态。"].exists)

        let initialAcceptRoutesValue = acceptRoutes.value as? String
        let expectedAcceptRoutesValue = initialAcceptRoutesValue == "1" ? "0" : "1"
        deviceName.tap()
        deviceName.typeText("ui-tailscale")
        app.keyboards.buttons["return"].tap()
        XCTAssertTrue(acceptRoutes.isEnabled)
        acceptRoutes.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let switchExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expectedAcceptRoutesValue),
            object: acceptRoutes
        )
        XCTAssertEqual(XCTWaiter.wait(for: [switchExpectation], timeout: 2), .completed)
        XCTAssertTrue(app.buttons["已保存"].waitForExistence(timeout: 2))
        app.navigationBars["编辑线路"].buttons["配置"].tap()

        let savedTailscaleLine = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@",
            "Tailscale"
        )).firstMatch
        XCTAssertTrue(savedTailscaleLine.waitForExistence(timeout: 2))
        savedTailscaleLine.tap()
        let restoredDeviceName = app.textFields["设备名称（可选）"]
        let restoredAcceptRoutes = app.switches["接受子网路由"]
        XCTAssertTrue(restoredDeviceName.waitForExistence(timeout: 2))
        XCTAssertTrue((restoredDeviceName.value as? String)?.contains("ui-tailscale") == true)
        XCTAssertEqual(restoredAcceptRoutes.value as? String, expectedAcceptRoutesValue)
    }

    func testTailscaleActionRequiredOffersSignInLocksConfigurationAndCanDisconnect() {
        let app = launchApp(extraArguments: ["-XDialUITestingTailscaleActionRequired"])

        app.buttons["连接"].tap()
        XCTAssertTrue(app.staticTexts["需要登录 Tailscale"].waitForExistence(timeout: 4))
        let disconnect = app.buttons["断开"]
        XCTAssertTrue(disconnect.exists)
        XCTAssertTrue(disconnect.isEnabled)

        app.tabBars.buttons["模式"].tap()
        XCTAssertFalse(app.buttons["添加模式"].isEnabled)

        app.tabBars.buttons["配置"].tap()
        XCTAssertFalse(app.buttons["添加线路"].isEnabled)
        let tailscale = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@",
            "Tailscale 演示"
        )).firstMatch
        XCTAssertTrue(tailscale.waitForExistence(timeout: 2))
        tailscale.tap()
        XCTAssertTrue(app.buttons["在浏览器中登录"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.textFields["设备名称（可选）"].isEnabled)

        app.tabBars.buttons["首页"].tap()
        disconnect.tap()
        XCTAssertTrue(app.staticTexts["未连接"].waitForExistence(timeout: 3))
    }

    func testSubscriptionDefaultAppearsInHomeActiveRoutes() {
        let app = launchApp(extraArguments: ["-XDialUITestingSubscriptionSummary"])

        XCTAssertTrue(app.staticTexts["本模式活动出口"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["UI 测试订阅"].exists)
        XCTAssertFalse(app.staticTexts["没有活动出口"].exists)
    }

    func testSystemOnDemandPreferencePersistsAfterRelaunch() {
        let app = launchApp()
        app.tabBars.buttons["设置"].tap()

        let toggle = app.switches["system-on-demand-reconnect"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 2))
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let enabledExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "1"),
            object: toggle
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enabledExpectation], timeout: 2), .completed)
        let status = app.staticTexts["system-on-demand-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 2))
        XCTAssertTrue(status.label.contains("待连接验收"))

        app.terminate()
        let relaunched = launchApp(reset: false)
        relaunched.tabBars.buttons["设置"].tap()
        XCTAssertTrue(relaunched.switches["system-on-demand-reconnect"].waitForExistence(timeout: 2))
        XCTAssertEqual(relaunched.switches["system-on-demand-reconnect"].value as? String, "1")
        let restoredStatus = relaunched.staticTexts["system-on-demand-status"]
        XCTAssertTrue(restoredStatus.waitForExistence(timeout: 2))
        XCTAssertTrue(restoredStatus.label.contains("待连接验收"))

        relaunched.tabBars.buttons["首页"].tap()
        relaunched.buttons["连接"].tap()
        XCTAssertTrue(relaunched.staticTexts["已连接"].waitForExistence(timeout: 4))
        relaunched.tabBars.buttons["设置"].tap()
        let activeStatus = relaunched.staticTexts["system-on-demand-status"]
        XCTAssertTrue(activeStatus.waitForExistence(timeout: 2))
        XCTAssertTrue(activeStatus.label.contains("系统已启用"))
    }

    private func visibleAcceptanceRule(named name: String, in app: XCUIApplication) -> XCUIElement {
        let rule = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@",
            name
        )).firstMatch
        for _ in 0..<3 where !rule.exists {
            app.swipeUp()
        }
        XCTAssertTrue(rule.waitForExistence(timeout: 2))
        return rule
    }

    private func openAnyConnectEditor(in app: XCUIApplication) {
        app.tabBars.buttons["配置"].tap()
        let line = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "AnyConnect")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 2))
        line.tap()
        XCTAssertTrue(app.navigationBars["编辑线路"].waitForExistence(timeout: 2))
    }

    private func launchApp(
        reset: Bool = true,
        extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            reset ? "-XDialUITestingReset" : "-XDialUITesting",
        ]
        app.launchArguments += extraArguments
        app.launch()
        return app
    }

    private func secureValueLength(_ element: XCUIElement) -> Int {
        (element.value as? String)?.count ?? 0
    }
}
