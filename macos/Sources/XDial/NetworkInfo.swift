import Foundation

struct PortNetInfo: Codable, Equatable {
    var ip: String = ""
    var region: String = ""
    var probedAt: Date?
    var error: String = ""

    var summary: String {
        if !ip.isEmpty {
            let r = region.isEmpty ? "" : " (\(region))"
            return "\(ip)\(r)"
        }
        if !error.isEmpty { return error }
        return ""
    }
}

@MainActor
final class NetworkInfo: ObservableObject {
    static let shared = NetworkInfo()

    @Published private(set) var localIP: String = ""
    @Published private(set) var perPort: [String: PortNetInfo] = [:]
    @Published private(set) var probing: Bool = false

    /// 由 AppState 同步语言
    var language: Lang = .system

    private let clashAPI = "http://127.0.0.1:9090"
    private var probeTask: Task<Void, Never>?

    /// 启动一次完整探测：本地 IP + 每个出口的 IP 信息
    func probeAll(ports: [Port], helperConnected: Bool) {
        probeTask?.cancel()
        localIP = Self.getLocalIP() ?? ""
        appLog("NetworkInfo: localIP=\(localIP) helperConnected=\(helperConnected)")

        probeTask = Task { [weak self] in
            guard let self else { return }
            await MainActor.run { self.probing = true }
            defer { Task { @MainActor in self.probing = false } }

            // 连接时先等 Clash API 就绪
            if helperConnected {
                _ = await self.waitForClashAPI()
            }

            for port in ports where port.enabled {
                if Task.isCancelled { return }
                let canProbe = (port.type == "direct") || helperConnected
                if !canProbe { continue }
                await probePort(port: port, helperConnected: helperConnected)
            }
        }
    }

    /// 轮询 Clash API 直到就绪（最多 5 秒）
    private func waitForClashAPI() async -> Bool {
        guard let url = URL(string: "\(clashAPI)/proxies/test-out") else { return false }
        for i in 0..<25 {
            if Task.isCancelled { return false }
            var req = URLRequest(url: url)
            req.timeoutInterval = 1
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    appLog("NetworkInfo: Clash API ready after \(i * 200)ms")
                    return true
                }
            } catch {
                // 没起来，等等再试
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        appLog("NetworkInfo: Clash API not ready after 5s")
        return false
    }

    private func probePort(port: Port, helperConnected: Bool) async {
        let tag = outboundTag(for: port)
        appLog("NetworkInfo: probing \(port.name) tag=\(tag)")

        // 通过 Clash API 切 selector 到目标出口（仅连接时）
        if helperConnected {
            let ok = await switchSelector(to: tag)
            if !ok {
                await MainActor.run {
                    var info = self.perPort[port.id] ?? PortNetInfo()
                    info.error = "无法切换出口"
                    info.probedAt = Date()
                    self.perPort[port.id] = info
                }
                return
            }
            // selector 切换后稍等一下，让连接生效
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        let r = await fetchIPInfo()
        await MainActor.run {
            var info = PortNetInfo()
            info.probedAt = Date()
            info.ip = r.ip
            info.region = r.region
            info.error = r.error
            self.perPort[port.id] = info
        }
    }

    /// PUT /proxies/test-out {"name": tag}
    private func switchSelector(to tag: String) async -> Bool {
        guard let url = URL(string: "\(clashAPI)/proxies/test-out") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 3
        guard let body = try? JSONSerialization.data(withJSONObject: ["name": tag]) else { return false }
        do {
            let (_, resp) = try await URLSession.shared.upload(for: req, from: body)
            if let http = resp as? HTTPURLResponse {
                appLog("NetworkInfo: selector → \(tag), HTTP \(http.statusCode)")
                return http.statusCode == 204 || http.statusCode == 200
            }
        } catch {
            appLog("NetworkInfo: switchSelector failed: \(error.localizedDescription)")
        }
        return false
    }

    private func fetchIPInfo() async -> (ip: String, region: String, error: String) {
        // 每次新建 URLSession 避免连接复用（确保走当前 selector 选中的出口）
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.urlCache = nil
        cfg.httpShouldUsePipelining = false
        cfg.httpMaximumConnectionsPerHost = 1
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }

        let services: [(String, (Data) -> (String, String)?)] = [
            ("https://api.ip.sb/geoip", parseIPSB),
            ("http://ip-api.com/json/?lang=\(language.ipAPILang)&fields=status,query,country,regionName,city", parseIPAPI),
        ]
        var lastErr = "无法获取 IP"
        for (urlStr, parser) in services {
            guard let url = URL(string: urlStr) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 6
            req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            appLog("NetworkInfo: GET \(urlStr)")
            do {
                let (data, _) = try await session.data(for: req)
                if let (ip, region) = parser(data) {
                    appLog("NetworkInfo: got ip=\(ip) region=\(region)")
                    return (ip, region, "")
                }
                appLog("NetworkInfo: parse failed for \(urlStr)")
            } catch {
                appLog("NetworkInfo: \(urlStr) failed: \(error.localizedDescription)")
                lastErr = error.localizedDescription
                continue
            }
        }
        return ("", "", lastErr)
    }

