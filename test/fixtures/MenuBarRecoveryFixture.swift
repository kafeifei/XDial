import AppKit
import SwiftUI

func appLog(_ message: String) { print(message) }

/// Opt-in login-session fixture. It links the production recovery controller,
/// but no AppState, helper, Network Extension, or connection implementation.
@main
struct MenuBarRecoveryFixture: App {
    @NSApplicationDelegateAdaptor(RecoveryFixtureDelegate.self) var delegate
    @StateObject private var controller = MenuBarRecoveryController.shared

    var body: some Scene {
        MenuBarExtra(isInserted: controller.insertion) {
            Text("XDial menu recovery test")
        } label: {
            Image(systemName: "testtube.2")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class RecoveryFixtureDelegate: NSObject, NSApplicationDelegate {
    private var report: [String: Any] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MenuBarRecoveryController.shared
        controller.start()
        Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(4))
                report["initial"] = controller.diagnostics
                guard controller.observation == .visible else {
                    finish(success: false, reason: "initial-menu-not-visible")
                    return
                }
                controller.insertion.wrappedValue = false
                // Reproduce the termination request accompanying system removal
                // as well as the missing scene, in this network-free fixture.
                NSApp.terminate(nil)
                var sawRebuild = false
                var stableSince: TimeInterval?
                let deadline = ProcessInfo.processInfo.systemUptime + 25
                while ProcessInfo.processInfo.systemUptime < deadline {
                    try await Task.sleep(for: .milliseconds(250))
                    let state = controller.diagnostics
                    sawRebuild = sawRebuild || (state["attempts"] as? Int ?? 0) > 0
                    if sawRebuild && controller.observation == .visible {
                        let now = ProcessInfo.processInfo.systemUptime
                        stableSince = stableSince ?? now
                        if now - (stableSince ?? now) >= 11,
                           controller.suppressedTerminations > 0 {
                            report["final"] = state
                            finish(success: true, reason: "menu-rebuilt-and-stable")
                            return
                        }
                    } else {
                        stableSince = nil
                    }
                }
                report["final"] = controller.diagnostics
                finish(success: false, reason: "recovery-deadline-exceeded")
            } catch {
                finish(success: false, reason: String(describing: error))
            }
        }
    }

    // Retain the production scene-removal versus explicit-quit distinction;
    // this fixture has no network transaction to drain.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let controller = MenuBarRecoveryController.shared
        if controller.explicitlyQuitting { return .terminateNow }
        controller.suppressMenuRemovalTermination()
        return .terminateCancel
    }

    private func finish(success: Bool, reason: String) {
        report["success"] = success
        report["reason"] = reason
        report["pid"] = ProcessInfo.processInfo.processIdentifier
        let result = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("result.json")
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: result, options: .atomic)
        } catch { fputs("cannot write fixture result: \(error)\n", stderr) }
        MenuBarRecoveryController.shared.requestQuit()
    }
}
