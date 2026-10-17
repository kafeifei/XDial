import AppKit
import SwiftUI

struct FeedbackView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var feedback: FeedbackCoordinator
    @State private var showsPreview = false
    @State private var showsAssistants = false

    private func text(_ key: String) -> String {
        let code = state.language == .zh ? "zh-Hans" : "en"
        let bundle = Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        return bundle.localizedString(forKey: "feedback." + key, value: nil, table: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(text(feedback.context.origin == .general ? "intro"
                : feedback.context.origin == .scenarioSwitchFailure ? "intro.switch" : "intro.connection"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if feedback.context.origin != .general {
                HStack(alignment: .top) {
                    Text(text(!feedback.includeDiagnostics ? "context.omitted"
                        : feedback.context.origin == .scenarioSwitchFailure ? "context.switch" : "context.connection"))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(text("context.clear")) { feedback.begin() }
                }
                .font(.system(size: 11))
            }

            Toggle(text("includeDiagnostics"), isOn: $feedback.includeDiagnostics)
                .toggleStyle(.switch)
            DisclosureGroup(text("preview"), isExpanded: $showsPreview) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(text("privacy"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if showsPreview {
                        SettingsReadOnlyText(text: (try? feedback.package().text(english: state.language == .en)) ?? "", multiline: true)
                            .frame(height: 160)
                    }
                }
                .padding(.top, 6)
            }
            assistantSection
            if let outcome = feedback.outcome {
                Label(outcomeText(outcome), systemImage: isError(outcome) ? "exclamationmark.circle" : "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(isError(outcome) ? XDialPalette.danger : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("feedback.outcome")
            }
            if feedback.fileURL != nil {
                Button(text("reveal")) { feedback.revealFile() }
                    .buttonStyle(.link)
            }
        }
        .onAppear { refresh() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            feedback.refreshAssistants()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            feedback.refreshAssistants()
        }
    }

    private var assistantSection: some View {
        Button {
            refresh()
            showsAssistants = true
        } label: {
            HStack(spacing: 8) {
                Text("🤖").font(.system(size: 22))
                Text(text("askAI")).fontWeight(.medium)
                if feedback.isOpening { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .disabled(feedback.isOpening)
        .accessibilityIdentifier("feedback.assistants")
        .popover(isPresented: $showsAssistants, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                if feedback.assistants.isEmpty {
                    Text(text("noAssistant"))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                } else {
                    ForEach(feedback.assistants) { assistant in
                        Button {
                            showsAssistants = false
                            feedback.selectedAssistantID = assistant.id
                            feedback.continueInAssistant(english: state.language == .en)
                        } label: {
                            HStack(spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: assistant.applicationURL.path))
                                    .resizable().frame(width: 28, height: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(assistant.name)
                                    if assistant.conversationEntry == .unsupported {
                                        Text(text("unsupported"))
                                            .font(.system(size: 10)).foregroundStyle(.secondary)
                                    } else {
                                        Text("Cowork").font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .padding(8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(assistant.conversationEntry == .unsupported)
                        .accessibilityIdentifier("feedback.assistant." + assistant.id)
                    }
                }
            }
            .padding(6)
            .frame(width: 230)
        }
    }

    private func refresh() {
        feedback.refreshAssistants()
        state.refreshFeedbackSnapshot()
    }

    private func outcomeText(_ outcome: FeedbackCoordinator.Outcome) -> String {
        switch outcome {
        case .handoffRequested(let name): return String(format: text("requested"), name)
        case .unsupported: return text("unsupported")
        case .assistantUnavailable: return text("assistantUnavailable")
        case .openFailed: return text("openFailed")
        case .exportFailed: return text("exportFailed")
        }
    }

    private func isError(_ outcome: FeedbackCoordinator.Outcome) -> Bool {
        switch outcome {
        case .assistantUnavailable, .openFailed, .exportFailed, .unsupported: return true
        default: return false
        }
    }
}
