import AppKit

switch ApplicationRelocator.prepareForLaunch() {
case .continueLaunch:
    break
case .relaunching:
    exit(0)
case let .failed(message):
    _ = NSApplication.shared
    let alert = NSAlert()
    alert.messageText = "XDial 无法完成安装"
    alert.informativeText = message
    alert.alertStyle = .critical
    alert.addButton(withTitle: "退出")
    alert.runModal()
    exit(1)
}

let me = NSRunningApplication.current
let others = NSRunningApplication.runningApplications(
    withBundleIdentifier: me.bundleIdentifier ?? ""
).filter { $0 != me }

if !others.isEmpty {
    _ = NSApplication.shared
    let alert = NSAlert()
    alert.messageText = "XDial 已在运行"
    alert.informativeText = "请在菜单栏找到 XDial 图标。"
    alert.alertStyle = .informational
    alert.addButton(withTitle: "确认")
    alert.runModal()
    exit(0)
}

XDialApp.main()
