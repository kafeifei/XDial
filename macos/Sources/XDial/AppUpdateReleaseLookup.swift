import Foundation

struct AppUpdateHTTPResult: Sendable {
    let data: Data
    let statusCode: Int
    let url: URL
    let headers: [String: String]
    let expectedContentLength: Int64

    init(
        data: Data = Data(),
        statusCode: Int,
        url: URL,
        headers: [String: String] = [:],
        expectedContentLength: Int64 = NSURLSessionTransferSizeUnknown
    ) {
        self.data = data
        self.statusCode = statusCode
        self.url = url
        self.headers = headers.reduce(into: [:]) { result, entry in
            result[entry.key.lowercased()] = entry.value
        }
        self.expectedContentLength = expectedContentLength
    }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

struct AppUpdateHTTPTransport: @unchecked Sendable {
    typealias Handler = @Sendable (
        URLRequest
    ) async throws -> AppUpdateHTTPResult

    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func perform(_ request: URLRequest) async throws
        -> AppUpdateHTTPResult
    {
        try await handler(request)
    }

    static func urlSession(
        _ session: URLSession = .shared
    ) -> AppUpdateHTTPTransport {
        AppUpdateHTTPTransport { request in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  let responseURL = http.url else {
                throw AppUpdateReleaseLookupError.invalidHTTPResponse
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headers[String(describing: key)] = String(
                    describing: value
                )
            }
            return AppUpdateHTTPResult(
                data: data,
                statusCode: http.statusCode,
                url: responseURL,
                headers: headers,
                expectedContentLength: http.expectedContentLength
            )
        }
    }
}

enum AppUpdateReleaseAvailability: Equatable, Sendable {
    case available(AppUpdateReleaseCandidate)
    case upToDate
}

enum AppUpdatePublicFallbackError: Error, Equatable, Sendable {
    case latestRequestFailed(String)
    case latestStatus(Int)
    case latestReleaseURLRejected(String)
    case assetRequestFailed(String)
    case assetStatus(Int)
    case assetURLRejected(String)
    case assetSizeRejected(Int64)
}

enum AppUpdateReleaseLookupError: Error, Equatable, Sendable {
    case invalidHTTPResponse
    case apiRequestFailed(String)
    case apiResponseRejected(String)
    case apiStatus(Int)
    case rateLimitedFallbackFailed(
        statusCode: Int,
        fallback: AppUpdatePublicFallbackError
    )
}

extension AppUpdateReleaseLookupError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse:
            return "更新服务返回了无法识别的响应。"
        case let .apiRequestFailed(detail):
            return "无法访问 GitHub 更新服务：\(detail)"
        case let .apiResponseRejected(url):
            return "GitHub 更新服务返回了非预期地址：\(url)"
        case let .apiStatus(statusCode):
            return "GitHub 更新服务返回 HTTP \(statusCode)。"
        case let .rateLimitedFallbackFailed(statusCode, fallback):
            return "GitHub API 受到速率限制（HTTP \(statusCode)）；"
                + "公开发布页备用检查失败："
                + fallback.localizedDescription
        }
    }
}

extension AppUpdatePublicFallbackError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .latestRequestFailed(detail):
            return "无法访问最新发布页（\(detail)）。"
        case let .latestStatus(statusCode):
            return "最新发布页返回 HTTP \(statusCode)。"
        case .latestReleaseURLRejected:
            return "最新发布页没有指向可信的稳定版本标签。"
        case let .assetRequestFailed(detail):
            return "无法验证发布资源（\(detail)）。"
        case let .assetStatus(statusCode):
            return "发布资源返回 HTTP \(statusCode)。"
        case .assetURLRejected:
            return "发布资源跳转到了不受信任的地址。"
        case let .assetSizeRejected(byteCount):
            return "发布资源大小不合法（\(byteCount) 字节）。"
        }
    }
}

