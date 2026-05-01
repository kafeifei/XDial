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
            Image(systemName: state.isConnected ? "shield.checkered" : "shield")
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)
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
