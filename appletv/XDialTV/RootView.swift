import SwiftUI

/// 导航路由。用值驱动的 NavigationStack（`navigationDestination(for:)`）而不是
/// 一堆散落的 NavigationLink 目标，方便任意视图 push 且集中定义目的地。
enum Route: Hashable {
    case modes
    case credentials
    case settings
}

/// 根视图：唯一持有 AppState 的地方（`@StateObject`），用 NavigationStack 承载
/// tvOS 的层级导航，并把 AppState 通过 environmentObject 注入整棵子树。
///
/// 交互范式：遥控器方向键在各视图内移动焦点，中键触发按钮/NavigationLink，
/// Menu 键回退上一层（NavigationStack 默认行为）。
struct RootView: View {
    @StateObject private var app: AppState

    init() {
        // Simulator：注入互联好的 fake 隧道层（见 FakeTunnel.swift），让 UI 交互
        // （连接/断开/状态转换/模式切换）在没有 NE entitlement / 真机时也能完整走通。
        // 真机 / Release：保持默认（NoopTunnelEngine，无 tunnelManager）——真实
        // GoEngine / TunnelManager 的接线留到真机联调时再做，本任务不动真实路径。
        #if targetEnvironment(simulator)
        let fakeEngine = FakeTunnelEngine()
        let fakeManager = FakeTunnelManager(engine: fakeEngine)
        // AppState 只 weak 持有 tunnelManager；让 engine 强持有 manager 作为存活锚点
        // （engine 由 AppState 强持有）。manager → engine 是 weak，不成环。
        fakeEngine.retain(manager: fakeManager)
        _app = StateObject(wrappedValue: AppState(engine: fakeEngine, tunnelManager: fakeManager))
        #else
        _app = StateObject(wrappedValue: AppState())
        #endif
    }

    var body: some View {
        NavigationStack {
            ConnectionView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .modes:
                        ModePickerView()
                    case .credentials:
                        CredentialsView()
                    case .settings:
                        SettingsView()
                    }
                }
        }
        .environmentObject(app)
        #if targetEnvironment(simulator)
        .onAppear { app.seedDemoDataForSimulator() }
        #endif
    }
}
