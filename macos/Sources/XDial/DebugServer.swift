#if DEBUG
import AppKit
import ApplicationServices
import Foundation
import Network

final class DebugServer {
    private var listener: NWListener?
    private let port: UInt16 = 19876

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // 只绑回环：调试服务器绝不能暴露到局域网
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        guard let l = try? NWListener(using: params) else {
            DispatchQueue.main.async { appLog("DebugServer: cannot bind 127.0.0.1:\(self.port)") }
            return
        }
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [port] state in
            switch state {
            case .ready:
                DispatchQueue.main.async { appLog("DebugServer: ready on localhost:\(port)") }
            case .failed(let error):
                DispatchQueue.main.async {
                    appLog("DebugServer: listener failed on 127.0.0.1:\(port): \(error)")
                }
            default:
                break
            }
        }
        l.start(queue: .global(qos: .utility))
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .utility))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
            guard let data, let raw = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }
            Task { @MainActor in
                let (code, body) = await Self.route(raw)
                let header = "HTTP/1.1 \(code)\r\nContent-Type: application/json; charset=utf-8\r\nConnection: close\r\n\r\n"
                conn.send(content: (header + body).data(using: .utf8),
                          completion: .contentProcessed { _ in conn.cancel() })
            }
        }
    }

    // MARK: - Routing

    @MainActor
    private static func route(_ raw: String) async -> (String, String) {
        let req = parseHTTP(raw)
        // 防 DNS rebinding：浏览器带任意 Host 打到 127.0.0.1 时拒绝。
        // 必须精确匹配主机名——用 hasPrefix 会被 localhost.evil.com / 127.0.0.1.evil.com
        // 这类"解析到回环但前缀相同"的域名绕过。
        guard isAllowedHost(req.host) else {
            return ("403 Forbidden", json(["error": "bad host"]))
        }
        switch (req.method, req.path) {
        case ("GET", "/health"):
            return ok(["ok": true, "pid": getpid()])
        case ("GET", "/state"):
            return ok(buildState())
        case ("GET", "/ax"):
            let depth = Int(req.query["depth"] ?? "") ?? 15
            return ok(buildAXTree(maxDepth: depth))
        case ("POST", "/action"):
            return await handleAction(req.body)
        default:
            return ("404 Not Found", json([
                "error": "not found",
                "endpoints": [
                    "GET  /health",
                    "GET  /state",
                    "GET  /ax[?depth=N]",
                    "POST /action  {action: connect|disconnect|reconnect|connect-with-failure|begin-route-probe|routing-probe-snapshot|select-mode|ax-press|ax-set-value, ...}",
                ],
            ]))
        }
    }

    // 只放行回环主机名：去掉端口后精确匹配（IPv6 保留 [] 包裹）。空 Host 放行（部分裸 TCP 客户端不带）。
    private static func isAllowedHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased()
        if host.isEmpty { return true }
        let hostNoPort: String
        if host.hasPrefix("[") {
            // [::1] 或 [::1]:port —— 取到 ] 为止
            if let end = host.firstIndex(of: "]") {
                hostNoPort = String(host[...end])
            } else {
                hostNoPort = host
            }
        } else if let colon = host.firstIndex(of: ":") {
            hostNoPort = String(host[..<colon])
        } else {
            hostNoPort = host
        }
        return hostNoPort == "127.0.0.1" || hostNoPort == "localhost" || hostNoPort == "[::1]"
    }

    // MARK: - State Snapshot

    @MainActor
    private static func buildState() -> [String: Any] {
        guard let s = AppState.current else {
            return ["error": "AppState not initialized"]
        }
        let net = NetworkInfo.shared
        var perLine: [String: Any] = [:]
        for (k, v) in net.perLine {
            perLine[k] = [
                "transactionID": v.transactionID,
                "lineID": v.lineID,
                "observedAt":
                    ISO8601DateFormatter().string(from: v.observedAt),
                "ip": v.ip,
                "region": v.region,
                "errorCode": v.errorCode,
                "summary": v.summary,
            ]
        }

        var dict: [String: Any] = [:]
        dict["engine"] = [
            "status": s.engine.status,
            "lastError": s.engine.lastError ?? "",
            "isConnected": s.isConnected,
            "isBusy": s.isBusy,
        ] as [String: Any]
        dict["helperInstalled"] = s.helperInstalled
        dict["helperNeedsApproval"] = s.helperNeedsApproval
        dict["helperSMStatus"] = PrivilegeManager.status.rawValue
        dict["helperLegacyInstalled"] = PrivilegeManager.legacyInstalled
        dict["daemonBundledSHA256"] = PrivilegeManager.bundledDaemonSHA256() ?? ""
        dict["dataPlane"] = "transparent-proxy"
        dict["canConnect"] = s.canConnect
        dict["statusText"] = s.statusText
        dict["language"] = s.language.rawValue
        dict["launchAtLogin"] = s.launchAtLogin
        dict["autoConnect"] = s.autoConnect
        dict["wakeReconnectPhase"] =
            s.wakeReconnectPhase?.rawValue ?? ""
        dict["desiredConnectionState"] =
            s.desiredConnectionStateForDiagnostics
        dict["desiredConnectionModeID"] =
            s.desiredConnectionModeIDForDiagnostics
        dict["desiredConnectionOwnership"] =
            s.desiredConnectionOwnershipForDiagnostics
        dict["systemIsSleeping"] =
            s.systemIsSleepingForDiagnostics
        dict["activeModeID"] = s.profile.activeModeID
        // 配置改了但引擎还在跑旧快照 —— 验收改动是否真正生效必须看这个
        dict["configDirty"] = s.configDirty
        if let report = s.engine.connectionReport,
           let data = try? JSONEncoder().encode(report),
           let object = try? JSONSerialization.jsonObject(with: data) {
            dict["connectionReport"] = object
        }
        if let data = try? JSONEncoder().encode(
            s.installation.report
        ),
        let object = try? JSONSerialization.jsonObject(with: data) {
            dict["installationReport"] = object
        }
        if let data = try? JSONEncoder().encode(
            TransparentProxyManager.shared.automaticReconnectState
        ),
        let object = try? JSONSerialization.jsonObject(with: data) {
            dict["automaticReconnect"] = object
        }
        if let data = try? JSONEncoder().encode(
            ReconnectIncidentJournal.read()
        ),
        let object = try? JSONSerialization.jsonObject(with: data) {
            dict["reconnectIncidents"] = object
        }

        if let d = try? JSONEncoder().encode(s.profile),
           let p = try? JSONSerialization.jsonObject(with: d) {
            dict["profile"] = redactSecrets(p)
        }

        dict["network"] = [
            "transactionID": net.transactionID ?? "",
            "perLine": perLine,
        ] as [String: Any]

        dict["windows"] = NSApp.windows.map { w -> [String: Any] in
            [
                "title": w.title,
                "isVisible": w.isVisible,
                "isKey": w.isKeyWindow,
                "frame": [
                    "x": Int(w.frame.origin.x), "y": Int(w.frame.origin.y),
                    "w": Int(w.frame.width), "h": Int(w.frame.height),
                ],
            ]
        }
        return dict
    }

    // 密码/凭据字段一律打码；订阅 url 内嵌 token，同样按凭据处理
    private static let secretKeys: Set<String> = [
        "vpn_password", "trojan_password", "ss_password", "vmess_uuid",
        "anytls_password",
        "tailscale_auth_key", "auth_key",
    ]

    private static func redactSecrets(_ value: Any) -> Any {
        if var dict = value as? [String: Any] {
            // Subscription 对象（有 lines + url）的 url 是带 token 的机场地址
            let isSubscription = dict["lines"] != nil && dict["url"] != nil
            for (k, v) in dict {
                if secretKeys.contains(k), let s = v as? String, !s.isEmpty {
                    dict[k] = "***"
                } else if k == "url", isSubscription, let s = v as? String, !s.isEmpty {
                    dict[k] = "***"
                } else {
                    dict[k] = redactSecrets(v)
                }
            }
            return dict
        }
        if let arr = value as? [Any] {
            return arr.map { redactSecrets($0) }
        }
        return value
    }

    // MARK: - AX Tree

    private static let secureTextFieldSubrole = "AXSecureTextField"

    /// AX is also a diagnostic surface. AppKit currently protects secure text
    /// fields, but that behavior is not a credential boundary we should depend
    /// on. Refuse the read before asking Accessibility for AXValue so neither
    /// the tree dump nor element lookup can observe a password.
    private static func safeAXValue(
        _ element: AXUIElement,
        subrole: String?
    ) -> CFTypeRef? {
        guard subrole != secureTextFieldSubrole else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func safeAXStringValue(
        _ element: AXUIElement,
        subrole: String?
    ) -> String? {
        guard let value = safeAXValue(element, subrole: subrole) else {
            return nil
        }
        return value as? String
    }

    @MainActor
    private static func buildAXTree(maxDepth: Int) -> [String: Any] {
        let app = AXUIElementCreateApplication(getpid())
        var result: [String: Any] = ["pid": getpid()]

        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
           let windows = ref as? [AXUIElement] {
            result["windows"] = windows.map { dumpAX($0, depth: 0, max: maxDepth) }
        } else {
            result["windows"] = [] as [Any]
        }

        if AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &ref) == .success {
            result["menuBar"] = dumpAX(ref as! AXUIElement, depth: 0, max: min(maxDepth, 5))
        }

        if AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &ref) == .success {
            result["extrasMenuBar"] = dumpAX(ref as! AXUIElement, depth: 0, max: min(maxDepth, 5))
        }

        return result
    }

    private static func dumpAX(_ el: AXUIElement, depth: Int, max maxDepth: Int) -> [String: Any] {
        var d: [String: Any] = [:]

        func str(_ attr: String) -> String? {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
            return ref as? String
        }
        func flag(_ attr: String) -> Bool? {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
            return (ref as? NSNumber)?.boolValue
        }

        if let v = str(kAXRoleAttribute) { d["role"] = v }
        let subrole = str(kAXSubroleAttribute)
        if let subrole { d["subrole"] = subrole }
        if let v = str(kAXTitleAttribute), !v.isEmpty { d["title"] = v }
        if let v = str(kAXDescriptionAttribute), !v.isEmpty { d["description"] = v }
        if let v = str("AXIdentifier"), !v.isEmpty { d["id"] = v }
        if let v = str(kAXRoleDescriptionAttribute), !v.isEmpty { d["roleDesc"] = v }
        if let v = str(kAXHelpAttribute), !v.isEmpty { d["help"] = v }

        if let v = safeAXValue(el, subrole: subrole) {
            if let s = v as? String { d["value"] = s }
            else if let n = v as? NSNumber { d["value"] = n }
            else { d["value"] = "\(v)" }
        }

        if let v = flag(kAXEnabledAttribute), !v { d["enabled"] = false }
        if let v = flag(kAXFocusedAttribute), v { d["focused"] = true }

        var posRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
           posRef != nil, CFGetTypeID(posRef!) == AXValueGetTypeID() {
            var pt = CGPoint.zero
            AXValueGetValue(posRef as! AXValue, .cgPoint, &pt)
            d["x"] = Int(pt.x); d["y"] = Int(pt.y)
        }
        var szRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &szRef) == .success,
           szRef != nil, CFGetTypeID(szRef!) == AXValueGetTypeID() {
            var sz = CGSize.zero
            AXValueGetValue(szRef as! AXValue, .cgSize, &sz)
            d["w"] = Int(sz.width); d["h"] = Int(sz.height)
        }

        if depth < maxDepth {
            var chRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &chRef) == .success,
               let children = chRef as? [AXUIElement], !children.isEmpty {
                d["children"] = children.map { dumpAX($0, depth: depth + 1, max: maxDepth) }
            }
        }

        return d
    }

    // MARK: - Actions

    @MainActor
    private static func settingsWindow() -> NSWindow? {
        NSApp.windows.first { $0.title.contains("设置") || $0.title.contains("Settings") }
    }

    @MainActor
    private static func handleAction(_ body: String) async -> (String, String) {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = obj["action"] as? String else {
            return ("400 Bad Request", json(["error": "missing or invalid 'action'"]))
        }
        guard let state = AppState.current else {
            return ("500 Internal Server Error", json(["error": "AppState unavailable"]))
        }

        switch action {
        case "connect":
            state.connect()
            return ok(["ok": true])
        case "connect-with-failure":
            guard state.canConnect else {
                return ("409 Conflict", json([
                    "error": "XDial is not ready to connect",
                ]))
            }
            guard
                let stage = obj["stage"] as? String,
                state.engine.injectFailureOnNextStart(stage)
            else {
                return ("400 Bad Request", json([
                    "error": "invalid failure stage",
                    "availableStages": [
                        "rule-set",
                        "line",
                        "commit",
                        "post-commit-fatal",
                    ],
                ]))
            }
            state.connect()
            return ok(["ok": true, "stage": stage])
        case "disconnect":
            state.disconnect()
            return ok(["ok": true])
        case "reconnect":
            state.reconnect()
            return ok(["ok": true, "status": state.engine.status])
        case "quit":
            // 先把 HTTP 响应交还调用方，再走 NSApplication 的正常退出委托；
            // make restart 因而能等待 Provider 回滚，而不是直接杀掉宿主。
            appLog("DebugServer: graceful quit requested")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                appLog("DebugServer: invoking NSApplication terminate")
                NSApp.terminate(nil)
            }
            return ok(["ok": true])
        case "prepare-system-extension":
            // 主线程同步轮询会阻塞 OSSystemExtensionRequest 的 main-queue
            // delegate，造成“实际已激活、接口却超时”的假阴性。挂起当前 Task 后，
            // 主线程可以正常接收系统回调。
            let result: DebugSystemExtensionResult =
                await withCheckedContinuation { continuation in
                    let gate = DebugSystemExtensionResultGate(
                        continuation: continuation
                    )
                    state.engine.prepareSystemExtension { result in
                        switch result {
                        case .success:
                            gate.finish(.success)
                        case let .failure(error):
                            gate.finish(.failure(error.localizedDescription))
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
                        gate.finish(.timeout)
                    }
                }
            switch result {
            case .success:
                return ok(["ok": true])
            case let .failure(error):
                return ok(["ok": false, "error": error])
            case .timeout:
                return ok([
                    "ok": false,
                    "error": "system extension activation timed out",
                ])
            }
        case "begin-route-probe":
            guard
                state.engine.status == "connected",
                let report = state.engine.connectionReport,
                report.state == .committed
            else {
                return ("409 Conflict", json([
                    "ok": false,
                    "code": "transparent-proxy-not-connected",
                ]))
            }
            guard
                let rawHost = obj["host"] as? String,
                let host = validatedProbeHost(rawHost)
            else {
                return ("400 Bad Request", json([
                    "ok": false,
                    "code": "invalid-route-probe-host",
                ]))
            }
            if let requestedPort = obj["port"] as? Int,
               requestedPort != 443 {
                return ("400 Bad Request", json([
                    "ok": false,
                    "code": "route-probe-port-must-be-443",
                ]))
            }
            let timeoutMS = obj["timeout_ms"] as? Int ?? 10_000
            guard (500 ... 15_000).contains(timeoutMS) else {
                return ("400 Bad Request", json([
                    "ok": false,
                    "code": "invalid-route-probe-timeout",
                ]))
            }
            let result: Result<ProviderBegunRouteProbe, Error> =
                await withCheckedContinuation { continuation in
                    state.engine.beginRouteProbe(
                        transactionID: report.transactionID,
                        host: host,
                        timeoutMS: timeoutMS
                    ) {
                        continuation.resume(returning: $0)
                    }
                }
            switch result {
            case let .success(begun):
                return ok([
                    "ok": true,
                    "transactionID": report.transactionID,
                    "probeID": begun.probeID,
                ])
            case let .failure(error):
                return ok([
                    "ok": false,
                    "transactionID": report.transactionID,
                    "code": providerDiagnosticsCode(error),
                ])
            }
        case "routing-probe-snapshot":
            guard
                state.engine.status == "connected",
                let report = state.engine.connectionReport,
                report.state == .committed
            else {
                return ("409 Conflict", json([
                    "ok": false,
                    "code": "transparent-proxy-not-connected",
                ]))
            }
            guard
                let rawProbeID = obj["probe_id"] as? String,
                let probeID = validatedProbeID(rawProbeID)
            else {
                return ("400 Bad Request", json([
                    "ok": false,
                    "code": "invalid-route-probe-id",
                ]))
            }
            let result:
                Result<ProviderRoutingProbeSnapshot, Error> =
                await withCheckedContinuation { continuation in
                    state.engine.routingProbeSnapshot(
                        transactionID: report.transactionID,
                        probeID: probeID
                    ) {
                        continuation.resume(returning: $0)
                    }
                }
            switch result {
            case let .success(snapshot):
                return ok([
                    "ok": true,
                    "transactionID": report.transactionID,
                    "probeID": snapshot.probeID,
                    "matchCount": snapshot.matchCount,
                    "candidateAddressCount":
                        snapshot.candidateAddressCount,
                    "outboundTagCounts": snapshot.outboundTagCounts,
                    "lineIDCounts": snapshot.lineIDCounts,
                    "ruleSetTag": snapshot.ruleSetTag ?? "",
                ])
            case let .failure(error):
                return ok([
                    "ok": false,
                    "transactionID": report.transactionID,
                    "code": providerDiagnosticsCode(error),
                ])
            }
        case "select-mode":
            guard let id = obj["id"] as? String else {
                return ("400 Bad Request", json(["error": "missing 'id'"]))
            }
            // 必须走和用户点击完全相同的 intent：直接改 state 会绕开门禁和
            // configDirty 置位，调试验收就会给出"已生效"的假象。
            guard state.activateMode(id) else {
                return ("404 Not Found", json(["error": "no such mode", "id": id]))
            }
            return ok([
                "ok": true,
                "activeModeID": state.profile.activeModeID,
                "configDirty": state.configDirty,
            ])
        case "open-settings":
            NSApp.activate(ignoringOtherApps: true)
            if let w = settingsWindow() {
                w.makeKeyAndOrderFront(nil)
                return ok(["ok": true])
            }
            // 窗口尚未创建：请常驻的菜单栏 label 代为 openWindow。同步等它出现，
            // 好让调用方拿到确定结果而不是自己去轮询。
            NotificationCenter.default.post(name: .xdialDebugOpenSettings, object: nil)
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                if let w = settingsWindow() {
                    w.makeKeyAndOrderFront(nil)
                    return ok(["ok": true])
                }
            }
            return ok(["ok": false, "error": "settings window did not open"])
        case "ax-press":
            return axPress(obj)
        case "ax-set-value":
            return axSetValue(obj)
        case "setup-helper":
            state.setupHelper()
            return ok(["ok": true, "smStatus": PrivilegeManager.status.rawValue])
        case "sm-register":
            do {
                try PrivilegeManager.register()
                state.checkHelper()
                return ok(["ok": true, "smStatus": PrivilegeManager.status.rawValue])
            } catch {
                state.checkHelper()
                return ok([
                    "ok": false,
                    "error": error.localizedDescription,
                    "smStatus": PrivilegeManager.status.rawValue,
                ])
            }
        case "sm-unregister":
            do {
                try PrivilegeManager.unregister()
                state.checkHelper()
                return ok(["ok": true, "smStatus": PrivilegeManager.status.rawValue])
            } catch {
                state.checkHelper()
                return ok([
                    "ok": false,
                    "error": error.localizedDescription,
                    "smStatus": PrivilegeManager.status.rawValue,
                ])
            }
        case "check-helper":
            state.checkHelper()
            return ok([
                "ok": true,
                "smStatus": PrivilegeManager.status.rawValue,
                "installed": state.helperInstalled,
                "needsApproval": state.helperNeedsApproval,
                "legacyInstalled": PrivilegeManager.legacyInstalled,
            ])
        case "daemon-info":
            let info = PrivilegeManager.probeDaemonInfo()
            return ok([
                "ok": info != nil,
                "version": info?.version ?? "",
                "exeSHA256": info?.exeSHA256 ?? "",
                "pid": info?.pid ?? 0,
                "bundledSHA256": PrivilegeManager.bundledDaemonSHA256() ?? "",
            ])
        default:
            return ("400 Bad Request", json(["error": "unknown action: \(action)",
                "available": ["connect", "disconnect", "reconnect", "select-mode", "open-settings",
                              "connect-with-failure",
                              "begin-route-probe", "routing-probe-snapshot",
                              "ax-press", "ax-set-value", "setup-helper", "check-helper",
                              "sm-register", "sm-unregister", "daemon-info"]]))
        }
    }

    @MainActor
    private static func axPress(_ obj: [String: Any]) -> (String, String) {
        guard let title = obj["title"] as? String else {
            return ("400 Bad Request", json(["error": "missing 'title'"]))
        }
        let role = obj["role"] as? String
        let app = AXUIElementCreateApplication(getpid())
        guard let el = findAXElement(root: app, role: role, title: title) else {
            return ("404 Not Found", json(["error": "element not found", "title": title]))
        }
        let r = AXUIElementPerformAction(el, kAXPressAction as CFString)
        if r == .success { return ok(["ok": true]) }
        return ("500 Internal Server Error", json(["error": "AXPress failed", "code": r.rawValue]))
    }

    @MainActor
    private static func axSetValue(_ obj: [String: Any]) -> (String, String) {
        guard let identifier = obj["title"] as? String ?? obj["id"] as? String,
              let value = obj["value"] as? String else {
            return ("400 Bad Request", json(["error": "missing 'title'/'id' or 'value'"]))
        }
        let role = obj["role"] as? String
        let app = AXUIElementCreateApplication(getpid())
        guard let el = findAXElement(root: app, role: role, title: identifier) else {
            return ("404 Not Found", json(["error": "element not found", "title": identifier]))
        }
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, true as CFTypeRef)
        let r = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, value as CFTypeRef)
        if r == .success { return ok(["ok": true]) }
        return ("500 Internal Server Error", json(["error": "set value failed", "code": r.rawValue]))
    }

    // MARK: - AX Search

    private static func findAXElement(root: AXUIElement, role: String?, title: String, maxDepth: Int = 20) -> AXUIElement? {
        func str(_ el: AXUIElement, _ attr: String) -> String? {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
            return ref as? String
        }

        func search(_ el: AXUIElement, depth: Int) -> AXUIElement? {
            if depth > maxDepth { return nil }
            let elRole = str(el, kAXRoleAttribute)
            let subrole = str(el, kAXSubroleAttribute)
            var texts = [
                str(el, kAXTitleAttribute),
                str(el, kAXDescriptionAttribute),
                str(el, kAXRoleDescriptionAttribute),
                subrole,
                str(el, "AXIdentifier"),
                str(el, kAXHelpAttribute),
            ].compactMap { $0 }
            if let value = safeAXStringValue(
                el,
                subrole: subrole
            ) {
                texts.append(value)
            }

            let titleMatch = texts.contains { $0.contains(title) }
            let roleMatch = role == nil || elRole == role

            if titleMatch && roleMatch { return el }

            var chRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &chRef) == .success,
                  let children = chRef as? [AXUIElement] else { return nil }
            for child in children {
                if let found = search(child, depth: depth + 1) { return found }
            }
            return nil
        }

        return search(root, depth: 0)
    }

    // MARK: - HTTP Parsing

    private static func parseHTTP(_ raw: String) -> (method: String, path: String, query: [String: String], body: String, host: String) {
        let headerEnd = raw.range(of: "\r\n\r\n")
        let body = headerEnd.map { String(raw[$0.upperBound...]) } ?? ""
        let headerBlock = headerEnd.map { String(raw[raw.startIndex..<$0.lowerBound]) } ?? raw
        var host = ""
        for line in headerBlock.split(separator: "\r\n").dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "host" {
                host = kv[1].trimmingCharacters(in: .whitespaces)
                break
            }
        }
        let firstLine = String(raw.prefix(while: { $0 != "\r" && $0 != "\n" }))
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return ("GET", "/", [:], body, host) }
        let method = String(parts[0])
        let fullPath = String(parts[1])

        let pathParts = fullPath.split(separator: "?", maxSplits: 1)
        let path = String(pathParts[0])
        var query: [String: String] = [:]
        if pathParts.count > 1 {
            for pair in pathParts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    query[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                } else if kv.count == 1 {
                    query[String(kv[0])] = ""
                }
            }
        }
        return (method, path, query, body, host)
    }

    /// Debug route probe 只接受 ASCII DNS 名；协议、路径、凭据和端口均不属于 host。
    /// Provider 侧仍会再次固定端口 443 并校验当前 transaction。
    private static func validatedProbeHost(_ raw: String) -> String? {
        let host = raw.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        guard !host.isEmpty, host.count <= 253 else { return nil }
        let labels = host.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard !labels.isEmpty else { return nil }
        for label in labels {
            guard
                !label.isEmpty,
                label.count <= 63,
                label.first != "-",
                label.last != "-"
            else {
                return nil
            }
            guard label.unicodeScalars.allSatisfy({
                (0x61 ... 0x7A).contains($0.value)
                    || (0x30 ... 0x39).contains($0.value)
                    || $0.value == 0x2D
            }) else {
                return nil
            }
        }
        return host
    }

    private static func validatedProbeID(_ raw: String) -> String? {
        guard
            raw == raw.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            !raw.isEmpty,
            raw.utf8.count <= 128,
            raw.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
        else {
            return nil
        }
        return raw
    }

    private static func providerDiagnosticsCode(
        _ error: Error
    ) -> String {
        (error as? ProviderDiagnosticsHostError)?.code
            ?? "provider-diagnostics-failed"
    }

    // MARK: - JSON Helpers

    private static func ok(_ dict: [String: Any]) -> (String, String) {
        ("200 OK", json(dict))
    }

    private static func json(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

private enum DebugSystemExtensionResult {
    case success
    case failure(String)
    case timeout
}

@MainActor
private final class DebugSystemExtensionResultGate {
    private var continuation:
        CheckedContinuation<DebugSystemExtensionResult, Never>?

    init(
        continuation:
            CheckedContinuation<DebugSystemExtensionResult, Never>
    ) {
        self.continuation = continuation
    }

    func finish(_ result: DebugSystemExtensionResult) {
        guard let continuation else {
            return
        }
        self.continuation = nil
        continuation.resume(returning: result)
    }
}
#endif
