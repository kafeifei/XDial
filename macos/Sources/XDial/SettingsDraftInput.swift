import AppKit
import SwiftUI

/// Typing belongs to the control. Publish a single edit when it is committed,
/// instead of splitting, validating and encrypting the catalog per keystroke.
struct SettingsDraftInput<Value: Equatable, Content: View>: View {
    @Binding private var value: Value
    @State private var draft: Value
    @State private var original: Value
    @FocusState private var focused: Bool
    private let onCommit: () -> Void
    private let content: (Binding<Value>) -> Content
    private let readOnlyText: String?
    private let multiline: Bool

    init(_ value: Binding<Value>, readOnlyText: String? = nil, multiline: Bool = false, onCommit: @escaping () -> Void,
         @ViewBuilder content: @escaping (Binding<Value>) -> Content) {
        _value = value
        _draft = State(initialValue: value.wrappedValue)
        _original = State(initialValue: value.wrappedValue)
        self.onCommit = onCommit
        self.content = content
        self.readOnlyText = readOnlyText
        self.multiline = multiline
    }

    var body: some View {
        if let readOnlyText {
            SettingsReadOnlyText(text: readOnlyText, multiline: multiline)
        } else {
        content($draft)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, focused in if !focused { commit() } }
            .onChange(of: value) { _, updated in
                if !focused || draft == original { draft = updated; original = updated }
            }
            .onDisappear(perform: commit)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in commit() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in commit() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in commit() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in commit() }
        }
    }

    private func commit() {
        guard readOnlyText == nil, original != draft else { return }
        original = draft
        guard value != draft else { return }
        value = draft
        onCommit()
    }
}
