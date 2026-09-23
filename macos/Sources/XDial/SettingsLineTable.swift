import AppKit
import SwiftUI

/// Collapsed rows reuse native controls. SwiftUI editors are created only for
/// expanded rows and retained by stable ID in a bounded cache.
struct SettingsLineTable: NSViewRepresentable {
    let lines: [Line]
    let allowsReordering: Bool
    let move: (String, String) -> Bool
    let content: (Line) -> AnyView
    var summaries: [String: Summary] = [:]
    var toggleExpanded: (String) -> Void = { _ in }
    var toggleEnabled: (String, Bool) -> Void = { _, _ in }
    var testLine: (String) -> Void = { _ in }
    var deleteLine: (String) -> Void = { _ in }
    var copyLine: (String) -> Void = { _ in }

    struct Summary: Equatable {
        let name: String
        let info: String
        let type: String
        let enabled: Bool
        let locked: Bool
        let sourceOwned: Bool
        let expanded: Bool
        let badgeLabel: String
        let badgeIcon: String
        let badgeColor: Color
        let badgeHelp: String
        let latency: LineLatencyPresentation
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 8)
        table.rowHeight = 50
        table.usesAutomaticRowHeights = false
        table.selectionHighlightStyle = .none
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("line"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.action = #selector(Coordinator.clicked(_:))
        table.registerForDraggedTypes([Coordinator.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        scroll.documentView = table
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let dragType = NSPasteboard.PasteboardType("com.kafeifei.xdial.settings-line")
        static let hostLimit = 256
        var parent: SettingsLineTable
        weak var table: NSTableView?
        private(set) var hosts: [String: Entry] = [:]
        private let dragToken = UUID().uuidString
        private var clock: UInt64 = 0
        private var heights: [String: CGFloat] = [:]
        private var pendingHeights: Set<String> = []
        private var heightUpdateScheduled = false

        struct Entry {
            var line: Line
            let host: NSHostingView<AnyView>
            var lastUse: UInt64
        }

        init(_ parent: SettingsLineTable) { self.parent = parent }

        func update(_ value: SettingsLineTable) {
            let oldSummaries = parent.summaries
            let oldIDs = parent.lines.map(\.id)
            let dragModeChanged = parent.allowsReordering != value.allowsReordering
            parent = value
            let newIDs = value.lines.map(\.id)
            let current = Dictionary(value.lines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            heights = heights.filter { current[$0.key] != nil }
            for id in Array(hosts.keys) {
                guard let line = current[id] else { hosts.removeValue(forKey: id); continue }
                if dragModeChanged || hosts[id]?.line != line {
                    hosts[id]?.line = line
                    hosts[id]?.host.rootView = row(line)
                }
            }
            // Runtime notifications already reach the hosted rows. Reloading
            // the table for those notifications would discard its height cache.
            if oldIDs != newIDs { table?.reloadData() }
            else {
                let changed = IndexSet(value.lines.indices.filter {
                    let id = value.lines[$0].id
                    // Keep the mounted editor (and its first responder) when
                    // only its data changes. It observes those updates itself.
                    if oldSummaries[id]?.expanded == true && value.summaries[id]?.expanded == true { return false }
                    return oldSummaries[id] != value.summaries[id]
                })
                if !changed.isEmpty {
                    table?.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
                    table?.noteHeightOfRows(withIndexesChanged: changed)
                }
            }
        }

        private func row(_ line: Line) -> AnyView {
            let payload = Data((dragToken + "\n" + line.id).utf8)
            return AnyView(Group {
                if parent.allowsReordering {
                    parent.content(line).id(line.id).onDrag {
                        let provider = NSItemProvider()
                        provider.registerDataRepresentation(forTypeIdentifier: Self.dragType.rawValue, visibility: .ownProcess) { completion in
                            completion(payload, nil)
                            return nil
                        }
                        return provider
                    }
                } else {
                    parent.content(line).id(line.id)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { [weak self] height in
                self?.recordHeight(height, for: line.id)
            })
        }

        private func draggedID(_ info: NSDraggingInfo) -> String? {
            guard let data = info.draggingPasteboard.data(forType: Self.dragType),
                  let payload = String(data: data, encoding: .utf8) else { return nil }
            let parts = payload.split(separator: "\n", maxSplits: 1)
            guard parts.count == 2, parts[0] == dragToken else { return nil }
            return String(parts[1])
        }

        func host(for line: Line) -> NSHostingView<AnyView> {
            clock &+= 1
            if var entry = hosts[line.id] {
                entry.lastUse = clock
                hosts[line.id] = entry
                return entry.host
            }
            let host = NSHostingView(rootView: row(line))
            host.translatesAutoresizingMaskIntoConstraints = false
            hosts[line.id] = Entry(line: line, host: host, lastUse: clock)
            trimHosts()
            return host
        }

        private func trimHosts() {
            guard hosts.count > Self.hostLimit else { return }
            let inactive = hosts.filter { $0.value.host.window == nil }
                .sorted { $0.value.lastUse < $1.value.lastUse }
            for entry in inactive.prefix(hosts.count - Self.hostLimit) {
                hosts.removeValue(forKey: entry.key)
            }
        }

        private func recordHeight(_ height: CGFloat, for id: String) {
            guard height.isFinite, height > 0,
                  parent.lines.contains(where: { $0.id == id }),
                  abs((heights[id] ?? 0) - height) > 0.5 else { return }
            heights[id] = ceil(height)
            pendingHeights.insert(id)
            guard !heightUpdateScheduled else { return }
            heightUpdateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.heightUpdateScheduled = false
                let rows = IndexSet(self.parent.lines.indices.filter { self.pendingHeights.contains(self.parent.lines[$0].id) })
                self.pendingHeights.removeAll()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    self.table?.noteHeightOfRows(withIndexesChanged: rows)
                }
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.lines.count }
        func tableViewColumnDidResize(_ notification: Notification) {
            table?.noteHeightOfRows(withIndexesChanged: IndexSet(parent.lines.indices))
        }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard parent.lines.indices.contains(row) else { return 50 }
            let id = parent.lines[row].id
            if let summary = parent.summaries[id], !summary.expanded {
                return NativeHeader.preferredHeight(summary, width: max(0, tableView.bounds.width - 28))
            }
            return heights[id] ?? 50
        }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            guard parent.lines.indices.contains(row), let summary = parent.summaries[parent.lines[row].id] else { return false }
            return !summary.locked && !summary.expanded
        }

        @objc func clicked(_ tableView: NSTableView) {
            guard parent.lines.indices.contains(tableView.clickedRow) else { return }
            let id = parent.lines[tableView.clickedRow].id
            guard let summary = parent.summaries[id], !summary.locked, !summary.expanded else { return }
            parent.toggleExpanded(id)
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.lines.indices.contains(row) else { return nil }
            let key = NSUserInterfaceItemIdentifier("line")
            let cell = (tableView.makeView(withIdentifier: key, owner: self) as? Cell) ?? Cell()
            cell.identifier = key
            let line = parent.lines[row]
            if let summary = parent.summaries[line.id], !summary.expanded {
                let header = cell.nativeHeader
                header.configure(summary)
                header.onExpand = { [weak self] in self?.parent.toggleExpanded(line.id) }
                header.onEnable = { [weak self] value in self?.parent.toggleEnabled(line.id, value) }
                header.onTest = { [weak self] in self?.parent.testLine(line.id) }
                header.onDelete = { [weak self] in self?.parent.deleteLine(line.id) }
                header.onCopy = { [weak self] in self?.parent.copyLine(line.id) }
                cell.show(header)
            } else {
                cell.show(host(for: line))
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard parent.allowsReordering, parent.lines.indices.contains(row) else { return nil }
            let item = NSPasteboardItem()
            item.setString(dragToken + "\n" + parent.lines[row].id, forType: Self.dragType)
            return item
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard parent.allowsReordering, let id = draggedID(info),
                  Self.moveTarget(ids: parent.lines.map(\.id), draggedID: id, insertionRow: row) != nil else { return [] }
            tableView.setDropRow(row, dropOperation: .above)
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard parent.allowsReordering, let id = draggedID(info),
                  let target = Self.moveTarget(ids: parent.lines.map(\.id), draggedID: id, insertionRow: row) else { return false }
            return id == target || parent.move(id, target)
        }

        /// Existing model reordering moves to another item's old index. A
        /// table drop instead denotes the gap before a row (including the end).
        static func moveTarget(ids: [String], draggedID: String, insertionRow: Int) -> String? {
            guard let source = ids.firstIndex(of: draggedID),
                  (0...ids.count).contains(insertionRow) else { return nil }
            let target = insertionRow > source ? insertionRow - 1 : insertionRow
            return ids.indices.contains(target) ? ids[target] : nil
        }
    }

    final class NativeHeader: NSView {
        var onExpand: (() -> Void)?
        var onEnable: ((Bool) -> Void)?
        var onTest: (() -> Void)?
        var onDelete: (() -> Void)?
        var onCopy: (() -> Void)?
        private var summary: Summary?
        private let chevron = NSButton()
        private let badgeIcon = NSImageView()
        private let badge = NSTextField(labelWithString: "")
        private let name = NSTextField(wrappingLabelWithString: "")
        private let info = NSTextField(labelWithString: "")
        private let latency = NSTextField(labelWithString: "")
        private let probe = NSButton()
        private let type = NSTextField(labelWithString: "")
        private let source = NSTextField(labelWithString: "")
        private let enabled = NSSwitch()
        private let trash = NSButton()
        private let copy = NSButton()
        private static let nameFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        override var isFlipped: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            translatesAutoresizingMaskIntoConstraints = false
            for view in [chevron, badgeIcon, badge, name, info, latency, probe, type, source, enabled, copy, trash] { addSubview(view) }
            for field in [badge, name, info, latency, type, source] {
                field.isEditable = false
                field.isSelectable = false
                field.font = .systemFont(ofSize: 11)
                field.textColor = .secondaryLabelColor
            }
            badge.font = .systemFont(ofSize: 10, weight: .medium)
            name.font = Self.nameFont
            name.textColor = .labelColor
            name.maximumNumberOfLines = 2
            name.lineBreakMode = .byWordWrapping
            info.lineBreakMode = .byTruncatingMiddle
            latency.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            latency.alignment = .right
            type.alignment = .right
            for button in [chevron, probe, copy, trash] {
                button.isBordered = false
                button.imagePosition = .imageOnly
                button.target = self
                button.bezelStyle = .regularSquare
                button.contentTintColor = .secondaryLabelColor
            }
            chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
            chevron.action = #selector(expandRow)
            probe.action = #selector(testRow)
            trash.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
            trash.action = #selector(deleteRow)
            trash.setAccessibilityLabel("删除线路")
            trash.toolTip = "删除线路"
            copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
            copy.action = #selector(copyRow)
            copy.setAccessibilityLabel("复制为自建副本")
            copy.toolTip = "复制为自建副本"
            enabled.controlSize = .mini
            enabled.target = self
            enabled.action = #selector(enableRow)
            enabled.setAccessibilityLabel("启用")
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(_ value: Summary) {
            summary = value
            name.stringValue = value.name
            name.toolTip = value.name
            info.stringValue = value.info
            info.toolTip = value.info
            badge.stringValue = value.badgeLabel
            badge.textColor = NSColor(value.badgeColor)
            badge.toolTip = value.badgeHelp
            badgeIcon.image = NSImage(systemSymbolName: value.badgeIcon, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
            badgeIcon.contentTintColor = NSColor(value.badgeColor)
            badgeIcon.toolTip = value.badgeHelp
            latency.stringValue = value.latency.label
            latency.toolTip = value.latency.detail
            latency.textColor = value.latency.failed ? NSColor(XDialPalette.danger) : .secondaryLabelColor
            probe.image = NSImage(systemSymbolName: value.latency.buttonIcon, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
            probe.toolTip = value.latency.buttonHelp
            probe.setAccessibilityLabel(value.latency.buttonLabel)
            probe.isEnabled = value.latency.buttonEnabled && !value.locked
            type.stringValue = value.type
            source.stringValue = value.sourceOwned ? "订阅" : "自建"
            enabled.state = value.enabled ? .on : .off
            enabled.isEnabled = !value.locked && !value.sourceOwned
            trash.isHidden = value.locked || value.sourceOwned
            copy.isHidden = value.locked
            chevron.isEnabled = !value.locked
            chevron.setAccessibilityLabel("展开 " + value.name)
            alphaValue = value.enabled ? 1 : 0.65
            needsLayout = true
            needsDisplay = true
        }

        // Use the same column widths for measurement and layout. Folded row
        // heights never depend on SwiftUI geometry or scroll callbacks.
        private static func widths(_ value: Summary, width: CGFloat) -> (badge: CGFloat, type: CGFloat, name: CGFloat, info: CGFloat) {
            let badge = ceil((value.badgeLabel as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium)]).width)
            let type = ceil((value.type as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width)
            let available = max(0, width - 22 - 19 - 16 - badge - 7 - 67 - 7 - type - 7 - 24 - 7 - 28 - (value.locked ? 0 : 25) - ((value.locked || value.sourceOwned) ? 0 : 25))
            let nameWidth = value.info.isEmpty ? available : min(230, max(80, available * 0.53))
            return (badge, type, min(available, nameWidth), max(0, available - nameWidth - 7))
        }

        static func preferredHeight(_ value: Summary, width: CGFloat) -> CGFloat {
            let nameWidth = widths(value, width: width).name
            // NSTextField reserves two points on each side of its text cell.
            let height = (value.name as NSString).boundingRect(with: NSSize(width: max(1, nameWidth - 4), height: 40), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: nameFont]).height
            return ceil(max(22, min(34, height))) + 18
        }

        override func layout() {
            super.layout()
            guard let value = summary else { return }
            let widths = Self.widths(value, width: bounds.width)
            let middle = bounds.midY
            func place(_ view: NSView, _ x: CGFloat, _ width: CGFloat, _ height: CGFloat = 16) {
                view.frame = NSRect(x: x, y: floor(middle - height / 2), width: max(0, width), height: height)
            }
            place(chevron, 11, 12, 22)
            place(badgeIcon, 30, 12)
            place(badge, 46, widths.badge)
            let nameX = 46 + widths.badge + 7
            place(name, nameX, widths.name, bounds.height - 18)
            place(info, nameX + widths.name + 7, widths.info)
            var x = bounds.width - 11
            if !trash.isHidden { x -= 18; place(trash, x, 18, 22); x -= 7 }
            if !copy.isHidden { x -= 18; place(copy, x, 18, 22); x -= 7 }
            x -= 28; place(enabled, x, 28, 16); x -= 7
            x -= 24; place(source, x, 24); x -= 7
            x -= widths.type; place(type, x, widths.type); x -= 7
            x -= 20; place(probe, x, 20, 22); x -= 5
            x -= 42; place(latency, x, 42)
        }

        override func draw(_ dirtyRect: NSRect) {
            let rect = bounds.insetBy(dx: 0.375, dy: 0.375)
            let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
            NSColor(XDialPalette.surface).setFill()
            path.fill()
            NSColor(XDialPalette.divider).setStroke()
            path.lineWidth = 0.75
            path.stroke()
        }

        @objc private func expandRow() { onExpand?() }
        @objc private func enableRow() { onEnable?(enabled.state == .on) }
        @objc private func testRow() { onTest?() }
        @objc private func deleteRow() { onDelete?() }
        @objc private func copyRow() { guard summary?.locked == false else { return }; onCopy?() }
    }

    final class Cell: NSTableCellView {
        private weak var hostedView: NSView?
        lazy var nativeHeader = NativeHeader()

        func show(_ host: NSView) {
            if hostedView === host && host.superview === self { return }
            // A retained host may already have moved to another reused cell.
            if hostedView?.superview === self { hostedView?.removeFromSuperview() }
            hostedView = host
            addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                host.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                host.topAnchor.constraint(equalTo: topAnchor),
                host.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }
}
