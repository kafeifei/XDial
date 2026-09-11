import XCTest

final class XDialBuildIdentityTests: XCTestCase {
    func testDevelopmentAndFormalIdentityAreCompleteAndDisjoint() {
        #if XDIAL_DEVELOPMENT_IDENTITY
        XCTAssertTrue(XDialBuildIdentity.isDevelopment)
        XCTAssertEqual(
            XDialBuildIdentity.applicationIdentifier,
            "com.kafeifei.xdial.debug"
        )
        XCTAssertEqual(
            XDialBuildIdentity.helperIdentifier,
            "com.kafeifei.xdial.debug.helper"
        )
        XCTAssertEqual(
            XDialBuildIdentity.daemonIdentifier,
            "com.kafeifei.xdial.debug.daemon"
        )
        XCTAssertEqual(
            XDialBuildIdentity.transparentProxyIdentifier,
            "com.kafeifei.xdial.debug.transparent-proxy"
        )
        XCTAssertEqual(
            XDialBuildIdentity.settingsUIIdentifier,
            "com.kafeifei.xdial.debug.settings-ui"
        )
        XCTAssertEqual(
            XDialBuildIdentity.appGroupIdentifier,
            "UVZM439VGU.com.kafeifei.xdial.debug.network"
        )
        XCTAssertEqual(
            XDialBuildIdentity.applicationBundleName,
            "Xdial debug.app"
        )
        XCTAssertEqual(
            XDialBuildIdentity.applicationDisplayName,
            "Xdial debug"
        )
        XCTAssertEqual(XDialBuildIdentity.productTitle, "XDial Debug")
        XCTAssertEqual(XDialBuildIdentity.dataIdentifier, "com.kafeifei.xdial.debug")
        XCTAssertEqual(XDialBuildIdentity.userDataDirectoryName, ".xdial-debug")
        XCTAssertEqual(XDialBuildIdentity.applicationSupportDirectoryName, "XDial Debug")
        XCTAssertEqual(XDialBuildIdentity.logDirectoryName, "XDial Debug")
        XCTAssertEqual(XDialBuildIdentity.daemonSocketPath, "/tmp/xdial-debug.sock")
        XCTAssertEqual(XDialBuildIdentity.engineRuntimePath, "/tmp/xdial-debug-engine")
        XCTAssertEqual(
            XDialBuildIdentity.registrationMaintenancePath,
            "/tmp/xdial-debug-registration-maintenance"
        )
        XCTAssertEqual(XDialBuildIdentity.debugServerPort, 19877)
        XCTAssertFalse(XDialBuildIdentity.allowsAutomaticUpdates)
        XCTAssertFalse(XDialBuildIdentity.allowsFormalDataMigration)
        XCTAssertFalse(XDialBuildIdentity.allowsLegacyCleanup)
        #else
        XCTAssertFalse(XDialBuildIdentity.isDevelopment)
        XCTAssertEqual(XDialBuildIdentity.applicationIdentifier, "com.kafeifei.xdial.app")
        XCTAssertEqual(XDialBuildIdentity.helperIdentifier, "com.kafeifei.xdial.app.helper")
        XCTAssertEqual(XDialBuildIdentity.daemonIdentifier, "com.kafeifei.xdial.app.daemon")
        XCTAssertEqual(
            XDialBuildIdentity.transparentProxyIdentifier,
            "com.kafeifei.xdial.app.transparent-proxy"
        )
        XCTAssertEqual(
            XDialBuildIdentity.settingsUIIdentifier,
            "com.kafeifei.xdial.app.settings-ui"
        )
        XCTAssertEqual(
            XDialBuildIdentity.appGroupIdentifier,
            "UVZM439VGU.com.kafeifei.xdial.network"
        )
        XCTAssertEqual(XDialBuildIdentity.applicationBundleName, "XDial.app")
        XCTAssertEqual(XDialBuildIdentity.applicationDisplayName, "XDial")
        XCTAssertEqual(XDialBuildIdentity.productTitle, "XDial")
        XCTAssertEqual(XDialBuildIdentity.dataIdentifier, "com.kafeifei.xdial")
        XCTAssertEqual(XDialBuildIdentity.userDataDirectoryName, ".xdial")
        XCTAssertEqual(XDialBuildIdentity.applicationSupportDirectoryName, "XDial")
        XCTAssertEqual(XDialBuildIdentity.logDirectoryName, "XDial")
        XCTAssertEqual(XDialBuildIdentity.daemonSocketPath, "/tmp/xdial.sock")
        XCTAssertEqual(XDialBuildIdentity.engineRuntimePath, "/tmp/xdial-engine")
        XCTAssertEqual(
            XDialBuildIdentity.registrationMaintenancePath,
            "/tmp/xdial-registration-maintenance"
        )
        XCTAssertEqual(XDialBuildIdentity.debugServerPort, 19876)
        XCTAssertTrue(XDialBuildIdentity.allowsAutomaticUpdates)
        XCTAssertTrue(XDialBuildIdentity.allowsFormalDataMigration)
        XCTAssertTrue(XDialBuildIdentity.allowsLegacyCleanup)
        #endif
    }

    func testInstalledVariantsCannotReplaceEachOther() {
        XCTAssertFalse(
            XDialApplicationIdentifierPolicy.permitsReplacement(
                existingIdentifier: XDialApplicationIdentifierPolicy.release,
                incomingIdentifier: XDialApplicationIdentifierPolicy.development,
                teamIdentifiersMatch: true
            )
        )
        XCTAssertFalse(
            XDialApplicationIdentifierPolicy.permitsReplacement(
                existingIdentifier: XDialApplicationIdentifierPolicy.development,
                incomingIdentifier: XDialApplicationIdentifierPolicy.release,
                teamIdentifiersMatch: true
            )
        )
    }

    func testNameOnlySiblingExtensionDoesNotBecomeOwnedOccupancy() {
        let siblingIdentifier = XDialBuildIdentity.isDevelopment
            ? XDialBuildIdentity.formalTransparentProxyIdentifier
            : "com.kafeifei.xdial.debug.transparent-proxy"
        XCTAssertFalse(
            ApplicationInstallationOccupancy.mayBeInUse(
                XDialBuildIdentity.applicationDestinationURL,
                processes: .available([
                    .init(
                        pid: 42,
                        name: siblingIdentifier,
                        executableURL: nil
                    ),
                ]),
                applicationURLs: []
            )
        )
    }

    func testSettingsCarrierNotificationsAreVariantScoped() {
        XCTAssertTrue(
            XDialBuildIdentity.settingsDockActivationNotification
                .hasPrefix(XDialBuildIdentity.dataIdentifier + ".")
        )
        XCTAssertTrue(
            XDialBuildIdentity.settingsDockDismissalNotification
                .hasPrefix(XDialBuildIdentity.dataIdentifier + ".")
        )
    }
}
