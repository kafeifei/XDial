import SwiftUI

struct LineGroupRow: View {
    @Binding var line: Line
    let onDelete: () -> Void
    @EnvironmentObject var state: AppState
    @State private var showAddMember = false
    @State private var showSettings = false
    @State private var reordering = false
    @State private var search = ""
    @State private var error: String?
    private var profileID: String { ProfileLibrary.configurationID }
    private var expanded: Bool {
        get { state.editorPosition.expandedLineIDs.contains(line.id) }
        nonmutating set {
            if newValue { state.editorPosition.expandedLineIDs.insert(line.id) }
            else { state.editorPosition.expandedLineIDs.remove(line.id) }
        }
    }
    private var readOnly: Bool { false }
    private func sourceMember(_ id: String) -> Bool {
        guard let source = state.profileLibrary.groupSources[line.id], source.followsMembers else { return false }
        return source.sourceMembers.contains(id)
    }
    private var members: [Line] {
        let catalog = state.configurationCatalog
        return line.groupMembers.compactMap { catalog.line($0) }.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }
    private var choiceLabel: String {
        guard let id = line.chosenGroupMemberID else { return "自动选择" }
        return state.configurationCatalog.line(id)?.name ?? "成员已不存在"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 12)
                        Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary)
                        Text(line.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text("\(line.groupMembers.count)").font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        if !expanded { Text(choiceLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                if !expanded { latency(line, interactive: false) }
                Button { showSettings.toggle(); expanded = true } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 24, height: 24)
                }.buttonStyle(.plain).foregroundStyle(.secondary).help("线路组设置")
                    .accessibilityLabel("设置 \(line.name)")
            }.padding(.horizontal, 12).padding(.vertical, 8)
            if expanded {
                let members = members
                Divider()
                VStack(spacing: 6) {
                    if showSettings { settings }
                    HStack(spacing: 10) {
                        SettingsSearchField("搜索成员", text: $search)
                        LineLatencyBatchButton(store: state.lineLatencies, lines: [line], profileID: profileID, title: "整组测速", control: .group(line.id))
                        if !readOnly {
                            Button { showAddMember = true } label: { Label("添加", systemImage: "plus") }
                            Button { reordering.toggle() } label: { Image(systemName: "arrow.up.arrow.down") }
                                .help(reordering ? "完成排序" : "调整成员顺序")
                        }
                    }.buttonStyle(.borderless).font(.caption).padding(.bottom, 3)
                    automaticSelectionRow
                    Divider()
                    if line.groupMembers.isEmpty {
                        Text("添加线路后，即可自动择优或固定选择一条线路")
                            .foregroundStyle(.secondary).font(.caption).frame(maxWidth: .infinity).padding(.vertical, 18)
                    } else {
                        NativeGroupMembersView(group: line, members: members, state: state,
                            latencies: state.lineLatencies, reordering: reordering && search.isEmpty,
                            select: select, move: move, remove: remove)
                            .frame(height: CGFloat(max(1, min(members.count, 7))) * 32)
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(XDialPalette.danger).frame(maxWidth: .infinity, alignment: .leading) }
                    Divider()
                    HStack(spacing: 6) {
                        GroupTestingCaption(store: state.lineLatencies, line: line, profileID: profileID)
                        Spacer()
                        Text(readOnly ? "订阅" : "本地")
                        if state.editingActiveProfile && state.configDirty { Text("修改待应用").foregroundStyle(XDialPalette.warning) }
                    }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 2)
                }.padding(12)
            }
        }
        .background(XDialPalette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(XDialPalette.divider, lineWidth: 0.75))
        .sheet(isPresented: $showAddMember) { LineGroupMemberSheet(groupID: line.id) }
    }

    private func latency(_ member: Line, interactive: Bool = true) -> some View {
        LineLatencyView(store: state.lineLatencies, line: member, profileID: profileID, group: member.id == line.id ? nil : line, allowsTesting: interactive)
    }

    private var automaticSelectionRow: some View {
        let selected = line.type == "urltest"
        return HStack(spacing: 8) {
            Button { select(nil) } label: {
                HStack(spacing: 8) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? XDialPalette.primaryAction : .secondary).frame(width: 17)
                    Text("自动选择").font(.system(size: 12, weight: .medium))
                    GroupSelectionCaption(store: state.lineLatencies, line: line, profileID: profileID, catalog: state.editingProfile.lines)
                    Spacer(minLength: 4)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("自动选择")
                .accessibilityValue(selected ? "已选择" : "未选择")
            if selected { latency(line, interactive: false) }
            else { Text("未启用").font(.system(size: 10)).foregroundStyle(.secondary) }
            Text("择优").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 30)
        }.buttonStyle(.borderless).padding(.horizontal, 6).frame(height: 32)
            .background(selected ? XDialPalette.selection.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 5))
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SettingsDraftInput($line.name, onCommit: state.saveEditingProfile) { TextField("名称", text: $0) }.disabled(readOnly)
                SettingsDraftInput($line.groupInterval, onCommit: state.saveEditingProfile) { TextField("自动测速间隔，如 3m", text: $0) }.frame(width: 145)
            }
            if let source = state.profileLibrary.groupSources[line.id],
               let record = state.profileLibrary.profiles.first(where: { $0.id == source.profileID }), record.source != nil {
                Toggle("跟随「\(record.name)」的源组成员", isOn: Binding(
                    get: { state.profileLibrary.groupSources[line.id]?.followsMembers == true },
                    set: { state.setGroupFollowsSource(line.id, enabled: $0) }
                ))
            }
            SettingsDraftInput($line.groupURL, onCommit: state.saveEditingProfile) { TextField("自动测速 URL（留空使用默认值）", text: $0) }
            HStack {
                Text(readOnly ? "成员随订阅更新；选线与测速参数可单独修改" : "成员可包含线路或其他线路组")
                    .foregroundStyle(.secondary)
                Spacer()
                if !readOnly { Button("删除线路组", role: .destructive, action: onDelete) }
                Button("完成") { showSettings = false }
            }
            Divider()
        }.font(.caption).textFieldStyle(.roundedBorder)
    }
    private func select(_ memberID: String?) {
        do {
            try state.editingProfile.selectLineGroupMember(memberID, in: line.id)
            state.saveEditingProfile(); error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func remove(_ id: String) {
        guard !readOnly, !sourceMember(id), line.groupMembers.contains(id) else { return }
        state.editingProfile.removeLineGroupMember(id, from: line.id)
        state.saveEditingProfile()
    }
    private func move(_ id: String, by offset: Int) {
        guard !readOnly, !sourceMember(id), let index = line.groupMembers.firstIndex(of: id), line.groupMembers.indices.contains(index + offset) else { return }
        line.groupMembers.swapAt(index, index + offset); state.saveEditingProfile()
    }
}

/// Only this adapter observes measurements for the member list. AppKit cells
/// receive plain display values and never subscribe to application state.
private struct NativeGroupMembersView: View {
    let group: Line
    let members: [Line]
    @ObservedObject var state: AppState
    @ObservedObject var latencies: LineLatencyStore
    let reordering: Bool
    let select: (String?) -> Void
    let move: (String, Int) -> Void
    let remove: (String) -> Void

    var body: some View {
        let source = state.profileLibrary.groupSources[group.id]
        let followedMembers = Set(source?.followsMembers == true ? source?.sourceMembers ?? [] : [])
        let rows = LineGroupMemberTable.rows(group: group, members: members,
            followedMembers: followedMembers, sourceNames: state.configurationCatalog.lineSources,
            globalSourceName: state.tr("全局", "Global"), reordering: reordering, store: latencies)
        LineGroupMemberTable(rows: rows) { id, action in
            guard let currentGroup = state.configurationCatalog.line(group.id),
                  currentGroup.groupMembers.contains(id),
                  let member = state.configurationCatalog.line(id) else { return }
            switch action {
            case .select: select(id)
            case .remove: remove(id)
            case .moveUp: move(id, -1)
            case .moveDown: move(id, 1)
            case .expand:
                if member.isGroup { state.editorPosition.expandedLineIDs.insert(id) }
            case .test:
                let profileID = ProfileLibrary.configurationID
                let control = LineLatencyStore.TestControl.line(id, groupID: group.id)
                if let job = latencies.activeJob(for: control, profileID: profileID) { latencies.cancel(job.id) }
                else { latencies.test([member], profileID: profileID, group: currentGroup, scope: .currentExit, control: control) }
            }
        }
    }
}

private struct GroupTestingCaption: View {
    @ObservedObject var store: LineLatencyStore
    let line: Line
    let profileID: String
    var body: some View {
        if line.type == "urltest" {
            Text("\(store.isAvailable(line, profileID: profileID) ? "自动测速" : "连接后自动测速") · \(line.groupInterval.isEmpty ? "3m" : line.groupInterval)")
        } else { Text("已固定选择 · 测速不会切换线路") }
    }
}

private struct GroupSelectionCaption: View {
    @ObservedObject var store: LineLatencyStore
    let line: Line
    let profileID: String
    let catalog: [Line]
    var body: some View {
        if line.type == "urltest", let fact = store.measurement(line, profileID: profileID),
           let id = fact.selectedLineID, let current = catalog.first(where: { $0.id == id }) {
            Text("\(store.isAvailable(line, profileID: profileID) ? "当前使用" : "本次优选")：\(current.name)")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                .help(store.isAvailable(line, profileID: profileID) ? "sing-box 当前出口" : "sing-box 根据本次测速得出的优选结果，尚未用于连接")
        }
    }
}

private struct LineGroupMemberSheet: View {
    let groupID: String
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selected: Set<String> = []
    @State private var error: String?
    private var group: Line? { state.editingProfile.lines.first { $0.id == groupID } }
    private var candidates: [Line] {
        state.editingProfile.lines.filter {
            $0.id != groupID && !(group?.groupMembers.contains($0.id) ?? false) &&
            $0.type != "vpn" && $0.type != "tailscale" &&
            (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.memberTypeLabel.localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("添加到「\(group?.name ?? "线路组")」").font(.headline)
            HStack {
                SettingsSearchField("搜索线路或组", text: $search)
                LineLatencyBatchButton(store: state.lineLatencies, lines: candidates, profileID: ProfileLibrary.configurationID, control: .candidates(groupID))
            }.buttonStyle(.borderless)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(candidates) { member in
                        candidateRow(member)
                    }
                    if candidates.isEmpty { Text("没有可添加的成员").foregroundStyle(.secondary).padding(.vertical, 24) }
                }.padding(.trailing, 20)
            }.frame(height: 300)
            if let error { Text(error).font(.caption).foregroundStyle(XDialPalette.danger) }
            HStack {
                Text("已选 \(selected.count) 项").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                Button("添加所选") { addSelected() }.keyboardShortcut(.defaultAction).disabled(selected.isEmpty)
            }
        }.padding(20).frame(width: 510)
    }
    private func candidateRow(_ member: Line) -> some View {
        let issue = state.editingProfile.lineGroupMemberIssue(member.id, addingTo: groupID)
        return HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { selected.contains(member.id) }, set: { value in
                if value { selected.insert(member.id) } else { selected.remove(member.id) }
            })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(member.name).lineLimit(1).font(.system(size: 12))
                    if let issue { Text(issue).font(.system(size: 10)).foregroundStyle(.secondary) }
                }
            }.toggleStyle(.checkbox).disabled(issue != nil)
            Spacer(minLength: 8)
            Text(member.isGroup ? "全局组" : state.lineSourceName(member.id)).font(.system(size: 10)).foregroundStyle(.secondary)
            LineLatencyView(store: state.lineLatencies, line: member, profileID: ProfileLibrary.configurationID)
        }.padding(.vertical, 7)
    }
    private func addSelected() {
        do {
            var profile = state.editingProfile
            // Stable catalog order, independent of filtering or checkbox click order.
            for member in profile.lines where selected.contains(member.id) {
                try profile.addLineGroupMember(member.id, to: groupID)
            }
            state.editingProfile = profile; state.saveEditingProfile(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct NativeRuleEditor: View {
    @Binding var rule: RuleSet
    @EnvironmentObject var state: AppState
    @State private var text = ""
    @State private var error: String?
    var readOnly = false
    private var simpleFields: [String]? {
        guard case let .object(fields) = rule.nativeRule, !fields.isEmpty,
              fields.keys.allSatisfy({ NativeMatchFieldEditor.labels[$0] != nil }),
              fields.values.allSatisfy({ value in
                  if case .string = value { return true }
                  if case let .array(items) = value { return items.allSatisfy { if case .string = $0 { return true }; return false } }
                  return false
              }) else { return nil }
        return NativeMatchFieldEditor.keys.filter { fields[$0] != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let fields = simpleFields {
                ForEach(fields, id: \.self) { key in NativeMatchFieldEditor(rule: $rule, fieldKey: key, readOnly: readOnly) }
            } else {
            Text("sing-box 匹配规则").font(.caption).foregroundStyle(.secondary)
            Group {
                if readOnly { SettingsReadOnlyText(text: rule.nativeRule?.formatted ?? "{}", multiline: true) }
                else { TextEditor(text: $text).font(.system(.caption, design: .monospaced)) }
            }.frame(height: 150)
            if let error { Text(error).font(.caption).foregroundStyle(XDialPalette.danger) }
            if !readOnly {
                Button("保存规则") {
                    do {
                        let candidate = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
                        var updated = rule
                        updated.nativeRule = candidate
                        try ProfileDocumentService.validateMatchingContent(updated)
                        rule.nativeRule = candidate
                        state.saveEditingProfile()
                        error = nil
                    } catch { self.error = error.localizedDescription }
                }
            }
            }
        }
        .onAppear { if simpleFields == nil { text = rule.nativeRule?.formatted ?? "{}" } }
        .onChange(of: rule.nativeRule) { if simpleFields == nil { text = rule.nativeRule?.formatted ?? "{}" } }
    }
}

struct NativeMatchFieldEditor: View {
    static let keys = ["domain", "domain_suffix", "domain_keyword", "domain_regex", "ip_cidr"]
    static let labels = ["domain": "完整域名", "domain_suffix": "域名后缀", "domain_keyword": "域名关键词", "domain_regex": "域名正则", "ip_cidr": "IP / 网段"]
    @Binding var rule: RuleSet
    let fieldKey: String
    let readOnly: Bool
    @EnvironmentObject var state: AppState
    @State private var text = ""
    @State private var selectedKey = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if fieldKey == "ip_cidr" { Text("IP / 网段").font(.caption) }
                else {
                    Picker("匹配方式", selection: $selectedKey) {
                        ForEach(Self.keys.filter { $0 != "ip_cidr" }, id: \.self) { key in Text(Self.labels[key]!).tag(key) }
                    }.labelsHidden().frame(width: 150).disabled(readOnly)
                }
                Spacer()
                Text("每行一项").font(.caption).foregroundStyle(.secondary)
            }
            Group {
                if readOnly { SettingsReadOnlyText(text: text, multiline: true) }
                else { TextEditor(text: $text).font(.system(.caption, design: .monospaced)) }
            }.frame(height: 125)
            if let error { Text(error).font(.caption).foregroundStyle(XDialPalette.danger) }
            if !readOnly {
                Button("保存匹配内容") { save() }
            }
        }
        .onAppear { load() }
        .onChange(of: rule.nativeRule) { load() }
    }

    private func load() {
        selectedKey = fieldKey
        guard case let .object(fields) = rule.nativeRule else { return }
        if case let .array(values) = fields[fieldKey] {
            text = values.compactMap { if case let .string(value) = $0 { return value }; return nil }.joined(separator: "\n")
        } else if case let .string(value) = fields[fieldKey] { text = value }
    }

    private func save() {
        do {
            guard case var .object(fields) = rule.nativeRule else { return }
            guard selectedKey == fieldKey || fields[selectedKey] == nil else {
                throw ProfileLibraryError.invalid("已有这种匹配内容，请在对应区域编辑")
            }
            let values = text.split(whereSeparator: \.isNewline).map { RuleSet.sanitizeEntry(String($0)) }.filter { !$0.isEmpty }
            fields.removeValue(forKey: fieldKey)
            fields[selectedKey] = .array(values.map(JSONValue.string))
            let candidate = JSONValue.object(fields)
            var updated = rule
            updated.nativeRule = candidate
            try ProfileDocumentService.validateMatchingContent(updated)
            rule.nativeRule = candidate
            state.saveEditingProfile()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct NativeLineOptionsEditor: View {
    @Binding var line: Line
    var readOnly = false
    @EnvironmentObject var state: AppState
    @State private var text = "{}"
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("填写 TLS、传输等附加选项；服务器与凭据使用上方表单。")
                .font(.caption).foregroundStyle(.secondary)
            Group {
                if readOnly { SettingsReadOnlyText(text: line.nativeOptions?.formatted ?? "{}", multiline: true) }
                else { TextEditor(text: $text).font(.system(.caption, design: .monospaced)) }
            }.frame(minHeight: 110)
            if let error { Text(error).font(.caption).foregroundStyle(XDialPalette.danger) }
            if !readOnly {
            Button("保存高级选项") {
                do {
                    let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
                    guard case .object = value else { throw ProfileLibraryError.invalid("高级选项必须是 JSON 对象") }
                    var profile = state.editingProfile
                    guard let index = profile.lines.firstIndex(where: { $0.id == line.id }) else { return }
                    profile.lines[index].nativeOptions = value
                    try ProfileDocumentService.validate(profile)
                    line.nativeOptions = value
                    state.saveEditingProfile()
                    error = nil
                } catch { self.error = error.localizedDescription }
            }
            }
        }
        .onAppear { text = line.nativeOptions?.formatted ?? "{}" }
        .onChange(of: line.nativeOptions) { text = line.nativeOptions?.formatted ?? "{}" }
    }
}
