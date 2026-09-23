import AppKit
import SwiftUI
import XCTest

@MainActor
final class LineGroupMemberTableTests: XCTestCase {
    private let a = Line(id: "a", name: "香港线路 A", type: "anytls")
    private let b = Line(id: "b", name: "香港线路 B", type: "anytls")
    private func group() -> Line {
        var group = Line(id: "g", name: "Group", type: "selector")
        group.groupMembers = ["a", "b"]
        return group
    }
    private func rows(_ group: Line, members: [Line]? = nil, followed: Set<String> = [], reordering: Bool = false,
                      store: LineLatencyStore? = nil) -> [LineGroupMemberTable.Row] {
        LineGroupMemberTable.rows(group: group, members: members ?? [a, b], followedMembers: followed,
            sourceNames: ["a": "来源一", "b": "来源二"], globalSourceName: "全局",
            reordering: reordering, store: store ?? LineLatencyStore())
    }

    func testAutomaticAndFixedChoiceKeepExistingModelSemantics() {
        var group = group()
        XCTAssertEqual(rows(group).filter(\.selected).map(\.id), ["a"])
        group.groupDefault = "b"
        XCTAssertEqual(rows(group).filter(\.selected).map(\.id), ["b"])
        group.type = "urltest"
        XCTAssertTrue(rows(group).allSatisfy { !$0.selected })
    }

    func testSourceMembersAndSearchCannotBeReorderedOrRemovedIncorrectly() {
        let values = rows(group(), followed: ["a"], reordering: true)
        XCTAssertFalse(values[0].allows(.remove))
        XCTAssertFalse(values[0].allows(.moveDown))
        XCTAssertTrue(values[0].allows(.select))
        XCTAssertTrue(values[1].allows(.moveUp))
        XCTAssertFalse(values[1].allows(.moveDown))
        XCTAssertFalse(values[1].allows(.remove))
        let filtered = rows(group(), members: [b], reordering: false)[0]
        XCTAssertFalse(filtered.allows(.moveUp))
        XCTAssertTrue(filtered.allows(.remove))
        XCTAssertEqual(filtered.source, "来源二")
    }

