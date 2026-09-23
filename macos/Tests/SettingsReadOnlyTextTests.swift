import AppKit
import XCTest

@MainActor
final class SettingsReadOnlyTextTests: XCTestCase {
    func testReadOnlyFieldsRetainSelectionAndCopyWithoutUsingUserClipboard() throws {
        _ = NSApplication.shared
        let field = try XCTUnwrap(SettingsReadOnlyText.makeControl(text: "server.example", multiline: false) as? NSTextField)
        XCTAssertTrue(field.isEnabled)
        XCTAssertTrue(field.isSelectable)
        XCTAssertFalse(field.isEditable)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
                              styleMask: .borderless, backing: .buffered, defer: true)
        field.frame = NSRect(x: 10, y: 10, width: 280, height: 22)
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        field.selectText(nil)
        let fieldEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertFalse(fieldEditor.isEditable)
        fieldEditor.setSelectedRange(NSRange(location: 0, length: 6))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(fieldEditor.writeSelection(to: pasteboard, types: fieldEditor.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: .string), "server")
        let scroll = try XCTUnwrap(SettingsReadOnlyText.makeControl(text: "first.example\nsecond.example", multiline: true) as? NSScrollView)
        let editor = try XCTUnwrap(scroll.documentView as? NSTextView)
        XCTAssertTrue(editor.isSelectable)
        XCTAssertFalse(editor.isEditable)
        editor.setSelectedRange(NSRange(location: 0, length: 13))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 13))
        XCTAssertTrue(editor.writeSelection(to: pasteboard, types: editor.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: .string), "first.example")
        XCTAssertEqual(editor.string, "first.example\nsecond.example")
    }
}
