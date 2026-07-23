import Combine
import Foundation
import Libbox

// MARK: - GoEngine (iOS / tvOS)
//
// macOS 版 GoEngine 通过 AF_UNIX socket 跟本地特权 daemon 进程收发 JSON 请求/响应。
// iOS / tvOS 上没有特权进程,VPN 逻辑跑在 NEPacketTunnelProvider 扩展进程里,App 与扩展
// 之间用 NEVPNConnection.sendProviderMessage(_:responseHandler:) 通信;订阅解析不依赖扩展,
// 直接调用 App 进程内的 Libbox。
//
// 这次移植只换「传输层」,不动「协议内容」:
//   - wire 结构体(DaemonResponse / EngineStatus / ParseResult)不变。
//   - 响应分发与状态应用逻辑(handleMessage / handleEvent / applyStatusData)不变。
// 变化的只有:
//   - AF_UNIX socket(fd / DispatchSource / newline framing)全部删除。
//   - PrivilegeManager / ensureHelperAsync 全部删除(tvOS 无特权进程)。
//   - id 关联字典 pendingCallbacks / nextID() / processLines() 删除 ——
//     sendProviderMessage 自带请求-响应配对(每次调用给一个 responseHandler),
//     不再需要手动做消息定界和 ID 匹配。这是本次移植的净简化。
//
// 传输由 `TunnelSession` 抽象注入(见下),真实实现是 NETunnelProviderManager 管理层
// 包一层 NEVPNConnection.sendProviderMessage。GoEngine 不直接依赖 NetworkExtension,
// 便于离线做语法检查与单测。

private struct SubscriptionSendableBox<Value>: @unchecked Sendable {
    let value: Value
}

/// App → 扩展的传输抽象。方法签名对齐真实的
/// `NEVPNConnection.sendProviderMessage(_ messageData: Data, responseHandler: ((Data?) -> Void)?) throws`。
///
/// 真实实现:NETunnelProviderManager 管理层持有 `NETunnelProviderSession`
/// (它是 `NEVPNConnection` 的子类,同时 conform `NETunnelProviderSession` 协议),
/// 转调 `session.sendProviderMessage(_:responseHandler:)` 即可满足此协议。
///
/// - responseHandler 传 nil 表示不关心响应(fire-and-forget)。
/// - 扩展侧对应的是 `NEPacketTunnelProvider.handleAppMessage(_:completionHandler:)`:
///   收到 messageData(一段 JSON 请求),处理后通过 completionHandler 回一段 JSON 响应
///   (即 DaemonResponse 的 JSON 编码)。
@MainActor
protocol TunnelSession: AnyObject {
    func sendProviderMessage(_ messageData: Data, responseHandler: ((Data?) -> Void)?) throws
}

@MainActor
final class GoEngine: ObservableObject, TunnelEngine {
    static let shared = GoEngine()

    /// 传输通道。由 NETunnelProviderManager 管理层注入;未注入(nil)时扩展控制请求会被拒绝,
    /// 语义等价于 macOS 版「socket 不可用」。用 weak 避免与管理层互相强引用。
    weak var session: TunnelSession?

    @Published private(set) var status: String = "disconnected"
    @Published var lastError: String?
    @Published var dataPathSummary: String?
    @Published private(set) var connectedAt: Date?
    var statusPublisher: AnyPublisher<String, Never> { $status.eraseToAnyPublisher() }
    private var automaticReconnectSuppressed = false

    // 订阅解析结果直接用 AppState.swift 里定义的顶层 `ParseResult`(与 macOS 版
    // GoEngine.ParseResult 同构)。parseSubscription 的回调结果可直接喂给
    // AppState.updateSubscription(_:with:),不再需要第二份等价定义。

    var isConnected: Bool { status == "connected" }
    var isBusy: Bool {
        status == "connecting" || status == "checking" ||
        status == "disconnecting" || status == "reconnecting"
    }

    // MARK: - Public API

    func suppressNextAutomaticReconnect() {
        automaticReconnectSuppressed = true
    }

    func consumeAutomaticReconnectPermission() -> Bool {
        let allowed = !automaticReconnectSuppressed
        automaticReconnectSuppressed = false
        return allowed
    }

