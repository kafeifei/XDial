import Darwin
import XCTest

@MainActor
final class HomeViewUITests: XCTestCase {
    func testPhysicalDeviceDirectTCPBaseline() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("真实物理网络基线只在 iPhone 上验收")
        #else
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["首页"].waitForExistence(timeout: 15))

        let disconnect = app.buttons["断开"]
        if disconnect.waitForExistence(timeout: 2) {
            disconnect.tap()
            XCTAssertTrue(app.buttons["连接"].waitForExistence(timeout: 15))
        }

        let targets: [(String, UInt16)] = [
            ("1.1.1.1", 443),
            ("1.1.1.1", 80),
            ("api.ipify.org", 443),
            ("checkip.amazonaws.com", 443),
            ("icanhazip.com", 443),
            ("ifconfig.me", 443),
            ("ipinfo.io", 443),
            ("www.apple.com", 443),
            ("example.com", 443),
        ]
        var results: [String] = []
        for (host, port) in targets {
            results.append(directTCPProbe(host: host, port: port, timeoutMS: 5_000))
        }

        print("XDIAL_DEVICE_DIRECT_TCP_BASELINE_BEGIN")
        results.forEach { print($0) }
        print("XDIAL_DEVICE_DIRECT_TCP_BASELINE_END")
        XCTAssertTrue(
            results.dropFirst(2).contains(where: { $0.contains("connected") }),
            "断开 XDial 后，所有替代公网 TCP 443 目标均不可达：\(results.joined(separator: " | "))"
        )
        #endif
    }

    func testPhysicalDeviceConnectionAndDiagnostics() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("真实 Packet Tunnel 数据面只在 iPhone 上验收")
        #else
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]

        addUIInterruptionMonitor(withDescription: "System authorization") { alert in
            for title in ["允许", "Allow", "好", "OK"] {
                let button = alert.buttons[title]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }

        app.launch()
        XCTAssertTrue(app.tabBars.buttons["首页"].waitForExistence(timeout: 15))

        let connect = app.buttons["连接"]
        if connect.waitForExistence(timeout: 5) {
            connect.tap()
            app.tap()
        }

        let connected = app.staticTexts["已连接"]
        let deadline = Date().addingTimeInterval(90)
        while !connected.exists && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }

        let homeLabels = app.staticTexts.allElementsBoundByIndex.map(\.label)
        print("XDIAL_DEVICE_HOME_LABELS_BEGIN")
        homeLabels.forEach { print($0) }
        print("XDIAL_DEVICE_HOME_LABELS_END")
        attachScreenshot(named: "physical-device-home", app: app)
        XCTAssertTrue(
            connected.exists,
            "连接未在 90 秒内通过。首页文本：\(homeLabels.joined(separator: " | "))"
        )

        app.tabBars.buttons["设置"].tap()
        let diagnostics = app.buttons["查看诊断详情"]
        for _ in 0..<5 where !diagnostics.exists {
            app.swipeUp()
        }
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
        diagnostics.tap()
        XCTAssertTrue(app.navigationBars["诊断详情"].waitForExistence(timeout: 10))

        let diagnosticLabels = app.staticTexts.allElementsBoundByIndex.map(\.label)
        let report = diagnosticLabels.joined(separator: "\n")
        print("XDIAL_DEVICE_DIAGNOSTICS_BEGIN")
        print(report)
        print("XDIAL_DEVICE_DIAGNOSTICS_END")
        attachScreenshot(named: "physical-device-diagnostics", app: app)

        XCTAssertTrue(report.contains("Direct"), "诊断缺少 Direct 线路证据")
        XCTAssertTrue(report.contains("AnyConnect"), "诊断缺少 AnyConnect 线路证据")
        XCTAssertTrue(report.contains("路由命中：通过"), "分流命中没有通过")
        XCTAssertTrue(report.contains("DNS：通过"), "DNS 验收没有通过")

        app.navigationBars["诊断详情"].buttons["设置"].tap()
        let onDemandToggle = app.switches["system-on-demand-reconnect"]
        for _ in 0..<5 where !onDemandToggle.exists {
            app.swipeDown()
        }
        guard onDemandToggle.waitForExistence(timeout: 10) else {
            XCTFail("设置页缺少系统按需重连开关")
            return
        }
        if onDemandToggle.value as? String != "1" {
            onDemandToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        let onDemandEnabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "1"),
            object: onDemandToggle
        )
        XCTAssertEqual(XCTWaiter.wait(for: [onDemandEnabled], timeout: 10), .completed)
        XCTAssertTrue(app.staticTexts["system-on-demand-status"].waitForExistence(timeout: 10))

        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["首页"].waitForExistence(timeout: 15))
        XCTAssertTrue(
            app.staticTexts["已连接"].waitForExistence(timeout: 20),
            "主 App 重启后没有恢复已连接状态"
        )
        attachScreenshot(named: "physical-device-relaunch-recovery", app: app)
        #endif
    }

    func testPhysicalDeviceTailscaleLoginOpensOfficialAuthorization() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("真实 Tailscale 授权入口只在 iPhone 上验收")
        #else
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["首页"].waitForExistence(timeout: 15))

        app.tabBars.buttons["配置"].tap()
        let tailscaleLine = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@",
            "Tailscale"
        )).firstMatch
        XCTAssertTrue(tailscaleLine.waitForExistence(timeout: 10))
        tailscaleLine.tap()
        XCTAssertTrue(app.navigationBars["编辑线路"].waitForExistence(timeout: 10))

        let signIn = app.buttons["tailscale-start-setup"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        attachScreenshot(named: "physical-device-tailscale-sign-in", app: app)
        signIn.tap()

        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        let foregroundDeadline = Date().addingTimeInterval(90)
        while app.state == .runningForeground,
              safari.state != .runningForeground,
              Date() < foregroundDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        if app.state == .runningForeground && safari.state != .runningForeground {
            attachScreenshot(named: "physical-device-tailscale-sign-in-result", app: app)
            XCTFail(
                "点击真实 Tailscale 登录入口后 XDial 仍停留在前台：首页文本 "
                    + app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
            )
        }
        safari.activate()
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 10))
        let address = safari.textFields.firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 15))
        let addressValue = (address.value as? String ?? "").lowercased()
        attachScreenshot(named: "physical-device-tailscale-authorization", app: safari)
        XCTAssertTrue(
            addressValue.contains("tailscale.com"),
            "打开的不是 Tailscale 官方授权页：\(addressValue)"
        )
        #endif
    }

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

    func testIncompleteReferencedLinePromptsBeforeConnectingAndOpensConfiguration() {
        let app = launchApp(extraArguments: ["-XDialUITestingIncompleteLine"])

        XCTAssertTrue(app.staticTexts["连接配置尚未完成"].waitForExistence(timeout: 3))
        let connect = app.buttons["连接"]
        XCTAssertTrue(connect.exists)
        connect.tap()

        let alert = app.alerts["连接前请先补齐线路"]
        XCTAssertTrue(alert.waitForExistence(timeout: 2))
        let message = alert.staticTexts.allElementsBoundByIndex
            .map(\.label)
            .joined(separator: " ")
        XCTAssertTrue(message.contains("待配置线路"))
        XCTAssertTrue(message.contains("服务器"))
        XCTAssertTrue(message.contains("用户名"))
        XCTAssertTrue(message.contains("密码"))

        alert.buttons["前往配置"].tap()
        XCTAssertTrue(app.navigationBars["配置"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@",
            "需配置",
            "缺少服务器"
        )).firstMatch.waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["正在连接…"].exists)
        XCTAssertFalse(app.staticTexts["已连接"].exists)
    }

    func testConfigurationModeAndDiagnosticsEntryPoints() {
        let app = launchApp()

        app.tabBars.buttons["配置"].tap()
        XCTAssertTrue(app.segmentedControls.buttons["线路"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.segmentedControls.buttons["规则"].exists)
        XCTAssertTrue(app.segmentedControls.buttons["订阅"].exists)

        app.buttons["添加线路"].tap()
        app.buttons["VMess"].tap()
        XCTAssertTrue(app.navigationBars["编辑线路"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["VMess"].waitForExistence(timeout: 2))
        app.navigationBars["编辑线路"].buttons["配置"].tap()
        XCTAssertTrue(app.navigationBars["配置"].waitForExistence(timeout: 2))

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

        XCTAssertTrue(app.navigationBars["编辑线路"].waitForExistence(timeout: 2))
        let lineNameField = app.textFields.matching(NSPredicate(
            format: "identifier BEGINSWITH %@",
            "line-name-line-"
        )).firstMatch
        XCTAssertTrue(lineNameField.waitForExistence(timeout: 2))
        let newLineIdentifier = lineNameField.identifier.replacingOccurrences(
            of: "line-name-",
            with: "line-row-"
        )
        let deviceName = app.textFields["设备名称（可选）"]
        let acceptRoutes = app.switches["接受子网路由"]
        XCTAssertTrue(deviceName.waitForExistence(timeout: 2))
        XCTAssertTrue(acceptRoutes.exists)
        XCTAssertEqual(app.switches["启用"].value as? String, "0")
        XCTAssertTrue(app.buttons["tailscale-start-setup"].isEnabled)

        let initialAcceptRoutesValue = acceptRoutes.value as? String
        let expectedAcceptRoutesValue = initialAcceptRoutesValue == "1" ? "0" : "1"
        deviceName.tap()
        deviceName.typeText("ui-tailscale")
        app.keyboards.buttons["Return"].tap()
        XCTAssertTrue(acceptRoutes.isEnabled)
        acceptRoutes.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let switchExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expectedAcceptRoutesValue),
            object: acceptRoutes
        )
        XCTAssertEqual(XCTWaiter.wait(for: [switchExpectation], timeout: 2), .completed)
        XCTAssertTrue(app.buttons["已保存"].waitForExistence(timeout: 2))
        app.navigationBars["编辑线路"].buttons["配置"].tap()

        let savedTailscaleLine = app.buttons[newLineIdentifier]
        for _ in 0..<4 where !savedTailscaleLine.exists {
            app.swipeUp()
        }
        XCTAssertTrue(savedTailscaleLine.waitForExistence(timeout: 2))
        savedTailscaleLine.tap()
        let restoredDeviceName = app.textFields["设备名称（可选）"]
        let restoredAcceptRoutes = app.switches["接受子网路由"]
        XCTAssertTrue(restoredDeviceName.waitForExistence(timeout: 2))
        XCTAssertTrue((restoredDeviceName.value as? String)?.contains("ui-tailscale") == true)
        XCTAssertEqual(restoredAcceptRoutes.value as? String, expectedAcceptRoutesValue)

        app.buttons["tailscale-start-setup"].tap()
        XCTAssertTrue(app.staticTexts["tailscale-login-status"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["tailscale-refresh-nodes"].exists)
        let exitNodePicker = app.buttons["tailscale-exit-node-picker"]
        XCTAssertTrue(exitNodePicker.waitForExistence(timeout: 3))
        exitNodePicker.tap()
        let homeExit = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@",
            "mbp64k"
        )).firstMatch
        XCTAssertTrue(homeExit.waitForExistence(timeout: 2))
        homeExit.tap()

        let finishSetup = app.buttons["tailscale-finish-setup"]
        XCTAssertTrue(finishSetup.isEnabled)
        finishSetup.tap()
        XCTAssertTrue(app.buttons["tailscale-start-setup"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["tailscale-start-setup"].label.contains("检查登录状态"))
        XCTAssertEqual(app.switches["启用"].value as? String, "0")

        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        let relaunched = launchApp(reset: false)
        relaunched.tabBars.buttons["配置"].tap()
        let restoredLine = relaunched.buttons[newLineIdentifier]
        for _ in 0..<4 where !restoredLine.exists {
            relaunched.swipeUp()
        }
        XCTAssertTrue(restoredLine.waitForExistence(timeout: 3))
        XCTAssertTrue(restoredLine.label.contains("100.64.0.8"))
        restoredLine.tap()
        XCTAssertEqual(relaunched.switches["启用"].value as? String, "0")
        XCTAssertTrue(relaunched.buttons["tailscale-start-setup"].label.contains("检查登录状态"))

        relaunched.buttons["tailscale-start-setup"].tap()
        XCTAssertTrue(relaunched.staticTexts["tailscale-login-status"].waitForExistence(timeout: 5))
        let signOut = relaunched.buttons["tailscale-logout"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 2))
        signOut.tap()
        let confirmSignOut = relaunched.buttons["tailscale-logout-confirm"].firstMatch
        XCTAssertTrue(confirmSignOut.waitForExistence(timeout: 2))
        confirmSignOut.tap()
        let signedOutSetup = relaunched.buttons["tailscale-start-setup"]
        XCTAssertTrue(signedOutSetup.waitForExistence(timeout: 3))
        XCTAssertTrue(signedOutSetup.label.contains("设置并登录"))

        relaunched.terminate()
        XCTAssertTrue(relaunched.wait(for: .notRunning, timeout: 5))
        let signedOutRelaunch = launchApp(reset: false)
        signedOutRelaunch.tabBars.buttons["配置"].tap()
        let signedOutLine = signedOutRelaunch.buttons[newLineIdentifier]
        for _ in 0..<4 where !signedOutLine.exists {
            signedOutRelaunch.swipeUp()
        }
        XCTAssertTrue(signedOutLine.waitForExistence(timeout: 3))
        XCTAssertTrue(signedOutLine.label.contains("尚未登录"))
        XCTAssertFalse(signedOutLine.label.contains("100.64.0.8"))
        signedOutLine.tap()
        XCTAssertTrue(signedOutRelaunch.buttons["tailscale-start-setup"].label.contains("设置并登录"))
    }

    func testOfflineTailscaleSetupThenFormalConnectAndColdRestart() {
        let fixture = "-XDialUITestingOfflineTailscaleSetup"
        let app = launchApp(extraArguments: [fixture])

        XCTAssertTrue(app.staticTexts["连接配置尚未完成"].waitForExistence(timeout: 3))
        app.buttons["连接"].tap()
        let openConfiguration = app.buttons["前往配置"]
        XCTAssertTrue(openConfiguration.waitForExistence(timeout: 2))
        openConfiguration.tap()

        let line = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@",
            "Tailscale 首次设置"
        )).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 3))
        line.tap()
        let setup = app.buttons["tailscale-start-setup"]
        XCTAssertTrue(setup.waitForExistence(timeout: 2))
        XCTAssertTrue(setup.isEnabled)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@",
            "请先连接"
        )).firstMatch.exists)
        setup.tap()

        XCTAssertTrue(app.staticTexts["tailscale-login-status"].waitForExistence(timeout: 5))
        let picker = app.buttons["tailscale-exit-node-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        picker.tap()
        let exitNode = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@",
            "mbp64k"
        )).firstMatch
        XCTAssertTrue(exitNode.waitForExistence(timeout: 2))
        exitNode.tap()

        let finish = app.buttons["tailscale-finish-setup"]
        XCTAssertTrue(finish.waitForExistence(timeout: 2))
        XCTAssertTrue(finish.isEnabled)
        finish.tap()
        XCTAssertTrue(app.buttons["tailscale-start-setup"].waitForExistence(timeout: 3))

        app.tabBars.buttons["首页"].tap()
        XCTAssertTrue(app.buttons["连接"].waitForExistence(timeout: 3))
        app.buttons["连接"].tap()
        XCTAssertTrue(app.staticTexts["已连接"].waitForExistence(timeout: 5))
        app.buttons["断开"].tap()
        XCTAssertTrue(app.staticTexts["未连接"].waitForExistence(timeout: 4))

        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        let relaunched = launchApp(reset: false, extraArguments: [fixture])
        XCTAssertTrue(relaunched.buttons["连接"].waitForExistence(timeout: 3))
        XCTAssertFalse(relaunched.staticTexts["连接配置尚未完成"].exists)
        relaunched.buttons["连接"].tap()
        XCTAssertTrue(relaunched.staticTexts["已连接"].waitForExistence(timeout: 5))
    }

    func testConnectedInactiveTailscaleCanUseIsolatedSetupWithoutDisconnecting() {
        let app = launchApp(extraArguments: ["-XDialUITestingConnectedInactiveTailscale"])
        app.buttons["连接"].tap()
        XCTAssertTrue(app.staticTexts["已连接"].waitForExistence(timeout: 5))

        app.tabBars.buttons["配置"].tap()
        let line = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@",
            "Tailscale 待设置"
        )).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 3))
        line.tap()

        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@",
            "当前连接没有运行这条线路"
        )).firstMatch.waitForExistence(timeout: 2))
        let setup = app.buttons["tailscale-start-setup"]
        XCTAssertTrue(setup.isEnabled)
        setup.tap()
        XCTAssertTrue(app.staticTexts["tailscale-login-status"].waitForExistence(timeout: 5))

        app.tabBars.buttons["首页"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@",
            "已连接",
            "正在设置"
        )).firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["断开"].exists)
        app.tabBars.buttons["配置"].tap()
        XCTAssertTrue(app.buttons["tailscale-finish-setup"].waitForExistence(timeout: 3))
        app.buttons["tailscale-finish-setup"].tap()
    }

    func testTailscaleActionRequiredOffersSignInLocksConfigurationAndCanDisconnect() {
        let app = launchApp(extraArguments: ["-XDialUITestingTailscaleActionRequired"])

        app.buttons["连接"].tap()
        XCTAssertTrue(app.staticTexts["需要登录 Tailscale"].waitForExistence(timeout: 4))
        let disconnect = app.buttons["断开"]
        XCTAssertTrue(disconnect.exists)
        XCTAssertTrue(disconnect.isEnabled)
        XCTAssertTrue(app.buttons["登录 Tailscale"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts[
            "这是 XDial 内置线路的独立授权，与手机上的 Tailscale App 登录状态不共享。完成一次授权后，XDial 会自动继续连接验收。"
        ].exists)

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

        XCTAssertTrue(app.staticTexts["连接后使用的出口"].waitForExistence(timeout: 2))
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

    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func directTCPProbe(host: String, port: UInt16, timeoutMS: Int32) -> String {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var list: UnsafeMutablePointer<addrinfo>?
        let service = String(port)
        let resolveCode = getaddrinfo(host, service, &hints, &list)
        guard resolveCode == 0, let first = list else {
            return "\(host):\(port) resolve_failed=\(resolveCode)"
        }
        defer { freeaddrinfo(first) }

        var candidate: UnsafeMutablePointer<addrinfo>? = first
        var failures: [String] = []
        while let current = candidate {
            let info = current.pointee
            let numericHost = numericAddress(info)
            let fd = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            guard fd >= 0 else {
                failures.append("\(numericHost) socket_errno=\(errno)")
                candidate = info.ai_next
                continue
            }
            defer { close(fd) }

            let previousFlags = fcntl(fd, F_GETFL, 0)
            guard previousFlags >= 0, fcntl(fd, F_SETFL, previousFlags | O_NONBLOCK) == 0 else {
                failures.append("\(numericHost) nonblock_errno=\(errno)")
                candidate = info.ai_next
                continue
            }

            let connectResult = connect(fd, info.ai_addr, info.ai_addrlen)
            if connectResult == 0 {
                return "\(host):\(port) \(numericHost) connected"
            }
            guard errno == EINPROGRESS else {
                failures.append("\(numericHost) connect_errno=\(errno)")
                candidate = info.ai_next
                continue
            }

            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let pollResult = poll(&descriptor, 1, timeoutMS)
            if pollResult > 0 {
                var socketError: Int32 = 0
                var errorLength = socklen_t(MemoryLayout<Int32>.size)
                if getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLength) == 0,
                   socketError == 0 {
                    return "\(host):\(port) \(numericHost) connected"
                }
                failures.append("\(numericHost) connect_errno=\(socketError)")
            } else if pollResult == 0 {
                failures.append("\(numericHost) timeout")
            } else {
                failures.append("\(numericHost) poll_errno=\(errno)")
            }
            candidate = info.ai_next
        }
        return "\(host):\(port) failed [\(failures.joined(separator: ", "))]"
    }

    private func numericAddress(_ info: addrinfo) -> String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let code = getnameinfo(
            info.ai_addr,
            info.ai_addrlen,
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        return code == 0 ? String(cString: host) : "unknown"
    }
}
