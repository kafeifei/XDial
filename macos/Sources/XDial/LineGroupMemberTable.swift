import AppKit
import SwiftUI

extension Line {
    var memberTypeLabel: String {
        switch type {
        case "selector", "urltest": return "线路组"
        case "direct": return "直连"
        default: return type.uppercased()
        }
    }
    var chosenGroupMemberID: String? {
        type == "urltest" ? nil : (groupDefault.isEmpty ? groupMembers.first : groupDefault)
    }
}


/// The member viewport contains only reusable native rows. Resolving catalog
/// and latency state belongs to data updates, never to scrolling or cell reuse.
struct LineGroupMemberTable: NSViewRepresentable {
    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
        let source: String
        let selected: Bool
        let latency: LineLatencyPresentation
        let isGroup: Bool
        let canRemove: Bool
        let reordering: Bool
        let canMoveUp: Bool
        let canMoveDown: Bool

        func allows(_ action: Action) -> Bool {
            switch action {
            case .select: return true
            case .test: return latency.buttonEnabled
            case .expand: return isGroup
            case .remove: return canRemove && !reordering
            case .moveUp: return reordering && canMoveUp
            case .moveDown: return reordering && canMoveDown
            }
        }
    }

    enum Action { case select, test, expand, remove, moveUp, moveDown }
    let rows: [Row]
    let onAction: (String, Action) -> Void

    @MainActor
    static func rows(group: Line, members: [Line], followedMembers: Set<String>,
                     sourceNames: [String: String], globalSourceName: String,
                     reordering: Bool, store: LineLatencyStore) -> [Row] {
        members.map { member in
            let editable = !followedMembers.contains(member.id)
            return Row(id: member.id, name: member.name,
                       source: member.isGroup ? "全局组" : sourceNames[member.id] ?? globalSourceName,
                       selected: group.chosenGroupMemberID == member.id,
                       latency: LineLatencyPresentation(store: store, line: member,
                                                        profileID: ProfileLibrary.configurationID, group: group),
                       isGroup: member.isGroup, canRemove: editable, reordering: editable && reordering,
                       canMoveUp: editable && group.groupMembers.first != member.id,
                       canMoveDown: editable && group.groupMembers.last != member.id)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.makeScrollView() }
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update(self) }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var parent: LineGroupMemberTable
        private var rowsByID: [String: Row]
        private(set) weak var table: NSTableView?

        init(_ parent: LineGroupMemberTable) {
            self.parent = parent
            rowsByID = Dictionary(uniqueKeysWithValues: parent.rows.map { ($0.id, $0) })
        }

        func makeScrollView() -> NSScrollView {
            let scroll = NSScrollView()
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.automaticallyAdjustsContentInsets = false
            let table = NSTableView()
            table.headerView = nil
            table.backgroundColor = .clear
            table.style = .plain
            table.intercellSpacing = .zero
            table.rowHeight = 32
            table.usesAutomaticRowHeights = false
            table.selectionHighlightStyle = .none
            let column = NSTableColumn(identifier: .init("member"))
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
            table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            table.dataSource = self
            table.delegate = self
            scroll.documentView = table
            self.table = table
            return scroll
        }

        func update(_ value: LineGroupMemberTable) {
            let oldRows = rowsByID
            let oldIDs = parent.rows.map(\.id)
            parent = value
            rowsByID = Dictionary(uniqueKeysWithValues: value.rows.map { ($0.id, $0) })
            guard oldIDs == value.rows.map(\.id) else { table?.reloadData(); return }
            // Offscreen rows will receive current data when reused. Updating a
            // measurement or selection must not recreate cells or move focus.
            for (index, row) in value.rows.enumerated() where oldRows[row.id] != row {
                (table?.view(atColumn: 0, row: index, makeIfNecessary: false) as? Cell)?.configure(row)
            }
        }

        func perform(_ action: Action, id: String) {
            guard let row = rowsByID[id], row.allows(action) else { return }
            parent.onAction(id, action)
        }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.rows.indices.contains(row) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("member")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? Cell ?? Cell()
            cell.identifier = identifier
            let value = parent.rows[row]
            cell.configure(value)
            cell.onAction = { [weak self] action in self?.perform(action, id: value.id) }
            return cell
        }
    }

    final class Cell: NSTableCellView {
        var onAction: ((Action) -> Void)?
        private(set) var row: Row?
        private let selectButton = NSButton()
        private let source = NSTextField(labelWithString: "")
        private let latency = NSTextField(labelWithString: "")
        private let testButton = NSButton()
        private let expandButton = NSButton()
        private let removeButton = NSButton()
        private let upButton = NSButton()
        private let downButton = NSButton()
        override var isFlipped: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            for button in [selectButton, testButton, expandButton, removeButton, upButton, downButton] {
                button.isBordered = false
                button.target = self
                button.imagePosition = .imageOnly
                button.font = .systemFont(ofSize: 11)
                button.contentTintColor = .secondaryLabelColor
                addSubview(button)
            }
            selectButton.setButtonType(.radio)
            selectButton.imagePosition = .imageLeading
            selectButton.alignment = .left
            selectButton.font = .systemFont(ofSize: 12)
            selectButton.lineBreakMode = .byTruncatingTail
            selectButton.action = #selector(selectMember)
            testButton.action = #selector(testMember)
            expandButton.action = #selector(expandMember)
            removeButton.action = #selector(removeMember)
            upButton.action = #selector(moveMemberUp)
            downButton.action = #selector(moveMemberDown)
            for (button, symbol, help) in [
                (expandButton, "arrow.turn.down.right", "展开子组"),
                (removeButton, "minus.circle", "从组中移除，保留原线路"),
                (upButton, "chevron.up", "上移"), (downButton, "chevron.down", "下移")
            ] {
                button.image = Self.symbol(symbol)
                button.toolTip = help
            }
            source.font = .systemFont(ofSize: 10)
            source.textColor = .secondaryLabelColor
            source.lineBreakMode = .byTruncatingMiddle
            latency.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            latency.alignment = .right
            for field in [source, latency] {
                field.isSelectable = false
                addSubview(field)
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        private static func symbol(_ name: String) -> NSImage? {
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        }

        func configure(_ row: Row) {
            self.row = row
            selectButton.title = row.name
            selectButton.state = row.selected ? .on : .off
            selectButton.toolTip = row.name
            selectButton.setAccessibilityLabel(row.name)
            source.stringValue = row.source
            source.toolTip = row.source
            latency.stringValue = row.latency.label
            latency.toolTip = row.latency.detail
            latency.textColor = row.latency.failed ? NSColor(XDialPalette.danger) : .secondaryLabelColor
            testButton.image = Self.symbol(row.latency.buttonIcon)
            testButton.isEnabled = row.allows(.test)
            testButton.toolTip = row.latency.buttonHelp
            testButton.setAccessibilityLabel(row.latency.buttonLabel)
            expandButton.isHidden = !row.isGroup
            expandButton.setAccessibilityLabel("展开 " + row.name)
            removeButton.isHidden = !row.canRemove || row.reordering
            removeButton.setAccessibilityLabel("移除 " + row.name)
            upButton.isHidden = !row.reordering
            downButton.isHidden = !row.reordering
            upButton.isEnabled = row.allows(.moveUp)
            downButton.isEnabled = row.allows(.moveDown)
            upButton.setAccessibilityLabel("上移 " + row.name)
            downButton.setAccessibilityLabel("下移 " + row.name)
            needsLayout = true
            needsDisplay = true
        }

        override func layout() {
            super.layout()
            // Leave room for the overlay scroller without covering row actions.
            var right = bounds.width - 22
            func trailing(_ view: NSView, width: CGFloat, height: CGFloat = 22) {
                guard !view.isHidden else { return }
                right -= width
                view.frame = NSRect(x: right, y: floor((bounds.height - height) / 2), width: width, height: height)
                right -= 8
            }
            trailing(downButton, width: 18)
            trailing(upButton, width: 18)
            trailing(removeButton, width: 20)
            trailing(expandButton, width: 20)
            trailing(testButton, width: 20)
            trailing(latency, width: 42, height: 16)
            trailing(source, width: min(90, ceil(source.intrinsicContentSize.width)), height: 15)
            selectButton.frame = NSRect(x: 6, y: 4, width: max(0, right - 6), height: 24)
        }

        override func draw(_ dirtyRect: NSRect) {
            guard row?.selected == true else { return }
            NSColor(XDialPalette.selection).withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 5, yRadius: 5).fill()
        }

        @objc private func selectMember() {
            // Selection is committed by the model. A rejected selection must
            // not leave AppKit's radio button optimistically checked.
            selectButton.state = row?.selected == true ? .on : .off
            onAction?(.select)
        }
        @objc private func testMember() { onAction?(.test) }
        @objc private func expandMember() { onAction?(.expand) }
        @objc private func removeMember() { onAction?(.remove) }
        @objc private func moveMemberUp() { onAction?(.moveUp) }
        @objc private func moveMemberDown() { onAction?(.moveDown) }
    }
}
