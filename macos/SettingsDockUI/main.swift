import AppKit

private final class SettingsDockUIDelegate:
    NSObject,
    NSApplicationDelegate
{
    private let hostPID: pid_t?
    private var dockIcon: NSImage?
    private var dismissalObserver: NSObjectProtocol?
    private var iconStateObserver: NSObjectProtocol?
    private var hostWatchTimer: Timer?

    init(connected: Bool, hostPID: pid_t?) {
        self.hostPID = hostPID
        super.init()
        updateDockIcon(connected: connected)
    }

    func configure(_ application: NSApplication) {
        application.applicationIconImage = dockIcon
        _ = application.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination(
            "The temporary XDial Dock process follows the settings window"
        )
        ProcessInfo.processInfo.disableSuddenTermination()

        dismissalObserver = DistributedNotificationCenter.default()
            .addObserver(
                forName: SettingsDockProxyProtocol.dismissalNotification,
                object: nil,
                queue: .main
            ) { _ in
                NSApp.terminate(nil)
            }
        iconStateObserver = DistributedNotificationCenter.default()
            .addObserver(
                forName: SettingsDockProxyProtocol.iconStateNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let connected = notification.userInfo?[
                    "connected"
                ] as? Bool else { return }
                self?.updateDockIcon(connected: connected)
            }

        if hostPID != nil {
            hostWatchTimer = Timer.scheduledTimer(
                withTimeInterval: 1,
                repeats: true
            ) { [weak self] _ in
                self?.terminateIfHostExited()
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        requestSettingsActivation()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        requestSettingsActivation()
        return true
    }

    private func updateDockIcon(connected: Bool) {
        let icon = AppIcon.dock(size: 512, connected: connected)
        dockIcon = icon
        NSApp.applicationIconImage = icon
    }

    private func requestSettingsActivation() {
        DistributedNotificationCenter.default().postNotificationName(
            SettingsDockProxyProtocol.activationNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private func terminateIfHostExited() {
        guard let hostPID else { return }
        guard NSRunningApplication(
            processIdentifier: hostPID
        )?.isTerminated != false else { return }
        NSApp.terminate(nil)
    }
}

private let application = NSApplication.shared
private let delegate = SettingsDockUIDelegate(
    connected: CommandLine.arguments.contains(
        SettingsDockProxyProtocol.connectedArgument
    ),
    hostPID: SettingsDockProxyProtocol.hostPID(
        in: CommandLine.arguments
    )
)
application.delegate = delegate
delegate.configure(application)
application.run()
