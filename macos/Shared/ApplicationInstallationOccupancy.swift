import Foundation

enum ApplicationInstallationOccupancy {
    static func mayBeInUse(
        _ bundleURL: URL,
        processes: LocalProcessInventory.Snapshot,
        applicationURLs: [URL],
        ignoringPID: Int32? = nil
    ) -> Bool {
        let path = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        func contains(_ url: URL) -> Bool {
            let candidate = url.resolvingSymlinksInPath().standardizedFileURL.path
            return candidate == path || candidate.hasPrefix(path + "/")
        }
        if applicationURLs.contains(where: contains) { return true }
        guard case let .available(entries) = processes else { return true }
        var productNames: Set<String> = [
            "XDial", "xdial", "xdial-daemon", "XDial Settings UI",
            XDialBuildIdentity.applicationDisplayName,
            XDialBuildIdentity.applicationIdentifier,
            XDialBuildIdentity.helperIdentifier,
            XDialBuildIdentity.daemonIdentifier,
            XDialBuildIdentity.transparentProxyIdentifier,
            XDialBuildIdentity.settingsUIIdentifier,
        ]
        if XDialBuildIdentity.allowsLegacyCleanup {
            productNames.formUnion([
                XDialBuildIdentity.legacyHelperIdentifier,
                XDialBuildIdentity.legacyTransparentProxyIdentifier,
            ])
        }
        return entries.contains { entry in
            guard entry.pid != ignoringPID else { return false }
            if let executableURL = entry.executableURL { return contains(executableURL) }
            // A missing path for a possible product process cannot prove that
            // the bundle is unused. Unrelated named system processes are safe.
            guard let name = entry.name else { return true }
            return productNames.contains(name)
        }
    }
}
