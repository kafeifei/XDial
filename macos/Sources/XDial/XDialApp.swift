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
            Text("🚢")
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
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let engine = GoEngine.shared
        guard engine.status == "connected" || engine.status == "connecting" else {
            return .terminateNow
        }
        Task { @MainActor in
            engine.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
