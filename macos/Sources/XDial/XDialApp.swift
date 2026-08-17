import AppKit
import SwiftUI

private struct SettingsWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        SettingsWindowChromeView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class SettingsWindowChromeView: NSView {
    private struct PendingTabClick {
        let index: Int
        let initialScreenPoint: NSPoint
    }

    private var headerMouseMonitor: Any?
    private var pendingTabClick: PendingTabClick?

    deinit {
        if let headerMouseMonitor {
            NSEvent.removeMonitor(headerMouseMonitor)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.configureWindow()
        }
    }

    private func configureWindow() {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.backgroundColor = XDialPalette.canvasNSColor
        window.layoutIfNeeded()
        installHeaderMouseMonitor()

        guard let contentView = window.contentView else { return }
        let targetCenter = NSPoint(
            x: 0,
            y: contentView.isFlipped
                ? 24
                : contentView.bounds.maxY - 24
        )
        let buttons: [(NSWindow.ButtonType, CGFloat)] = [
            (.closeButton, 16),
            (.miniaturizeButton, 37),
            (.zoomButton, 57),
        ]
        for (kind, x) in buttons {
            guard let button = window.standardWindowButton(kind),
                  let buttonContainer = button.superview else { continue }
            let center = buttonContainer.convert(
                targetCenter,
                from: contentView
            )
            var frame = button.frame
            frame.origin.x = x
            frame.origin.y += center.y - frame.midY
            button.setFrameOrigin(frame.origin)
        }
    }

    private func installHeaderMouseMonitor() {
        guard headerMouseMonitor == nil else { return }
        headerMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .leftMouseDown:
                return self.handleHeaderMouseDown(event)
            case .leftMouseUp:
                return self.handleHeaderMouseUp(event)
            default:
                return event
            }
        }
    }

    private func handleHeaderMouseDown(_ event: NSEvent) -> NSEvent? {
        guard let window,
              event.window === window,
              let contentView = window.contentView else { return event }
        let point = contentView.convert(event.locationInWindow, from: nil)
        let distanceFromTop = contentView.isFlipped
            ? point.y
            : contentView.bounds.maxY - point.y
        guard (0 ... 48).contains(distanceFromTop),
              point.x >= 80 else { return event }

        pendingTabClick = nil
        let initialWindowOrigin = window.frame.origin
        let initialScreenPoint = window.convertPoint(
            toScreen: event.locationInWindow
        )
        window.performDrag(with: event)

        let finalWindowOrigin = window.frame.origin
        let finalScreenPoint = NSEvent.mouseLocation
        let windowDistance = hypot(
            finalWindowOrigin.x - initialWindowOrigin.x,
            finalWindowOrigin.y - initialWindowOrigin.y
        )
        let pointerDistance = hypot(
            finalScreenPoint.x - initialScreenPoint.x,
            finalScreenPoint.y - initialScreenPoint.y
        )
        if max(windowDistance, pointerDistance) < 3,
           let index = settingsTabIndex(at: point.x) {
            if NSEvent.pressedMouseButtons & 1 == 0 {
                selectSettingsTab(index, in: window)
            } else {
                pendingTabClick = PendingTabClick(
                    index: index,
                    initialScreenPoint: initialScreenPoint
                )
            }
        }
        return nil
    }

    private func handleHeaderMouseUp(_ event: NSEvent) -> NSEvent? {
        guard let pendingTabClick else { return event }
        self.pendingTabClick = nil
        guard let window,
              event.window === window,
              let contentView = window.contentView else { return nil }
        let point = contentView.convert(event.locationInWindow, from: nil)
        let finalScreenPoint = window.convertPoint(
            toScreen: event.locationInWindow
        )
        let pointerDistance = hypot(
            finalScreenPoint.x - pendingTabClick.initialScreenPoint.x,
            finalScreenPoint.y - pendingTabClick.initialScreenPoint.y
        )
        if pointerDistance < 3,
           settingsTabIndex(at: point.x) == pendingTabClick.index {
            selectSettingsTab(pendingTabClick.index, in: window)
        }
        return nil
    }

    private func selectSettingsTab(_ index: Int, in window: NSWindow) {
        NotificationCenter.default.post(
            name: .xdialSettingsSelectTab,
            object: window,
            userInfo: ["index": index]
        )
    }

    private func settingsTabIndex(at x: CGFloat) -> Int? {
        let mainStart: CGFloat = 126
        let mainWidth: CGFloat = 260
        if x >= mainStart, x < mainStart + mainWidth {
            return min(Int((x - mainStart) / (mainWidth / 3)), 2)
        }
        if x >= 440, x < 524 {
            return 3
        }
        return nil
    }
}

