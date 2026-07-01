import SwiftUI

/// tvOS app 入口。RootView 持有 AppState 并承载遥控器焦点导航 UI。
///
/// Phase 0 的 Libbox 手测桩已迁到 `DebugSmokeTest.swift`，由「设置 → 长按版本行」
/// 触发（仅 DEBUG 构建）。这里不再直接调 Libbox，正常连接走引擎层。
@main
struct XDialTVApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
