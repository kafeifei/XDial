import Foundation

struct LineNetInfo: Codable, Equatable {
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
    @Published private(set) var perLine: [String: LineNetInfo] = [:]
    @Published private(set) var probing: Bool = false

    /// 由 AppState 同步语言
    var language: Lang = .system

    private let clashAPI = "http://127.0.0.1:9090"
    private var probeTask: Task<Void, Never>?

    /// 启动一次完整探测：本地 IP + 每条活动线路的 IP 信息 + 活动订阅主策略组。
    func probeAll(lines: [Line], subscriptions: [Subscription] = [], helperConnected: Bool) {
        probeTask?.cancel()
        localIP = Self.getLocalIP() ?? ""
        appLog("NetworkInfo: localIP=\(localIP) helperConnected=\(helperConnected)")

        probeTask = Task { [weak self] in
            guard let self else { return }
            self.probing = true
            defer { self.probing = false }

            guard helperConnected, await self.waitForClashAPI() else { return }

            for line in lines where line.enabled {
                if Task.isCancelled { return }
                await probeLine(line: line)
            }
            for sub in subscriptions where sub.enabled && !sub.lines.isEmpty {
                if Task.isCancelled { return }
                await probeSub(sub: sub)
            }
        }
    }

    private func probeSub(sub: Subscription) async {
        let mainTag: String
        if let first = sub.proxyGroups.first {
            mainTag = "sub-" + sub.id + "-" + slugify(first.name)
        } else {
            mainTag = "sub-" + sub.id
        }
        appLog("NetworkInfo: probing sub \(sub.name) tag=\(mainTag)")
        perLine[sub.id] = await probe(tag: mainTag)
    }

    private func probeLine(line: Line) async {
        let tag = outboundTag(for: line)
        appLog("NetworkInfo: probing \(line.name) tag=\(tag)")
        perLine[line.id] = await probe(tag: tag)
    }

    private func probe(tag: String) async -> LineNetInfo {
        var info = LineNetInfo()
        info.probedAt = Date()

        guard await switchSelector(to: tag) else {
            info.error = "无法切换出口"
            return info
        }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let result = await fetchIPInfo()
        info.ip = result.ip
        info.region = result.region
        info.error = result.error
        return info
    }

    /// 必须与 Go 端 core/config/generator.go 的 slugify 完全一致。
    private func slugify(_ value: String) -> String {
        var mapped = ""
        mapped.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            let v = scalar.value
            if (v >= 0x61 && v <= 0x7A)
                || (v >= 0x41 && v <= 0x5A)
                || (v >= 0x30 && v <= 0x39) {
                mapped.unicodeScalars.append(scalar)
            } else {
                mapped.append("-")
            }
        }
        let truncated = mapped.count > 16 ? String(mapped.prefix(16)) : mapped
        return truncated.lowercased()
    }

    private func waitForClashAPI() async -> Bool {
        guard let url = URL(string: "\(clashAPI)/proxies/test-out") else { return false }
        for i in 0..<25 {
            if Task.isCancelled { return false }
            var request = URLRequest(url: url)
            request.timeoutInterval = 1
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    appLog("NetworkInfo: Clash API ready after \(i * 200)ms")
                    return true
                }
            } catch {
                // 数据面还没就绪，继续在总预算内轮询。
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        appLog("NetworkInfo: Clash API not ready after 5s")
        return false
    }

    /// PUT /proxies/test-out {"name": tag}
    private func switchSelector(to tag: String) async -> Bool {
        guard let url = URL(string: "\(clashAPI)/proxies/test-out") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3
        guard let body = try? JSONSerialization.data(withJSONObject: ["name": tag]) else {
            return false
        }
        do {
            let (_, response) = try await URLSession.shared.upload(for: request, from: body)
            if let http = response as? HTTPURLResponse {
                appLog("NetworkInfo: selector → \(tag), HTTP \(http.statusCode)")
                return http.statusCode == 204 || http.statusCode == 200
            }
        } catch {
            appLog("NetworkInfo: switchSelector failed: \(error.localizedDescription)")
        }
        return false
    }

    private func fetchIPInfo() async -> (ip: String, region: String, error: String) {
        // 每次新建会话，避免复用切换 selector 前的连接。
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpShouldUsePipelining = false
        configuration.httpMaximumConnectionsPerHost = 1
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let services: [(String, (Data) -> (String, String)?)] = [
            ("https://api.ip.sb/geoip", parseIPSB),
            (
                "http://ip-api.com/json/?lang=\(language.ipAPILang)&fields=status,query,country,regionName,city",
                parseIPAPI
            ),
        ]
        var lastError = "无法获取 IP"
        for (urlString, parser) in services {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            do {
                let (data, _) = try await session.data(for: request)
                if let (ip, region) = parser(data) {
                    return (ip, region, "")
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        return ("", "", lastError)
    }

    private func parseIPAPI(_ data: Data) -> (String, String)? {
        guard let info = try? JSONDecoder().decode(IPAPIResp.self, from: data),
              info.status == "success" else { return nil }
        var parts: [String] = []
        if !info.country.isEmpty { parts.append(info.country) }
        if !info.regionName.isEmpty && info.regionName != info.country {
            parts.append(info.regionName)
        }
        if !info.city.isEmpty && info.city != info.regionName { parts.append(info.city) }
        return (info.query, parts.joined(separator: " "))
    }

    private func parseIPSB(_ data: Data) -> (String, String)? {
        guard let info = try? JSONDecoder().decode(IPSBResp.self, from: data),
              !info.ip.isEmpty else { return nil }
        var parts: [String] = []
        if let country = info.country { parts.append(country) }
        if let region = info.region, region != info.country { parts.append(region) }
        if let city = info.city, city != info.region { parts.append(city) }
        return (info.ip, parts.joined(separator: " "))
    }

    /// 与 Go 侧 resolveOutboundTag 保持一致。
    private func outboundTag(for line: Line) -> String {
        switch line.type {
        case "direct": return "direct"
        case "vpn": return "vpn"
        default: return "proxy-" + line.id
        }
    }

    /// 通过 getifaddrs 获取活跃 IPv4 接口地址（非 loopback / 非 utun）。
    static func getLocalIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr = first
        while true {
            let interface = ptr.pointee
            let flags = Int32(interface.ifa_flags)
            if let addrPtr = interface.ifa_addr {
                let addr = addrPtr.pointee
                if (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
                   (flags & IFF_LOOPBACK) == 0,
                   addr.sa_family == UInt8(AF_INET) {
                    let name = String(cString: interface.ifa_name)
                    if !name.hasPrefix("utun"), !name.hasPrefix("awdl"),
                       !name.hasPrefix("bridge"), !name.hasPrefix("llw"),
                       !name.hasPrefix("anpi") {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        let result = addrPtr.withMemoryRebound(
                            to: sockaddr.self,
                            capacity: 1
                        ) { socketAddress in
                            getnameinfo(
                                socketAddress,
                                socklen_t(addr.sa_len),
                                &hostname,
                                socklen_t(NI_MAXHOST),
                                nil,
                                0,
                                NI_NUMERICHOST
                            )
                        }
                        if result == 0 {
                            let ip = String(cString: hostname)
                            if !ip.isEmpty { return ip }
                        }
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
