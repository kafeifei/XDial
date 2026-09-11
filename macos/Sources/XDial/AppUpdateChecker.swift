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
    @Published private(set) var lastCheckedAt: Date?
    #if XDIAL_TESTING
    private(set) var launchAttemptCount = 0
    #endif

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
        guard handoffTask == nil,
              phase == .ready,
              let candidate = releaseCandidate,
              let stagedUpdate else {
            return
        }
        failure = nil
        phase = .checking
        handoffTask = Task { [weak self] in
            guard let self else { return }
            guard let freshCandidate = await self.revalidate(
                candidate,
                preserving: .ready
            ), self.stagedUpdate == stagedUpdate else {
                self.handoffTask = nil
                return
            }
            do {
                self.releaseCandidate = freshCandidate
                try AppUpdateRelaunchIntentStore.write(
                    targetVersion: freshCandidate.version,
                    reconnectScenarioID: reconnectScenarioID
                )
                self.stopObservingHandoffTermination()
                self.phase = .handingOff
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
            self.handoffTask = nil
        }
    }

    private static let pollingInterval: UInt64 = 600_000_000_000
    private static let manualCheckCooldown: TimeInterval = 5

    private let releaseLookup: AppUpdateReleaseLookup
    private let automaticUpdatesPermitted: @MainActor () -> Bool
    private var checkInFlight = false
    private var downloadTask: Task<Void, Never>?
    private var handoffTask: Task<Void, Never>?
    private var cacheRestoreTask: Task<Void, Never>?
    private var handoffTerminationObserver: NSObjectProtocol?
    private var lastManualCheckStartedAt: Date?

    init(
        releaseLookup: AppUpdateReleaseLookup = AppUpdateReleaseLookup(),
        automaticUpdatesPermitted:
            @escaping @MainActor () -> Bool = {
                ApplicationRelocator.permitsAutomaticUpdates
            },
        pruneStaleStaging:
            @escaping @MainActor () -> Void = {
                AppUpdateStager.pruneStaleRoots()
            }
    ) {
        self.releaseLookup = releaseLookup
        self.automaticUpdatesPermitted = automaticUpdatesPermitted
        pruneStaleStaging()
        cacheRestoreTask = Task { [weak self, releaseLookup] in
            guard let validatedAt = await releaseLookup.lastValidatedAt(),
                  let self else { return }
            if let lastCheckedAt = self.lastCheckedAt,
               lastCheckedAt >= validatedAt {
                return
            }
            self.lastCheckedAt = validatedAt
        }
        #if DEBUG
        Self.current = self
        #endif
    }

    deinit {
        downloadTask?.cancel()
        handoffTask?.cancel()
        cacheRestoreTask?.cancel()
        if let handoffTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(
                handoffTerminationObserver
            )
        }
    }

    func pollForUpdates() async {
        guard automaticUpdatesPermitted() else { return }
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
        let now = Date()
        if let lastManualCheckStartedAt,
           now.timeIntervalSince(lastManualCheckStartedAt)
            < Self.manualCheckCooldown {
            return
        }
        lastManualCheckStartedAt = now
        await check(manual: true)
    }

    func downloadAndPrepare() {
        guard downloadTask == nil,
              let candidate = releaseCandidate,
              automaticUpdatesPermitted() else {
            return
        }
        failure = nil
        phase = .checking
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
            build: "9999999999",
            minimumSystemVersion: "15.0",
            publishedAt: Date(),
            archiveName: "XDial-\(tag).zip",
            archiveURL: URL(
                string: "https://github.com/kafeifei/XDial/releases/download/\(tag)/XDial-\(tag).zip"
            )!,
            archiveSize: 1,
            archiveSHA256: String(repeating: "0", count: 64),
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
              handoffTask == nil,
              phase != .ready,
              phase != .handingOff,
              automaticUpdatesPermitted() else {
            return
        }
        checkInFlight = true
        let previousCandidate = releaseCandidate
        failure = nil
        phase = .checking
        defer { checkInFlight = false }

        do {
            let result = try await releaseLookup.check(
                currentVersion: currentVersion
            )
            lastCheckedAt = result.checkedAt
            switch result.availability {
            case let .available(candidate):
                releaseCandidate = candidate
                phase = .available
            case .upToDate:
                releaseCandidate = nil
                phase = .upToDate
            case .noRelease:
                releaseCandidate = nil
                phase = .noRelease
            }
        } catch is CancellationError {
            releaseCandidate = previousCandidate
            phase = previousCandidate == nil ? .idle : .available
        } catch {
            releaseCandidate = previousCandidate
            failure = AppUpdateFailure(
                code: .checkUnavailable,
                detail: error.localizedDescription
            )
            phase = previousCandidate == nil ? .failed : .available
            if !manual {
                NSLog(
                    "XDial update check unavailable: %@",
                    error.localizedDescription
                )
            }
        }
    }

    private func runDownload(
        _ candidate: AppUpdateReleaseCandidate
    ) async {
        var stagingRoot: URL?
        guard let candidate = await revalidate(
            candidate,
            preserving: .available
        ) else { return }
        do {
            if let stagedUpdate {
                AppUpdateStager.discard(stagedUpdate)
                self.stagedUpdate = nil
            }
            releaseCandidate = candidate
            downloadProgress = 0
            failure = nil
            phase = .downloading
            let rootURL = try AppUpdateStager.makeStagingRoot()
            stagingRoot = rootURL
            let archiveURL = AppUpdateStager.archiveURL(in: rootURL)
            let downloader = AppUpdateDownloader()
            _ = try await downloader.download(
                from: candidate.archiveURL,
                to: archiveURL,
                expectedSize: candidate.archiveSize,
                expectedSHA256: candidate.archiveSHA256
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
                            expectedVersion: candidate.version,
                            expectedBuild: candidate.build
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

    private func revalidate(
        _ expected: AppUpdateReleaseCandidate,
        preserving phaseOnFailure: AppUpdatePhase
    ) async -> AppUpdateReleaseCandidate? {
        do {
            let result = try await releaseLookup.check(
                currentVersion: currentVersion
            )
            lastCheckedAt = result.checkedAt
            switch result.availability {
            case let .available(candidate)
                where candidate.identity == expected.identity:
                return candidate
            case let .available(candidate):
                discardPreparedUpdate()
                releaseCandidate = candidate
                failure = AppUpdateFailure(
                    code: .candidateChanged,
                    detail: "发布清单已更改，请确认新版本后重试。"
                )
                phase = .available
            case .upToDate, .noRelease:
                discardPreparedUpdate()
                releaseCandidate = nil
                failure = AppUpdateFailure(
                    code: .candidateChanged,
                    detail: "这个更新已被撤回或不再适用于当前版本，请重新检查。"
                )
                phase = .failed
            }
        } catch is CancellationError {
            phase = phaseOnFailure
        } catch {
            releaseCandidate = expected
            failure = AppUpdateFailure(
                code: .checkUnavailable,
                detail: "无法重新确认更新：\(error.localizedDescription)"
            )
            phase = phaseOnFailure
        }
        return nil
    }

    private func discardPreparedUpdate() {
        if let stagedUpdate {
            AppUpdateStager.discard(stagedUpdate)
        }
        stagedUpdate = nil
        downloadProgress = 0
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
        #if XDIAL_TESTING
        launchAttemptCount += 1
        #endif
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

    #if XDIAL_TESTING
    func configureForTesting(
        candidate: AppUpdateReleaseCandidate,
        stagedUpdate: StagedAppUpdate? = nil,
        phase: AppUpdatePhase
    ) {
        releaseCandidate = candidate
        self.stagedUpdate = stagedUpdate
        self.phase = phase
        failure = nil
        lastCheckedAt = nil
        launchAttemptCount = 0
    }

    func waitForTasksForTesting() async {
        if let task = cacheRestoreTask { await task.value }
        while let task = downloadTask { await task.value }
        while let task = handoffTask { await task.value }
    }
    #endif
}
