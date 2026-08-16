import AppKit

enum ApplicationLaunchPolicy {
    static func configure(
        _ configuration: NSWorkspace.OpenConfiguration
    ) {
        // XDial is a menu-bar agent. It becomes a regular application only
        // while the settings window is open, so relaunching it must not create
        // a recent-application tile that outlives that window.
        configuration.addsToRecentItems = false
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
    }
}
