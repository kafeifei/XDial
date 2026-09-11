import Foundation

struct AppUpdateFeedRelease: Codable, Equatable, Sendable {
    let tag: String
    let version: String
    let build: String
    let minimumSystemVersion: String
    let publishedAt: Date
    let releaseNotes: String
    let archiveURL: URL
    let archiveSize: Int64
    let archiveSHA256: String
}

struct AppUpdateFeedManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let revision: Int64
    let channel: String
    let generatedAt: Date
    let release: AppUpdateFeedRelease?
}

enum AppUpdateFeedConfigurationError: Error, Equatable {
    case invalidAcceptanceID
}

extension AppUpdateFeedConfigurationError: LocalizedError {
    var errorDescription: String? {
        "XDialUpdateAcceptanceID 必须是 1–80 位字母、数字或连字符。"
    }
}

struct AppUpdateFeedConfiguration: Equatable, Sendable {
    static let acceptanceInfoKey = "XDialUpdateAcceptanceID"
    static let production = AppUpdateFeedConfiguration(
        feedURL: URL(
            string: "https://saymiao.github.io/xdial-updates/stable.json"
        )!,
        archiveOwner: "kafeifei",
        archiveRepository: "XDial",
        cacheNamespace: "production",
        acceptanceID: nil
    )

    let feedURL: URL
    let archiveOwner: String
    let archiveRepository: String
    let cacheNamespace: String
    let acceptanceID: String?

    static func current(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) throws -> AppUpdateFeedConfiguration {
        guard let configuredValue = infoDictionary[acceptanceInfoKey] else {
            return .production
        }
        guard let rawValue = configuredValue as? String else {
            throw AppUpdateFeedConfigurationError.invalidAcceptanceID
        }
        guard !rawValue.isEmpty else { return .production }
        return try acceptance(id: rawValue)
    }

    static func current(
        at bundleURL: URL
    ) throws -> AppUpdateFeedConfiguration {
        guard let infoDictionary = ApplicationBundleInfo.infoDictionary(
            at: bundleURL
        ) else {
            throw AppUpdateFeedConfigurationError.invalidAcceptanceID
        }
        return try current(infoDictionary: infoDictionary)
    }

    static func acceptance(
        id: String
    ) throws -> AppUpdateFeedConfiguration {
        guard permitsAcceptanceID(id),
              let feedURL = URL(
                  string: "https://saymiao.github.io/xdial-updates/"
                      + "acceptance/\(id)/stable.json"
              ) else {
            throw AppUpdateFeedConfigurationError.invalidAcceptanceID
        }
        return AppUpdateFeedConfiguration(
            feedURL: feedURL,
            archiveOwner: "saymiao",
            archiveRepository: "xdial-updates",
            cacheNamespace: "acceptance-\(id)",
            acceptanceID: id
        )
    }

    static func validatedAcceptanceID(_ value: String?) throws -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard permitsAcceptanceID(value) else {
            throw AppUpdateFeedConfigurationError.invalidAcceptanceID
        }
        return value
    }

    func permitsArchiveURL(
        _ url: URL,
        tag: String,
        archiveName: String
    ) -> Bool {
        url.absoluteString
            == "https://github.com/\(archiveOwner)/\(archiveRepository)"
                + "/releases/download/\(tag)/\(archiveName)"
    }

    private static func permitsAcceptanceID(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              value.utf8.count <= 80,
              (48 ... 57).contains(first)
                || (65 ... 90).contains(first)
                || (97 ... 122).contains(first) else {
            return false
        }
        return value.utf8.dropFirst().allSatisfy {
            (48 ... 57).contains($0)
                || (65 ... 90).contains($0)
                || (97 ... 122).contains($0)
                || $0 == 45
        }
    }
}

enum AppUpdateManifestError: Error, Equatable, Sendable {
    case tooLarge
    case malformed
    case unexpectedFields
    case unsupportedSchema
    case invalidRevision
    case invalidChannel
    case invalidGeneratedAt
    case invalidPublishedAt
}

