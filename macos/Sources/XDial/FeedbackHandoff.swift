import AppKit

/// Only native file-bearing URLs are allowed. OS acceptance is not proof that
/// the target application attached or read the file, so report a request only.
@MainActor
enum FeedbackHandoff {
    typealias OpenURLs = ([URL], URL, @escaping (Bool) -> Void) -> Void

    static func open(_ request: FeedbackLaunchRequest, completion: @escaping (FeedbackHandoffResult) -> Void) {
        open(request, using: { urls, application, finished in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: configuration) { app, error in
                Task { @MainActor in finished(app != nil && error == nil) }
            }
        }, completion: completion)
    }

    static func open(_ request: FeedbackLaunchRequest, using openURLs: OpenURLs,
                     completion: @escaping (FeedbackHandoffResult) -> Void) {
        guard request.conversationEntry != .unsupported else {
            completion(.unsupported)
            return
        }
        guard !request.urls.isEmpty, let file = request.file,
              FileManager.default.isReadableFile(atPath: file.path) else {
            completion(.failed)
            return
        }
        openURLs(request.urls, request.applicationURL) { accepted in
            completion(accepted ? .requested : .failed)
        }
    }
}