    private func parseIPAPI(_ data: Data) -> (String, String)? {
        guard let info = try? JSONDecoder().decode(IPAPIResp.self, from: data),
              info.status == "success" else { return nil }
        var parts: [String] = []
        if !info.country.isEmpty { parts.append(info.country) }
        if !info.regionName.isEmpty && info.regionName != info.country { parts.append(info.regionName) }
        if !info.city.isEmpty && info.city != info.regionName { parts.append(info.city) }
        return (info.query, parts.joined(separator: " "))
    }

    private func parseIPSB(_ data: Data) -> (String, String)? {
        guard let info = try? JSONDecoder().decode(IPSBResp.self, from: data),
              !info.ip.isEmpty else { return nil }
        var parts: [String] = []
        if let c = info.country { parts.append(c) }
        if let r = info.region, info.region != info.country { parts.append(r) }
        if let city = info.city, info.city != info.region { parts.append(city) }
        return (info.ip, parts.joined(separator: " "))
    }

    /// 与 Go 侧 resolveOutboundTag 保持一致
    private func outboundTag(for port: Port) -> String {
        switch port.type {
        case "direct": return "direct"
        case "vpn": return "vpn"
        default: return "proxy-" + port.id
        }
    }

    /// 通过 getifaddrs 获取活跃 IPv4 接口地址（非 loopback / 非 utun）
    static func getLocalIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr = first
        while true {
            let interface = ptr.pointee
            let flags = Int32(interface.ifa_flags)
            let addr = interface.ifa_addr.pointee
            if (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
               (flags & IFF_LOOPBACK) == 0,
               addr.sa_family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if !name.hasPrefix("utun"), !name.hasPrefix("awdl"),
                   !name.hasPrefix("bridge"), !name.hasPrefix("llw"),
                   !name.hasPrefix("anpi") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let s = withUnsafePointer(to: interface.ifa_addr.pointee) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            getnameinfo(sa, socklen_t(interface.ifa_addr.pointee.sa_len),
                                        &hostname, socklen_t(NI_MAXHOST),
                                        nil, 0, NI_NUMERICHOST)
                        }
                    }
                    if s == 0 {
                        let ip = String(cString: hostname)
                        if !ip.isEmpty { return ip }
                    }
                }
            }
            if let next = interface.ifa_next {
                ptr = next
            } else {
                break
            }
        }
        return nil
    }
}

private struct IPAPIResp: Decodable {
    let status: String
    let query: String
    let country: String
    let regionName: String
    let city: String
}

private struct IPSBResp: Decodable {
    let ip: String
    let country: String?
    let region: String?
    let city: String?
}
