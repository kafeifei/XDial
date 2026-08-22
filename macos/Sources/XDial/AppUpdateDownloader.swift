import Foundation

enum AppUpdateDownloadError: LocalizedError {
    case redirectRejected
    case responseRejected
    case archiveTooLarge
    case downloadMissing
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .redirectRejected:
            "更新下载被重定向到未经允许的服务器"
        case .responseRejected:
            "更新服务器返回了无效响应"
        case .archiveTooLarge:
            "更新包超过 512 MiB"
        case .downloadMissing:
            "更新下载完成后没有找到文件"
        case .alreadyRunning:
            "更新下载已经在进行中"
        }
    }
}

final class AppUpdateDownloader: NSObject,
    URLSessionDownloadDelegate,
    @unchecked Sendable
{
    typealias ProgressHandler = @Sendable (Double) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var destinationURL: URL?
    private var progressHandler: ProgressHandler?
    private var completed = false

    func download(
        from url: URL,
        to destinationURL: URL,
        progress: @escaping ProgressHandler
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard self.continuation == nil else {
                lock.unlock()
                continuation.resume(
                    throwing: AppUpdateDownloadError.alreadyRunning
                )
                return
            }
            self.continuation = continuation
            self.destinationURL = destinationURL
            progressHandler = progress
            completed = false
            lock.unlock()

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 15 * 60
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: nil
            )
            lock.lock()
            self.session = session
            lock.unlock()
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              AppUpdateDownloadPolicy.permitsRedirect(to: url) else {
            completionHandler(nil)
            finish(.failure(AppUpdateDownloadError.redirectRejected))
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard AppUpdateDownloadPolicy.permitsProgress(
            totalBytesWritten: totalBytesWritten,
            totalBytesExpectedToWrite: totalBytesExpectedToWrite
        ) else {
            downloadTask.cancel()
            finish(.failure(AppUpdateDownloadError.archiveTooLarge))
            return
        }
        guard totalBytesExpectedToWrite > 0 else { return }
        let value = min(
            1,
            Double(totalBytesWritten)
                / Double(totalBytesExpectedToWrite)
        )
        lock.lock()
        let handler = progressHandler
        lock.unlock()
        handler?(value)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let response = downloadTask.response as? HTTPURLResponse,
              AppUpdateDownloadPolicy.permitsResponse(
                  statusCode: response.statusCode,
                  expectedByteCount: response.expectedContentLength
              ) else {
            finish(.failure(AppUpdateDownloadError.responseRejected))
            return
        }
        lock.lock()
        let destinationURL = self.destinationURL
        lock.unlock()
        guard let destinationURL else {
            finish(.failure(AppUpdateDownloadError.downloadMissing))
            return
        }
        do {
            let values = try location.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            )
            guard values.isRegularFile == true,
                  AppUpdateArchivePolicy.permitsArchiveByteCount(
                      Int64(values.fileSize ?? 0)
                  ) else {
                finish(.failure(AppUpdateDownloadError.archiveTooLarge))
                return
            }
            try FileManager.default.moveItem(
                at: location,
                to: destinationURL
            )
            finish(.success(destinationURL))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard !completed, let continuation else {
            lock.unlock()
            return
        }
        completed = true
        self.continuation = nil
        destinationURL = nil
        progressHandler = nil
        let activeSession = session
        session = nil
        lock.unlock()

        activeSession?.invalidateAndCancel()
        continuation.resume(with: result)
    }
}