extension AppUpdateManifestError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .tooLarge: "更新清单超过 512 KiB"
        case .malformed: "更新清单不是有效 JSON"
        case .unexpectedFields: "更新清单包含缺失或未定义的字段"
        case .unsupportedSchema: "更新清单版本不受支持"
        case .invalidRevision: "更新清单修订号无效"
        case .invalidChannel: "更新清单通道不是 stable"
        case .invalidGeneratedAt: "更新清单生成时间无效"
        case .invalidPublishedAt: "更新清单发布时间无效"
        }
    }
}

enum AppUpdateManifestParser {
    static let maximumBytes = 512 * 1024

    private static let manifestFields = Set([
        "schemaVersion", "revision", "channel", "generatedAt", "release",
    ])
    private static let releaseFields = Set([
        "tag", "version", "build", "minimumSystemVersion", "publishedAt",
        "releaseNotes", "archiveURL", "archiveSize", "archiveSHA256",
    ])

    static func parse(_ data: Data) throws -> AppUpdateFeedManifest {
        guard data.count <= maximumBytes else {
            throw AppUpdateManifestError.tooLarge
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AppUpdateManifestError.malformed
        }
        guard let dictionary = object as? [String: Any],
              Set(dictionary.keys) == manifestFields else {
            throw AppUpdateManifestError.unexpectedFields
        }
        if let release = dictionary["release"], !(release is NSNull) {
            guard let releaseDictionary = release as? [String: Any],
                  Set(releaseDictionary.keys) == releaseFields else {
                throw AppUpdateManifestError.unexpectedFields
            }
        }

        let wire: WireManifest
        do {
            wire = try JSONDecoder().decode(WireManifest.self, from: data)
        } catch {
            throw AppUpdateManifestError.malformed
        }
        guard wire.schemaVersion == 1 else {
            throw AppUpdateManifestError.unsupportedSchema
        }
        guard wire.revision > 0 else {
            throw AppUpdateManifestError.invalidRevision
        }
        guard wire.channel == "stable" else {
            throw AppUpdateManifestError.invalidChannel
        }
        guard let generatedAt = ISO8601Timestamp.parse(wire.generatedAt) else {
            throw AppUpdateManifestError.invalidGeneratedAt
        }

        let release: AppUpdateFeedRelease?
        if let value = wire.release {
            guard let publishedAt = ISO8601Timestamp.parse(
                value.publishedAt
            ) else {
                throw AppUpdateManifestError.invalidPublishedAt
            }
            release = AppUpdateFeedRelease(
                tag: value.tag,
                version: value.version,
                build: value.build,
                minimumSystemVersion: value.minimumSystemVersion,
                publishedAt: publishedAt,
                releaseNotes: value.releaseNotes,
                archiveURL: value.archiveURL,
                archiveSize: value.archiveSize,
                archiveSHA256: value.archiveSHA256
            )
        } else {
            release = nil
        }
        return AppUpdateFeedManifest(
            schemaVersion: wire.schemaVersion,
            revision: wire.revision,
            channel: wire.channel,
            generatedAt: generatedAt,
            release: release
        )
    }

    private struct WireManifest: Decodable {
        let schemaVersion: Int
        let revision: Int64
        let channel: String
        let generatedAt: String
        let release: WireRelease?
    }

    private struct WireRelease: Decodable {
        let tag: String
        let version: String
        let build: String
        let minimumSystemVersion: String
        let publishedAt: String
        let releaseNotes: String
        let archiveURL: URL
        let archiveSize: Int64
        let archiveSHA256: String
    }
}

private enum ISO8601Timestamp {
    static func parse(_ value: String) -> Date? {
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime],
        ] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

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

    static func boundedURLSession() -> AppUpdateHTTPTransport {
        AppUpdateHTTPTransport { request in
            try await BoundedMetadataRequest.load(
                request,
                maximumBytes: AppUpdateManifestParser.maximumBytes
            )
        }
    }
}

enum AppUpdateMetadataTransportError: Error, Equatable {
    case invalidHTTPResponse
    case redirectRejected
    case responseTooLarge
}

