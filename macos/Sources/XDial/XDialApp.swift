import AppKit
import SwiftUI

extension Notification.Name {
    /// DebugServer 请求打开设置窗口。
    ///
    /// 设置窗口平时由 popover 里的齿轮用 openWindow 打开，而 popover 只有点菜单栏
    /// 图标才会出现 —— 那个图标是系统 status item，AXPress 和 System Events 都点不动。
    /// 所以调试时改由常驻渲染的菜单栏 label 代为 openWindow。
    static let xdialDebugOpenSettings = Notification.Name("xdial.debug.openSettings")
}

/// 菜单栏图标。之所以单独成 View：它常驻渲染，是 DEBUG 下唯一能稳定拿到
/// openWindow 环境值的地方（popover 的内容只在展开时才存在）。
private struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    let connected: Bool

    var body: some View {
        Image(nsImage: AppIcon.menuBar(connected: connected))
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

    var body: some Scene {
        MenuBarExtra {
            MainPopover()
                .environmentObject(state)
                .tint(XDialPalette.accent)
                .preferredColorScheme(state.appearance.colorScheme)
        } label: {
            MenuBarLabel(connected: state.isConnected)
        }
        .menuBarExtraStyle(.window)

        Window("XDial 设置", id: "settings") {
            SettingsView()
                .environmentObject(state)
                .tint(XDialPalette.accent)
                .preferredColorScheme(state.appearance.colorScheme)
        }
        .defaultSize(width: 540, height: 540)
        .windowResizability(.contentSize)

        Window("XDial 安装与卸载", id: "installation") {
            InstallationView(
                coordinator: InstallationCoordinator.shared
            )
            .environmentObject(state)
            .tint(XDialPalette.accent)
            .preferredColorScheme(state.appearance.colorScheme)
        }
        .defaultSize(width: 480, height: 420)
        .windowResizability(.contentSize)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationTask: Task<Void, Never>?
    private var terminationApproved = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppIcon.applyDockState(connected: GoEngine.shared.isConnected)

        // 设置窗口：不随失焦隐藏 + 出现在 Cmd+Tab
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { n in
            guard let w = n.object as? NSWindow,
                  w.title.contains("设置")
                    || w.title.contains("Settings")
                    || w.title.contains("安装")
                    || w.title.contains("Installation") else { return }
            w.hidesOnDeactivate = false
            AppIcon.applyDockState(connected: GoEngine.shared.isConnected)
            NSApp.setActivationPolicy(.regular)
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