actor AppUpdateReleaseLookup {
    static let apiURL = URL(
        string: "https://api.github.com/repos/kafeifei/XDial/releases/latest"
    )!
    static let publicLatestURL = URL(
        string: "https://github.com/kafeifei/XDial/releases/latest"
    )!

    private static let requestTimeout: TimeInterval = 8
    private static let defaultRateLimitCooldown: TimeInterval = 10 * 60

    private let transport: AppUpdateHTTPTransport
    private var apiCooldownUntil: Date?
    private var rateLimitStatusCode = 403

    init(transport: AppUpdateHTTPTransport = .urlSession()) {
        self.transport = transport
    }

    func check(
        currentVersion: String,
        now: Date = Date()
    ) async throws -> AppUpdateReleaseAvailability {
        if let apiCooldownUntil, apiCooldownUntil > now {
            return try await checkPublicFallback(
                currentVersion: currentVersion,
                rateLimitStatusCode: rateLimitStatusCode
            )
        }

        let response: AppUpdateHTTPResult
        do {
            response = try await transport.perform(
                Self.apiRequest(currentVersion: currentVersion)
            )
        } catch {
            try Self.rethrowCancellation(error)
            throw AppUpdateReleaseLookupError.apiRequestFailed(
                error.localizedDescription
            )
        }
        guard response.url == Self.apiURL else {
            throw AppUpdateReleaseLookupError.apiResponseRejected(
                response.url.absoluteString
            )
        }

        switch response.statusCode {
        case 200:
            apiCooldownUntil = nil
            return try Self.selectAvailability(
                data: response.data,
                currentVersion: currentVersion
            )
        case 403 where Self.isRateLimited(response), 429:
            rateLimitStatusCode = response.statusCode
            apiCooldownUntil = Self.rateLimitDeadline(
                from: response,
                now: now
            )
            return try await checkPublicFallback(
                currentVersion: currentVersion,
                rateLimitStatusCode: response.statusCode
            )
        default:
            throw AppUpdateReleaseLookupError.apiStatus(
                response.statusCode
            )
        }
    }

    private static func isRateLimited(
        _ response: AppUpdateHTTPResult
    ) -> Bool {
        if response.statusCode == 429 {
            return true
        }
        if response.header("X-RateLimit-Remaining")?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "0" {
            return true
        }
        if response.header("Retry-After") != nil {
            return true
        }
        guard let object = try? JSONSerialization.jsonObject(
            with: response.data
        ) as? [String: Any],
              let message = object["message"] as? String else {
            return false
        }
        return message.lowercased().contains("rate limit")
    }

    private func checkPublicFallback(
        currentVersion: String,
        rateLimitStatusCode: Int
    ) async throws -> AppUpdateReleaseAvailability {
        do {
            let latestResponse: AppUpdateHTTPResult
            do {
                latestResponse = try await transport.perform(
                    Self.headRequest(
                        url: Self.publicLatestURL,
                        currentVersion: currentVersion
                    )
                )
            } catch {
                try Self.rethrowCancellation(error)
                throw AppUpdatePublicFallbackError.latestRequestFailed(
                    error.localizedDescription
                )
            }
            guard latestResponse.statusCode == 200 else {
                throw AppUpdatePublicFallbackError.latestStatus(
                    latestResponse.statusCode
                )
            }

            let candidate: AppUpdateReleaseCandidate
            do {
                candidate = try AppUpdateReleasePolicy
                    .selectPublicFallbackCandidate(
                        fromLatestReleaseURL: latestResponse.url,
                        currentVersion: currentVersion
                    )
            } catch AppUpdateReleaseSelectionError.notNewer {
                return .upToDate
            } catch {
                throw AppUpdatePublicFallbackError
                    .latestReleaseURLRejected(
                        latestResponse.url.absoluteString
                    )
            }

            let assetResponse: AppUpdateHTTPResult
            do {
                assetResponse = try await transport.perform(
                    Self.headRequest(
                        url: candidate.archiveURL,
                        currentVersion: currentVersion
                    )
                )
            } catch {
                try Self.rethrowCancellation(error)
                throw AppUpdatePublicFallbackError.assetRequestFailed(
                    error.localizedDescription
                )
            }
            guard assetResponse.statusCode == 200 else {
                throw AppUpdatePublicFallbackError.assetStatus(
                    assetResponse.statusCode
                )
            }
            guard assetResponse.url == candidate.archiveURL
                    || AppUpdateDownloadPolicy.permitsRedirect(
                        to: assetResponse.url
                    ) else {
                throw AppUpdatePublicFallbackError.assetURLRejected(
                    assetResponse.url.absoluteString
                )
            }
            guard AppUpdateDownloadPolicy.permitsResponse(
                statusCode: assetResponse.statusCode,
                expectedByteCount:
                    assetResponse.expectedContentLength
            ) else {
                throw AppUpdatePublicFallbackError.assetSizeRejected(
                    assetResponse.expectedContentLength
                )
            }
            return .available(candidate)
        } catch let fallback as AppUpdatePublicFallbackError {
            throw AppUpdateReleaseLookupError
                .rateLimitedFallbackFailed(
                    statusCode: rateLimitStatusCode,
                    fallback: fallback
                )
        }
    }

    private static func selectAvailability(
        data: Data,
        currentVersion: String
    ) throws -> AppUpdateReleaseAvailability {
        do {
            return .available(
                try AppUpdateReleasePolicy.selectCandidate(
                    from: data,
                    currentVersion: currentVersion
                )
            )
        } catch AppUpdateReleaseSelectionError.notNewer {
            return .upToDate
        }
    }

    private static func apiRequest(
        currentVersion: String
    ) -> URLRequest {
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = requestTimeout
        request.cachePolicy = .reloadRevalidatingCacheData
        request.setValue(
            "application/vnd.github+json",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "XDial/\(currentVersion)",
            forHTTPHeaderField: "User-Agent"
        )
        return request
    }

    private static func headRequest(
        url: URL,
        currentVersion: String
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "XDial/\(currentVersion)",
            forHTTPHeaderField: "User-Agent"
        )
        return request
    }

    private static func rateLimitDeadline(
        from response: AppUpdateHTTPResult,
        now: Date
    ) -> Date {
        var deadlines: [Date] = []
        if let value = response.header("X-RateLimit-Reset"),
           let epoch = TimeInterval(value) {
            deadlines.append(Date(timeIntervalSince1970: epoch))
        }
        if let value = response.header("Retry-After") {
            if let seconds = TimeInterval(value), seconds >= 0 {
                deadlines.append(now.addingTimeInterval(seconds))
            } else if let date = HTTPDateParser.date(from: value) {
                deadlines.append(date)
            }
        }
        return deadlines.filter { $0 > now }.max()
            ?? now.addingTimeInterval(defaultRateLimitCooldown)
    }

    private static func rethrowCancellation(_ error: Error) throws {
        if error is CancellationError {
            throw error
        }
        if let urlError = error as? URLError,
           urlError.code == .cancelled {
            throw CancellationError()
        }
    }
}

private enum HTTPDateParser {
    static func date(from value: String) -> Date? {
        for format in [
            "EEE',' dd MMM yyyy HH':'mm':'ss z",
            "EEEE',' dd-MMM-yy HH':'mm':'ss z",
            "EEE MMM d HH':'mm':'ss yyyy",
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }
}
