import AppKit
import Combine

struct FeedbackAssistant: Identifiable, Equatable {
    let id: String
    let name: String
    let applicationURL: URL
    var conversationEntry: ConversationEntry = .unsupported

    enum ConversationEntry: Equatable {
        case unsupported, claudeCowork
    }

    // Bundle identities, not filenames: apps may be renamed or installed in
    // ~/Applications. Only interactive assistants belong in this list.
    static let catalog: [(id: String, fallback: String)] = [
        ("com.xd.cindy", "Cindy"),
        ("com.openai.codex", "Codex"),
        ("com.openai.chat", "ChatGPT"),
        ("com.anthropic.claudefordesktop", "Claude"),
        ("com.todesktop.230313mzl4w4u92", "Cursor"),
        ("com.google.antigravity", "Antigravity"),
        ("ai.opencode.desktop", "OpenCode"),
    ]

    static func discover(resolve: (String) -> URL? = NSWorkspace.shared.urlForApplication(withBundleIdentifier:)) -> [Self] {
        catalog.compactMap { item in
            guard let url = resolve(item.id),
                  FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/MacOS").path),
                  let bundle = Bundle(url: url), bundle.bundleIdentifier == item.id,
                  let executable = bundle.executableURL,
                  FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? item.fallback
            let protocols = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
            let schemes = protocols.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
            // Opening a workspace or prefilling text is not file attachment.
            // https://support.claude.com/en/articles/14729294-open-claude-desktop-with-a-link
            let entry: ConversationEntry = item.id == "com.anthropic.claudefordesktop" && schemes.contains("claude")
                ? .claudeCowork : .unsupported
            return Self(id: item.id, name: name, applicationURL: url, conversationEntry: entry)
        }
    }

    func launchRequest(file: URL) -> FeedbackLaunchRequest {
        guard conversationEntry == .claudeCowork else {
            return FeedbackLaunchRequest(applicationURL: applicationURL, urls: [], conversationEntry: .unsupported, file: file)
        }
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "cowork"
        components.path = "/new"
        // q can submit immediately in some desktop versions. Send only the
        // file; all conversation guidance is already included in its contents.
        components.queryItems = [URLQueryItem(name: "file", value: file.path)]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return FeedbackLaunchRequest(applicationURL: applicationURL, urls: [components.url!],
                                     conversationEntry: .claudeCowork, file: file)
    }

}

struct FeedbackLaunchRequest: Equatable {
    let applicationURL: URL
    let urls: [URL]
    let conversationEntry: FeedbackAssistant.ConversationEntry
    var file: URL? = nil
}

enum FeedbackHandoffResult: Equatable {
    case requested, unsupported, failed
}

@MainActor
final class FeedbackCoordinator: ObservableObject {
    @Published var kind: FeedbackKind = .problem {
        didSet {
            if kind != oldValue { includeDiagnostics = kind != .suggestion }
            if kind != .diagnosis { context = .general }
        }
    }
    @Published var description = ""
    @Published var includeDiagnostics = true
    @Published private(set) var assistants: [FeedbackAssistant] = []
    @Published var selectedAssistantID = ""
    @Published var snapshot: FeedbackRuntimeSnapshot?
    @Published private(set) var context: FeedbackContext = .general
    @Published private(set) var fileURL: URL?
    @Published private(set) var isOpening = false
    @Published private(set) var outcome: Outcome?
    private let defaults: UserDefaults
    private let discover: () -> [FeedbackAssistant]
    private let open: (FeedbackLaunchRequest, @escaping (FeedbackHandoffResult) -> Void) -> Void
    private let directory: URL
    private var requiresAssistantSelection = false

    enum Outcome: Equatable {
        case handoffRequested(String)
        case assistantUnavailable, openFailed, exportFailed, unsupported
    }

    init(defaults: UserDefaults = xdialDefaults,
         directory: URL = ScenarioSwitchFeedbackRecorder.directoryURL.deletingLastPathComponent()
            .appendingPathComponent("Feedback", isDirectory: true),
         discover: @escaping () -> [FeedbackAssistant] = { FeedbackAssistant.discover() },
         open: @escaping (FeedbackLaunchRequest, @escaping (FeedbackHandoffResult) -> Void) -> Void = FeedbackHandoff.open) {
        self.defaults = defaults
        self.directory = directory
        self.discover = discover
        self.open = open
    }

    var selectedAssistant: FeedbackAssistant? {
        assistants.first { $0.id == selectedAssistantID }
    }

    func begin(context: FeedbackContext = .general) {
        if context.origin != .general {
            kind = .diagnosis
            includeDiagnostics = true
        } else if self.context.origin != .general {
            kind = .problem
        }
        self.context = context
        outcome = nil
        fileURL = nil
    }

    func refreshAssistants() {
        let previousID = selectedAssistantID
        let preferred = defaults.string(forKey: "xdial.feedback.assistant")
        let discovered = discover()
        assistants = discovered.filter { $0.id == preferred } + discovered.filter { $0.id != preferred }
        if selectedAssistant == nil {
            if !previousID.isEmpty {
                requiresAssistantSelection = true
                selectedAssistantID = ""
                outcome = .assistantUnavailable
            } else if !requiresAssistantSelection {
                let preferred = defaults.string(forKey: "xdial.feedback.assistant")
                selectedAssistantID = assistants.first { $0.id == preferred }?.id ?? assistants.first?.id ?? ""
            }
        } else {
            requiresAssistantSelection = false
        }
    }

    func package() -> FeedbackPackage {
        FeedbackPackage(kind: kind, description: description,
                        runtime: includeDiagnostics ? snapshot : nil,
                        context: includeDiagnostics ? context : .general)
    }

    func continueInAssistant(english: Bool) {
        guard !isOpening else { return }
        let requestedID = selectedAssistantID
        refreshAssistants()
        guard let assistant = selectedAssistant, assistant.id == requestedID else {
            outcome = .openFailed
            return
        }
        guard assistant.conversationEntry != .unsupported else {
            outcome = .unsupported
            return
        }
        do {
            let package = package()
            fileURL = try package.write(text: package.text(english: english), under: directory)
        } catch {
            outcome = .exportFailed
            return
        }
        guard let fileURL else { return }
        let request = assistant.launchRequest(file: fileURL)
        isOpening = true
        open(request) { [weak self] result in
            guard let self else { return }
            self.isOpening = false
            if result == .requested {
                self.defaults.set(assistant.id, forKey: "xdial.feedback.assistant")
                self.outcome = .handoffRequested(assistant.name)
            } else {
                self.outcome = result == .unsupported ? .unsupported : .openFailed
                self.refreshAssistants()
            }
        }
    }

    func revealFile() {
        if let fileURL { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
    }
}
