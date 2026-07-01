import Combine
import Foundation

// MARK: - GoEngine (tvOS)
//
// macOS 版 GoEngine 通过 AF_UNIX socket 跟本地特权 daemon 进程收发 JSON 请求/响应。
// tvOS 上没有特权进程,VPN 逻辑跑在 NEPacketTunnelProvider 扩展进程里,App 与扩展
// 之间用 NEVPNConnection.sendProviderMessage(_:responseHandler:) 通信。
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

    /// 传输通道。由 NETunnelProviderManager 管理层注入;未注入(nil)时所有请求都被拒绝,
    /// 语义等价于 macOS 版「socket 不可用」。用 weak 避免与管理层互相强引用。
    weak var session: TunnelSession?

    @Published private(set) var status: String = "disconnected"
    @Published var lastError: String?
    @Published private(set) var connectedAt: Date?

    // 订阅解析结果直接用 AppState.swift 里定义的顶层 `ParseResult`(与 macOS 版
    // GoEngine.ParseResult 同构)。parseSubscription 的回调结果可直接喂给
    // AppState.updateSubscription(_:with:),不再需要第二份等价定义。

    var isConnected: Bool { status == "connected" }
    var isBusy: Bool { status == "connecting" || status == "disconnecting" || status == "reconnecting" }

    // MARK: - Public API

    func start(profileJSON: String) {
        lastError = nil
        status = "connecting"
        guard session != nil else {
            lastError = "VPN 隧道不可用(扩展未启动)"
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
        sendRequest(cmd: "stop") { [weak self] resp in
            if resp.ok != true {
                self?.lastError = resp.message
            }
        }
    }

    func parseSubscription(url: String, content: String = "", format: String = "auto",
                           completion: @escaping (Result<ParseResult, Error>) -> Void) {
        guard session != nil else {
            completion(.failure(NSError(domain: "XDial", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "隧道不可用,无法解析订阅"])))
            return
        }
        sendSubRequest(url: url, content: content, format: format, completion: completion)
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

    // MARK: - Request sending

    /// 发送一条请求到扩展。原 macOS 版 write(fd,...) + newline framing + pendingCallbacks[id]
    /// 这里全部塌缩成一次 sendProviderMessage 调用 —— 请求/响应由 API 自身配对。
    private func sendRequest(cmd: String, profile: String? = nil,
                             callback: ((DaemonResponse) -> Void)? = nil) {
        guard let session else {
            appLog("sendRequest(\(cmd)): no session")
            return
        }

        var obj: [String: String] = ["cmd": cmd]
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
            appLog("sendRequest(\(cmd)): sendProviderMessage threw \(error.localizedDescription)")
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

    private func sendSubRequest(url: String, content: String, format: String,
                                completion: @escaping (Result<ParseResult, Error>) -> Void) {
        guard let session else {
            completion(.failure(NSError(domain: "XDial", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "隧道不可用"])))
            return
        }
        var obj: [String: String] = [
            "cmd": "parse-sub",
            "sub_url": url,
            "sub_format": format,
        ]
        if !content.isEmpty {
            obj["sub_content"] = content
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else {
            completion(.failure(NSError(domain: "XDial", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "请求编码失败"])))
            return
        }

        let decodeAndComplete: (DaemonResponse) -> Void = { resp in
            if resp.ok == true, let raw = resp.data?.data(using: .utf8),
               let result = try? JSONDecoder().decode(ParseResult.self, from: raw) {
                completion(.success(result))
            } else {
                let msg = resp.message ?? "parse failed"
                completion(.failure(NSError(domain: "XDial", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: msg])))
            }
        }

        do {
            try session.sendProviderMessage(data) { respData in
                Task { @MainActor in
                    guard let respData,
                          let resp = try? JSONDecoder().decode(DaemonResponse.self, from: respData) else {
                        completion(.failure(NSError(domain: "XDial", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "扩展无响应或响应格式错误"])))
                        return
                    }
                    decodeAndComplete(resp)
                }
            }
        } catch {
            completion(.failure(error))
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
        appLog("response(\(cmd)): ok=\(String(describing: resp.ok)) data=\(resp.data ?? "")")

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
        appLog("event: \(event) data=\(data ?? "")")
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
        appLog("response: id=\(id) ok=\(String(describing: msg.ok)) data=\(msg.data ?? "")")
        if msg.ok != true {
            lastError = msg.message
        }
    }

    private func applyStatusData(_ dataStr: String) {
        guard let data = dataStr.data(using: .utf8),
              let msg = try? JSONDecoder().decode(EngineStatus.self, from: data) else { return }
        let old = status
        status = msg.status
        if msg.status == "connected" && old != "connected" {
            connectedAt = Date()
            lastError = nil
        } else if msg.status == "disconnected" {
            connectedAt = nil
        }
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
