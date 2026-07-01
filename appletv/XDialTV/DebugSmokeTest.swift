import Foundation
import Libbox

/// Phase 0 手测能力（从 XDialTVApp.swift 迁出）。
///
/// 直接从 app target（非 NE 扩展）调用 Libbox，验证 gomobile 生成的桥接代码
/// 在真实 tvOS Simulator 运行时下能否正确初始化并完成一次真实 AnyConnect 拨号。
/// 凭据经环境变量传入（`SIMCTL_CHILD_ANYCONNECT_*`），不写进代码。
///
/// UI 层通过「设置 → 长按调试入口」触发 `DebugSmokeTest.run()`，保留这个手测闭环，
/// 与正常的连接流程（走引擎层）解耦。
enum DebugSmokeTest {

    private final class TestCallback: NSObject, LibboxCallbackProtocol {
        func onStatusChanged(_ statusJSON: String?) {
            NSLog("[libbox status] \(statusJSON ?? "")")
        }
        func onError(_ code: Int, message: String?) {
            NSLog("[libbox error \(code)] \(message ?? "")")
        }
    }

    /// 最近一次手测的结果摘要，UI 可展示给开发者看（避免只能翻 NSLog）。
    /// 用简单的回调把结果回传，不引入额外状态类型。
    static func run(report: @escaping @Sendable (String) -> Void) {
        guard let server = ProcessInfo.processInfo.environment["ANYCONNECT_SERVER"],
              let username = ProcessInfo.processInfo.environment["ANYCONNECT_USERNAME"],
              let password = ProcessInfo.processInfo.environment["ANYCONNECT_PASSWORD"] else {
            let msg = "跳过：未设置 ANYCONNECT_* 环境变量"
            NSLog("[libbox smoke test] skipped: no ANYCONNECT_* env vars")
            report(msg)
            return
        }
        NSLog("[libbox smoke test] starting, server=\(server)")
        report("开始拨号 server=\(server)…")

        let cb = TestCallback()
        guard let lb = LibboxNew(cb) else {
            NSLog("[libbox smoke test] LibboxNew returned nil")
            report("失败：LibboxNew 返回 nil")
            return
        }
        let configJSON = """
        {"log":{"level":"info"},"outbounds":[{"type":"vpn","tag":"vpn"},{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}
        """
        DispatchQueue.global().async {
            do {
                try lb.start(server, username: username, password: password, configJSON: configJSON)
                NSLog("[libbox smoke test] start() returned OK")
                DispatchQueue.main.async { report("start() OK，3 秒后断开…") }
                Thread.sleep(forTimeInterval: 3)
                try? lb.stop()
                NSLog("[libbox smoke test] stop() done")
                DispatchQueue.main.async { report("完成：start/stop 均成功") }
            } catch {
                NSLog("[libbox smoke test] start() FAILED: \(error)")
                DispatchQueue.main.async { report("失败：start() 抛错 \(error.localizedDescription)") }
            }
        }
    }
}
