import SwiftUI
import AppKit

/// 原生 NSMenu 弹出选择，点击时才构建菜单项，零预渲染开销
struct MenuButton: NSViewRepresentable {
    let title: String
    let delays: [String: Int]
    let items: [String]
    let onSelect: (String) -> Void

    init(_ title: String, delays: [String: Int], items: [String], onSelect: @escaping (String) -> Void) {
        self.title = title
        self.delays = delays
        self.items = items
        self.onSelect = onSelect
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let btn = NSPopUpButton(frame: .zero, pullsDown: false)
        btn.font = .systemFont(ofSize: 11)
        btn.bezelStyle = .inline
        btn.target = context.coordinator
        btn.action = #selector(Coordinator.changed(_:))
        return btn
    }

    func updateNSView(_ btn: NSPopUpButton, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.items = items

        btn.removeAllItems()
        for name in items {
            btn.addItem(withTitle: name)
            btn.lastItem?.representedObject = name
            if let ms = delays[name], let item = btn.lastItem {
                let color: NSColor
                if ms < 0 { color = .systemRed }
                else if ms <= 200 { color = .systemGreen }
                else { color = .systemOrange }
                let text = ms < 0 ? "超时" : (ms > 999 ? "999ms" : "\(ms)ms")

                let para = NSMutableParagraphStyle()
                para.tabStops = [NSTextTab(textAlignment: .right, location: 280)]

                let attr = NSMutableAttributedString(string: name + "\t", attributes: [.paragraphStyle: para])
                let badge = Self.badgeImage(text: text, color: color)
                let attach = NSTextAttachment()
                attach.image = badge
                attach.bounds = NSRect(x: 0, y: -2, width: badge.size.width, height: badge.size.height)
                attr.append(NSAttributedString(attachment: attach))
                item.attributedTitle = attr
            }
        }
        // 选中当前
        if let idx = items.firstIndex(of: title) {
            btn.selectItem(at: idx)
        }
    }

    private static func badgeImage(text: String, color: NSColor) -> NSImage {
        let font = NSFont.systemFont(ofSize: 9, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let w = max(textSize.width + 10, 28)
        let h: CGFloat = 14

        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            color.setFill()
            path.fill()
            let textRect = NSRect(x: (w - textSize.width) / 2, y: (h - textSize.height) / 2, width: textSize.width, height: textSize.height)
            (text as NSString).draw(in: textRect, withAttributes: attrs)
            return true
        }
        img.isTemplate = false
        return img
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject {
        var onSelect: ((String) -> Void)?
        var items: [String] = []

        @objc func changed(_ sender: NSPopUpButton) {
            if let name = sender.selectedItem?.representedObject as? String {
                onSelect?(name)
            }
        }
    }
}

