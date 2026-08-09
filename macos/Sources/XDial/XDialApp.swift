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
    let connected: Bool
    let hasError: Bool
    let updateAvailable: Bool

    var body: some View {
        Image(nsImage: AppIcon.menuBar(
            connected: connected,
            hasError: hasError,
            updateAvailable: updateAvailable
        ))
            .resizable()
            .interpolation(.high)
            .frame(width: 20, height: 20)
            // 系统 status item 还会增加自身左右 inset；缩窄
            // label 布局宽度，但不裁剪 20pt 的月球。
            .frame(width: 16, height: 22)
            .accessibilityLabel("XDial")
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
                openWindow(id: "installation")
                NSApp.activate(ignoringOtherApps: true)
            }
        #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: .xdialDebugOpenSettings)) { _ in
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
        }
        .defaultSize(width: 480, height: 420)
        .windowResizability(.contentSize)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationTask: Task<Void, Never>?
    private var terminationApproved = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        XDialWindowAppearanceController.applyToApplication(
            AppAppearance.persisted(in: xdialDefaults)
        )
        AppIcon.applyDockState(connected: GoEngine.shared.isConnected)

        // 设置窗口：不随失焦隐藏 + 出现在 Cmd+Tab
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { n in
            MainActor.assumeIsolated {
                guard let w = n.object as? NSWindow,
                      w.title.contains("设置")
                        || w.title.contains("Settings")
                        || w.title.contains("安装")
                        || w.title.contains("Installation") else { return }
                w.hidesOnDeactivate = false
                AppIcon.applyDockState(
                    connected: GoEngine.shared.isConnected
                )
                NSApp.setActivationPolicy(.regular)
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { n in
            guard let w = n.object as? NSWindow,
                  w.title.contains("设置")
                    || w.title.contains("Settings")
                    || w.title.contains("安装")
                    || w.title.contains("Installation") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let hasSettings = NSApp.windows.contains {
                    $0.isVisible && (
                        $0.title.contains("设置")
                            || $0.title.contains("Settings")
                            || $0.title.contains("安装")
                            || $0.title.contains("Installation")
                    )
                }
                if !hasSettings { NSApp.setActivationPolicy(.accessory) }
            }
        }
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
