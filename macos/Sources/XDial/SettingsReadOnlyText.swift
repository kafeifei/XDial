import AppKit
import SwiftUI

/// Read-only is an editing constraint, not a disabled interaction state.
struct SettingsReadOnlyText: NSViewRepresentable {
    let text: String
    var multiline = false

    func makeNSView(context: Context) -> NSView { Self.makeControl(text: text, multiline: multiline) }

    func updateNSView(_ view: NSView, context: Context) {
        if let field = view as? NSTextField, field.stringValue != text { field.stringValue = text }
        if let scroll = view as? NSScrollView, let editor = scroll.documentView as? NSTextView,
           editor.string != text { editor.string = text }
    }

    static func makeControl(text: String, multiline: Bool) -> NSView {
        if !multiline {
            let field = NSTextField(string: text)
            field.isEditable = false
            field.isSelectable = true
            field.font = .systemFont(ofSize: 11)
            field.bezelStyle = .roundedBezel
            field.lineBreakMode = .byClipping
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return field
        }
        let scroll = NSTextView.scrollableTextView()
        let editor = scroll.documentView as! NSTextView
        editor.isEditable = false
        editor.isSelectable = true
        editor.isRichText = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        editor.textContainerInset = NSSize(width: 4, height: 4)
        editor.string = text
        scroll.hasHorizontalScroller = false
        return scroll
    }
}

struct SettingsReadOnlySecret: View {
    let text: String
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 4) {
            SettingsReadOnlyText(text: revealed ? text : "••••••••")
            Button { revealed.toggle() } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.plain)
            .help(revealed ? "隐藏" : "显示")
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.plain)
            .help("复制")
            .accessibilityLabel("复制凭据")
        }
    }
}
