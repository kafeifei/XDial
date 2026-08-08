import AppKit
import Foundation
import ServiceManagement

/// Explicit, ordered removal of XDial's persistent platform components.
///
/// The app must still be present while the System Extension request is
/// submitted because macOS discovers the target extension inside the current
/// app bundle. Moving the app to Trash therefore belongs at the very end.
@MainActor
enum ApplicationUninstaller {
    static func run(
        deleteData: Bool,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        GoEngine.shared.stop()
        GoEngine.shared.uninstallSystemExtension { result in
            if case let .failure(error) = result {
                completion(.failure(error))
                return
            }
            do {
                if #available(macOS 13.0, *) {
                    try? SMAppService.mainApp.unregister()
                }
                try PrivilegeManager.uninstall(
                    deleteData: deleteData
                )
                if deleteData {
                    xdialDefaults.removeObject(
                        forKey: "xdial.profile"
                    )
                    xdialDefaults.removeObject(
                        forKey: "xdial.language"
                    )
                    xdialDefaults.removeObject(
                        forKey: "xdial.appearance"
                    )
                    xdialDefaults.removeObject(
                        forKey: "xdial.launchAtLogin"
                    )
                    xdialDefaults.removeObject(
                        forKey: "xdial.autoConnect"
                    )
                    KeychainStore.deleteVault()
                    try? FileManager.default.removeItem(
                        atPath: appLogPath()
                    )
                }
                xdialDefaults.removeObject(
                    forKey: "xdial.installation.ready"
                )
                try ApplicationRelocator
                    .moveInstalledApplicationToTrash()
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }
}