private struct InstallationWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        InstallationWindowChromeView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class InstallationWindowChromeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            window.level = .floating
            window.hidesOnDeactivate = false
            window.styleMask.remove(.miniaturizable)
        }
    }
}

extension Notification.Name {
    /// DebugServer 请求打开设置窗口。
    ///
    /// 设置窗口平时由 popover 里的齿轮用 openWindow 打开，而 popover 只有点菜单栏
    /// 图标才会出现 —— 那个图标是系统 status item，AXPress 和 System Events 都点不动。
    /// 所以调试时改由常驻渲染的菜单栏 label 代为 openWindow。
    static let xdialDebugOpenSettings = Notification.Name("xdial.debug.openSettings")
    static let xdialSettingsSelectTab = Notification.Name(
        "xdial.settings.selectTab"
    )
}

/// 菜单栏图标。之所以单独成 View：它常驻渲染，是 DEBUG 下唯一能稳定拿到
/// openWindow 环境值的地方（popover 的内容只在展开时才存在）。
private struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    // label 的 colorScheme 来自 status item 所在的 NSStatusBarWindow，跟随真实
    // 菜单栏明暗（含壁纸压暗），不受设置页外观覆盖影响；只用于非模板的「有更新」图。
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let connected: Bool
    let connecting: Bool
    let hasError: Bool
    let updateAvailable: Bool
    /// 连接中拨号动画的帧号；只在真正连接中且未开启 Reduce Motion 时推进。
    @State private var animationFrame = 0

    private var connection: MenuBarStatusIcon.ConnectionState {
        if connected { return .connected }
        if connecting { return .connecting }
        return .disconnected
    }

    private var animates: Bool {
        connection == .connecting && !reduceMotion
    }

    var body: some View {
        Image(nsImage: MenuBarStatusIcon.image(
            connection: connection,
            badge: .resolve(
                hasError: hasError,
                updateAvailable: updateAvailable
            ),
            menuBarTone: colorScheme == .dark ? .dark : .light,
            animationFrame: animationFrame
        ))
            .frame(
                width: MenuBarStatusIcon.canvasSize,
                height: MenuBarStatusIcon.canvasSize
            )
            // 系统 status item 还会增加自身左右 inset；缩窄 label 布局宽度，
            // 但不裁剪 20 pt 的拨盘。
            .frame(width: 16, height: 22)
            .accessibilityLabel("XDial")
            .task(id: animates) {
                // 状态离开连接中时任务被取消并复位帧号，静态图始终是第 0 帧。
                guard animates else {
                    animationFrame = 0
                    return
                }
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(
                            for: MenuBarStatusIcon.animationFrameInterval
                        )
                    } catch {
                        return
                    }
                    animationFrame = (animationFrame + 1)
                        % MenuBarStatusIcon.animationFramesPerCycle
                }
            }
            .onAppear {
                AppIcon.applyDockState(connected: connected)
            }
            .onChange(of: connected) { _, isConnected in
                AppIcon.applyDockState(connected: isConnected)
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .xdialOpenInstallation
                )
            ) { _ in
                ApplicationWindowLifecycleController.shared
                    .prepareToPresentInstallationWindow()
                openWindow(id: "installation")
                NSApp.activate(ignoringOtherApps: true)
            }
        #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: .xdialDebugOpenSettings)) { _ in
                ApplicationWindowLifecycleController.shared
                    .prepareToPresentSettingsWindow()
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
        #endif
    }
}

