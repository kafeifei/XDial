import Foundation

enum SettingsDockProxyProtocol {
    static let hostPIDArgumentPrefix = "--settings-dock-host-pid="

    static let activationNotification = Notification.Name(
        "com.kafeifei.xdial.settings-dock.activate"
    )
    static let dismissalNotification = Notification.Name(
        "com.kafeifei.xdial.settings-dock.dismiss"
    )

    static func hostPID(in arguments: [String]) -> pid_t? {
        guard let argument = arguments.first(where: {
            $0.hasPrefix(hostPIDArgumentPrefix)
        }) else { return nil }
        return pid_t(argument.dropFirst(hostPIDArgumentPrefix.count))
    }
}
