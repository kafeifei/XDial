import AppKit
import Combine
import Foundation

@MainActor
final class AppUpdateChecker: ObservableObject {
    #if DEBUG
    static private(set) weak var current: AppUpdateChecker?
    #endif

    @Published private(set) var phase: AppUpdatePhase = .idle
    @Published private(set) var releaseCandidate:
        AppUpdateReleaseCandidate?
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var failure: AppUpdateFailure?
    @Published private(set) var stagedUpdate: StagedAppUpdate?

    var isUpdateAvailable: Bool { releaseCandidate != nil }
    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .validating:
            true
        default:
            false
        }
    }

    func installPreparedUpdate(
        reconnectScenarioID: String?
    ) {
        guard phase == .ready,
              let candidate = releaseCandidate,
              let stagedUpdate else {
            return
        }
        stopObservingHandoffTermination()
        do {
            try AppUpdateRelaunchIntentStore.write(
                targetVersion: candidate.version,
                reconnectScenarioID: reconnectScenarioID
            )
        } catch {
            failure = AppUpdateFailure(
                code: .validationFailed,
                detail: error.localizedDescription
            )
            phase = .failed
            return
        }
        failure = nil
        phase = .handingOff
        Task { [weak self] in
            guard let self else { return }
            do {
                let application = try await self.launchStagedApplication(
                    stagedUpdate.applicationURL
                )
                self.observeHandoffTermination(of: application)
            } catch {
                AppUpdateRelaunchIntentStore.clear()
                self.failure = AppUpdateFailure(
                    code: .validationFailed,
                    detail: error.localizedDescription
                )
                self.phase = .failed
            }
        }
    }

    private static let pollingInterval: UInt64 = 600_000_000_000
    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/kafeifei/XDial/releases/latest"
    )!

    private var checkInFlight = false
    private var downloadTask: Task<Void, Never>?
    private var handoffTerminationObserver: NSObjectProtocol?

    init() {
        AppUpdateStager.pruneStaleRoots()
        #if DEBUG
        Self.current = self
        #endif
    }

    deinit {
        downloadTask?.cancel()
        if let handoffTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(
                handoffTerminationObserver
            )
        }
    }

    func pollForUpdates() async {
        guard ApplicationRelocator.permitsAutomaticUpdates else { return }
        while !Task.isCancelled {
            await check(manual: false)
            do {
                try await Task.sleep(
                    nanoseconds: Self.pollingInterval
                )
            } catch {
                return
            }
        }
    }

    func checkNow() async {
        await check(manual: true)
    }

    func downloadAndPrepare() {
        guard downloadTask == nil,
              let candidate = releaseCandidate,
              ApplicationRelocator.permitsAutomaticUpdates else {
            return
        }
        if let stagedUpdate {
            AppUpdateStager.discard(stagedUpdate)
            self.stagedUpdate = nil
        }
        downloadProgress = 0
        failure = nil
        phase = .downloading
        downloadTask = Task { [weak self] in
            guard let self else { return }
            await self.runDownload(candidate)
            self.downloadTask = nil
        }
    }

    #if DEBUG
    func injectFakeRelease(
        version: String = "99.0.0",
        notes: String = "- 验证自动更新界面与状态。"
    ) {
        let tag = "v\(version)"
        releaseCandidate = AppUpdateReleaseCandidate(
            tag: tag,
            version: version,
            archiveName: "XDial-\(tag).zip",
            archiveURL: URL(
                string: "https://github.com/kafeifei/XDial/releases/download/\(tag)/XDial-\(tag).zip"
            )!,
            releaseNotes: notes
        )
        failure = nil
        phase = .available
    }

    func clearFakeRelease() {
        if let stagedUpdate {
            AppUpdateStager.discard(stagedUpdate)
        }
        releaseCandidate = nil
        stagedUpdate = nil
        failure = nil
        downloadProgress = 0
        phase = .idle
    }
    #endif

    private func check(manual: Bool) async {
        guard !checkInFlight,
              downloadTask == nil,
              phase != .ready,
              phase != .handingOff,
              ApplicationRelocator.permitsAutomaticUpdates else {
            return
        }
        checkInFlight = true
        let previousCandidate = releaseCandidate
        failure = nil
        phase = .checking
        defer { checkInFlight = false }

        do {
            var request = URLRequest(url: Self.latestReleaseURL)
            request.timeoutInterval = 8
            request.cachePolicy = .reloadRevalidatingCacheData
            request.setValue(
                "application/vnd.github+json",
                forHTTPHeaderField: "Accept"
            )
            request.setValue(
                "XDial/\(currentVersion)",
                forHTTPHeaderField: "User-Agent"
            )

            let (data, response) = try await URLSession.shared.data(
                for: request
            )
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            do {
                releaseCandidate = try AppUpdateReleasePolicy
                    .selectCandidate(
                        from: data,
                        currentVersion: currentVersion
                    )
                phase = .available
            } catch AppUpdateReleaseSelectionError.notNewer {
                releaseCandidate = nil
                phase = .upToDate
            }
        } catch {
            releaseCandidate = previousCandidate
            if previousCandidate != nil {
                phase = .available
            } else if manual {
                failure = AppUpdateFailure(
                    code: .checkUnavailable,
                    detail: error.localizedDescription
                )
                phase = .failed
            } else {
                phase = .idle
                appLog(
                    "update check unavailable: "
                        + error.localizedDescription
                )
            }
        }
    }

    private func runDownload(
        _ candidate: AppUpdateReleaseCandidate
    ) async {
        var stagingRoot: URL?
        do {
            let rootURL = try AppUpdateStager.makeStagingRoot()
            stagingRoot = rootURL
            let archiveURL = AppUpdateStager.archiveURL(in: rootURL)
            let downloader = AppUpdateDownloader()
            _ = try await downloader.download(
                from: candidate.archiveURL,
                to: archiveURL
            ) { progress in
                Task { @MainActor [weak self] in
                    guard self?.phase == .downloading else { return }
                    self?.downloadProgress = progress
                }
            }
            try Task.checkCancellation()
            phase = .validating
            let staged = try await Task.detached {
                try AppUpdateStager.stageArchive(at: archiveURL) {
                    applicationURL in
                    try ApplicationRelocator
                        .validateIncomingUpdateBundle(
                            at: applicationURL,
                            expectedVersion: candidate.version
                        )
                }
            }.value
            stagedUpdate = staged
            downloadProgress = 1
            phase = .ready
        } catch is CancellationError {
            cleanupStagingRoot(stagingRoot)
            phase = releaseCandidate == nil ? .idle : .available
        } catch {
            cleanupStagingRoot(stagingRoot)
            let code: AppUpdateFailureCode = phase == .validating
                ? .validationFailed
                : .downloadFailed
            failure = AppUpdateFailure(
                code: code,
                detail: error.localizedDescription
            )
            phase = .failed
        }
    }

    private func cleanupStagingRoot(_ rootURL: URL?) {
        guard let rootURL,
              FileManager.default.fileExists(atPath: rootURL.path) else {
            return
        }
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func launchStagedApplication(
        _ applicationURL: URL
    ) async throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        ApplicationLaunchPolicy.configure(
            configuration,
            relocationPredecessorProcessIdentifier:
                NSRunningApplication.current.processIdentifier
        )
        return try await withCheckedThrowingContinuation {
            (
                continuation:
                    CheckedContinuation<NSRunningApplication, Error>
            ) in
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            ) { application, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let application {
                    continuation.resume(returning: application)
                } else {
                    continuation.resume(
                        throwing: CocoaError(.executableNotLoadable)
                    )
                }
            }
        }
    }

    private func observeHandoffTermination(
        of application: NSRunningApplication
    ) {
        stopObservingHandoffTermination()
        let processIdentifier = application.processIdentifier
        handoffTerminationObserver = NSWorkspace.shared.notificationCenter
            .addObserver(
                forName:
                    NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let terminated = notification.userInfo?[
                    NSWorkspace.applicationUserInfoKey
                ] as? NSRunningApplication,
                      terminated.processIdentifier == processIdentifier else {
                    return
                }
                Task { @MainActor [weak self] in
                    self?.handleHandoffSuccessorTermination()
                }
            }
        if application.isTerminated {
            handleHandoffSuccessorTermination()
        }
    }

    private func handleHandoffSuccessorTermination() {
        stopObservingHandoffTermination()
        guard phase == .handingOff else { return }
        AppUpdateRelaunchIntentStore.clear()
        failure = AppUpdateFailure(
            code: .validationFailed,
            detail: "新版本安装进程已退出；当前版本仍在运行，"
                + "可以重新下载后再试。"
        )
        phase = .failed
    }

    private func stopObservingHandoffTermination() {
        guard let handoffTerminationObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(
            handoffTerminationObserver
        )
        self.handoffTerminationObserver = nil
    }

    private var currentVersion: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0"
    }
}