struct XDialApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = AppState()
    @StateObject private var updateChecker = AppUpdateChecker()

    var body: some Scene {
        MenuBarExtra {
            MainPopover()
                .environmentObject(state)
                .tint(XDialPalette.accent)
        } label: {
            MenuBarLabel(
                connected: state.isConnected,
                connecting: state.isBusy,
                hasError: state.hasMenuBarError,
                updateAvailable: updateChecker.isUpdateAvailable
            )
            .task {
                await updateChecker.checkIfNeeded()
            }
        }
        .menuBarExtraStyle(.window)

        Window("XDial 设置", id: "settings") {
            SettingsView()
                .environmentObject(state)
                .tint(XDialPalette.accent)
                .background(SettingsWindowChrome())
        }
        .defaultSize(width: 540, height: 520)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Window("XDial 安装与卸载", id: "installation") {
            InstallationView(
                coordinator: InstallationCoordinator.shared
            )
            .environmentObject(state)
            .tint(XDialPalette.accent)
            .background(InstallationWindowChrome())
        }
        .defaultSize(width: 480, height: 420)
        .windowResizability(.contentSize)
    }
}

@MainActor
final class ApplicationWindowLifecycleController {
    static let shared = ApplicationWindowLifecycleController()

    private enum ManagedWindowKind: String {
        case settings
        case installation
    }

    private var observers: [NSObjectProtocol] = []
    private(set) var lastPolicyTransitionSucceeded = true

    private init() {}

