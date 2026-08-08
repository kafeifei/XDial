import AppKit

if CommandLine.arguments.contains("--uninstall") {
    guard ApplicationRelocator.isRunningFromApplications else {
        fputs(
            "XDial must be installed in /Applications before uninstalling.\n",
            stderr
        )
        exit(2)
    }
    let deleteData = CommandLine.arguments.contains(
        "--delete-data"
    )
    let application = NSApplication.shared
    Task { @MainActor in
        ApplicationUninstaller.run(
            deleteData: deleteData
        ) { result in
            switch result {
            case .success:
                fputs("XDial uninstalled successfully.\n", stdout)
                exit(0)
            case let .failure(error):
                fputs(
                    "XDial uninstall failed: "
                        + error.localizedDescription + "\n",
                    stderr
                )
                exit(1)
            }
        }
    }
    application.run()
    exit(0)
}

if CommandLine.arguments.contains("--install-only") {
    do {
        try ApplicationRelocator.installCurrentBundleWithoutRelaunch()
        fputs("XDial installed successfully.\n", stdout)
        exit(0)
    } catch {
        fputs(
            "XDial installation failed: "
                + error.localizedDescription + "\n",
            stderr
        )
        exit(1)
    }
}

var launchPreparationComplete = false
while !launchPreparationComplete {
    switch ApplicationRelocator.prepareForLaunch() {
    case .continueLaunch:
        launchPreparationComplete = true
    case .relaunching:
        exit(0)
    case let .failed(message, canRetry):
        _ = NSApplication.shared
        let alert = NSAlert()
        alert.messageText = "XDial 无法完成安装"
        alert.informativeText = message
        alert.alertStyle = .critical
        if canRetry {
            alert.addButton(withTitle: "重试")
            alert.addButton(withTitle: "退出")
            if alert.runModal() == .alertFirstButtonReturn {
                continue
            }
        } else {
            alert.addButton(withTitle: "退出")
            alert.runModal()
        }
        exit(1)
    }
}

let me = NSRunningApplication.current
let others = NSRunningApplication.runningApplications(
    withBundleIdentifier: me.bundleIdentifier ?? ""
).filter {
    $0.processIdentifier != me.processIdentifier
}

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
