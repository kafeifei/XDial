#if DEBUG
import AppKit
import CryptoKit
import Security
import SwiftUI

/// An offline layout check using production views and synthetic resources.
/// Entered before relocation, normal AppState setup or any connection lifecycle.
@MainActor
enum SettingsLayoutPreview {
    static var outputDirectory = ""
    static var state: AppState!

    /// Uses production views in a window that is never shown. No relocation,
    /// user configuration, helper registration or networking is started.
    static func checkScenarioLayout() -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let arguments = CommandLine.arguments
        let bindingCount = arguments.firstIndex(of: "--binding-count").flatMap { index in
            arguments.indices.contains(index + 1) ? Int(arguments[index + 1]) : nil
        }.map { max(1, min(500, $0)) } ?? 6
        var library = ProfileLibrary()
        library.profiles[0].profile.lines += (0..<160).map {
            Line(id: "layout-line-\($0)", name: "线路 \($0)", type: "trojan",
                 trojanServer: "layout.example", trojanPort: 443)
        }
        library.profiles[0].profile.ruleSets = (0..<bindingCount).map {
            RuleSet(id: "layout-rule-\($0)", name: "匹配条件 \($0)", type: "manual", domains: ["layout.example"])
        }
        var scenario = Scenario(id: "layout-scenario", name: "场景布局检查",
            bindings: (0..<bindingCount).map { RuleBinding(ruleSetID: "layout-rule-\($0)", lineID: "layout-line-\($0 % 160)") },
            defaultLineID: "direct")
        scenario.matchSSIDs = ["Hotel Network", "Home Network 5G", "Phone Hotspot", "Office Network", "Guest Network"]
        library.scenarios = (0..<12).map { index in
            var item = scenario
            item.id = index == 2 ? scenario.id : "other-scenario-\(index)"
            item.name = "场景 \(index)"
            return item
        }
        if CommandLine.arguments.contains("--user-configuration") {
            do {
                let store = ProfileLibraryStore(keyProvider: { create in
                    guard !create else { throw CocoaError(.fileReadNoPermission) }
                    let query: [String: Any] = [
                        kSecClass as String: kSecClassGenericPassword,
                        kSecAttrService as String: ConfigurationStorage.keychainService,
                        kSecAttrAccount as String: "profile-library-key-v1",
                        kSecReturnData as String: true,
                        kSecMatchLimit as String: kSecMatchLimitOne,
                        kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
                    ]
                    var output: CFTypeRef?
                    guard SecItemCopyMatching(query as CFDictionary, &output) == errSecSuccess,
                          let bytes = output as? Data, bytes.count == 32 else {
                        throw CocoaError(.fileReadNoPermission)
                    }
                    return SymmetricKey(data: bytes)
                })
                library = try store.load().unwrap()
                let arguments = CommandLine.arguments
                let name = arguments.firstIndex(of: "--scenario-name").flatMap { index in
                    arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
                }
                scenario = try (library.scenarios.first { $0.name == name } ?? library.scenarios.first).unwrap()
            } catch {
                fputs("Cannot read the existing library without interaction; no data was changed.\n", stderr)
                exit(2)
            }
        }
        state = AppState(previewLibrary: library)
        state.editorPosition.tab = 2
        let hosting = NSHostingView(rootView: SettingsView().environmentObject(state!))
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 620, height: 580),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        func settle(_ stage: String) {
            print("scenario-layout begin: \(stage)"); fflush(stdout)
            hosting.layoutSubtreeIfNeeded()
            if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            }
            let deadline = Date().addingTimeInterval(0.15)
            while Date() < deadline { _ = RunLoop.current.run(mode: .default, before: deadline) }
            hosting.layoutSubtreeIfNeeded()
            print("scenario-layout settled: \(stage)"); fflush(stdout)
        }
        settle("collapsed")
        withAnimation(.easeInOut(duration: 0.2)) {
            state.editorPosition.expandedScenarioID = scenario.id
        }
        settle("expanded")
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        let scrollers = scrollViews(hosting)
        print("scenario-layout scrollers: \(scrollers.count)"); fflush(stdout)
        for offset in [80, 140, 250, 420, 600, 300, 100, 0] {
            state.objectWillChange.send()
            for scroll in scrollers {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            settle("scroll \(offset)")
        }
        for width in [620, 800, 560, 620] {
            window.setContentSize(CGSize(width: width, height: 580))
            settle("width \(width)")
        }
        state.editorPosition.expandedScenarioID = nil
        settle("collapsed again")
        state.editorPosition.expandedScenarioID = scenario.id
        settle("expanded again")
        print("Scenario layout check passed without showing a window")
        exit(0)
    }

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
