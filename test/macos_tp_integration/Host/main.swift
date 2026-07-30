import AppKit
import Foundation
@preconcurrency import NetworkExtension
@preconcurrency import SystemExtensions

private let extensionIdentifier =
    "com.kafeifei.xdial.ne-probe.extension"
private let configurationName =
    "XDial Transparent Proxy Formal Integration"

private final class IntegrationHost:
    NSObject,
    NSApplicationDelegate,
    OSSystemExtensionRequestDelegate
{
    private var activationRequest: OSSystemExtensionRequest?
    private var timer: Timer?
    private var finished = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        timer = Timer.scheduledTimer(
            timeInterval: 30,
            target: self,
            selector: #selector(timedOut),
            userInfo: nil,
            repeats: false
        )
        switch CommandLine.arguments.dropFirst().first ?? "status" {
        case "activate":
            activate()
        case "start-current":
            startCurrentProfile()
        case "stop":
            stop()
        case "status":
            status()
        default:
            finish("unknown command", code: 2)
        }
    }

    private func activate() {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        activationRequest = request
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func startCurrentProfile() {
        let profile: String
        do {
            profile = try currentHydratedProfile()
        } catch {
            finish("profile-load-failed: \(error.localizedDescription)", code: 1)
            return
        }
        loadManager { result in
            switch result {
            case let .failure(error):
                self.finish("manager-load-failed: \(error)", code: 1)
            case let .success(manager):
                let provider = NETunnelProviderProtocol()
                provider.providerBundleIdentifier = extensionIdentifier
                provider.providerConfiguration = ["schema_version": 1]
                provider.serverAddress = configurationName
                manager.protocolConfiguration = provider
                manager.localizedDescription = configurationName
                manager.isEnabled = true
                manager.saveToPreferences { error in
                    if let error {
                        self.finish("manager-save-failed: \(error)", code: 1)
                        return
                    }
                    manager.loadFromPreferences { error in
                        if let error {
                            self.finish(
                                "manager-reload-failed: \(error)",
                                code: 1
                            )
                            return
                        }
                        do {
                            try manager.connection.startVPNTunnel(options: [
                                "profile": profile as NSString,
                            ])
                            self.finish("start-requested")
                        } catch {
                            self.finish(
                                "start-failed: \(error)",
                                code: 1
                            )
                        }
                    }
                }
            }
        }
    }

    private func stop() {
        loadExistingManager { result in
            switch result {
            case let .failure(error):
                self.finish("manager-load-failed: \(error)", code: 1)
            case .success(nil):
                self.finish("configuration=absent")
            case let .success(manager?):
                manager.connection.stopVPNTunnel()
                self.finish("stop-requested")
            }
        }
    }

    private func status() {
        loadExistingManager { result in
            switch result {
            case let .failure(error):
                self.finish("manager-load-failed: \(error)", code: 1)
            case .success(nil):
                self.finish("configuration=absent")
            case let .success(manager?):
                self.finish(
                    "configuration=present enabled=\(manager.isEnabled) status=\(statusName(manager.connection.status))"
                )
            }
        }
    }

    private func loadManager(
        completion: @escaping (
            Result<NETransparentProxyManager, Error>
        ) -> Void
    ) {
        loadExistingManager { result in
            switch result {
            case let .failure(error):
                completion(.failure(error))
            case let .success(manager):
                completion(.success(manager ?? NETransparentProxyManager()))
            }
        }
    }

    private func loadExistingManager(
        completion: @escaping (
            Result<NETransparentProxyManager?, Error>
        ) -> Void
    ) {
        NETransparentProxyManager.loadAllFromPreferences { managers, error in
            if let error {
                completion(.failure(error))
                return
            }
            completion(.success(managers?.first {
                $0.localizedDescription == configurationName
                    || ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == extensionIdentifier
            }))
        }
    }

    private func currentHydratedProfile() throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let preferences = home.appendingPathComponent(
            "Library/Preferences/com.kafeifei.xdial.plist"
        )
        guard
            let stored = NSDictionary(contentsOf: preferences),
            let profileData = stored["xdial.profile"] as? Data,
            var profile = try JSONSerialization.jsonObject(
                with: profileData
            ) as? [String: Any]
        else {
            throw IntegrationError.profileUnavailable
        }

        let vaultURL = home.appendingPathComponent(".xdial/vault.json")
        let vaultData = try Data(contentsOf: vaultURL)
        let vault = try JSONDecoder().decode(
            [String: String].self,
            from: vaultData
        )
        hydrate(lines: &profile["lines"], prefix: nil, vault: vault)
        if var subscriptions = profile["subscriptions"]
            as? [[String: Any]] {
            for index in subscriptions.indices {
                guard
                    let subscriptionID = subscriptions[index]["id"]
                        as? String
                else { continue }
                hydrate(
                    lines: &subscriptions[index]["lines"],
                    prefix: subscriptionID,
                    vault: vault
                )
            }
            profile["subscriptions"] = subscriptions
        }
        let encoded = try JSONSerialization.data(withJSONObject: profile)
        guard let result = String(data: encoded, encoding: .utf8) else {
            throw IntegrationError.profileUnavailable
        }
        return result
    }

    private func hydrate(
        lines rawLines: inout Any?,
        prefix: String?,
        vault: [String: String]
    ) {
        guard var lines = rawLines as? [[String: Any]] else { return }
        for index in lines.indices {
            guard let lineID = lines[index]["id"] as? String else { continue }
            let key = [prefix, lineID].compactMap { $0 }.joined(separator: "-")
            for (suffix, field) in [
                ("vpn", "vpn_password"),
                ("trojan", "trojan_password"),
                ("ss", "ss_password"),
                ("vmess", "vmess_uuid"),
            ] {
                if let value = vault["\(key)-\(suffix)"] {
                    lines[index][field] = value
                }
            }
        }
        rawLines = lines
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension extension: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        print("approval-required")
        fflush(stdout)
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        finish("activation-result=\(result.rawValue)")
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFailWithError error: Error
    ) {
        finish("activation-failed: \(error)", code: 1)
    }

    @objc private func timedOut() {
        finish("operation-timed-out", code: 124)
    }

    private func finish(_ message: String, code: Int32 = 0) {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        print(message)
        fflush(stdout)
        DispatchQueue.main.async {
            NSApp.terminate(nil)
            exit(code)
        }
    }
}

private enum IntegrationError: LocalizedError {
    case profileUnavailable

    var errorDescription: String? {
        "无法读取当前 XDial Profile"
    }
}

private func statusName(_ status: NEVPNStatus) -> String {
    switch status {
    case .invalid: "invalid"
    case .disconnected: "disconnected"
    case .connecting: "connecting"
    case .connected: "connected"
    case .reasserting: "reasserting"
    case .disconnecting: "disconnecting"
    @unknown default: "unknown-\(status.rawValue)"
    }
}

let application = NSApplication.shared
private let delegate = IntegrationHost()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
