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

    var body: some View {
        let icon = Image(nsImage: AppIcon.menuBar())
            .accessibilityLabel("XDial")
        #if DEBUG
        icon.onReceive(NotificationCenter.default.publisher(for: .xdialDebugOpenSettings)) { _ in
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        #else
        icon
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
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Window("XDial 设置", id: "settings") {
            SettingsView()
                .environmentObject(state)
        }
        .defaultSize(width: 540, height: 540)
        .windowResizability(.contentSize)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 设置窗口：不随失焦隐藏 + 出现在 Cmd+Tab
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { n in
            guard let w = n.object as? NSWindow,
                  w.title.contains("设置") || w.title.contains("Settings") else { return }
            w.hidesOnDeactivate = false
            NSApp.applicationIconImage = AppIcon.dock(size: 256)
            NSApp.setActivationPolicy(.regular)
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { n in
            guard let w = n.object as? NSWindow,
                  w.title.contains("设置") || w.title.contains("Settings") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let hasSettings = NSApp.windows.contains {
                    $0.isVisible && ($0.title.contains("设置") || $0.title.contains("Settings"))
                }
                if !hasSettings { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let engine = GoEngine.shared
        guard engine.status == "connected" || engine.status == "connecting" || engine.status == "reconnecting" else {
            return .terminateNow
        }
        Task { @MainActor in
            engine.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
