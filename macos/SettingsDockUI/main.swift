import AppKit

private final class SettingsDockUIDelegate:
    NSObject,
    NSApplicationDelegate
{
    private let hostPID: pid_t?
    private var dismissalObserver: NSObjectProtocol?
    private var hostWatchTimer: Timer?

    init(hostPID: pid_t?) {
        self.hostPID = hostPID
        super.init()
    }

    /// Dock 图标只用 Bundle 的 SettingsDockIcon.icns，不在运行时另设
    /// `applicationIconImage`：否则进程退出瞬间 Dock 会从自定义图切回系统渲染的
    /// icns，退去动画里图标会“变一下”。
    func configure(_ application: NSApplication) {
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
    hostPID: SettingsDockProxyProtocol.hostPID(
        in: CommandLine.arguments
    )
)
application.delegate = delegate
delegate.configure(application)
application.run()