    func start(profileJSON: String) {
        lastError = nil
        status = "connecting"
        guard session != nil else {
            lastError = "系统隧道不可用(扩展未启动)"
            status = "disconnected"
            return
        }
        sendRequest(cmd: "start", profile: profileJSON)
    }

    func stop() {
        appLog("stop() called, status=\(self.status)")
        guard session != nil else {
            appLog("stop: no session")
            status = "disconnected"
            connectedAt = nil
            return
        }
        status = "disconnecting"
        sendRequest(cmd: "stop") { [weak self] resp in
            if resp.ok != true {
                self?.lastError = resp.message
            }
        }
    }

    func parseSubscription(url: String, content: String = "", format: String = "auto",
                           completion: @escaping (Result<ParseResult, Error>) -> Void) {
        let completionBox = SubscriptionSendableBox(value: completion)
        DispatchQueue.global(qos: .userInitiated).async {
            var parseError: NSError?
            let raw = LibboxParseSubscription(url, content, format, &parseError)

            let result: Result<ParseResult, Error>
            if let parseError {
                result = .failure(parseError)
            } else {
                do {
                    let decoded = try JSONDecoder().decode(ParseResult.self, from: Data(raw.utf8))
                    result = .success(decoded)
                } catch {
                    result = .failure(error)
                }
            }

            let resultBox = SubscriptionSendableBox(value: result)
            DispatchQueue.main.async {
                completionBox.value(resultBox.value)
            }
        }
    }

    func selectSubscriptionMember(
        profileJSON: String,
        subscriptionID: String,
        groupName: String,
        memberName: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        do {
            let catalog = try runtimeSubscriptionCatalog(profileJSON: profileJSON)
            guard let group = catalog.subscriptions
                .first(where: { $0.id == subscriptionID })?.groups
                .first(where: { $0.name == groupName }),
                  let member = group.members.first(where: { $0.name == memberName }) else {
                completion(.failure(TunnelRuntimeError.missingTarget))
                return
            }
            sendRequest(
                cmd: "select-outbound",
                fields: ["group_tag": group.tag, "outbound_tag": member.tag]
            ) { response in
                if response.ok == true {
                    completion(.success(()))
                } else {
                    completion(.failure(TunnelRuntimeError.requestFailed(
                        response.message ?? "Runtime route selection failed."
                    )))
                }
            }
        } catch {
            completion(.failure(error))
        }
    }

    func testSubscriptionNode(
        profileJSON: String,
        subscriptionID: String,
        nodeID: String,
        testURL: String,
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        do {
            let catalog = try runtimeSubscriptionCatalog(profileJSON: profileJSON)
            guard let node = catalog.subscriptions
                .first(where: { $0.id == subscriptionID })?.nodes
                .first(where: { $0.id == nodeID }) else {
                completion(.failure(TunnelRuntimeError.missingTarget))
                return
            }
            sendRequest(
                cmd: "test-outbound",
                fields: ["outbound_tag": node.tag, "test_url": testURL, "timeout_ms": "5000"]
            ) { response in
                guard response.ok == true, let rawDelay = response.data, let delay = Int(rawDelay) else {
                    completion(.failure(TunnelRuntimeError.requestFailed(
                        response.message ?? "Runtime route test failed."
                    )))
                    return
                }
                completion(.success(delay))
            }
        } catch {
            completion(.failure(error))
        }
    }

    func probeSubscriptionNodeAddress(
        profileJSON: String,
        subscriptionID: String,
        nodeID: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        do {
            let catalog = try runtimeSubscriptionCatalog(profileJSON: profileJSON)
            guard let node = catalog.subscriptions
                .first(where: { $0.id == subscriptionID })?.nodes
                .first(where: { $0.id == nodeID }) else {
                completion(.failure(TunnelRuntimeError.missingTarget))
                return
            }
            sendRequest(
                cmd: "probe-outbound-address",
                fields: ["outbound_tag": node.tag, "timeout_ms": "7000"]
            ) { response in
                guard response.ok == true, let address = response.data, !address.isEmpty else {
                    completion(.failure(TunnelRuntimeError.requestFailed(
                        response.message ?? "Runtime route address probe failed."
                    )))
                    return
                }
                completion(.success(address))
            }
        } catch {
            completion(.failure(error))
        }
    }

