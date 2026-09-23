#if DEBUG
import AppKit
import SwiftUI

/// An offline layout check using production views and synthetic resources.
/// Entered before relocation, normal AppState setup or any connection lifecycle.
@MainActor
enum SettingsLayoutPreview {
    static var outputDirectory = ""
    static var state: AppState!

    static func run(directory: String) -> Never {
        outputDirectory = directory
        _ = NSApplication.shared
        var library = ProfileLibrary()
        library.profiles[0].name = "个人订阅"
        library.profiles[0].profile.lines.append(Line(id: "hk", name: "香港 01", type: "trojan", trojanServer: "proxy.example", trojanPort: 443))
        library.profiles[0].profile.ruleSets = [RuleSet(id: "media", name: "流媒体", type: "manual", domains: ["video.example"])]
        var company = ProfileRecord(id: "company", name: "公司配置", profile: Profile())
        company.profile.lines = [Line(id: "company-line", name: "公司代理", type: "trojan", trojanServer: "company.example", trojanPort: 443)]
        company.profile.ruleSets = [RuleSet(id: "work", name: "工作服务", type: "manual", domains: ["work.example"])]
        try! library.insert(company)
        library.editingProfileID = library.profiles[0].id
        var group = Line(id: "shared", name: "常用线路", type: "selector")
        group.groupMembers = ["hk", "company-line"]; group.groupDefault = "hk"
        library.groups = [group]
        library.scenarios = [Scenario(id: "daily", name: "日常", bindings: [RuleBinding(ruleSetID: "media", lineID: "shared")], defaultLineID: "direct"), Scenario(id: "work-scene", name: "办公", bindings: [RuleBinding(ruleSetID: "work", lineID: "company-line")], defaultLineID: "shared")]
        library.activeScenarioID = "daily"
        state = AppState(previewLibrary: library)
        state.editorPosition.expandedLineIDs.insert("shared")
        state.editorPosition.expandedScenarioID = "work-scene"
        SettingsLayoutPreviewApp.main()
        exit(0)
    }

    static func capture() async {
        do {
            try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
            try await Task.sleep(for: .milliseconds(700))
            let window = try NSApp.windows.first(where: { $0.contentView != nil }).unwrap()
            let initialWindow = window.windowNumber
            for (tab, name) in [(0, "lines"), (3, "groups"), (1, "rules"), (2, "scenarios"), (4, "general")] {
                state.editorPosition.tab = tab
                try await Task.sleep(for: .milliseconds(400))
                guard window.windowNumber == initialWindow else { throw CocoaError(.validationMissingMandatoryProperty) }
                let view = try window.contentView?.superview.unwrap()
                guard let view else { throw CocoaError(.fileReadUnknown) }
                view.layoutSubtreeIfNeeded()
                let bitmap = try view.bitmapImageRepForCachingDisplay(in: view.bounds).unwrap()
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try bitmap.representation(using: .png, properties: [:]).unwrap()
                try png.write(to: URL(fileURLWithPath: outputDirectory).appendingPathComponent(name + ".png"))
            }
            print("Rendered five settings pages in one native window: \(outputDirectory)")
            exit(0)
        } catch {
            fputs("Layout preview failed: \(error)\n", stderr)
            exit(1)
        }
    }
}

private extension Optional {
    func unwrap() throws -> Wrapped {
        guard let value = self else { throw CocoaError(.fileReadUnknown) }
        return value
    }
}

private struct SettingsLayoutPreviewApp: App {
    @StateObject private var state = SettingsLayoutPreview.state!
    @State private var started = false
    var body: some Scene {
        Window("XDial Settings Preview", id: "settings-preview") {
            SettingsView().environmentObject(state)
                .background(SettingsWindowChrome())
                .preferredColorScheme(.light)
                .task {
                    guard !started else { return }
                    started = true
                    await SettingsLayoutPreview.capture()
                }
        }
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}
#endif
