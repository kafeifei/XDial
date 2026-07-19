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
    private let runtimeAnchor: AnyObject

    init() {
        #if targetEnvironment(simulator)
        let engine = FakeTunnelEngine()
        let manager = FakeTunnelManager(engine: engine)
        engine.retain(manager: manager)
        runtimeAnchor = manager
        _app = StateObject(wrappedValue: AppState(engine: engine, tunnelManager: manager))
        #else
        let engine = GoEngine.shared
        let manager = TunnelManager(engine: engine)
        runtimeAnchor = manager
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