    func start() {
        guard observers.isEmpty else { return }

        SettingsDockProxyCoordinator.shared.dismiss()
        SettingsDockProxyCoordinator.shared.activationRequested = {
            [weak self] in
            self?.bringSettingsWindowForward()
        }

        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { notification in
                MainActor.assumeIsolated {
                    self.windowDidBecomeKey(notification)
                }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: nil,
                queue: .main
            ) { notification in
                MainActor.assumeIsolated {
                    self.windowWillClose(notification)
                }
            }
        )
    }

    func prepareToPresentSettingsWindow() {
        AppIcon.applyDockState(connected: GoEngine.shared.isConnected)
        SettingsDockProxyCoordinator.shared.present()
        _ = NSApp.setActivationPolicy(.accessory)
        lastPolicyTransitionSucceeded =
            NSApp.activationPolicy() == .accessory
    }

    func prepareToPresentInstallationWindow() {
        guard !hasOpenWindow(.settings) else { return }
        _ = NSApp.setActivationPolicy(.accessory)
        lastPolicyTransitionSucceeded =
            NSApp.activationPolicy() == .accessory
    }

    private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let kind = kind(of: window) else { return }
        window.hidesOnDeactivate = false
        switch kind {
        case .settings:
            prepareToPresentSettingsWindow()
        case .installation:
            window.level = .floating
            window.styleMask.remove(.miniaturizable)
            prepareToPresentInstallationWindow()
        }
    }

    private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              kind(of: window) != nil else { return }

        // willClose 触发时窗口仍被 AppKit 视为可见。等本轮关闭事件完成后再统一
        // 核对受管窗口，随后恢复 agent policy 并让出 active 状态。
        DispatchQueue.main.async { [weak self] in
            self?.reconcileAfterWindowClose()
        }
    }

    private func reconcileAfterWindowClose() {
        if hasOpenWindow(.settings) {
            prepareToPresentSettingsWindow()
            return
        }
        SettingsDockProxyCoordinator.shared.dismiss()
        _ = NSApp.setActivationPolicy(.accessory)
        lastPolicyTransitionSucceeded =
            NSApp.activationPolicy() == .accessory
        if !hasOpenWindow(.installation) {
            NSApp.deactivate()
        }
    }

    private func bringSettingsWindowForward() {
        guard let settingsWindow = NSApp.windows.first(where: { window in
            kind(of: window) == .settings
                && (window.isVisible || window.isMiniaturized)
        }) else { return }
        if settingsWindow.isMiniaturized {
            settingsWindow.deminiaturize(nil)
        }
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var diagnostics: [String: Any] {
        [
            "desiredDockPresentation": hasOpenWindow(.settings)
                ? "settings" : "hidden",
            "activationPolicy": Self.activationPolicyName(
                NSApp.activationPolicy()
            ),
            "isActive": NSApp.isActive,
            "lastPolicyTransitionSucceeded":
                lastPolicyTransitionSucceeded,
            "settingsDockProxyDesired":
                SettingsDockProxyCoordinator.shared.isDesiredVisible,
            "settingsDockProxyRunning":
                SettingsDockProxyCoordinator.shared.isRunning,
            "settingsDockProxyLaunchInFlight":
                SettingsDockProxyCoordinator.shared.isLaunchInFlight,
            "isAgent": Bundle.main.object(
                forInfoDictionaryKey: "LSUIElement"
            ) as? Bool ?? false,
        ]
    }

    private static func activationPolicyName(
        _ policy: NSApplication.ActivationPolicy
    ) -> String {
        switch policy {
        case .regular:
            return "regular"
        case .accessory:
            return "accessory"
        case .prohibited:
            return "prohibited"
        @unknown default:
            return "unknown"
        }
    }

    private func hasOpenWindow(_ kind: ManagedWindowKind) -> Bool {
        NSApp.windows.contains { window in
            self.kind(of: window) == kind
                && (window.isVisible || window.isMiniaturized)
        }
    }

    private func kind(of window: NSWindow) -> ManagedWindowKind? {
        guard let identifier = window.identifier?.rawValue else {
            return nil
        }
        return ManagedWindowKind(rawValue: identifier)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationTask: Task<Void, Never>?
    private var terminationApproved = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // XDial 的最后一个普通窗口关闭后仍必须作为菜单栏网络控制面常驻。
        // SwiftUI/AppKit 在无普通窗口时可能重新允许 automatic termination；
        // 对网络托管进程明确保持禁止，不能用保留 Dock 图标来间接续命。
        ProcessInfo.processInfo.disableAutomaticTermination(
            "XDial must remain available after its settings windows close"
        )
        ProcessInfo.processInfo.disableSuddenTermination()
        XDialWindowAppearanceController.applyToApplication(
            AppAppearance.persisted(in: xdialDefaults)
        )
        AppIcon.applyDockState(connected: GoEngine.shared.isConnected)
        ApplicationWindowLifecycleController.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        SettingsDockProxyCoordinator.shared.dismiss()
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        appLog("application termination: delegate entered")
        if terminationApproved {
            appLog("application termination: final exit approved")
            return .terminateNow
        }
        if terminationTask != nil {
            return .terminateCancel
        }
        let engine = GoEngine.shared
        guard Self.requiresTerminationDrain(engine) else {
            appLog("application termination: no active network transaction")
            return .terminateNow
        }

        // terminateLater 会让 NSApplication.terminate() 进入嵌套 RunLoop；
        // NE 的 completion 与 MainActor 投影在这个状态下都可能无法推进。先
        // cancel 本轮退出，让主事件循环继续跑；回滚闭合后再发起第二轮退出。
        appLog("application termination: draining active network transaction")
        engine.stop(userInitiated: true)
        let deadline = Date().addingTimeInterval(12)
        terminationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while Date() < deadline,
                  Self.requiresTerminationDrain(engine) {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if Self.requiresTerminationDrain(engine) {
                let report = engine.connectionReport
                let reportState = report?.state.rawValue ?? "none"
                appLog(
                    "application termination: network drain timed out; "
                        + "status=\(engine.status) "
                        + "report=\(reportState) "
                        + "rollback_complete="
                        + "\(report?.rollbackComplete ?? false) "
                        + "system_takeover_removed="
                        + "\(report?.systemTakeoverRemoved ?? false)"
                )
            } else {
                appLog("application termination: network drain completed")
            }
            self.terminationApproved = true
            self.terminationTask = nil
            NSApp.terminate(nil)
        }
        return .terminateCancel
    }

    @MainActor
    private static func requiresTerminationDrain(
        _ engine: GoEngine
    ) -> Bool {
        engine.requiresTerminationDrain()
    }
}
