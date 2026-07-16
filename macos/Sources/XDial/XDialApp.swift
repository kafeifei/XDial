import AppKit
import SwiftUI

struct XDialApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MainPopover()
                .environmentObject(state)
        } label: {
            Image(nsImage: AppIcon.menuBar())
                .accessibilityLabel("XDial")
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
