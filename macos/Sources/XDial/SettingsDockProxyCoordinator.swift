import AppKit

@MainActor
final class SettingsDockProxyCoordinator {
    static let shared = SettingsDockProxyCoordinator()
    private static let helperBundleName = "XDial Settings UI.app"

    var activationRequested: (() -> Void)?

    private var desiredVisible = false
    private var launchInFlight = false
    private var runningApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var dismissalFallbackTask: Task<Void, Never>?

    var isDesiredVisible: Bool { desiredVisible }
    var isRunning: Bool {
        runningApplication?.isTerminated == false
    }
    var isLaunchInFlight: Bool { launchInFlight }

    private init() {
        activationObserver = DistributedNotificationCenter.default()
            .addObserver(
                forName: SettingsDockProxyProtocol.activationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard self?.desiredVisible == true else { return }
                    self?.activationRequested?()
                }
            }
        terminationObserver = NSWorkspace.shared.notificationCenter
            .addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self,
                          let application = notification.userInfo?[
                              NSWorkspace.applicationUserInfoKey
                          ] as? NSRunningApplication,
                          application.processIdentifier
                              == self.runningApplication?.processIdentifier
                    else { return }
                    self.runningApplication = nil
                    if self.desiredVisible {
                        self.present()
                    }
                }
            }
    }

    func present() {
        desiredVisible = true
        dismissalFallbackTask?.cancel()
        dismissalFallbackTask = nil
        if runningApplication?.isTerminated == false || launchInFlight {
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        ApplicationLaunchPolicy.configure(configuration)
        configuration.arguments = [
            SettingsDockProxyProtocol.hostPIDArgumentPrefix
                + String(ProcessInfo.processInfo.processIdentifier),
        ]
        launchInFlight = true
        NSWorkspace.shared.openApplication(
            at: helperBundleURL,
            configuration: configuration
        ) { [weak self] application, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.launchInFlight = false
                if let error {
                    appLog(
                        "temporary XDial Dock instance launch failed: "
                            + error.localizedDescription
                    )
                    return
                }
                guard self.desiredVisible else {
                    _ = application?.terminate()
                    return
                }
                self.runningApplication = application
            }
        }
    }

    private var helperBundleURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(
                Self.helperBundleName,
                isDirectory: true
            )
    }

    func dismiss() {
        desiredVisible = false
        dismissalFallbackTask?.cancel()
        DistributedNotificationCenter.default().postNotificationName(
            SettingsDockProxyProtocol.dismissalNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        dismissalFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled,
                  let self,
                  !self.desiredVisible else { return }
            if let application = self.runningApplication,
               !application.isTerminated {
                _ = application.terminate()
            }
            if self.runningApplication?.isTerminated != false {
                self.runningApplication = nil
            }
            self.dismissalFallbackTask = nil
        }
    }
}