extension AppUpdateMetadataTransportError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse: "更新服务器返回了无法识别的响应"
        case .redirectRejected: "更新清单被重定向到未经允许的地址"
        case .responseTooLarge: "更新清单传输超过 512 KiB"
        }
    }
}

enum AppUpdateReleaseAvailability: Equatable, Sendable {
    case available(AppUpdateReleaseCandidate)
    case upToDate
    case noRelease
}

struct AppUpdateReleaseLookupResult: Equatable, Sendable {
    let availability: AppUpdateReleaseAvailability
    let checkedAt: Date
    let revision: Int64
}

enum AppUpdateReleaseLookupError: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case requestFailed(String)
    case responseURLRejected(String)
    case responseTooLarge
    case httpStatus(Int)
    case rateLimited(until: Date)
    case missingETag
    case notModifiedWithoutCache
    case cacheInvalid
    case manifestInvalid(String)
    case revisionRollback(previous: Int64, received: Int64)
    case revisionConflict(Int64)
    case retryDeferred(until: Date)
}

extension AppUpdateReleaseLookupError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(detail):
            "更新通道配置无效：\(detail)"
        case let .requestFailed(detail):
            "无法访问更新清单：\(detail)"
        case let .responseURLRejected(url):
            "更新清单来自非预期地址：\(url)"
        case .responseTooLarge:
            "更新清单超过 512 KiB"
        case let .httpStatus(status):
            "更新清单服务器返回 HTTP \(status)"
        case let .rateLimited(until):
            "更新检查过于频繁，请在 \(until.formatted()) 后重试"
        case .missingETag:
            "更新清单响应缺少 ETag"
        case .notModifiedWithoutCache:
            "更新清单返回 304，但本机没有有效缓存"
        case .cacheInvalid:
            "本机更新清单缓存无效"
        case let .manifestInvalid(detail):
            "更新清单无效：\(detail)"
        case let .revisionRollback(previous, received):
            "更新清单修订号从 \(previous) 回退到 \(received)"
        case let .revisionConflict(revision):
            "更新清单修订号 \(revision) 对应了不同内容"
        case let .retryDeferred(until):
            "更新检查暂时冷却中，请在 \(until.formatted()) 后重试"
        }
    }
}

