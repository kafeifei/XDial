import AppKit

#if XDIAL_NEXT_IDENTITY
// This entry point precedes all App/engine/installation initialization. The
// read-only check works while Debug and Next run; the writer refuses a live
// Next process so its in-memory library cannot overwrite an imported record.
if CommandLine.arguments.contains("--import-xdial-debug") ||
    CommandLine.arguments.contains("--check-xdial-debug-import") {
    do {
        let checkOnly = CommandLine.arguments.contains("--check-xdial-debug-import")
        guard checkOnly || NSRunningApplication.runningApplications(
            withBundleIdentifier: XDialBuildIdentity.applicationIdentifier
        ).filter({ $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }).isEmpty else {
            throw ProfileLibraryError.invalid("Next 正在运行，请使用配置菜单导入，或关闭 Next 后执行；XDail Debug 可以继续运行")
        }
        let id = UUID().uuidString.lowercased()
        let profile = try ProfileDocumentService.importExistingDebug(id: id)
        guard try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile)) == profile else {
            throw ProfileLibraryError.invalid("导入配置往返验证失败")
        }
        if !checkOnly {
            let store = ProfileLibraryStore()
            var library = try store.load() ?? ProfileLibrary()
            library.profiles.append(ProfileRecord(id: id, name: "XDail Debug 导入", profile: profile))
            library.editingProfileID = id
            try store.save(library)
            guard try store.load() == library else { throw ProfileLibraryError.invalid("导入后的加密配置校验失败") }
        }
        let credentials = profile.lines.filter {
            !$0.vpnPassword.isEmpty || !$0.trojanPassword.isEmpty || !$0.ssPassword.isEmpty ||
            !$0.vmessUUID.isEmpty || !$0.anytlsPassword.isEmpty
        }.count
        fputs("\(checkOnly ? "Validated" : "Imported") XDail Debug: \(profile.lines.count) lines, \(profile.ruleSets.count) rule sets, \(profile.scenarios.count) scenarios, \(credentials) credential-bearing lines. No connection or activation.\n", stdout)
        exit(0)
    } catch {
        // Decoder/validator errors can contain source fields; never emit them.
        let message = (error as? ProfileLibraryError)?.localizedDescription ?? "读取或验证配置失败；未输出配置正文"
        fputs("Import failed: " + message + "\n", stderr)
        exit(1)
    }
}
#endif

if CommandLine.arguments.contains(OutgoingApplicationCleanup.helperReplacementArgument) {
    let application = NSApplication.shared
    Task { @MainActor in
        do {
            let outgoingURL = try ApplicationRelocator.validateHelperReplacement()
            appLog("installation outgoing helper teardown begin before bundle replacement")
            try await PrivilegeManager.teardownRegisteredHelper(outgoingBundleURL: outgoingURL)
            appLog("installation outgoing helper teardown completed before bundle replacement")
            fputs("XDial outgoing helper teardown completed.\n", stdout)
            exit(0)
        } catch {
            appLog("installation outgoing helper teardown failed: \(error)")
            fputs("XDial outgoing helper teardown failed: " + error.localizedDescription + "\n", stderr)
            exit(1)
        }
    }
    application.run()
    exit(0)
}

if CommandLine.arguments.contains(
    OutgoingApplicationCleanup.replacementArgument
) {
    let application = NSApplication.shared
    TransparentProxyManager.shared.uninstallSystemExtension { result in
        switch result {
        case .success:
            do {
                try PrivilegeManager.unregisterForIdentityReplacement()
                fputs(
                    "XDial platform components cleaned successfully.\n",
                    stdout
                )
                exit(0)
            } catch {
                fputs(
                    "XDial helper cleanup failed: "
                        + error.localizedDescription + "\n",
                    stderr
                )
                exit(1)
            }
        case let .failure(error):
            fputs(
                "XDial System Extension cleanup failed: "
                    + error.localizedDescription + "\n",
                stderr
            )
            exit(1)
        }
    }
    application.run()
    exit(0)
}

if CommandLine.arguments.contains(
    "--deactivate-owned-system-extension"
) {
    let application = NSApplication.shared
    TransparentProxyManager.shared.uninstallSystemExtension { result in
        switch result {
        case .success:
            fputs(
                "XDial System Extension deactivated successfully.\n",
                stdout
            )
            exit(0)
        case let .failure(error):
            fputs(
                "XDial System Extension deactivation failed: "
                    + error.localizedDescription + "\n",
                stderr
            )
            exit(1)
        }
    }
    application.run()
    exit(0)
}

if CommandLine.arguments.contains(
    "--remove-owned-network-configurations"
) {
    let application = NSApplication.shared
    TransparentProxyManager.shared
        .removeOwnedNetworkConfigurationsOnly { result in
            switch result {
            case .success:
                fputs(
                    "XDial network configurations removed successfully.\n",
                    stdout
                )
                exit(0)
            case let .failure(error):
                fputs(
                    "XDial network configuration removal failed: "
                        + error.localizedDescription + "\n",
                    stderr
                )
                exit(1)
            }
        }
    application.run()
    exit(0)
}

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
    do {
        try ApplicationRelocator.prepareCommandLineUninstall()
    } catch {
        fputs("XDial uninstall could not stop the running app: "
            + error.localizedDescription + "\n", stderr)
        exit(1)
    }
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
let relocationPredecessorProcessIdentifier =
    ApplicationLaunchPolicy.relocationPredecessorProcessIdentifier(
        arguments: CommandLine.arguments
    )
let others = NSRunningApplication.runningApplications(
    withBundleIdentifier: me.bundleIdentifier ?? ""
).filter {
    $0.processIdentifier != me.processIdentifier
        && !ApplicationRelocator.isExpectedRelaunchPredecessor(
            $0,
            processIdentifier: relocationPredecessorProcessIdentifier
        )
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
