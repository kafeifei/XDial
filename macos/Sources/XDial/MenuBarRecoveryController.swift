import AppKit
import SwiftUI

/// Owns only menu-bar recovery. Never restarts the host or touches the network.
@MainActor
final class MenuBarRecoveryController: ObservableObject {
    static let shared = MenuBarRecoveryController()

    @Published private(set) var isInserted = true
    private var monitor: Task<Void, Never>?
    private var rebuildTask: Task<Void, Never>?
    private var policy = MenuBarRecoveryPolicy()
    private var sessionAvailable = true
    private var observers: [NSObjectProtocol] = []
    private var trackingRepairAttempted = false
    private var trackingRepairInFlight = false
    private var trackingRepairStatus = "not-needed"
    private(set) var observation = MenuBarRecoveryPolicy.Observation.deferred
    private(set) var suppressedTerminations = 0
    private(set) var explicitlyQuitting = false

    var insertion: Binding<Bool> {
        Binding(get: { self.isInserted }, set: { value in
            // MenuBarExtra writes its current insertion state back during scene
            // reconciliation. Publishing an unchanged value invalidates that
            // same scene again and can starve the application's main run loop.
            guard self.isInserted != value else { return }
            self.isInserted = value
        })
    }

    func start() {
        guard monitor == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSessionAvailable(false) }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSessionAvailable(true) }
            })
        }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.check()
            }
        }
    }

    private func setSessionAvailable(_ available: Bool) {
        sessionAvailable = available
        _ = policy.observe(.deferred, at: ProcessInfo.processInfo.systemUptime)
    }

    private func sample() -> MenuBarRecoveryPolicy.Observation {
        guard sessionAvailable, !NSScreen.screens.isEmpty else { return .deferred }
        guard isInserted else { return .missing }
        // Full-screen/auto-hidden system menu bars are not a missing app item.
        guard NSMenu.menuBarVisible() else { return .deferred }
        // SwiftUI may render the label in a detached hosting view. The host's
        // actual status-level window is the observable menu-bar presence.
        let hasMenuWindow = NSApp.windows.contains { window in
            guard window.level == .statusBar, window.isVisible,
                  let screen = window.screen else { return false }
            return MenuBarRecoveryPolicy.isAtMenuBar(
                frame: window.frame, screen: screen.frame,
                thickness: NSStatusBar.system.thickness
            )
        }
        return hasMenuWindow ? .visible : .missing
    }

    private func check() {
        guard !explicitlyQuitting, rebuildTask == nil, !trackingRepairInFlight else { return }
        observation = sample()
        switch policy.observe(observation, at: ProcessInfo.processInfo.systemUptime) {
        case .none: break
        case .rebuild: rebuild()
        case .recovered:
            trackingRepairAttempted = false
            appLog("menu bar recovery: menu-bar geometry restored and stable")
        case .blocked:
            repairForeignTrackingIfNeeded()
        }
    }

    private func repairForeignTrackingIfNeeded() {
        guard !trackingRepairAttempted else {
            appLog("menu bar recovery: still blocked; automatic retries stopped; host remains running")
            return
        }
        trackingRepairAttempted = true
        guard Bundle.main.bundleIdentifier == XDialBuildIdentity.applicationIdentifier else {
            trackingRepairStatus = "unexpected-host"
            return
        }
        trackingRepairInFlight = true
        let target = XDialBuildIdentity.applicationIdentifier
        let backupDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(XDialBuildIdentity.applicationSupportDirectoryName)
            .appendingPathComponent("MenuBarRecovery")
        Task { [weak self] in
            let status = await Task.detached(priority: .utility) {
                do {
                    return try MenuBarTrackingRepair.repair(target: target, backupDirectory: backupDirectory).status
                } catch {
                    // No permission prompts, reset-all fallback, or destructive
                    // retry when the OS denies access or changes its schema.
                    return "unavailable: \(error)"
                }
            }.value
            guard let self else { return }
            self.trackingRepairInFlight = false
            self.trackingRepairStatus = status
            appLog("menu bar recovery: tracking repair \(status)")
            if status == "repaired", !self.explicitlyQuitting {
                self.policy = MenuBarRecoveryPolicy()
                self.isInserted = false
            }
        }
    }

    private func rebuild() {
        appLog("menu bar recovery: rebuilding scene; attempt=\(policy.attempts)")
        // Let SwiftUI remove the old scene before inserting its replacement.
        // AppState and the connection transaction are outside this scene.
        isInserted = false
        rebuildTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, !self.explicitlyQuitting else { return }
            self.isInserted = true
            self.rebuildTask = nil
        }
    }

    func recoverOnReopen() {
        guard !explicitlyQuitting else { return }
        policy = MenuBarRecoveryPolicy()
        trackingRepairAttempted = false
        check()
    }

    /// SwiftUI calls terminate when a MenuBarExtra is removed. This is not the
    /// user's Quit command. Keep the host alive so it can rebuild the entry.
    func suppressMenuRemovalTermination() {
        suppressedTerminations += 1
        isInserted = false
        appLog("menu bar recovery: suppressed scene-removal termination")
    }

    func requestQuit() {
        explicitlyQuitting = true
        NSApp.terminate(nil)
    }

    func cancelQuit() { explicitlyQuitting = false }

    var diagnostics: [String: Any] {
        [
            "isInserted": isInserted,
            "observation": observation.rawValue,
            "attempts": policy.attempts,
            "blocked": policy.isBlocked,
            "rebuilding": rebuildTask != nil,
            "suppressedTerminations": suppressedTerminations,
            "trackingRepairInFlight": trackingRepairInFlight,
            "trackingRepairStatus": trackingRepairStatus,
        ]
    }
}