    func testReusedCellRestoresSelectionSourceAndActionVisibility() {
        var group = group()
        var child = Line(id: "child", name: "子组", type: "selector")
        child.groupMembers = ["a"]
        group.groupMembers = ["child", "a", "b"]
        let values = rows(group, members: [child, a, b], reordering: true)
        let cell = LineGroupMemberTable.Cell(frame: NSRect(x: 0, y: 0, width: 550, height: 32))
        cell.configure(values[0])
        XCTAssertTrue(cell.row?.isGroup == true)
        XCTAssertEqual(cell.row?.source, "全局组")
        cell.configure(rows(group, members: [b], followed: ["b"])[0])
        cell.layoutSubtreeIfNeeded()
        let buttons = cell.subviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.first?.title, b.name)
        XCTAssertEqual(buttons.first?.state, .off)
        XCTAssertFalse(buttons.contains { !$0.isHidden && ($0.accessibilityLabel()?.hasPrefix("上移") == true || $0.accessibilityLabel()?.hasPrefix("移除") == true || $0.accessibilityLabel()?.hasPrefix("展开") == true) })
        XCTAssertTrue(cell.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "来源二" })
    }

    func testSelectionButtonWaitsForTheModelBeforeCheckingItself() {
        _ = NSApplication.shared // NSControl dispatches actions through NSApp.
        let cell = LineGroupMemberTable.Cell()
        cell.configure(rows(group())[1])
        var calls = 0
        cell.onAction = { action in if case .select = action { calls += 1 } }
        let radio = cell.subviews.compactMap { $0 as? NSButton }.first!
        radio.performClick(nil)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(radio.state, .off)
    }

    func testOldCallbackResolvesStableIDAndLatestPermissionsAfterReorder() {
        var calls: [String] = []
        var value = LineGroupMemberTable(rows: rows(group())) { id, _ in calls.append(id) }
        let coordinator = value.makeCoordinator()
        let cell = coordinator.tableView(NSTableView(), viewFor: nil, row: 0) as! LineGroupMemberTable.Cell
        value = LineGroupMemberTable(rows: rows(group(), members: [b, a], followed: ["a"])) { id, _ in calls.append("updated:" + id) }
        coordinator.update(value)
        cell.onAction?(.select)
        cell.onAction?(.remove)
        XCTAssertEqual(calls, ["updated:a"])
        coordinator.update(LineGroupMemberTable(rows: rows(group(), members: [b]), onAction: value.onAction))
        cell.onAction?(.select)
        XCTAssertEqual(calls, ["updated:a"])
    }

    func testPresentationDoesNotProbeOrChangeThePinnedExit() {
        let store = LineLatencyStore()
        var probes = 0
        store.request = { _, id, _, reply in if id != nil { probes += 1 }; reply(.success([])) }
        var group = group()
        group.groupDefault = "b"
        store.bind(transactionID: "tx", profileID: ProfileLibrary.configurationID, lines: [a, b, group])
        store.accept([ProviderLineLatency(lineID: "a", milliseconds: 23, observedAt: 100, selectedLineID: nil)])
        for _ in 0..<10 {
            let values = rows(group, store: store)
            XCTAssertEqual(values[0].latency.label, "23 ms")
            XCTAssertEqual(values.filter(\.selected).map(\.id), ["b"])
        }
        XCTAssertEqual(probes, 0)
        XCTAssertEqual(group.groupDefault, "b")
    }

    func testStopButtonIsScopedToTheOwningGroup() {
        let store = LineLatencyStore()
        let group = group()
        var other = group
        other.id = "other"
        store.bind(transactionID: "tx", profileID: ProfileLibrary.configurationID, lines: [a, b, group, other])
        let job = store.test([a], profileID: ProfileLibrary.configurationID, group: group,
                             control: .line(a.id, groupID: group.id))
        defer { store.cancel(job) }
        XCTAssertEqual(rows(group, store: store)[0].latency.buttonIcon, "stop.circle")
        XCTAssertTrue(rows(group, store: store)[0].allows(.test))
        XCTAssertEqual(rows(other, store: store)[0].latency.buttonIcon, "arrow.clockwise")
        XCTAssertFalse(rows(other, store: store)[0].allows(.test))
    }

    func testControlsFitLongNamesAndSourcesWithoutOverlapping() {
        var group = group()
        var child = Line(id: "child", name: String(repeating: "长名称", count: 20), type: "selector")
        child.groupMembers = ["a"]
        group.groupMembers = ["child", "a", "b"]
        let cell = LineGroupMemberTable.Cell()
        cell.configure(rows(group, members: [child], reordering: true)[0])
        for width: CGFloat in [420, 550, 900] {
            cell.frame = NSRect(x: 0, y: 0, width: width, height: 32)
            cell.layout()
            let views = cell.subviews.filter { !$0.isHidden }.sorted { $0.frame.minX < $1.frame.minX }
            for view in views { XCTAssertTrue(cell.bounds.contains(view.frame)) }
            for (left, right) in zip(views, views.dropFirst()) { XCTAssertLessThanOrEqual(left.frame.maxX, right.frame.minX) }
        }
    }

    func testThousandMembersKeepOnlyViewportCellsDuringOffscreenScrolling() {
        let members = (0..<1000).map { Line(id: "member-\($0)", name: "香港线路 \($0)", type: "anytls") }
        var group = group()
        group.groupMembers = members.map(\.id)
        let store = LineLatencyStore()
        store.bind(transactionID: "tx", profileID: ProfileLibrary.configurationID, lines: members + [group])
        let projectionStarted = ProcessInfo.processInfo.systemUptime
        let values = rows(group, members: members, store: store)
        let projectionMS = (ProcessInfo.processInfo.systemUptime - projectionStarted) * 1000
        let coordinator = LineGroupMemberTable(rows: values, onAction: { _, _ in }).makeCoordinator()
        let scroll = coordinator.makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 550, height: 224)
        let table = coordinator.table!
        table.reloadData()
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(table.numberOfRows, 1000)
        var maxCells = 0
        let started = ProcessInfo.processInfo.systemUptime
        for index in stride(from: 0, through: 990, by: 30) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(index) * 32))
            scroll.reflectScrolledClipView(scroll.contentView)
            table.layoutSubtreeIfNeeded()
            for row in index..<min(index + 7, 1000) {
                let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? LineGroupMemberTable.Cell
                XCTAssertEqual(cell?.row?.id, members[row].id)
            }
            var count = 0
            table.enumerateAvailableRowViews { _, _ in count += 1 }
            maxCells = max(maxCells, count)
        }
        XCTAssertGreaterThan(maxCells, 0)
        XCTAssertLessThan(maxCells, 40)
        let scrollMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
        let visible = table.view(atColumn: 0, row: 990, makeIfNecessary: false) as! LineGroupMemberTable.Cell
        let origin = scroll.contentView.bounds.origin
        store.accept([ProviderLineLatency(lineID: members[990].id, milliseconds: 19, observedAt: 100, selectedLineID: nil)])
        coordinator.update(LineGroupMemberTable(rows: rows(group, members: members, store: store), onAction: { _, _ in }))
        XCTAssertTrue(table.view(atColumn: 0, row: 990, makeIfNecessary: false) === visible)
        XCTAssertEqual(visible.row?.latency.label, "19 ms")
        XCTAssertEqual(scroll.contentView.bounds.origin, origin)
        XCTAssertNil(table.view(atColumn: 0, row: 0, makeIfNecessary: false))
        print("Group member offscreen scroll: 1000 rows, 34 positions, max resident rows \(maxCells), projection \(projectionMS) ms, scroll \(scrollMS) ms; not a displayed FPS measurement")
    }
}
