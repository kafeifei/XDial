import SwiftUI

@main
struct XDialIOSApp: App {
    var body: some Scene {
        WindowGroup {
            MobileRootView()
        }
    }
}

struct MobileRootView: View {
    @StateObject private var app: AppState

    init() {
        #if targetEnvironment(simulator)
        let engine = FakeTunnelEngine()
        let manager = FakeTunnelManager(engine: engine)
        engine.retain(manager: manager)
        let arguments = ProcessInfo.processInfo.arguments
        let shouldResetUITesting = arguments.contains("-XDialUITestingReset")
        let isUITesting = shouldResetUITesting || arguments.contains("-XDialUITesting")
        let persistence: AppPersistenceContext = isUITesting ? .uiTesting : .production
        if shouldResetUITesting { _ = persistence.clearForTesting() }
        let state = AppState(engine: engine, tunnelManager: manager, persistence: persistence)
        _app = StateObject(wrappedValue: state)
        #else
        let engine = GoEngine.shared
        let manager = TunnelManager(engine: engine)
        _app = StateObject(wrappedValue: AppState(engine: engine, tunnelManager: manager))
        #endif
    }

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label(app.tr("首页", "Home"), systemImage: "power") }

            ModesView()
                .tabItem { Label(app.tr("模式", "Modes"), systemImage: "shuffle") }

            ConfigurationView()
                .tabItem { Label(app.tr("配置", "Config"), systemImage: "slider.horizontal.3") }

            MobileSettingsView()
                .tabItem { Label(app.tr("设置", "Settings"), systemImage: "gearshape") }
        }
        .environmentObject(app)
        #if targetEnvironment(simulator)
        .onAppear { app.seedDemoDataForSimulator() }
        #endif
    }
}
