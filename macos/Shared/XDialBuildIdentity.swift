import Foundation

/// Compile-time product identity shared by the host, helper-facing code,
/// Settings carrier, and Network Extension. FormalDevelopment and Release use
/// the established production identity; only Debug defines
/// XDIAL_DEVELOPMENT_IDENTITY.
enum XDialBuildIdentity {
    static let formalApplicationIdentifier = "com.kafeifei.xdial.app"
    static let formalHelperIdentifier = "com.kafeifei.xdial.app.helper"
    static let formalDaemonIdentifier = "com.kafeifei.xdial.app.daemon"
    static let formalTransparentProxyIdentifier =
        "com.kafeifei.xdial.app.transparent-proxy"
    static let formalSettingsUIIdentifier =
        "com.kafeifei.xdial.app.settings-ui"
    static let formalDataIdentifier = "com.kafeifei.xdial"
    static let formalUserDataDirectoryName = ".xdial"
    static let developmentApplicationIdentifier =
        "com.kafeifei.xdial.debug"
    static let developmentSettingsUIIdentifier =
        "com.kafeifei.xdial.debug.settings-ui"
    static let legacyProbeApplicationIdentifier =
        "com.kafeifei.xdial.ne-probe"
    static let legacyApplicationIdentifier = "com.kafeifei.xdial"
    static let legacyProbeSettingsUIIdentifier =
        "com.kafeifei.xdial.ne-probe.settings-ui"
    static let legacySettingsUIIdentifier =
        "com.kafeifei.xdial.settings-ui"
    static let legacyHelperIdentifier = "com.kafeifei.xdial.helper"
    static let legacyTransparentProxyIdentifier =
        "com.kafeifei.xdial.transparent-proxy"

    #if XDIAL_NEXT_IDENTITY
    static let isDevelopment = true
    static let applicationIdentifier = "com.kafeifei.xdial.next"
    static let helperIdentifier = "com.kafeifei.xdial.next.helper"
    static let daemonIdentifier = "com.kafeifei.xdial.next.daemon"
    static let transparentProxyIdentifier =
        "com.kafeifei.xdial.next.transparent-proxy"
    static let settingsUIIdentifier = "com.kafeifei.xdial.next.settings-ui"
    static let appGroupIdentifier =
        "UVZM439VGU.com.kafeifei.xdial.next.network"
    static let applicationBundleName = "XDial Next.app"
    static let applicationDisplayName = "XDial Next"
    static let productTitle = "XDial Next"
    static let dataIdentifier = "com.kafeifei.xdial.next"
    static let userDataDirectoryName = ".xdial-next"
    static let applicationSupportDirectoryName = "XDial Next"
    static let logDirectoryName = "XDial Next"
    static let daemonSocketPath = "/tmp/xdial-next.sock"
    static let engineRuntimePath = "/tmp/xdial-next-engine"
    static let daemonLogPath = "/tmp/xdial-next.log"
    static let registrationMaintenancePath =
        "/tmp/xdial-next-registration-maintenance"
    static let debugServerPort: UInt16 = 19878
    static let allowsAutomaticUpdates = false
    static let allowsFormalDataMigration = false
    static let allowsLegacyCleanup = false
    #elseif XDIAL_DEVELOPMENT_IDENTITY
    static let isDevelopment = true
    static let applicationIdentifier = developmentApplicationIdentifier
    static let helperIdentifier = "com.kafeifei.xdial.debug.helper"
    static let daemonIdentifier = "com.kafeifei.xdial.debug.daemon"
    static let transparentProxyIdentifier =
        "com.kafeifei.xdial.debug.transparent-proxy"
    static let settingsUIIdentifier = developmentSettingsUIIdentifier
    static let appGroupIdentifier =
        "UVZM439VGU.com.kafeifei.xdial.debug.network"
    static let applicationBundleName = "XDail Debug.app"
    static let applicationDisplayName = "XDail Debug"
    static let productTitle = "XDial Debug"
    static let dataIdentifier = "com.kafeifei.xdial.debug"
    static let userDataDirectoryName = ".xdial-debug"
    static let applicationSupportDirectoryName = "XDial Debug"
    static let logDirectoryName = "XDial Debug"
    static let daemonSocketPath = "/tmp/xdial-debug.sock"
    static let engineRuntimePath = "/tmp/xdial-debug-engine"
    static let daemonLogPath = "/tmp/xdial-debug.log"
    static let registrationMaintenancePath =
        "/tmp/xdial-debug-registration-maintenance"
    static let debugServerPort: UInt16 = 19877
    static let allowsAutomaticUpdates = false
    static let allowsFormalDataMigration = false
    static let allowsLegacyCleanup = false
    #else
    static let isDevelopment = false
    static let applicationIdentifier = formalApplicationIdentifier
    static let helperIdentifier = formalHelperIdentifier
    static let daemonIdentifier = formalDaemonIdentifier
    static let transparentProxyIdentifier =
        formalTransparentProxyIdentifier
    static let settingsUIIdentifier = formalSettingsUIIdentifier
    static let appGroupIdentifier =
        "UVZM439VGU.com.kafeifei.xdial.network"
    static let applicationBundleName = "XDial.app"
    static let applicationDisplayName = "XDial"
    static let productTitle = "XDial"
    static let dataIdentifier = formalDataIdentifier
    static let userDataDirectoryName = formalUserDataDirectoryName
    static let applicationSupportDirectoryName = "XDial"
    static let logDirectoryName = "XDial"
    static let daemonSocketPath = "/tmp/xdial.sock"
    static let engineRuntimePath = "/tmp/xdial-engine"
    static let daemonLogPath = "/tmp/xdial.log"
    static let registrationMaintenancePath =
        "/tmp/xdial-registration-maintenance"
    static let debugServerPort: UInt16 = 19876
    static let allowsAutomaticUpdates = true
    static let allowsFormalDataMigration = true
    static let allowsLegacyCleanup = true
    #endif

