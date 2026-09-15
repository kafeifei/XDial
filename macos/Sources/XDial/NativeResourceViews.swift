import SwiftUI

extension Line {
    var memberTypeLabel: String {
        switch type {
        case "selector": return "手动选择组"
        case "urltest": return "测速组"
        case "direct": return "直连"
        default: return type.uppercased()
        }
    }
}

struct LineGroupRow: View {
    @Binding var line: Line
    let onDelete: () -> Void
    @EnvironmentObject var state: AppState
    @State private var showAddMember = false
    private var expanded: Bool {
        get { state.editorPosition.expandedLineIDs.contains(line.id) }
        nonmutating set {
            if newValue { state.editorPosition.expandedLineIDs.insert(line.id) }
            else { state.editorPosition.expandedLineIDs.remove(line.id) }
        }
    }
    private var readOnly: Bool { state.editingRecord.baseline?.lines.contains(where: { $0.id == line.id }) == true }

    var body: some View {
        CollapsibleCard(isExpanded: expanded, onToggle: { expanded.toggle() },
                        onDelete: readOnly ? nil : onDelete,
                        header: {
            Image(systemName: line.type == "urltest" ? "speedometer" : "square.stack.3d.up")
                .foregroundStyle(.secondary)
            Text(line.name).font(.system(size: 13, weight: .medium))
            Spacer()
            Text("\(line.groupMembers.count) 个成员").font(.caption).foregroundStyle(.secondary)
            Text(line.type == "urltest" ? "自动测速" : "手动选择").font(.caption).foregroundStyle(.secondary)
            Text(readOnly ? "订阅" : "自建").font(.caption).foregroundStyle(.secondary)
        }, detail: {
            VStack(alignment: .leading, spacing: 10) {
                TextField("名称", text: $line.name).textFieldStyle(.roundedBorder)
                    .disabled(readOnly).onChange(of: line.name) { state.saveEditingProfile() }
                if line.type == "selector" {
                    Picker("选用成员", selection: $line.groupDefault) {
                        Text("第一条成员").tag("")
                        ForEach(line.groupMembers, id: \.self) { id in
                            Text(state.editingProfile.lines.first { $0.id == id }?.name ?? id).tag(id)
                        }
                    }
                    .disabled(line.groupMembers.isEmpty)
                    .onChange(of: line.groupDefault) { state.saveEditingProfile() }
                } else {
                    Label("运行时自动测速并选用成员", systemImage: "speedometer")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("测速 URL（留空使用默认值）", text: $line.groupURL)
                            .onChange(of: line.groupURL) { state.saveEditingProfile() }
                        TextField("间隔，如 3m", text: $line.groupInterval)
                            .frame(width: 105)
                            .onChange(of: line.groupInterval) { state.saveEditingProfile() }
                    }.textFieldStyle(.roundedBorder).disabled(readOnly)
                }
                Divider()
                HStack {
                    Text("成员 · \(line.groupMembers.count)").foregroundStyle(.secondary)
                    Spacer()
                    if !readOnly {
                        Button { showAddMember = true } label: {
                            Label("添加线路或组", systemImage: "plus")
                        }.buttonStyle(.borderless)
                    }
                }
                if line.groupMembers.isEmpty {
                    Text("尚未添加成员").foregroundStyle(.secondary).padding(.vertical, 6)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(line.groupMembers, id: \.self) { id in
                                memberRow(id)
                            }
                        }
                    }
                    .frame(height: CGFloat(min(line.groupMembers.count, 7)) * 30)
                }
            }.font(.caption)
        })
        .sheet(isPresented: $showAddMember) {
            LineGroupMemberSheet(groupID: line.id)
        }
    }

    private func memberRow(_ id: String) -> some View {
        let member = state.editingProfile.lines.first { $0.id == id }
        return HStack(spacing: 8) {
            Image(systemName: member?.isGroup == true ? "square.stack.3d.up" : "network")
                .foregroundStyle(.secondary).frame(width: 16)
            Text(member?.name ?? "缺失线路：\(id)").lineLimit(1)
            Spacer(minLength: 8)
            Text(member?.memberTypeLabel ?? "引用失效").foregroundStyle(.secondary)
            if !readOnly {
                Button {
                    state.editingProfile.removeLineGroupMember(id, from: line.id)
                    state.saveEditingProfile()
                } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("从组中移除，保留原线路")
                    .accessibilityLabel("移除成员 \(member?.name ?? id)")
            }
        }.frame(height: 30)
    }
}

private struct LineGroupMemberSheet: View {
    let groupID: String
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var error: String?

    private var group: Line? { state.editingProfile.lines.first { $0.id == groupID } }
    private var candidates: [Line] {
        state.editingProfile.lines.filter {
            $0.id != groupID && !(group?.groupMembers.contains($0.id) ?? false) &&
            $0.type != "vpn" && $0.type != "tailscale" &&
            (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) ||
             $0.memberTypeLabel.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("添加到「\(group?.name ?? "线路组")」").font(.headline)
            TextField("搜索线路或组", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(candidates) { member in
                        let issue = state.editingProfile.lineGroupMemberIssue(member.id, addingTo: groupID)
                        HStack(spacing: 10) {
                            Image(systemName: member.isGroup ? "square.stack.3d.up" : "network")
                                .foregroundStyle(.secondary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(member.name).lineLimit(1)
                                if let issue { Text(issue).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 8)
                            Text(member.memberTypeLabel).font(.caption).foregroundStyle(.secondary)
                            Button {
                                do {
                                    try state.editingProfile.addLineGroupMember(member.id, to: groupID)
                                    state.saveEditingProfile()
                                    error = nil
                                } catch { self.error = error.localizedDescription }
                            } label: { Image(systemName: "plus.circle") }
                                .buttonStyle(.borderless).disabled(issue != nil)
                                .accessibilityLabel("添加成员 \(member.name)")
                        }.padding(.vertical, 7)
                    }
                    if candidates.isEmpty {
                        Text(search.isEmpty ? "所有可用成员都已添加" : "没有匹配的线路或组")
                            .foregroundStyle(.secondary).padding(.vertical, 24)
                    }
                }
            }.frame(height: 300)
            if let error { Text(error).font(.caption).foregroundStyle(XDialPalette.danger) }
            HStack {
                Text("已添加 \(group?.groupMembers.count ?? 0) 个成员")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 460)
    }
}

struct NativeRuleEditor: View {
    @Binding var rule: RuleSet
    @EnvironmentObject var state: AppState
    @State private var text = ""
    @State private var error: String?
    private var readOnly: Bool { state.editingRecord.baseline?.matchingResources.contains(where: { $0.id == rule.id }) == true }
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
            TextEditor(text: $text).font(.system(.caption, design: .monospaced))
                .frame(height: 150).disabled(readOnly)
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
            TextEditor(text: $text).font(.system(.caption, design: .monospaced))
                .frame(height: 125).disabled(readOnly)
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
    @EnvironmentObject var state: AppState
    @State private var text = "{}"
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("填写 TLS、传输等附加选项；服务器与凭据使用上方表单。")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(.caption, design: .monospaced)).frame(minHeight: 110)
            if let error { Text(error).font(.caption).foregroundStyle(XDialPalette.danger) }
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
        .onAppear { text = line.nativeOptions?.formatted ?? "{}" }
        .onChange(of: line.nativeOptions) { text = line.nativeOptions?.formatted ?? "{}" }
    }
}