    func tailscaleStatus(
        endpointTag: String,
        completion: @escaping (Result<TailscaleRuntimeStatus, Error>) -> Void
    ) {
        guard !endpointTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(.failure(TunnelRuntimeError.missingTarget))
            return
        }
        sendRequest(cmd: "tailscale-status", fields: ["endpoint_tag": endpointTag]) { response in
            guard response.ok == true, let rawStatus = response.data,
                  let data = rawStatus.data(using: .utf8) else {
                completion(.failure(TunnelRuntimeError.requestFailed(
                    response.message ?? "Tailscale status request failed."
                )))
                return
            }
            do {
                completion(.success(try JSONDecoder().decode(TailscaleRuntimeStatus.self, from: data)))
            } catch {
                completion(.failure(TunnelRuntimeError.invalidTailscaleStatus))
            }
        }
    }

    private func runtimeSubscriptionCatalog(profileJSON: String) throws -> RuntimeSubscriptionCatalog {
        var catalogError: NSError?
        let raw = LibboxSubscriptionRuntimeCatalog(profileJSON, &catalogError)
        if let catalogError { throw catalogError }
        guard let data = raw.data(using: .utf8),
              let catalog = try? JSONDecoder().decode(RuntimeSubscriptionCatalog.self, from: data) else {
            throw TunnelRuntimeError.invalidCatalog
        }
        return catalog
    }

    func syncStatus() {
        // macOS 版靠 PrivilegeManager.isHelperRunning + openSocket();tvOS 改为看 session 是否可用。
        guard session != nil else {
            // 没有隧道会话时,把状态归位为断开,避免残留 connecting/connected。
            if status != "disconnected" {
                status = "disconnected"
                connectedAt = nil
            }
            return
        }
        sendRequest(cmd: "status") { [weak self] resp in
            if resp.ok == true, let data = resp.data {
                self?.applyStatusData(data)
            }
        }
    }

    /// NETunnelProviderManager 的系统连接状态是移动端 UI 的事实源。
    /// provider message 只补充引擎内部错误，不能替代 connecting/reasserting 等系统状态。
    func applySystemStatus(_ newStatus: String, connectedAt date: Date? = nil) {
        status = newStatus
        switch newStatus {
        case "connected":
            connectedAt = date ?? connectedAt ?? Date()
            lastError = nil
        case "disconnected":
            connectedAt = nil
        default:
            break
        }
    }

    // MARK: - Request sending

    /// 发送一条请求到扩展。原 macOS 版 write(fd,...) + newline framing + pendingCallbacks[id]
    /// 这里全部塌缩成一次 sendProviderMessage 调用 —— 请求/响应由 API 自身配对。
    private func sendRequest(cmd: String, profile: String? = nil, fields: [String: String] = [:],
                             callback: ((DaemonResponse) -> Void)? = nil) {
        guard let session else {
            appLog("sendRequest(\(cmd)): no session")
            let response = DaemonResponse(
                id: nil,
                ok: false,
                message: "连接扩展不可用",
                data: nil,
                event: nil
            )
            if let callback {
                callback(response)
            } else {
                lastError = response.message
            }
            return
        }

        var obj = fields
        obj["cmd"] = cmd
        if let profile { obj["profile"] = profile }

        guard let data = try? JSONSerialization.data(withJSONObject: obj) else {
            appLog("sendRequest(\(cmd)): encode failed")
            return
        }

        do {
            try session.sendProviderMessage(data) { [weak self] respData in
                // responseHandler 可能在非主线程回调,统一切回 MainActor 再动状态。
                Task { @MainActor [weak self] in
                    self?.handleProviderResponse(cmd: cmd, respData: respData, callback: callback)
                }
            }
            appLog("sendRequest(\(cmd)): sent \(data.count) bytes")
        } catch {
            appLog("sendRequest(\(cmd)): sendProviderMessage failed")
            if let callback {
                // 发送本身失败:合成一个失败响应喂回调,语义等价 macOS 版 write 失败后不会有回调
                // (这里比 macOS 更友好,直接告知失败)。
                callback(DaemonResponse(id: nil, ok: false,
                                        message: error.localizedDescription, data: nil, event: nil))
            } else {
                lastError = error.localizedDescription
            }
        }
    }

    /// 解码一条 provider 响应并按原有分发逻辑处理。
    /// - 若带 callback(request/response 配对):把解码后的 DaemonResponse 交给它,
    ///   同时(为兼容响应体里携带的 event/status 字段)也走一遍 handleMessage。
    /// - 若无 callback:纯走 handleMessage(等价 macOS 版扩展主动推来的事件/状态)。
    private func handleProviderResponse(cmd: String, respData: Data?,
                                        callback: ((DaemonResponse) -> Void)?) {
        guard let respData, !respData.isEmpty else {
            appLog("handleProviderResponse(\(cmd)): empty response")
            if let callback {
                callback(DaemonResponse(id: nil, ok: false,
                                        message: "扩展无响应", data: nil, event: nil))
            }
            return
        }
        guard let resp = try? JSONDecoder().decode(DaemonResponse.self, from: respData) else {
            appLog("handleProviderResponse(\(cmd)): decode failed")
            if let callback {
                callback(DaemonResponse(id: nil, ok: false,
                                        message: "响应格式错误", data: nil, event: nil))
            }
            return
        }
        appLog("response(\(cmd)): ok=\(String(describing: resp.ok)) hasData=\(resp.data != nil)")

        if let callback {
            // 请求-响应配对:回调优先。响应里若还夹带 event(如扩展在响应里顺带推 status),
            // 也过一遍事件分发,保持与 macOS 版一致的状态应用。
            callback(resp)
            if resp.event != nil {
                handleMessage(resp)
            }
        } else {
            handleMessage(resp)
        }
    }

    // MARK: - Message handling (原样保留:操作已解码结构体,与传输方式无关)

    private func handleMessage(_ msg: DaemonResponse) {
        if let event = msg.event {
            handleEvent(event: event, data: msg.data)
        } else if let id = msg.id {
            handleResponse(id: id, msg: msg)
        }
    }

    private func handleEvent(event: String, data: String?) {
        appLog("event: \(event) hasData=\(data != nil)")
        switch event {
        case "status":
            if let data {
                applyStatusData(data)
            }
        case "error":
            lastError = data
            if status == "connecting" || status == "disconnecting" {
                sendRequest(cmd: "status") { [weak self] resp in
                    if resp.ok == true, let data = resp.data {
                        self?.applyStatusData(data)
                    }
                }
            }
        default:
            break
        }
    }

    private func handleResponse(id: String, msg: DaemonResponse) {
        // sendProviderMessage 已按调用配对了响应,不再有 id→callback 字典。
        // 保留此方法处理「响应体带 id 但走了无 callback 路径」的边缘情况:仅在失败时冒泡错误。
        appLog("response: id=\(id) ok=\(String(describing: msg.ok)) hasData=\(msg.data != nil)")
        if msg.ok != true {
            lastError = msg.message
        }
    }

    private func applyStatusData(_ dataStr: String) {
        guard let data = dataStr.data(using: .utf8),
              let msg = try? JSONDecoder().decode(EngineStatus.self, from: data) else { return }
        // provider 的 "connected" 只表示 Go/sing-box 已启动，不能证明真实流量可用。
        // 移动端 UI 状态只由 TunnelManager 的系统状态 + 主 App 数据链路探测推进；
        // 这里仅吸收扩展内部错误，避免再次把控制面启动误报为链路已连接。
        if let e = msg.error, !e.isEmpty {
            lastError = e
        }
    }
}

// MARK: - Wire structs (协议内容不变,只是传输方式变)

struct DaemonResponse: Decodable {
    let id: String?
    let ok: Bool?
    let message: String?
    let data: String?
    let event: String?
}

struct EngineStatus: Decodable {
    let status: String
    let mode: String?
    let connectedAt: Int?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case status, mode, error
        case connectedAt = "connected_at"
    }
}

private struct RuntimeSubscriptionCatalog: Decodable {
    let subscriptions: [RuntimeSubscriptionEntry]
}

private struct RuntimeSubscriptionEntry: Decodable {
    let id: String
    let nodes: [RuntimeSubscriptionMember]
    let groups: [RuntimeSubscriptionGroup]
}

private struct RuntimeSubscriptionGroup: Decodable {
    let name: String
    let tag: String
    let members: [RuntimeSubscriptionMember]
}

private struct RuntimeSubscriptionMember: Decodable {
    let id: String?
    let name: String
    let tag: String
}
