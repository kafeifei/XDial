import AppKit
import SwiftUI
import XCTest

@MainActor
final class SettingsLineTableTests: XCTestCase {
    private func model(_ lines: [Line]) -> SettingsLineTable {
        SettingsLineTable(lines: lines, allowsReordering: true, move: { _, _ in true },
                          content: { AnyView(Text($0.name)) })
    }

    private func summary(_ line: Line, expanded: Bool = false, sourceOwned: Bool = false) -> SettingsLineTable.Summary {
        .init(name: line.name, info: "server.example:443", type: "AnyTLS", enabled: line.enabled,
              locked: line.type == "direct", sourceOwned: sourceOwned, expanded: expanded,
              badgeLabel: "尚未运行", badgeIcon: "circle", badgeColor: .secondary, badgeHelp: "尚未运行",
              latency: LineLatencyPresentation(store: LineLatencyStore(), line: line, profileID: "p"))
    }

    func testCollapsedRowsNeverConstructAnEditorAndExpandedRowsReuseByID() {
        let line = Line(id: "a", name: "A", type: "anytls")
        var constructions = 0
        var value = SettingsLineTable(lines: [line], allowsReordering: true, move: { _, _ in true },
                                      content: { _ in constructions += 1; return AnyView(Text("Editor")) },
                                      summaries: [line.id: summary(line)])
        let coordinator = value.makeCoordinator()
        let table = NSTableView()
        for _ in 0..<20 { _ = coordinator.tableView(table, viewFor: nil, row: 0) }
        XCTAssertEqual(constructions, 0)
        XCTAssertTrue(coordinator.hosts.isEmpty)
        value.summaries[line.id] = summary(line, expanded: true)
        coordinator.update(value)
        _ = coordinator.tableView(table, viewFor: nil, row: 0)
        _ = coordinator.tableView(table, viewFor: nil, row: 0)
        XCTAssertEqual(constructions, 1)
    }