    static let applicationDestinationURL = URL(
        fileURLWithPath: "/Applications/\(applicationBundleName)",
        isDirectory: true
    )
    // Every independently installed channel is a known sibling. In particular,
    // Next must exclude Debug as well as the formal app when checking whether
    // its own helper has exited during a registration refresh.
    struct InstalledChannel {
        let applicationIdentifier: String
        let bundleName: String
        let daemonSocketPath: String
        var bundleURL: URL { URL(fileURLWithPath: "/Applications/\(bundleName)", isDirectory: true) }
    }
    static let siblingChannels: [InstalledChannel] = [
        .init(applicationIdentifier: "com.kafeifei.xdial.app", bundleName: "XDial.app", daemonSocketPath: "/tmp/xdial.sock"),
        .init(applicationIdentifier: "com.kafeifei.xdial.debug", bundleName: "XDail Debug.app", daemonSocketPath: "/tmp/xdial-debug.sock"),
        .init(applicationIdentifier: "com.kafeifei.xdial.next", bundleName: "XDial Next.app", daemonSocketPath: "/tmp/xdial-next.sock"),
    ].filter { $0.applicationIdentifier != applicationIdentifier }
    static let siblingApplicationDestinationURLs = siblingChannels.map(\.bundleURL)
    static let settingsEntryTypeIdentifier =
        applicationIdentifier + ".settings-entry"
    static let settingsDockActivationNotification =
        dataIdentifier + ".settings-dock.activate"
    static let settingsDockDismissalNotification =
        dataIdentifier + ".settings-dock.dismiss"
    static let providerConfigurationName =
        applicationDisplayName + " Transparent Proxy"
    static let queueLabelPrefix = applicationIdentifier
    static let updateStagingDirectoryName = applicationIdentifier == "com.kafeifei.xdial.next"
        ? "XDialNextUpdates" : isDevelopment
        ? "XDialDebugUpdates" : "XDialUpdates"
    static let installationArtifactPrefix = applicationIdentifier == "com.kafeifei.xdial.next"
        ? ".XDial-next" : isDevelopment
        ? ".Xdial-debug" : ".XDial"
}
