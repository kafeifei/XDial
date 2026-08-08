import SwiftUI

@main
struct XDialIOSApp: App {
    var body: some Scene {
        WindowGroup {
            MobileRootView()
        }
    }
}

enum MobileTab: Hashable {
    case home
    case scenarios
    case configuration
    case settings
}

struct MobileRootView: View {
    @StateObject private var app: AppState
    @State private var selectedTab: MobileTab = .home

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
        let state = AppState(
            engine: engine,
            tunnelManager: manager,
            tailscaleSetupRuntime: FakeTailscaleSetupRuntime(),
            persistence: persistence
        )
        _app = StateObject(wrappedValue: state)
        #else
        let engine = GoEngine.shared
        let manager = TunnelManager(engine: engine)
        _app = StateObject(wrappedValue: AppState(
            engine: engine,
            tunnelManager: manager,
            tailscaleSetupRuntime: LocalTailscaleSetupRuntime()
        ))
        #endif
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(selectedTab: $selectedTab)
                .tabItem { Label(app.tr("首页", "Home"), systemImage: "power") }
                .tag(MobileTab.home)

            ScenariosView()
                .tabItem {
                    Label(
                        app.tr("场景", "Scenarios"),
                        systemImage: "square.grid.2x2"
                    )
                }
                .tag(MobileTab.scenarios)

            ConfigurationView()
                .tabItem { Label(app.tr("配置", "Config"), systemImage: "slider.horizontal.3") }
                .tag(MobileTab.configuration)

            MobileSettingsView()
                .tabItem { Label(app.tr("设置", "Settings"), systemImage: "gearshape") }
                .tag(MobileTab.settings)
        }
        .environmentObject(app)
        #if targetEnvironment(simulator)
        .onAppear { app.seedDemoDataForSimulator() }
        #endif
    }
}
