import AppKit
import Foundation

// Build together with macos/Sources/XDial/MenuBarTrackingRepair.swift.
// Default is read-only; --apply changes only foreign references to Debug.
@main
enum MenuBarTrackingRepairTool {
    static let target = "com.kafeifei.xdial.debug"
    static let reportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/XDial-menu-bar-repair")

    static func report(_ value: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
            try data.write(to: reportDirectory.appendingPathComponent("report.json"), options: .atomic)
            print(String(decoding: data, as: UTF8.self))
        } catch { fputs("Could not write repair report: \(error)\n", stderr) }
    }

    static func main() {
        do {
            let arguments = CommandLine.arguments
            do { _ = try Data(contentsOf: MenuBarTrackingRepair.preferencesURL) }
            catch {
                guard arguments.contains("--select-preferences-folder") else { throw error }
                _ = NSApplication.shared
                let panel = NSOpenPanel()
                panel.title = "XDial 菜单栏修复"
                panel.message = "仅授权 Control Center 的 Preferences 文件夹，用于检查和修复 XDial Debug 的错误菜单栏关联。"
                panel.prompt = "授权此文件夹"
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                let expected = MenuBarTrackingRepair.preferencesURL.deletingLastPathComponent()
                panel.directoryURL = expected
                NSApp.activate(ignoringOtherApps: true)
                guard panel.runModal() == .OK, let selected = panel.url,
                      selected.standardizedFileURL == expected.standardizedFileURL else {
                    throw CocoaError(.userCancelled)
                }
                _ = selected.startAccessingSecurityScopedResource()
            }
            if arguments.contains("--apply") {
                let result = try MenuBarTrackingRepair.repair(target: target, backupDirectory: reportDirectory)
                report(["status": result.status, "target": target, "owners": result.owners,
                        "backup": result.backupPath ?? ""])
            } else {
                let plan = try MenuBarTrackingRepair.inspect(target: target)
                report(["status": plan.ownEntryDisabled ? "own-entry-disabled" :
                        (plan.repairedTracking == nil ? "already-clean" : "dry-run"),
                        "target": target, "owners": plan.owners])
            }
        } catch {
            report(["status": "failed", "error": String(describing: error), "target": target])
            exit(1)
        }
    }
}