    func testReusedNativeHeaderReplacesReadOnlyStateAndControls() {
        _ = NSApplication.shared
        let header = SettingsLineTable.NativeHeader()
        var line = Line(id: "a", name: "Subscribed", type: "anytls")
        header.configure(summary(line, sourceOwned: true))
        let toggle = header.subviews.compactMap { $0 as? NSSwitch }.first!
        let trash = header.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "删除线路" }!
        XCTAssertFalse(toggle.isEnabled)
        XCTAssertTrue(trash.isHidden)
        let copy = header.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "复制为自建副本" }!
        var copies = 0
        header.onCopy = { copies += 1 }
        XCTAssertFalse(copy.isHidden)
        copy.performClick(nil)
        XCTAssertEqual(copies, 1)
        line.name = "Local"
        line.enabled = false
        header.configure(summary(line))
        XCTAssertTrue(toggle.isEnabled)
        XCTAssertEqual(toggle.state, .off)
        XCTAssertFalse(trash.isHidden)
        XCTAssertTrue(header.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Local" })
        XCTAssertFalse(header.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Subscribed" })
    }

    func testNativeCallbackUsesStableIDAndLatestParentAfterReorder() {
        let a = Line(id: "a", name: "A", type: "anytls")
        let b = Line(id: "b", name: "B", type: "anytls")
        var value = model([a, b])
        value.summaries = [a.id: summary(a), b.id: summary(b)]
        let coordinator = value.makeCoordinator()
        let cell = coordinator.tableView(NSTableView(), viewFor: nil, row: 0) as! SettingsLineTable.Cell
        var edited: String?
        value = model([b, a])
        value.toggleEnabled = { id, _ in edited = id }
        coordinator.update(value)
        cell.nativeHeader.onEnable?(false)
        XCTAssertEqual(edited, a.id)
        value.copyLine = { id in edited = "copy:" + id }
        coordinator.update(value)
        cell.nativeHeader.onCopy?()
        XCTAssertEqual(edited, "copy:" + a.id)
    }

    func testLongNamesStayWithinRowAtDifferentWindowWidths() {
        let line = Line(id: "a", name: "🇭🇰 香港高速线路 01 | 低延迟与长名称展示测试", type: "anytls")
        let value = summary(line)
        let header = SettingsLineTable.NativeHeader()
        header.configure(value)
        for width: CGFloat in [420, 592, 900] {
            let height = SettingsLineTable.NativeHeader.preferredHeight(value, width: width)
            XCTAssertLessThanOrEqual(height, 52)
            header.frame = NSRect(x: 0, y: 0, width: width, height: height)
            header.layoutSubtreeIfNeeded()
            let fields = header.subviews.filter { !$0.isHidden && $0.frame.width > 0 }
            for field in fields { XCTAssertTrue(header.bounds.contains(field.frame)) }
            let sorted = fields.sorted { $0.frame.minX < $1.frame.minX }
            for (left, right) in zip(sorted, sorted.dropFirst()) {
                XCTAssertLessThanOrEqual(left.frame.maxX, right.frame.minX)
            }
        }
    }

    func testEditingDataDoesNotReloadMountedEditorButCollapseDoes() {
        final class Table: NSTableView {
            var reloads = IndexSet()
            override func reloadData(forRowIndexes rowIndexes: IndexSet, columnIndexes: IndexSet) { reloads.formUnion(rowIndexes) }
        }
        var line = Line(id: "a", name: "A", type: "anytls")
        var value = model([line])
        value.summaries = [line.id: summary(line, expanded: true)]
        let coordinator = value.makeCoordinator()
        let table = Table()
        table.dataSource = coordinator
        coordinator.table = table
        line.name = "Edited"
        value = model([line])
        value.summaries = [line.id: summary(line, expanded: true)]
        coordinator.update(value)
        XCTAssertTrue(table.reloads.isEmpty)
        value.summaries[line.id] = summary(line)
        coordinator.update(value)
        XCTAssertEqual(table.reloads, IndexSet(integer: 0))
    }

    func testLatencyPresentationDoesNotProbeAndDoesNotLeakPreviousTransaction() {
        let line = Line(id: "a", name: "A", type: "anytls")
        let store = LineLatencyStore()
        var probes = 0
        store.request = { _, id, _, reply in
            if id != nil { probes += 1 }
            reply(.success([]))
        }
        store.bind(transactionID: "one", profileID: "p", lines: [line])
        store.accept([ProviderLineLatency(lineID: line.id, milliseconds: 42, observedAt: 100, selectedLineID: nil)])
        XCTAssertEqual(LineLatencyPresentation(store: store, line: line, profileID: "p").label, "42 ms")
        store.bind(transactionID: "two", profileID: "p", lines: [line])
        XCTAssertEqual(LineLatencyPresentation(store: store, line: line, profileID: "p").label, "未测速")
        XCTAssertEqual(probes, 0)
    }

    func testLatencyStopButtonOnlyControlsItsOwnJob() {
        let line = Line(id: "a", name: "A", type: "anytls")
        let store = LineLatencyStore()
        store.bind(transactionID: "one", profileID: "p", lines: [line])
        let batch = store.test([line], profileID: "p", control: .catalog(groupsOnly: false))
        let batchValue = LineLatencyPresentation(store: store, line: line, profileID: "p")
        XCTAssertEqual(batchValue.buttonIcon, "arrow.clockwise")
        XCTAssertFalse(batchValue.buttonEnabled)
        store.cancel(batch)
        let own = store.test([line], profileID: "p", control: .line(line.id, groupID: nil))
        let ownValue = LineLatencyPresentation(store: store, line: line, profileID: "p")
        XCTAssertEqual(ownValue.buttonIcon, "stop.circle")
        XCTAssertTrue(ownValue.buttonEnabled)
        store.cancel(own)
    }

    func testVisitedRowReusesItsHostAfterReordering() {
        let a = Line(id: "a", name: "A", type: "anytls")
        let b = Line(id: "b", name: "B", type: "anytls")
        let coordinator = model([a, b]).makeCoordinator()
        let host = coordinator.host(for: a)
        coordinator.update(model([b, a]))
        XCTAssertTrue(coordinator.host(for: a) === host)
    }

    func testChangedLineUpdatesCachedContentAndRemovedLineIsReleased() {
        var a = Line(id: "a", name: "A", type: "anytls")
        let coordinator = model([a]).makeCoordinator()
        let host = coordinator.host(for: a)
        a.name = "Updated"
        coordinator.update(model([a]))
        XCTAssertEqual(coordinator.hosts[a.id]?.line.name, "Updated")
        XCTAssertTrue(coordinator.host(for: a) === host)
        coordinator.update(model([]))
        XCTAssertTrue(coordinator.hosts.isEmpty)
    }

    func testInactiveHostCacheIsBoundedAndKeepsRecentlyUsedRows() {
        let lines = (0..<270).map { Line(id: "line-\($0)", name: "Row \($0)", type: "anytls") }
        let coordinator = model(lines).makeCoordinator()
        for line in lines { _ = coordinator.host(for: line) }
        XCTAssertEqual(coordinator.hosts.count, SettingsLineTable.Coordinator.hostLimit)
        XCTAssertNil(coordinator.hosts[lines[0].id])
        XCTAssertNotNil(coordinator.hosts[lines.last!.id])
    }

    func testReusedCellDoesNotDetachHostAlreadyMovedToAnotherCell() {
        let first = SettingsLineTable.Cell()
        let second = SettingsLineTable.Cell()
        let a = NSView()
        let b = NSView()
        a.translatesAutoresizingMaskIntoConstraints = false
        b.translatesAutoresizingMaskIntoConstraints = false
        first.show(a)
        second.show(a)
        first.show(b)
        XCTAssertTrue(a.superview === second)
        XCTAssertTrue(b.superview === first)
    }

    func testNativeDragPayloadReordersOnlyWithinItsOwnUnfilteredTable() {
        let lines = ["a", "b", "c"].map { Line(id: $0, name: $0, type: "anytls") }
        var moves: [String] = []
        let value = SettingsLineTable(lines: lines, allowsReordering: true,
                                      move: { source, target in moves = [source, target]; return true },
                                      content: { AnyView(Text($0.name)) })
        let coordinator = value.makeCoordinator()
        let table = NSTableView()
        table.dataSource = coordinator
        let drag = DragInfo()
        defer { drag.draggingPasteboard.releaseGlobally() }
        let writer = coordinator.tableView(table, pasteboardWriterForRow: 0)!
        XCTAssertTrue(drag.draggingPasteboard.writeObjects([writer]))
        XCTAssertEqual(coordinator.tableView(table, validateDrop: drag, proposedRow: 3, proposedDropOperation: .above), .move)
        XCTAssertTrue(coordinator.tableView(table, acceptDrop: drag, row: 3, dropOperation: .above))
        XCTAssertEqual(moves, ["a", "c"])
        let otherTable = value.makeCoordinator()
        XCTAssertEqual(otherTable.tableView(table, validateDrop: drag, proposedRow: 3, proposedDropOperation: .above), [])
        let filtered = SettingsLineTable(lines: lines, allowsReordering: false, move: value.move, content: value.content)
        coordinator.update(filtered)
        XCTAssertNil(coordinator.tableView(table, pasteboardWriterForRow: 0))
        XCTAssertFalse(coordinator.tableView(table, acceptDrop: drag, row: 3, dropOperation: .above))
    }

    private final class DragInfo: NSObject, NSDraggingInfo {
        let draggingPasteboard = NSPasteboard.withUniqueName()
        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { .move }
        var draggingLocation: NSPoint { .zero }
        var draggedImageLocation: NSPoint { .zero }
        var draggedImage: NSImage? { nil }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 1 }
        var draggingFormation: NSDraggingFormation = .none
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
        func resetSpringLoading() {}
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    }

    func testDropGapMapsToExistingMoveOperation() {
        let ids = ["a", "b", "c", "d"]
        let target = SettingsLineTable.Coordinator.moveTarget
        XCTAssertEqual(target(ids, "b", 3), "c") // A C B D
        XCTAssertEqual(target(ids, "b", 4), "d") // A C D B
        XCTAssertEqual(target(ids, "d", 0), "a") // D A B C
        XCTAssertEqual(target(ids, "b", 1), "b")
        XCTAssertEqual(target(ids, "b", 2), "b")
        XCTAssertNil(target(ids, "missing", 0))
        XCTAssertNil(target(ids, "b", 5))
        XCTAssertNil(target([], "b", 0))
    }
}
