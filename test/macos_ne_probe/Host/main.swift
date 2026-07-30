import AppKit
import Foundation
@preconcurrency import NetworkExtension
@preconcurrency import SystemExtensions

private let extensionIdentifier = "com.kafeifei.xdial.ne-probe.extension"
private let configurationName = "XDial Transparent Proxy Coexistence Probe"

private final class ProbeHost: NSObject, NSApplicationDelegate, OSSystemExtensionRequestDelegate {
    private var activationRequest: OSSystemExtensionRequest?
    private var operationTimer: Timer?
    private var activeCommand = "unknown"
    private var isFinishing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let command = CommandLine.arguments.dropFirst().first ?? "status"
        activeCommand = command
        if command != "activate" {
            operationTimer = Timer.scheduledTimer(
                timeInterval: 15,
                target: self,
                selector: #selector(operationTimedOut),
                userInfo: nil,
                repeats: false
            )
        }
        switch command {
        case "activate":
            activateExtension()
        case "configure-scoped":
            configure(scope: "scoped")
        case "configure-dns":
            configure(scope: "dns")
        case "configure-relay-tcp":
            guard
                let rawPort = CommandLine.arguments.dropFirst(2).first,
                let port = Int(rawPort),
                (1 ... 65535).contains(port)
            else {
                finish("configure-relay-tcp requires a SOCKS port", code: 2)
                return
            }
            configure(scope: "relay-tcp", socksPort: port)
        case "configure-relay-domain":
            guard
                let rawPort = CommandLine.arguments.dropFirst(2).first,
                let port = Int(rawPort),
                (1 ... 65535).contains(port)
            else {
                finish("configure-relay-domain requires a SOCKS port", code: 2)
                return
            }
            let domain = CommandLine.arguments.dropFirst(3).first
            configure(
                scope: "relay-domain",
                socksPort: port,
                domain: domain
            )
        case "configure-relay-all":
            guard
                let rawPort = CommandLine.arguments.dropFirst(2).first,
                let port = Int(rawPort),
                (1 ... 65535).contains(port)
            else {
                finish("configure-relay-all requires a SOCKS port", code: 2)
                return
            }
            configure(scope: "relay-all", socksPort: port)
        case "configure-embedded-all":
            guard
                let rawPort = CommandLine.arguments.dropFirst(2).first,
                let port = Int(rawPort),
                (1 ... 65535).contains(port)
            else {
                finish("configure-embedded-all requires a SOCKS port", code: 2)
                return
            }
            configure(scope: "embedded-all", socksPort: port)
        case "configure-all":
            configure(scope: "all")
        case "stop":
            stopConfiguration()
        case "remove":
            removeConfiguration()
        case "status":
            printStatus()
        default:
            finish("unknown command \(command)", code: 2)
        }
    }

    private func activateExtension() {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        activationRequest = request
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func configure(
        scope: String,
        socksPort: Int? = nil,
        domain: String? = nil
    ) {
        let trialID = UUID().uuidString
        loadManager { result in
            switch result {
            case let .failure(error):
                self.finish("load manager failed: \(error)", code: 1)
            case let .success(manager):
                let providerProtocol = NETunnelProviderProtocol()
                providerProtocol.providerBundleIdentifier = extensionIdentifier
                var providerConfiguration: [String: Any] = [
                    "scope": scope,
                    "trialID": trialID,
                ]
                if let socksPort {
                    providerConfiguration["socksPort"] = socksPort
                }
                if let domain, !domain.isEmpty {
                    providerConfiguration["domain"] = domain
                }
                providerProtocol.providerConfiguration = providerConfiguration
                providerProtocol.serverAddress = configurationName
                manager.protocolConfiguration = providerProtocol
                manager.localizedDescription = configurationName
                manager.isEnabled = true
                manager.saveToPreferences { error in
                    if let error {
                        self.finish("save manager failed: \(error)", code: 1)
                        return
                    }
                    manager.loadFromPreferences { error in
                        if let error {
                            self.finish("reload manager failed: \(error)", code: 1)
                            return
                        }
                        do {
                            try manager.connection.startVPNTunnel()
                            self.finish("configured scope=\(scope) trial=\(trialID)")
                        } catch {
                            self.finish("start transparent proxy failed: \(error)", code: 1)
                        }
                    }
                }
            }
        }
    }

    private func stopConfiguration() {
        loadExistingManager { result in
            switch result {
            case let .failure(error):
                self.finish("load manager failed: \(error)", code: 1)
            case .success(nil):
                self.finish("no configuration")
            case let .success(manager?):
                manager.connection.stopVPNTunnel()
                manager.isEnabled = false
                manager.saveToPreferences { error in
                    if let error {
                        self.finish("disable manager failed: \(error)", code: 1)
                    } else {
                        self.finish("stopped")
                    }
                }
            }
        }
    }

    private func removeConfiguration() {
        loadExistingManager { result in
            switch result {
            case let .failure(error):
                self.finish("load manager failed: \(error)", code: 1)
            case .success(nil):
                self.finish("no configuration")
            case let .success(manager?):
                manager.connection.stopVPNTunnel()
                manager.removeFromPreferences { error in
                    if let error {
                        self.finish("remove manager failed: \(error)", code: 1)
                    } else {
                        self.finish("removed")
                    }
                }
            }
        }
    }

    private func printStatus() {
        loadExistingManager { result in
            switch result {
            case let .failure(error):
                self.finish("load manager failed: \(error)", code: 1)
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
        completion: @escaping (Result<NETransparentProxyManager, Error>) -> Void
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
        completion: @escaping (Result<NETransparentProxyManager?, Error>) -> Void
    ) {
        NETransparentProxyManager.loadAllFromPreferences { managers, error in
            if let error {
                completion(.failure(error))
                return
            }
            let manager = managers?.first {
                $0.localizedDescription == configurationName
                    || ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == extensionIdentifier
            }
            completion(.success(manager))
        }
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

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        finish("activation-failed: \(error)", code: 1)
    }

    @objc private func operationTimedOut() {
        finish("command timed out: \(activeCommand)", code: 124)
    }

    private func finish(_ message: String, code: Int32 = 0) {
        guard !isFinishing else {
            return
        }
        isFinishing = true
        operationTimer?.invalidate()
        print(message)
        fflush(stdout)
        DispatchQueue.main.async {
            NSApp.terminate(nil)
            exit(code)
        }
    }
}

private func statusName(_ status: NEVPNStatus) -> String {
    switch status {
    case .invalid:
        "invalid"
    case .disconnected:
        "disconnected"
    case .connecting:
        "connecting"
    case .connected:
        "connected"
    case .reasserting:
        "reasserting"
    case .disconnecting:
        "disconnecting"
    @unknown default:
        "unknown-\(status.rawValue)"
    }
}

let application = NSApplication.shared
private let delegate = ProbeHost()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