actor AppUpdateReleaseLookup {
    private static let requestTimeout: TimeInterval = 8
    private static let maximumClockSkew: TimeInterval = 5 * 60
    private static let cacheKeyPrefix = "xdial.update.pages-cache."

    private let configuration: AppUpdateFeedConfiguration?
    private let configurationError: String?
    private let transport: AppUpdateHTTPTransport
    private let defaults: UserDefaults
    private var retryNotBefore: Date?
    private var consecutiveFailures = 0

    init(
        configuration: AppUpdateFeedConfiguration? = nil,
        transport: AppUpdateHTTPTransport? = nil,
        defaults: UserDefaults = xdialDefaults
    ) {
        if let configuration {
            self.configuration = configuration
            configurationError = nil
        } else {
            do {
                self.configuration = try AppUpdateFeedConfiguration.current()
                configurationError = nil
            } catch {
                self.configuration = nil
                configurationError = error.localizedDescription
            }
        }
        self.transport = transport ?? .boundedURLSession()
        self.defaults = defaults
    }

    func check(
        currentVersion: String,
        currentSystemVersion: String? = nil,
        now: Date = Date()
    ) async throws -> AppUpdateReleaseLookupResult {
        guard let configuration else {
            throw AppUpdateReleaseLookupError.invalidConfiguration(
                configurationError ?? "未知错误"
            )
        }
        if let retryNotBefore, retryNotBefore > now {
            throw AppUpdateReleaseLookupError.retryDeferred(
                until: retryNotBefore
            )
        }

        let currentSystemVersion = currentSystemVersion
            ?? Self.systemVersion()
        let requestCache = loadCache(for: configuration, now: now)
        var request = URLRequest(url: configuration.feedURL)
        request.timeoutInterval = Self.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "no-cache, max-age=0",
            forHTTPHeaderField: "Cache-Control"
        )
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue(
            "XDial/\(currentVersion)",
            forHTTPHeaderField: "User-Agent"
        )
        if let etag = requestCache?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let response: AppUpdateHTTPResult
        do {
            response = try await transport.perform(request)
        } catch {
            try Self.rethrowCancellation(error)
            registerFailure(now: now)
            throw AppUpdateReleaseLookupError.requestFailed(
                error.localizedDescription
            )
        }
        guard response.url == configuration.feedURL else {
            registerFailure(now: now)
            throw AppUpdateReleaseLookupError.responseURLRejected(
                response.url.absoluteString
            )
        }
        guard response.data.count <= AppUpdateManifestParser.maximumBytes else {
            registerFailure(now: now)
            throw AppUpdateReleaseLookupError.responseTooLarge
        }

        switch response.statusCode {
        case 200:
            return try acceptNetworkManifest(
                response,
                configuration: configuration,
                currentVersion: currentVersion,
                currentSystemVersion: currentSystemVersion,
                now: now
            )
        case 304:
            guard let requestCache else {
                registerFailure(now: now)
                throw AppUpdateReleaseLookupError.notModifiedWithoutCache
            }
            guard let cache = loadCache(for: configuration, now: now)
            else {
                registerFailure(now: now)
                throw AppUpdateReleaseLookupError.cacheInvalid
            }
            guard cache.manifest.revision
                    == requestCache.manifest.revision else {
                if cache.manifest.revision
                    > requestCache.manifest.revision {
                    throw AppUpdateReleaseLookupError.revisionRollback(
                        previous: cache.manifest.revision,
                        received: requestCache.manifest.revision
                    )
                }
                registerFailure(now: now)
                throw AppUpdateReleaseLookupError.cacheInvalid
            }
            guard cache.manifestData == requestCache.manifestData else {
                throw AppUpdateReleaseLookupError.revisionConflict(
                    cache.manifest.revision
                )
            }
            do {
                let availability = try releaseAvailability(
                    from: cache.manifest,
                    configuration: configuration,
                    currentVersion: currentVersion,
                    currentSystemVersion: currentSystemVersion
                )
                saveCache(
                    PersistedFeedCache(
                        endpoint: cache.endpoint,
                        etag: cache.etag,
                        manifestData: cache.manifestData,
                        manifest: cache.manifest,
                        validatedAt: now
                    ),
                    for: configuration
                )
                resetFailures()
                return AppUpdateReleaseLookupResult(
                    availability: availability,
                    checkedAt: now,
                    revision: cache.manifest.revision
                )
            } catch {
                clearCache(for: configuration)
                registerFailure(now: now)
                throw AppUpdateReleaseLookupError.cacheInvalid
            }
        case 429:
            let deadline = Self.retryAfterDeadline(
                response.header("Retry-After"),
                now: now
            ) ?? backoffDeadline(now: now)
            registerFailure(until: deadline)
            throw AppUpdateReleaseLookupError.rateLimited(until: deadline)
        default:
            registerFailure(now: now)
            throw AppUpdateReleaseLookupError.httpStatus(
                response.statusCode
            )
        }
    }

    func lastValidatedAt(now: Date = Date()) -> Date? {
        guard let configuration else { return nil }
        return loadCache(for: configuration, now: now)?.validatedAt
    }

    private func acceptNetworkManifest(
        _ response: AppUpdateHTTPResult,
        configuration: AppUpdateFeedConfiguration,
        currentVersion: String,
        currentSystemVersion: String,
        now: Date
    ) throws -> AppUpdateReleaseLookupResult {
        guard let contentType = response.header("Content-Type")?
            .lowercased(), contentType.hasPrefix("application/json") else {
            registerFailure(now: now)
            throw AppUpdateReleaseLookupError.manifestInvalid(
                "Content-Type 不是 application/json"
            )
        }
        guard let etag = Self.validETag(response.header("ETag")) else {
            registerFailure(now: now)
            throw AppUpdateReleaseLookupError.missingETag
        }

        let manifest: AppUpdateFeedManifest
        do {
            manifest = try AppUpdateManifestParser.parse(response.data)
        } catch {
            registerFailure(now: now)
            throw AppUpdateReleaseLookupError.manifestInvalid(
                error.localizedDescription
            )
        }
        guard manifest.generatedAt
                <= now.addingTimeInterval(Self.maximumClockSkew) else {
            registerFailure(now: now)
            throw AppUpdateReleaseLookupError.manifestInvalid(
                AppUpdateManifestError.invalidGeneratedAt
                    .localizedDescription
            )
        }
        if let cache = loadCache(for: configuration, now: now) {
            guard manifest.revision >= cache.manifest.revision else {
                throw AppUpdateReleaseLookupError.revisionRollback(
                    previous: cache.manifest.revision,
                    received: manifest.revision
                )
            }
            guard manifest.revision != cache.manifest.revision
                    || response.data == cache.manifestData else {
                throw AppUpdateReleaseLookupError.revisionConflict(
                    manifest.revision
                )
            }
        }

        let availability: AppUpdateReleaseAvailability
        do {
            availability = try releaseAvailability(
                from: manifest,
                configuration: configuration,
                currentVersion: currentVersion,
                currentSystemVersion: currentSystemVersion
            )
        } catch {
            registerFailure(now: now)
            throw AppUpdateReleaseLookupError.manifestInvalid(
                error.localizedDescription
            )
        }
        saveCache(
            PersistedFeedCache(
                endpoint: configuration.feedURL,
                etag: etag,
                manifestData: response.data,
                manifest: manifest,
                validatedAt: now
            ),
            for: configuration
        )
        resetFailures()
        return AppUpdateReleaseLookupResult(
            availability: availability,
            checkedAt: now,
            revision: manifest.revision
        )
    }

    private func releaseAvailability(
        from manifest: AppUpdateFeedManifest,
        configuration: AppUpdateFeedConfiguration,
        currentVersion: String,
        currentSystemVersion: String
    ) throws -> AppUpdateReleaseAvailability {
        guard let release = manifest.release else { return .noRelease }
        do {
            return .available(
                try AppUpdateReleasePolicy.selectCandidate(
                    from: release,
                    generatedAt: manifest.generatedAt,
                    configuration: configuration,
                    currentVersion: currentVersion,
                    currentSystemVersion: currentSystemVersion
                )
            )
        } catch AppUpdateReleaseSelectionError.notNewer {
            return .upToDate
        } catch AppUpdateReleaseSelectionError.unsupportedSystemVersion {
            return .noRelease
        }
    }

    private func loadCache(
        for configuration: AppUpdateFeedConfiguration,
        now: Date
    ) -> PersistedFeedCache? {
        guard let data = defaults.data(forKey: cacheKey(for: configuration)),
              let record = try? JSONDecoder().decode(
                  PersistedFeedCacheRecord.self,
                  from: data
              ),
              record.endpoint == configuration.feedURL,
              Self.validETag(record.etag) != nil,
              let manifest = try? AppUpdateManifestParser.parse(
                  record.manifestData
              ),
              record.validatedAt
                <= now.addingTimeInterval(Self.maximumClockSkew),
              manifest.generatedAt
                <= now.addingTimeInterval(Self.maximumClockSkew) else {
            defaults.removeObject(forKey: cacheKey(for: configuration))
            return nil
        }
        return PersistedFeedCache(
            endpoint: record.endpoint,
            etag: record.etag,
            manifestData: record.manifestData,
            manifest: manifest,
            validatedAt: record.validatedAt
        )
    }

    private func saveCache(
        _ cache: PersistedFeedCache,
        for configuration: AppUpdateFeedConfiguration
    ) {
        let record = PersistedFeedCacheRecord(
            endpoint: cache.endpoint,
            etag: cache.etag,
            manifestData: cache.manifestData,
            validatedAt: cache.validatedAt
        )
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: cacheKey(for: configuration))
    }

    private func clearCache(
        for configuration: AppUpdateFeedConfiguration
    ) {
        defaults.removeObject(forKey: cacheKey(for: configuration))
    }

    private func cacheKey(
        for configuration: AppUpdateFeedConfiguration
    ) -> String {
        Self.cacheKeyPrefix + configuration.cacheNamespace
    }

    private func backoffDeadline(now: Date) -> Date {
        let exponent = min(consecutiveFailures, 4)
        let delay = min(60 * pow(2, Double(exponent)), 10 * 60)
        return now.addingTimeInterval(delay)
    }

    private func registerFailure(now: Date) {
        registerFailure(until: backoffDeadline(now: now))
    }

    private func registerFailure(until deadline: Date) {
        consecutiveFailures += 1
        retryNotBefore = deadline
    }

    private func resetFailures() {
        consecutiveFailures = 0
        retryNotBefore = nil
    }

    private static func validETag(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 1024,
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return trimmed
    }

    private static func retryAfterDeadline(
        _ value: String?,
        now: Date
    ) -> Date? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        return HTTPDateParser.date(from: value).flatMap {
            $0 > now ? $0 : nil
        }
    }

    private static func systemVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
            + ".\(version.patchVersion)"
    }

    private static func rethrowCancellation(_ error: Error) throws {
        if error is CancellationError { throw error }
        if let urlError = error as? URLError,
           urlError.code == .cancelled {
            throw CancellationError()
        }
    }

    private struct PersistedFeedCache: Equatable {
        let endpoint: URL
        let etag: String
        let manifestData: Data
        let manifest: AppUpdateFeedManifest
        let validatedAt: Date
    }

    private struct PersistedFeedCacheRecord: Codable, Equatable {
        let endpoint: URL
        let etag: String
        let manifestData: Data
        let validatedAt: Date
    }
}

private enum HTTPDateParser {
    static func date(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value)
    }
}

private final class BoundedMetadataRequest: NSObject,
    URLSessionDataDelegate,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let maximumBytes: Int
    private var continuation:
        CheckedContinuation<AppUpdateHTTPResult, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var completed = false

    private init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    static func load(
        _ request: URLRequest,
        maximumBytes: Int
    ) async throws -> AppUpdateHTTPResult {
        let loader = BoundedMetadataRequest(maximumBytes: maximumBytes)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                loader.start(request, continuation: continuation)
            }
        } onCancel: {
            loader.cancel()
        }
    }

    private func start(
        _ request: URLRequest,
        continuation:
            CheckedContinuation<AppUpdateHTTPResult, Error>
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil
        )
        let task = session.dataTask(with: request)
        lock.lock()
        self.continuation = continuation
        self.session = session
        self.task = task
        lock.unlock()
        task.resume()
    }

    private func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        finish(.failure(AppUpdateMetadataTransportError.redirectRejected))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(
                AppUpdateMetadataTransportError.invalidHTTPResponse
            ))
            return
        }
        guard http.expectedContentLength == NSURLSessionTransferSizeUnknown
                || http.expectedContentLength <= Int64(maximumBytes) else {
            completionHandler(.cancel)
            finish(.failure(
                AppUpdateMetadataTransportError.responseTooLarge
            ))
            return
        }
        lock.lock()
        self.response = http
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        guard !completed, self.data.count + data.count <= maximumBytes else {
            lock.unlock()
            dataTask.cancel()
            finish(.failure(
                AppUpdateMetadataTransportError.responseTooLarge
            ))
            return
        }
        self.data.append(data)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
            return
        }
        lock.lock()
        let response = self.response
        let data = self.data
        lock.unlock()
        guard let response, let url = response.url else {
            finish(.failure(
                AppUpdateMetadataTransportError.invalidHTTPResponse
            ))
            return
        }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            headers[String(describing: key)] = String(describing: value)
        }
        finish(.success(AppUpdateHTTPResult(
            data: data,
            statusCode: response.statusCode,
            url: url,
            headers: headers,
            expectedContentLength: response.expectedContentLength
        )))
    }

    private func finish(
        _ result: Result<AppUpdateHTTPResult, Error>
    ) {
        lock.lock()
        guard !completed, let continuation else {
            lock.unlock()
            return
        }
        completed = true
        self.continuation = nil
        task = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        session?.invalidateAndCancel()
        continuation.resume(with: result)
    }
}
